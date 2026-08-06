[CmdletBinding()]
param(
  [string]$ValidatedSourceRoot = 'D:\fengchao-control',
  [Parameter(Mandatory = $true)]
  [string]$DestinationControlRoot,
  [string]$ExpectedCandidate = 'b282e83f746b6aa042e0e724166cb49c05da21e9',
  [switch]$InstallRetentionOnly,
  [Parameter(DontShow = $true)]
  [switch]$TestFailStagingCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-Path([string]$Value) {
  $full = [System.IO.Path]::GetFullPath($Value)
  $root = [System.IO.Path]::GetPathRoot($full)
  if ($full.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $root }
  return $full.TrimEnd('\', '/')
}

function Test-PathWithin([string]$Child, [string]$Parent) {
  $childPath = (Normalize-Path $Child) + [System.IO.Path]::DirectorySeparatorChar
  $parentPath = (Normalize-Path $Parent) + [System.IO.Path]::DirectorySeparatorChar
  return $childPath.StartsWith($parentPath, [System.StringComparison]::OrdinalIgnoreCase)
}

function Find-ReparsePointInExistingPathChain([string]$PathValue) {
  $fullPath = Normalize-Path $PathValue
  $pathRoot = Normalize-Path ([System.IO.Path]::GetPathRoot($fullPath))
  $probe = $fullPath
  while (-not (Test-Path -LiteralPath $probe)) {
    if ($probe.Equals($pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $fullPath }
    $parent = Split-Path -Parent $probe
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { return $fullPath }
    $probe = Normalize-Path $parent
  }
  while ($true) {
    $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $probe }
    if ($probe.Equals($pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) { break }
    $probe = Normalize-Path (Split-Path -Parent $probe)
  }
  return $null
}

function Assert-GitTopLevel([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "Control root does not exist: $Root" }
  if (Find-ReparsePointInExistingPathChain $Root) { throw "Control root traverses a reparse point: $Root" }
  $gitOutput = @(& git -C $Root rev-parse --show-toplevel 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "Control root is not a Git repository: $Root / $($gitOutput -join ' ')" }
  $gitTop = Normalize-Path (($gitOutput -join [Environment]::NewLine).Trim())
  if (-not $gitTop.Equals((Normalize-Path $Root), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Control root is not an exact Git top level: $Root"
  }
}

function Get-LowerHash([string]$PathValue) {
  return (Get-FileHash -LiteralPath $PathValue -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-NormalizedManifestCarrierHash([string]$PathValue) {
  $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
  $text = [System.IO.File]::ReadAllText($PathValue, $strictUtf8)
  $startMarker = '# RETENTION_TRUST_MANIFEST_START'
  $endMarker = '# RETENTION_TRUST_MANIFEST_END'
  $startMatch = [Text.RegularExpressions.Regex]::Match($text, "(?m)^$startMarker`r?$")
  $endMatch = [Text.RegularExpressions.Regex]::Match($text, "(?m)^$endMarker`r?$")
  if (-not $startMatch.Success -or -not $endMatch.Success -or $endMatch.Index -le $startMatch.Index) {
    throw "Retention manifest carrier markers are missing or out of order: $PathValue"
  }
  $startIndex = $startMatch.Index
  $blockLength = ($endMatch.Index + $endMatch.Length) - $startIndex
  $block = $text.Substring($startIndex, $blockLength)
  $hashPattern = "(?i)'[0-9a-f]{64}'"
  $matches = [Text.RegularExpressions.Regex]::Matches($block, $hashPattern)
  if ($matches.Count -ne 5) {
    throw "Retention manifest carrier must contain exactly five fixed hash slots: $PathValue"
  }
  $normalizedBlock = [Text.RegularExpressions.Regex]::Replace($block, $hashPattern, ("'" + ('0' * 64) + "'"))
  $normalizedText = $text.Substring(0, $startIndex) + $normalizedBlock + $text.Substring($startIndex + $blockLength)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($strictUtf8.GetBytes($normalizedText)))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-RetentionArtifactHash([string]$PathValue, [string]$FileName) {
  if ($FileName -in @('install-governed-runner.ps1', 'validate-run-evidence-retention.ps1')) {
    return Get-NormalizedManifestCarrierHash $PathValue
  }
  return Get-LowerHash $PathValue
}

function Assert-RetentionManifestCarrierMatches(
  [string]$PathValue,
  [System.Collections.IDictionary]$ExpectedManifest
) {
  $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
  $text = [System.IO.File]::ReadAllText($PathValue, $strictUtf8)
  $startMatches = [Text.RegularExpressions.Regex]::Matches($text, '(?m)^# RETENTION_TRUST_MANIFEST_START\r?$')
  $endMatches = [Text.RegularExpressions.Regex]::Matches($text, '(?m)^# RETENTION_TRUST_MANIFEST_END\r?$')
  if ($startMatches.Count -ne 1 -or $endMatches.Count -ne 1) {
    throw "Retention manifest carrier must contain one unique marker pair: $PathValue"
  }
  $startMatch = $startMatches[0]
  $endMatch = $endMatches[0]
  if ($endMatch.Index -le $startMatch.Index) {
    throw "Retention manifest carrier markers are out of order: $PathValue"
  }
  $block = $text.Substring(
    $startMatch.Index,
    ($endMatch.Index + $endMatch.Length) - $startMatch.Index
  )
  $matches = [Text.RegularExpressions.Regex]::Matches(
    $block,
    "(?m)^\s*'([^']+)'\s*=\s*'([0-9a-f]{64})'\s*$"
  )
  if ($matches.Count -ne 5) {
    throw "Retention manifest carrier must contain exactly five named hash entries: $PathValue"
  }
  $actualManifest = @{}
  foreach ($match in $matches) {
    $name = [string]$match.Groups[1].Value
    if ($actualManifest.ContainsKey($name)) {
      throw "Retention manifest carrier contains a duplicate entry: $name"
    }
    $actualManifest[$name] = [string]$match.Groups[2].Value
  }
  foreach ($entry in $ExpectedManifest.GetEnumerator()) {
    if (
      -not $actualManifest.ContainsKey([string]$entry.Key) -or
      [string]$actualManifest[[string]$entry.Key] -cne [string]$entry.Value
    ) {
      throw "Retention manifest carrier values disagree: $PathValue / $($entry.Key)"
    }
  }
}

$runnerManifest = [ordered]@{
  'scripts/yefeng/lib/runner-common.ps1' = '6de0eb2e4c7c8f0b46757a8e33eab66f5ca1608dc53ddc0f3242ded4b805be30'
  'scripts/yefeng/role-runner.ps1' = '3b763560b02a47bbd92cde20d5f07b05563ac75958707b5f65b9899feaa96d7b'
  'scripts/yefeng/run-backend-worker.ps1' = '9ed435941b5a9ce1212e1be4ce199be8b1a12250a87ac04feeda377be64f27b0'
  'scripts/yefeng/runner-policy.json' = '0b69a1754299e5b9b8e14d5866552e95cac002b6c3c04ecb2812ed833dc8c5c4'
  'scripts/yefeng/test-runner-contract.ps1' = '52efc0d51126cc8960839777728a7926e1e8fb76e8d2b47a87c9307707a9e9b8'
  'scripts/yefeng/test-runner-governance.ps1' = 'f7650e813d428672fb5c37393dae834cd7b61fc5310efd5168c3c86773698af1'
  'scripts/yefeng/test-runner-process-cleanup.ps1' = '60f7c5f02effb7f8515b17998def361d49bf8fe9153936d1ea003756e9b96604'
}
# RETENTION TRUST INVARIANT (keep this comment identical in both carriers):
# The marked block must contain exactly five single-quoted 64-hex value slots.
# Adding a sixth slot or moving a trusted hash outside the block must fail tests.
# RETENTION_TRUST_MANIFEST_START
$retentionManifest = [ordered]@{
  'compact-run-evidence.ps1' = 'b3fe0a438bed444c2ba4bf38ed1459c86ec1efaf3de2fc7f2f2105289954b01b'
  'run-retention-policy.json' = '295df97cd07341663fe1716f310c372fccaaed7a553c560c2e364c91d93dcb4b'
  'test-run-evidence-retention.ps1' = '05878f93394555a85baca1618d4ec652e2222bbd9fe05fe6bee31c0b3e2ee91f'
  'install-governed-runner.ps1' = '6893bee6c2703671551880ac404b9ff36cbe66146e7346680b90cdfd7c6e8cd0'
  'validate-run-evidence-retention.ps1' = 'a536cc130ff796a2b96e285cddf4763dd7245202519827afe2459d0df6440eef'
}
# RETENTION_TRUST_MANIFEST_END

$destinationRoot = Normalize-Path $DestinationControlRoot
Assert-GitTopLevel $destinationRoot

# Validate every source artifact before the first destination write.
$retentionSources = [ordered]@{}
foreach ($entry in $retentionManifest.GetEnumerator()) {
  $sourcePath = Normalize-Path (Join-Path $PSScriptRoot $entry.Key)
  if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Bundled retention helper is missing: $($entry.Key)" }
  if (Find-ReparsePointInExistingPathChain $sourcePath) { throw "Bundled retention helper traverses a reparse point: $($entry.Key)" }
  $actualHash = Get-RetentionArtifactHash $sourcePath ([string] $entry.Key)
  if ($actualHash -cne $entry.Value) { throw "Bundled retention helper hash mismatch: $($entry.Key)" }
  $retentionSources[$entry.Key] = $sourcePath
}
foreach ($carrierName in @('install-governed-runner.ps1', 'validate-run-evidence-retention.ps1')) {
  Assert-RetentionManifestCarrierMatches ([string]$retentionSources[$carrierName]) $retentionManifest
}

$sourceRoot = ''
if (-not $InstallRetentionOnly) {
  $sourceRoot = Normalize-Path $ValidatedSourceRoot
  Assert-GitTopLevel $sourceRoot
  & git -C $sourceRoot cat-file -e "$ExpectedCandidate^{commit}"
  if ($LASTEXITCODE -ne 0) { throw "Validated candidate does not exist: $ExpectedCandidate" }
  foreach ($entry in $runnerManifest.GetEnumerator()) {
    $sourcePath = Join-Path $sourceRoot $entry.Key
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Validated runner file is missing: $($entry.Key)" }
    if ((Get-LowerHash $sourcePath) -cne $entry.Value) { throw "Validated runner hash changed: $($entry.Key)" }
  }
}

$destinationScriptsRoot = Normalize-Path (Join-Path $destinationRoot 'scripts\yefeng')
if (-not (Test-PathWithin $destinationScriptsRoot $destinationRoot)) { throw 'Destination scripts root escaped control repository.' }
if (Find-ReparsePointInExistingPathChain $destinationScriptsRoot) { throw "Destination scripts root traverses a reparse point: $destinationScriptsRoot" }
if (-not (Test-Path -LiteralPath $destinationScriptsRoot)) {
  New-Item -ItemType Directory -Path $destinationScriptsRoot -Force | Out-Null
}

if (-not $InstallRetentionOnly) {
  foreach ($entry in $runnerManifest.GetEnumerator()) {
    $sourcePath = Join-Path $sourceRoot $entry.Key
    $destinationPath = Join-Path $destinationRoot $entry.Key
    $destinationParent = Split-Path -Parent $destinationPath
    if (-not (Test-Path -LiteralPath $destinationParent)) { New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null }
    [System.IO.File]::Copy($sourcePath, $destinationPath, $true)
  }
}

$stagingRoot = Normalize-Path (Join-Path $destinationScriptsRoot ('.retention-install-' + [Guid]::NewGuid().ToString('N')))
$newRoot = Join-Path $stagingRoot 'new'
$backupRoot = Join-Path $stagingRoot 'backup'
$replaceBackupRoot = Join-Path $stagingRoot 'replace-backup'
$originallyPresent = @{}
$originalRawHashes = @{}
$replaceStarted = $false
$stagingCleanupWarning = ''
try {
  New-Item -ItemType Directory -Path $newRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $replaceBackupRoot -Force | Out-Null

  # Stage and validate the complete new trust chain before inspecting or
  # mutating any destination leaf. This also makes source=destination refresh
  # safe because every source byte is detached before the first replace.
  foreach ($entry in $retentionManifest.GetEnumerator()) {
    $stagedPath = Join-Path $newRoot $entry.Key
    [System.IO.File]::Copy([string] $retentionSources[$entry.Key], $stagedPath, $false)
    if ((Get-RetentionArtifactHash $stagedPath ([string] $entry.Key)) -cne $entry.Value) {
      throw "Staged retention helper hash mismatch: $($entry.Key)"
    }
  }

  # Prepare and verify every backup before the first replace. A directory or
  # other non-leaf at an exact destination blocks the entire transaction.
  foreach ($entry in $retentionManifest.GetEnumerator()) {
    $destinationPath = Join-Path $destinationScriptsRoot $entry.Key
    $exists = Test-Path -LiteralPath $destinationPath
    $originallyPresent[$entry.Key] = $exists -and (Test-Path -LiteralPath $destinationPath -PathType Leaf)
    if ($exists -and -not $originallyPresent[$entry.Key]) {
      throw "Destination retention helper is not an ordinary leaf: $($entry.Key)"
    }
    if ($originallyPresent[$entry.Key]) {
      if (Find-ReparsePointInExistingPathChain $destinationPath) { throw "Destination retention helper traverses a reparse point: $($entry.Key)" }
      $backupPath = Join-Path $backupRoot $entry.Key
      $originalRawHashes[$entry.Key] = Get-LowerHash $destinationPath
      [System.IO.File]::Copy($destinationPath, $backupPath, $false)
      if ((Get-LowerHash $backupPath) -cne $originalRawHashes[$entry.Key]) {
        throw "Destination retention helper backup mismatch: $($entry.Key)"
      }
    }
  }

  $replaceStarted = $true
  foreach ($entry in $retentionManifest.GetEnumerator()) {
    $stagedPath = Join-Path $newRoot $entry.Key
    $destinationPath = Join-Path $destinationScriptsRoot $entry.Key
    if ($originallyPresent[$entry.Key]) {
      [System.IO.File]::Replace($stagedPath, $destinationPath, (Join-Path $replaceBackupRoot $entry.Key))
    } else {
      [System.IO.File]::Move($stagedPath, $destinationPath)
    }
    if ((Get-RetentionArtifactHash $destinationPath ([string] $entry.Key)) -cne $entry.Value) {
      throw "Installed retention helper hash mismatch: $($entry.Key)"
    }
  }
} catch {
  $installError = $_
  if (-not $replaceStarted) {
    throw $installError
  }
  $rollbackErrors = [System.Collections.Generic.List[string]]::new()
  $manifestNames = @($retentionManifest.Keys)
  for ($index = $manifestNames.Count - 1; $index -ge 0; $index--) {
    $fileName = [string] $manifestNames[$index]
    $destinationPath = Join-Path $destinationScriptsRoot $fileName
    try {
      if ($originallyPresent.ContainsKey($fileName) -and $originallyPresent[$fileName]) {
        $backupPath = Join-Path $backupRoot $fileName
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
          throw "Prepared backup is missing: $fileName"
        }
        $alreadyOriginal = (
          (Test-Path -LiteralPath $destinationPath -PathType Leaf) -and
          (Get-LowerHash $destinationPath) -ceq [string] $originalRawHashes[$fileName]
        )
        if (-not $alreadyOriginal) {
          if (Test-Path -LiteralPath $destinationPath) {
            if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
              throw "Rollback destination is not an ordinary leaf: $fileName"
            }
            $rollbackSource = Join-Path $newRoot ($fileName + '.rollback')
            [System.IO.File]::Copy($backupPath, $rollbackSource, $false)
            [System.IO.File]::Replace($rollbackSource, $destinationPath, (Join-Path $replaceBackupRoot ($fileName + '.failed')))
          } else {
            [System.IO.File]::Copy($backupPath, $destinationPath, $false)
          }
        }
        if ((Get-LowerHash $destinationPath) -cne [string] $originalRawHashes[$fileName]) {
          throw "Rollback content mismatch: $fileName"
        }
      } elseif (Test-Path -LiteralPath $destinationPath) {
        if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
          throw "Rollback cannot remove a non-leaf destination: $fileName"
        }
        Remove-Item -LiteralPath $destinationPath -Force
      }
    } catch {
      $rollbackErrors.Add("$fileName / $($_.Exception.Message)")
    }
  }
  if ($rollbackErrors.Count -gt 0) {
    throw "Retention installation failed: $($installError.Exception.Message). Rollback also failed: $($rollbackErrors -join '; ')"
  }
  throw $installError
} finally {
  if (Test-Path -LiteralPath $stagingRoot) {
    try {
      if ($TestFailStagingCleanup) {
        throw 'Injected staging cleanup failure.'
      }
      if (-not (Test-PathWithin $stagingRoot $destinationScriptsRoot) -or (Find-ReparsePointInExistingPathChain $stagingRoot)) {
        throw "Refusing unsafe staging cleanup: $stagingRoot"
      }
      Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    } catch {
      $stagingCleanupWarning = "Retention staging cleanup failed at '$stagingRoot': $($_.Exception.Message)"
      Write-Warning $stagingCleanupWarning
    }
  }
}

[pscustomobject]@{
  installed = $true
  retention_only = [bool] $InstallRetentionOnly
  source_root = $sourceRoot
  source_candidate = $(if ($InstallRetentionOnly) { '' } else { $ExpectedCandidate })
  destination_root = $destinationRoot
  runner_files = $(if ($InstallRetentionOnly) { @() } else { @($runnerManifest.Keys) })
  retention_manifest = $retentionManifest
  staging_cleanup_warning = $stagingCleanupWarning
} | ConvertTo-Json -Depth 5
