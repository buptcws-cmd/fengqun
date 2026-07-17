[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $ControlRoot,

  [Parameter(Mandatory = $true)]
  [string] $ProductRoot,

  [Parameter(Mandatory = $true)]
  [string] $ProjectName,

  [Parameter(Mandatory = $true)]
  [string] $ProjectId,

  [Parameter(Mandatory = $true)]
  [string] $ScopeId,

  [string] $ControlRepoId = "",
  [string] $ProductRepoId = "",
  [string] $ProductBranch = "",
  [string] $ModuleGoal = "Define and deliver the governed module outcome.",
  [string] $TokenBudget = "unspecified",
  [string] $ModuleSoftBudget = "unspecified",
  [ValidateSet('LEVEL_1_GOVERNANCE_BOOTSTRAP')]
  [string] $StartupLevel = 'LEVEL_1_GOVERNANCE_BOOTSTRAP',
  [switch] $BindProductGitConfig
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

function Assert-StableId([string] $Name, [string] $Value) {
  if ($Value -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
    throw "$Name must use lowercase letters, digits, and hyphens and be at most 64 characters: $Value"
  }
}

function Normalize-Path([string] $PathValue) {
  $fullPath = [System.IO.Path]::GetFullPath($PathValue)
  $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
  if ($fullPath.Equals($pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $pathRoot }
  return $fullPath.TrimEnd('\', '/')
}

function Test-PathWithin([string] $Child, [string] $Parent) {
  $childPath = (Normalize-Path $Child) + [System.IO.Path]::DirectorySeparatorChar
  $parentPath = (Normalize-Path $Parent) + [System.IO.Path]::DirectorySeparatorChar
  return $childPath.StartsWith($parentPath, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePointInExistingPathChain([string] $PathValue, [string] $Label) {
  $fullPath = Normalize-Path $PathValue
  $pathRoot = Normalize-Path ([System.IO.Path]::GetPathRoot($fullPath))
  if ($pathRoot.StartsWith('\\', [System.StringComparison]::Ordinal)) {
    throw "$Label uses an unsupported UNC path: $fullPath"
  }
  $driveName = $pathRoot.TrimEnd('\').TrimEnd(':')
  $psDrive = Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction Stop
  if (-not [string]::IsNullOrWhiteSpace([string] $psDrive.DisplayRoot)) {
    throw "$Label uses an unsupported mapped drive: $pathRoot -> $($psDrive.DisplayRoot)"
  }
  if (Get-Command subst.exe -ErrorAction SilentlyContinue) {
    $substPrefix = "$($pathRoot.TrimEnd('\'))\:"
    foreach ($line in @(& subst.exe 2>$null)) {
      if ($line.TrimStart().StartsWith($substPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label uses an unsupported SUBST drive: $line"
      }
    }
  }
  $probe = $fullPath
  $existingProbe = $null

  while ($true) {
    try {
      $null = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
      $existingProbe = $probe
      break
    } catch [System.Management.Automation.ItemNotFoundException] {
      if ($probe.Equals($pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) { break }
      $parent = Split-Path -Parent $probe
      if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
      $probe = Normalize-Path $parent
    }
  }

  if (-not $existingProbe) { throw "$Label has no resolvable existing ancestor: $fullPath" }
  $probe = $existingProbe
  while ($true) {
    $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
      throw "$Label traverses a reparse point and cannot be used for isolated control state: $probe"
    }
    if ($probe.Equals($pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) { break }
    $parent = Split-Path -Parent $probe
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
    $probe = Normalize-Path $parent
  }
}

function Assert-NoReparsePointInTree([string] $Root, [string] $Label) {
  $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
  if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "$Label must be an ordinary directory: $Root"
  }
  foreach ($item in Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop) {
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
      throw "$Label contains a reparse point and is unsafe for recursive copy or cleanup: $($item.FullName)"
    }
  }
}

function Invoke-Git([string] $Root, [string[]] $Arguments) {
  $output = & git -C $Root @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "git -C $Root $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  return ($output -join [Environment]::NewLine).Trim()
}

function Invoke-ProductGitRead([string] $Root, [string[]] $Arguments) {
  $hadValue = Test-Path Env:GIT_OPTIONAL_LOCKS
  $previousValue = $env:GIT_OPTIONAL_LOCKS
  try {
    $env:GIT_OPTIONAL_LOCKS = '0'
    return Invoke-Git $Root $Arguments
  } finally {
    if ($hadValue) { $env:GIT_OPTIONAL_LOCKS = $previousValue }
    else { Remove-Item Env:GIT_OPTIONAL_LOCKS -ErrorAction SilentlyContinue }
  }
}

function ConvertTo-JsonStringContent([string] $Value) {
  $literal = ConvertTo-Json -InputObject ([string] $Value) -Compress
  if ($literal.Length -lt 2 -or $literal[0] -ne '"' -or $literal[$literal.Length - 1] -ne '"') {
    throw 'Failed to serialize a template value as a JSON string.'
  }
  return $literal.Substring(1, $literal.Length - 2)
}

function ConvertFrom-JsonTemplate([string] $Content, [System.Collections.IDictionary] $Values) {
  $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
    param($match)
    $token = $match.Value
    if (-not $Values.Contains($token)) { throw "Unknown JSON template placeholder: $token" }
    return ConvertTo-JsonStringContent ([string] $Values[$token])
  }
  return [regex]::Replace($Content, '__[A-Z0-9_]+__', $evaluator)
}

function ConvertTo-MarkdownPlainText([string] $Value) {
  $rendered = ([string] $Value) -replace "`r`n|`r|`n", ' '
  return $rendered.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function ConvertTo-MarkdownCodeSpan([string] $Value) {
  $rendered = ([string] $Value) -replace "`r`n|`r|`n", ' '
  $longestRun = 0
  foreach ($match in [regex]::Matches($rendered, '`+')) {
    if ($match.Length -gt $longestRun) { $longestRun = $match.Length }
  }
  $delimiter = '`' * ($longestRun + 1)
  return "$delimiter $rendered $delimiter"
}

function ConvertTo-MarkdownTableText([string] $Value) {
  $rendered = ([string] $Value) -replace "`r`n|`r|`n", ' '
  return $rendered.Replace('\', '\\').Replace('|', '\|').Replace('`', '\`').Replace('<', '\<').Replace('>', '\>')
}

function ConvertFrom-MarkdownTemplate([string] $Content, [System.Collections.IDictionary] $Values) {
  $pattern = '`(?<code>__[A-Z0-9_]+__)`|(?<plain>__[A-Z0-9_]+__)'
  $renderedLines = foreach ($line in [regex]::Split($Content, '(?<=\n)')) {
    $isTableLine = $line.TrimStart().StartsWith('|', [System.StringComparison]::Ordinal)
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
      param($match)
      $isCode = $match.Groups['code'].Success
      $token = if ($isCode) { $match.Groups['code'].Value } else { $match.Groups['plain'].Value }
      if (-not $Values.Contains($token)) { throw "Unknown Markdown template placeholder: $token" }
      $value = [string] $Values[$token]
      if ($isCode) { return ConvertTo-MarkdownCodeSpan $value }
      if ($isTableLine) { return ConvertTo-MarkdownTableText $value }
      return ConvertTo-MarkdownPlainText $value
    }
    [regex]::Replace($line, $pattern, $evaluator)
  }
  return ($renderedLines -join '')
}

function Get-LocalGitConfigValues([string] $Root, [string] $Key) {
  $output = @(& git -C $Root config --local --get-all $Key 2>&1)
  $exitCode = $LASTEXITCODE
  if ($exitCode -eq 1) { return }
  if ($exitCode -ne 0) {
    throw "git -C $Root config --local --get-all $Key failed: $($output -join [Environment]::NewLine)"
  }
  return @($output | ForEach-Object { [string] $_ })
}

function Restore-LocalGitConfigValues([string] $Root, [string] $Key, [string[]] $Values) {
  $null = & git -C $Root config --local --unset-all $Key 2>&1
  $unsetExitCode = $LASTEXITCODE
  if ($unsetExitCode -notin @(0, 5)) {
    throw "git -C $Root config --local --unset-all $Key failed with exit code $unsetExitCode"
  }
  foreach ($value in $Values) {
    Invoke-Git $Root @('config', '--local', '--add', $Key, $value) | Out-Null
  }
}

function Assert-StructuredTemplateFiles([string] $Root) {
  foreach ($file in Get-ChildItem -LiteralPath $Root -Force -Recurse -File -Filter '*.json') {
    try { $null = [System.IO.File]::ReadAllText($file.FullName, $utf8NoBom) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Invalid rendered JSON in $($file.FullName): $($_.Exception.Message)" }
  }
  foreach ($file in Get-ChildItem -LiteralPath $Root -Force -Recurse -File -Filter '*.jsonl') {
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($file.FullName, $utf8NoBom)) {
      $lineNumber++
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $null = $line | ConvertFrom-Json -ErrorAction Stop }
      catch { throw "Invalid rendered JSONL in $($file.FullName) at line ${lineNumber}: $($_.Exception.Message)" }
    }
  }
}

Assert-StableId 'ProjectId' $ProjectId
Assert-StableId 'ScopeId' $ScopeId

if ([string]::IsNullOrWhiteSpace($ControlRepoId)) {
  $ControlRepoId = "$ProjectId-control"
}
if ([string]::IsNullOrWhiteSpace($ProductRepoId)) {
  $ProductRepoId = $ProjectId
}

Assert-StableId 'ControlRepoId' $ControlRepoId
Assert-StableId 'ProductRepoId' $ProductRepoId

$productRootPath = Normalize-Path ((Resolve-Path -LiteralPath $ProductRoot).Path)
$null = Assert-NoReparsePointInExistingPathChain $productRootPath 'ProductRoot'
$productTopLevel = Normalize-Path (Invoke-ProductGitRead $productRootPath @('rev-parse', '--show-toplevel'))
if (-not $productRootPath.Equals($productTopLevel, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "ProductRoot must be the product repository top level: $productTopLevel"
}

if ([string]::IsNullOrWhiteSpace($ProductBranch)) {
  $ProductBranch = Invoke-ProductGitRead $productRootPath @('branch', '--show-current')
}
if ([string]::IsNullOrWhiteSpace($ProductBranch)) {
  throw 'ProductBranch is required when the product repository is in detached HEAD state.'
}
$ProductBranch = Invoke-ProductGitRead $productRootPath @('check-ref-format', '--branch', $ProductBranch)
$productBranchRef = "refs/heads/$ProductBranch"
$productBaseline = Invoke-ProductGitRead $productRootPath @('rev-parse', '--verify', "$productBranchRef^{commit}")

$controlRootPath = Normalize-Path $ControlRoot
$null = Assert-NoReparsePointInExistingPathChain $controlRootPath 'ControlRoot'
if (Test-PathWithin $controlRootPath $productRootPath) {
  throw "ControlRoot must not be inside ProductRoot: $controlRootPath"
}
if (Test-PathWithin $productRootPath $controlRootPath) {
  throw "ProductRoot must not be inside ControlRoot: $productRootPath"
}

if (Test-Path -LiteralPath $controlRootPath) {
  throw "ControlRoot must not already exist; refusing to replace even an empty directory: $controlRootPath"
}

$assetRoot = Normalize-Path (Join-Path $PSScriptRoot '..\assets\external-control-repo')
if (-not (Test-Path -LiteralPath $assetRoot -PathType Container)) {
  throw "External control repository asset is missing: $assetRoot"
}
$null = Assert-NoReparsePointInExistingPathChain $assetRoot 'External control repository asset root'
$null = Assert-NoReparsePointInTree $assetRoot 'External control repository asset tree'

$createdAt = [DateTimeOffset]::UtcNow
$createdAtText = $createdAt.ToString('o')
$createdCompact = $createdAt.ToString('yyyyMMddHHmmss')
$writerId = "bootstrap-$createdCompact"
$controlPathJson = $controlRootPath.Replace('\', '/')
$productPathJson = $productRootPath.Replace('\', '/')
$locatorMode = if ($BindProductGitConfig) { 'product-local-git-config' } else { 'prompt-required' }

$replacementValues = [ordered]@{
  '__PROJECT_NAME__' = $ProjectName
  '__PROJECT_ID__' = $ProjectId
  '__SCOPE_ID__' = $ScopeId
  '__CONTROL_REPO_ID__' = $ControlRepoId
  '__CONTROL_ROOT__' = $controlPathJson
  '__LOCATOR_MODE__' = $locatorMode
  '__PRODUCT_REPO_ID__' = $ProductRepoId
  '__PRODUCT_ROOT__' = $productPathJson
  '__PRODUCT_BRANCH__' = $ProductBranch
  '__PRODUCT_BASELINE__' = $productBaseline
  '__MODULE_GOAL__' = $ModuleGoal
  '__TOKEN_BUDGET__' = $TokenBudget
  '__MODULE_SOFT_BUDGET__' = $ModuleSoftBudget
  '__STARTUP_LEVEL__' = $StartupLevel
  '__WRITER_ID__' = $writerId
  '__CREATED_AT__' = $createdAtText
  '__CREATED_COMPACT__' = $createdCompact
}

$controlParent = Split-Path -Parent $controlRootPath
$controlLeaf = Split-Path -Leaf $controlRootPath
if ([string]::IsNullOrWhiteSpace($controlLeaf) -or -not (Test-Path -LiteralPath $controlParent -PathType Container)) {
  throw "ControlRoot must have an existing parent directory and cannot be a filesystem root: $controlRootPath"
}
$null = Assert-NoReparsePointInExistingPathChain $controlParent 'ControlRoot parent'
$stagingRoot = Join-Path $controlParent ".$controlLeaf.yefeng-init-$([guid]::NewGuid().ToString('N'))"
$bindingKeys = @('yefeng.controlRepoId', 'yefeng.controlRoot', 'yefeng.scopeId')
$bindingValues = @($ControlRepoId, $controlPathJson, $ScopeId)
$bindingSnapshots = @{}
$bindingChangedKeys = New-Object System.Collections.Generic.List[string]
if ($BindProductGitConfig) {
  foreach ($bindingKey in $bindingKeys) {
    $bindingSnapshots[$bindingKey] = @(Get-LocalGitConfigValues $productRootPath $bindingKey)
  }
}

try {
  $null = Assert-NoReparsePointInExistingPathChain $controlParent 'ControlRoot parent before staging'
  New-Item -ItemType Directory -Path $stagingRoot | Out-Null
  $null = Assert-NoReparsePointInExistingPathChain $stagingRoot 'ControlRoot staging directory'

  foreach ($item in Get-ChildItem -LiteralPath $assetRoot -Force) {
    Copy-Item -LiteralPath $item.FullName -Destination $stagingRoot -Recurse -Force
  }

  $moduleTemplate = Join-Path $stagingRoot 'docs\modules\SCOPE_TEMPLATE'
  $seriesTemplate = Join-Path $stagingRoot '.yefeng\series\SCOPE_TEMPLATE'
  Move-Item -LiteralPath $moduleTemplate -Destination (Join-Path $stagingRoot "docs\modules\$ScopeId")
  Move-Item -LiteralPath $seriesTemplate -Destination (Join-Path $stagingRoot ".yefeng\series\$ScopeId")

  foreach ($file in Get-ChildItem -LiteralPath $stagingRoot -Force -Recurse -File) {
    $content = [System.IO.File]::ReadAllText($file.FullName, $utf8NoBom)
    $templateTokens = @([regex]::Matches($content, '__[A-Z0-9_]+__') | ForEach-Object { $_.Value } | Select-Object -Unique)
    foreach ($templateToken in $templateTokens) {
      if (-not $replacementValues.Contains($templateToken)) {
        throw "Unknown template placeholder in $($file.FullName): $templateToken"
      }
    }
    $isStructuredJson = [System.IO.Path]::GetExtension($file.Name) -in @('.json', '.jsonl')
    if ($isStructuredJson) {
      $content = ConvertFrom-JsonTemplate $content $replacementValues
    } else {
      $content = ConvertFrom-MarkdownTemplate $content $replacementValues
    }
    [System.IO.File]::WriteAllText($file.FullName, $content, $utf8NoBom)
  }
  Assert-StructuredTemplateFiles $stagingRoot

  $helperRoot = Join-Path $stagingRoot 'scripts\yefeng'
  New-Item -ItemType Directory -Path $helperRoot -Force | Out-Null
  foreach ($helperName in @('enter-control-write.ps1', 'exit-control-write.ps1', 'recover-control-write.ps1', 'prepare-control-writer-takeover.ps1', 'validate-external-control-repo.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $helperName) -Destination (Join-Path $helperRoot $helperName)
  }

  New-Item -ItemType Directory -Path (Join-Path $stagingRoot '.runtime') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $stagingRoot ".yefeng\runs\$ScopeId") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $stagingRoot ".yefeng\outbox\$ScopeId") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $stagingRoot ".yefeng\quarantine\$ScopeId") -Force | Out-Null

  $writerFence = [ordered]@{
    version = 1
    control_repo_id = $ControlRepoId
    scope_id = $ScopeId
    run_epoch = 1
    writer_id = $writerId
    lease_expires_at = $null
    lock_token = $null
    recovery_required = $false
    created_at = $createdAtText
  }
  $writerFencePath = Join-Path $stagingRoot ".yefeng\local\writer-fences\$ScopeId.json"
  New-Item -ItemType Directory -Path (Split-Path -Parent $writerFencePath) -Force | Out-Null
  [System.IO.File]::WriteAllText(
    $writerFencePath,
    ($writerFence | ConvertTo-Json -Depth 10) + "`n",
    $utf8NoBom
  )

  $controlHeadState = [ordered]@{
    version = 1
    control_repo_id = $ControlRepoId
    expected_control_head = $null
    updated_at = $createdAtText
  }
  $controlHeadPath = Join-Path $stagingRoot '.yefeng\local\control-head.json'
  [System.IO.File]::WriteAllText(
    $controlHeadPath,
    ($controlHeadState | ConvertTo-Json -Depth 10) + "`n",
    $utf8NoBom
  )

  $initOutput = & git -C $stagingRoot init -b main 2>&1
  if ($LASTEXITCODE -ne 0) {
    $fallbackOutput = & git -C $stagingRoot init 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "git init failed: $($initOutput -join [Environment]::NewLine); fallback: $($fallbackOutput -join [Environment]::NewLine)"
    }
    Invoke-Git $stagingRoot @('symbolic-ref', 'HEAD', 'refs/heads/main') | Out-Null
  }

  Assert-StructuredTemplateFiles $stagingRoot
  if (Test-Path -LiteralPath $controlRootPath) { throw "ControlRoot appeared during initialization; refusing final move: $controlRootPath" }
  $null = Assert-NoReparsePointInExistingPathChain $controlParent 'ControlRoot parent before final move'
  $null = Assert-NoReparsePointInExistingPathChain $stagingRoot 'ControlRoot staging before final move'
  $null = Assert-NoReparsePointInTree $stagingRoot 'ControlRoot staging tree before final move'
  if ($BindProductGitConfig) {
    for ($bindingIndex = 0; $bindingIndex -lt $bindingKeys.Count; $bindingIndex++) {
      $bindingKey = $bindingKeys[$bindingIndex]
      Invoke-Git $productRootPath @('config', '--local', $bindingKey, $bindingValues[$bindingIndex]) | Out-Null
      $bindingChangedKeys.Add($bindingKey)
    }
  }
  Move-Item -LiteralPath $stagingRoot -Destination $controlRootPath
} catch {
  $initializationError = $_
  $bindingRollbackIssues = New-Object System.Collections.Generic.List[string]
  for ($bindingIndex = $bindingChangedKeys.Count - 1; $bindingIndex -ge 0; $bindingIndex--) {
    $bindingKey = $bindingChangedKeys[$bindingIndex]
    try {
      Restore-LocalGitConfigValues $productRootPath $bindingKey @($bindingSnapshots[$bindingKey])
    } catch {
      $bindingRollbackIssues.Add("$bindingKey`: $($_.Exception.Message)")
    }
  }
  if (Test-Path -LiteralPath $stagingRoot) {
    if (-not (Test-PathWithin $stagingRoot $controlParent)) {
      throw "Refusing unsafe staging cleanup outside control parent: $stagingRoot"
    }
    try {
      $null = Assert-NoReparsePointInExistingPathChain $controlParent 'ControlRoot parent during cleanup'
      $null = Assert-NoReparsePointInExistingPathChain $stagingRoot 'ControlRoot staging during cleanup'
      $null = Assert-NoReparsePointInTree $stagingRoot 'ControlRoot staging tree during cleanup'
      Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    } catch {
      throw "Initialization failed ($($initializationError.Exception.Message)); staging cleanup was refused because path isolation changed: $($_.Exception.Message)"
    }
  }
  if ($bindingRollbackIssues.Count -gt 0) {
    throw "Initialization failed ($($initializationError.Exception.Message)); product Git config rollback also failed: $($bindingRollbackIssues -join '; ')"
  }
  throw $initializationError
}

[ordered]@{
  control_root = $controlRootPath
  control_repo_id = $ControlRepoId
  product_root = $productRootPath
  product_repo_id = $ProductRepoId
  product_branch = $ProductBranch
  product_baseline = $productBaseline
  scope_id = $ScopeId
  locator_mode = $locatorMode
  startup_level = $StartupLevel
  git_initialized = $true
  product_git_config_bound = [bool] $BindProductGitConfig
  roles_launched = 0
} | ConvertTo-Json -Depth 10
