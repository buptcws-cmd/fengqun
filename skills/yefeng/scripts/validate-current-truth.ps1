[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$RegistryPath,

  [ValidateNotNullOrEmpty()]
  [string]$ArchiveIndexPath,

  [ValidateRange(1, 1048576)]
  [int]$MaxBytes = 16384,

  [ValidateRange(1, 10000)]
  [int]$MaxLines = 120,

  [ValidateRange(1, 100000)]
  [int]$MaxLineCharacters = 1000,

  [ValidateRange(0, 1000)]
  [int]$MaxActiveRows = 3,

  [ValidateRange(0, 1000)]
  [int]$MaxTerminalRows = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$issues = [System.Collections.Generic.List[object]]::new()
$resolvedLinks = [System.Collections.Generic.List[string]]::new()
$utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)

function Add-Issue {
  param(
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][string]$Message,
    [AllowNull()][object]$Actual = $null,
    [AllowNull()][object]$Expected = $null,
    [AllowNull()][object]$Line = $null
  )

  $issue = [ordered]@{
    code = $Code
    message = $Message
  }
  if ($null -ne $Actual) { $issue.actual = $Actual }
  if ($null -ne $Expected) { $issue.expected = $Expected }
  if ($null -ne $Line) { $issue.line = $Line }
  $issues.Add([pscustomobject]$issue)
}

function Get-NormalizedFullPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  return [System.IO.Path]::GetFullPath($Path).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
}

function Write-ResultAndExit {
  param(
    [AllowNull()][string]$ResolvedRegistry,
    [AllowNull()][string]$ResolvedArchiveIndex,
    [int]$ByteCount = 0,
    [int]$LineCount = 0,
    [int]$LongestLine = 0,
    [int]$ActiveRows = 0,
    [int]$TerminalRows = 0,
    [int]$LinkCount = 0
  )

  $result = [ordered]@{
    valid = ($issues.Count -eq 0)
    registry_path = $ResolvedRegistry
    archive_index_path = $ResolvedArchiveIndex
    metrics = [ordered]@{
      utf8_bytes = $ByteCount
      lines = $LineCount
      longest_line_characters = $LongestLine
      active_rows = $ActiveRows
      terminal_rows = $TerminalRows
      local_links = $LinkCount
    }
    limits = [ordered]@{
      max_bytes = $MaxBytes
      max_lines = $MaxLines
      max_line_characters = $MaxLineCharacters
      max_active_rows = $MaxActiveRows
      max_terminal_rows = $MaxTerminalRows
    }
    issues = @($issues)
  }

  $result | ConvertTo-Json -Depth 8
  if ($issues.Count -gt 0) { exit 2 }
  exit 0
}

$registryFull = $null
$archiveIndexFull = $null

if (-not [System.IO.Path]::IsPathRooted($RegistryPath)) {
  Add-Issue -Code 'registry_path_not_absolute' -Message 'RegistryPath must be absolute.' -Actual $RegistryPath
}

try {
  $registryFull = Get-NormalizedFullPath -Path $RegistryPath
}
catch {
  Add-Issue -Code 'registry_path_invalid' -Message 'RegistryPath could not be normalized.' -Actual $_.Exception.Message
  Write-ResultAndExit -ResolvedRegistry $null -ResolvedArchiveIndex $null
}

if (-not (Test-Path -LiteralPath $registryFull -PathType Leaf)) {
  Add-Issue -Code 'registry_missing' -Message 'The hot current-truth file does not exist.' -Actual $registryFull
  Write-ResultAndExit -ResolvedRegistry $registryFull -ResolvedArchiveIndex $null
}

$bytes = [System.IO.File]::ReadAllBytes($registryFull)
$text = $null
try {
  $text = $utf8Strict.GetString($bytes)
}
catch {
  Add-Issue -Code 'registry_invalid_utf8' -Message 'The hot current-truth file must be strict UTF-8.' -Actual $_.Exception.Message
  Write-ResultAndExit -ResolvedRegistry $registryFull -ResolvedArchiveIndex $null -ByteCount $bytes.Length
}

if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
  $text = $text.Substring(1)
}

$lines = @([System.Text.RegularExpressions.Regex]::Split($text, "`r`n|`n|`r"))
if ($lines.Count -gt 1 -and $lines[-1] -eq '' -and ($text.EndsWith("`n") -or $text.EndsWith("`r"))) {
  $lines = @($lines[0..($lines.Count - 2)])
}

$lineCount = $lines.Count
$longestLine = 0
if ($lineCount -gt 0) {
  $longestLine = [int](($lines | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum)
}

if ($bytes.Length -gt $MaxBytes) {
  Add-Issue -Code 'registry_too_large' -Message 'The hot current-truth file exceeds its UTF-8 byte budget.' -Actual $bytes.Length -Expected $MaxBytes
}
if ($lineCount -gt $MaxLines) {
  Add-Issue -Code 'registry_too_many_lines' -Message 'The hot current-truth file exceeds its line budget.' -Actual $lineCount -Expected $MaxLines
}

$seenIds = @{}
$activeRows = 0
$terminalRows = 0
$activeStatuses = @('claimed', 'implementation', 'running', 'validation', 'review')
$terminalStatuses = @('done', 'merged', 'closed', 'cancelled', 'canceled', 'archived')
$markdownLinkPattern = [System.Text.RegularExpressions.Regex]::new('\]\((?<target><[^>]+>|[^)]+)\)')

for ($index = 0; $index -lt $lines.Count; $index++) {
  $line = [string]$lines[$index]
  $lineNumber = $index + 1

  if ($line.Length -gt $MaxLineCharacters) {
    Add-Issue -Code 'registry_line_too_long' -Message 'A hot current-truth line exceeds the character budget.' -Actual $line.Length -Expected $MaxLineCharacters -Line $lineNumber
  }

  if ($line -match '^\s*\|.*\|\|\s*[A-Za-z][A-Za-z0-9._/-]{0,63}\s*\|') {
    Add-Issue -Code 'registry_fused_rows' -Message 'A Markdown table line appears to contain two fused rows.' -Line $lineNumber
  }

  $trimmed = $line.Trim()
  if ($trimmed.StartsWith('|') -and $trimmed.EndsWith('|')) {
    $cells = @($trimmed.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
    if ($cells.Count -gt 0) {
      $candidateId = [string]$cells[0]
      $isSeparator = $candidateId -match '^:?-{3,}:?$'
      $isHeader = $candidateId -match '^(?i:id|task|checkpoint|检查点|任务)$'
      if (-not $isSeparator -and -not $isHeader -and $candidateId -match '^[A-Za-z][A-Za-z0-9._/-]{0,63}$') {
        if ($seenIds.ContainsKey($candidateId)) {
          Add-Issue -Code 'registry_duplicate_id' -Message 'A Markdown table checkpoint ID is duplicated.' -Actual $candidateId -Expected $seenIds[$candidateId] -Line $lineNumber
        }
        else {
          $seenIds[$candidateId] = $lineNumber
        }
      }

      $normalizedCells = @($cells | ForEach-Object { $_.ToLowerInvariant() })
      if (@($normalizedCells | Where-Object { $_ -in $activeStatuses }).Count -gt 0) { $activeRows++ }
      if (@($normalizedCells | Where-Object { $_ -in $terminalStatuses }).Count -gt 0) { $terminalRows++ }
    }
  }

  foreach ($match in $markdownLinkPattern.Matches($line)) {
    $target = [string]$match.Groups['target'].Value
    if ($target.StartsWith('<') -and $target.EndsWith('>')) {
      $target = $target.Substring(1, $target.Length - 2)
    }
    else {
      $target = [string](($target -split '\s+')[0])
    }

    $target = $target.Trim()
    if ($target.Length -eq 0 -or $target.StartsWith('#') -or $target -match '^(?i:https?|mailto|ftp|app):') {
      continue
    }

    $pathPart = [string](($target -split '#', 2)[0])
    try { $pathPart = [System.Uri]::UnescapeDataString($pathPart) } catch {}
    if ($pathPart -match '^/[A-Za-z]:[/\\]') { $pathPart = $pathPart.Substring(1) }

    $candidatePaths = [System.Collections.Generic.List[string]]::new()
    $candidatePaths.Add($pathPart)
    if ($pathPart -match '^(?<plain>.+\.[A-Za-z0-9]+):\d+$') {
      $candidatePaths.Add([string]$Matches['plain'])
    }

    $resolved = $null
    foreach ($candidatePath in $candidatePaths) {
      try {
        if ([System.IO.Path]::IsPathRooted($candidatePath)) {
          $possible = Get-NormalizedFullPath -Path $candidatePath
        }
        else {
          $possible = Get-NormalizedFullPath -Path (Join-Path (Split-Path -Parent $registryFull) $candidatePath)
        }
        if (Test-Path -LiteralPath $possible) {
          $resolved = $possible
          break
        }
      }
      catch {}
    }

    if ($null -eq $resolved) {
      Add-Issue -Code 'registry_local_link_missing' -Message 'A local Markdown link does not resolve.' -Actual $target -Line $lineNumber
    }
    else {
      $resolvedLinks.Add($resolved)
    }
  }
}

if ($activeRows -gt $MaxActiveRows) {
  Add-Issue -Code 'registry_too_many_active_rows' -Message 'The hot current-truth table exceeds its active-row budget.' -Actual $activeRows -Expected $MaxActiveRows
}
if ($terminalRows -gt $MaxTerminalRows) {
  Add-Issue -Code 'registry_too_many_terminal_rows' -Message 'The hot current-truth table exceeds its terminal-pointer-row budget.' -Actual $terminalRows -Expected $MaxTerminalRows
}

if ($PSBoundParameters.ContainsKey('ArchiveIndexPath')) {
  if (-not [System.IO.Path]::IsPathRooted($ArchiveIndexPath)) {
    Add-Issue -Code 'archive_index_path_not_absolute' -Message 'ArchiveIndexPath must be absolute.' -Actual $ArchiveIndexPath
  }
  try { $archiveIndexFull = Get-NormalizedFullPath -Path $ArchiveIndexPath }
  catch { Add-Issue -Code 'archive_index_path_invalid' -Message 'ArchiveIndexPath could not be normalized.' -Actual $_.Exception.Message }

  if ($null -ne $archiveIndexFull) {
    if (-not (Test-Path -LiteralPath $archiveIndexFull -PathType Leaf)) {
      Add-Issue -Code 'archive_index_missing' -Message 'The declared archive index does not exist.' -Actual $archiveIndexFull
    }
    elseif (@($resolvedLinks | Where-Object { $_ -ieq $archiveIndexFull }).Count -eq 0) {
      Add-Issue -Code 'archive_index_unlinked' -Message 'The hot current-truth file must link to the declared archive index.' -Actual $archiveIndexFull
    }
  }
}

Write-ResultAndExit `
  -ResolvedRegistry $registryFull `
  -ResolvedArchiveIndex $archiveIndexFull `
  -ByteCount $bytes.Length `
  -LineCount $lineCount `
  -LongestLine $longestLine `
  -ActiveRows $activeRows `
  -TerminalRows $terminalRows `
  -LinkCount $resolvedLinks.Count
