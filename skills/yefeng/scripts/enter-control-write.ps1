<#
.SYNOPSIS
Acquires the repository-wide yefeng writer fence.

.DESCRIPTION
The lock records whether this is the one-time Level 1 bootstrap HEAD binding.
That explicit state is the only case in which exit-control-write.ps1 may release
a normal lock without observing a new control commit.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $ControlRoot,

  [Parameter(Mandatory = $true)]
  [string] $ScopeId,

  [Parameter(Mandatory = $true)]
  [string] $WriterId,

  [ValidateRange(30, 3600)]
  [int] $LeaseSeconds = 300,

  [switch] $RecoveryTransition
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

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

function Find-ReparsePointInExistingPathChain([string] $PathValue) {
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
    $parent = Split-Path -Parent $probe
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
    $probe = Normalize-Path $parent
  }
  return $null
}

function Find-UnsupportedPathRoot([string] $PathValue) {
  $fullPath = Normalize-Path $PathValue
  $pathRoot = Normalize-Path ([System.IO.Path]::GetPathRoot($fullPath))
  if ($pathRoot.StartsWith('\\', [System.StringComparison]::Ordinal)) { return "UNC path: $pathRoot" }
  $driveName = $pathRoot.TrimEnd('\').TrimEnd(':')
  $psDrive = Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction Stop
  if (-not [string]::IsNullOrWhiteSpace([string] $psDrive.DisplayRoot)) { return "mapped drive: $pathRoot -> $($psDrive.DisplayRoot)" }
  if (Get-Command subst.exe -ErrorAction SilentlyContinue) {
    $substPrefix = "$($pathRoot.TrimEnd('\'))\:"
    foreach ($line in @(& subst.exe 2>$null)) {
      if ($line.TrimStart().StartsWith($substPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return "SUBST drive: $line" }
    }
  }
  return $null
}

function Test-IsInteger([object] $Value) {
  return (
    $Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or
    $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
  )
}

function ConvertFrom-ControlJson([string] $Json) {
  $convertCommand = Get-Command ConvertFrom-Json -ErrorAction Stop
  if ($convertCommand.Parameters.ContainsKey('DateKind')) {
    return $Json | ConvertFrom-Json -DateKind String -ErrorAction Stop
  }
  return $Json | ConvertFrom-Json -ErrorAction Stop
}

function Assert-ExplicitOffsetTimestamp([string] $Label, [object] $Value) {
  if (
    $Value -isnot [string] -or
    $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$'
  ) { throw "$Label must be an ISO-8601 timestamp with an explicit offset." }
  $parsed = [DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref] $parsed)) {
    throw "$Label is not parseable."
  }
}

function Assert-LocalFenceSchema([object] $LocalFence) {
  $requiredProperties = @(
    'version', 'control_repo_id', 'scope_id', 'run_epoch', 'writer_id',
    'lease_expires_at', 'lock_token', 'recovery_required', 'created_at'
  )
  $actualProperties = @($LocalFence.PSObject.Properties | ForEach-Object { [string] $_.Name })
  $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($name in $requiredProperties) { $null = $expectedSet.Add($name) }
  foreach ($name in $actualProperties) {
    if (-not $expectedSet.Remove($name)) { throw "Local writer fence has an unknown or duplicated property: $name" }
  }
  if ($expectedSet.Count -ne 0 -or $actualProperties.Count -ne $requiredProperties.Count) {
    throw "Local writer fence is missing required properties: $(@($expectedSet) -join ', ')"
  }
  if (-not (Test-IsInteger $LocalFence.version) -or [int64] $LocalFence.version -ne 1) { throw 'Local writer fence version must be integer 1.' }
  if (-not (Test-IsInteger $LocalFence.run_epoch) -or [int64] $LocalFence.run_epoch -lt 1 -or [int64] $LocalFence.run_epoch -gt [int]::MaxValue) { throw 'Local writer fence run_epoch must be a positive 32-bit integer.' }
  foreach ($name in @('control_repo_id', 'scope_id', 'writer_id', 'created_at')) {
    if ($LocalFence.$name -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $LocalFence.$name)) { throw "Local writer fence $name must be a non-empty native String." }
  }
  if ([string] $LocalFence.control_repo_id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Local writer fence control_repo_id is invalid.' }
  if ([string] $LocalFence.scope_id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Local writer fence scope_id is invalid.' }
  if ([string] $LocalFence.writer_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw 'Local writer fence writer_id is invalid.' }
  if ($LocalFence.recovery_required -isnot [bool]) { throw 'Local writer fence recovery_required must be a native Boolean.' }
  foreach ($name in @('lease_expires_at', 'lock_token')) {
    if ($null -ne $LocalFence.$name -and $LocalFence.$name -isnot [string]) { throw "Local writer fence $name must be null or a native String." }
  }
  if (-not [string]::IsNullOrWhiteSpace([string] $LocalFence.lease_expires_at)) { Assert-ExplicitOffsetTimestamp 'Local writer fence lease_expires_at' $LocalFence.lease_expires_at }
  if (-not [string]::IsNullOrWhiteSpace([string] $LocalFence.lock_token) -and [string] $LocalFence.lock_token -notmatch '^[A-Fa-f0-9]{32}$') { throw 'Local writer fence lock_token must be 32 hexadecimal characters when present.' }
  Assert-ExplicitOffsetTimestamp 'Local writer fence created_at' $LocalFence.created_at
}

function Assert-NoReparsePointInTree([string] $Root) {
  $pending = [System.Collections.Generic.Stack[string]]::new()
  $pending.Push((Normalize-Path $Root))
  while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    $directoryItem = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
    if (-not $directoryItem.PSIsContainer -or ($directoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
      throw "Control repository contains a reparse point and cannot provide one safe lifecycle identity: $directory"
    }
    foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
      if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Control repository contains a reparse point and cannot provide one safe lifecycle identity: $($item.FullName)"
      }
      if ($item.PSIsContainer) { $pending.Push($item.FullName) }
    }
  }
}

function Assert-ControlPath([string] $Root, [string] $PathValue, [string] $Label) {
  $rootPath = Normalize-Path $Root
  $fullPath = Normalize-Path $PathValue
  if (-not $fullPath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase) -and -not (Test-PathWithin $fullPath $rootPath)) {
    throw "$Label escapes ControlRoot: $fullPath"
  }
  $reparsePoint = Find-ReparsePointInExistingPathChain $fullPath
  if ($reparsePoint) { throw "$Label traverses a reparse point: $reparsePoint" }
  return $fullPath
}

function Invoke-Git([string] $Root, [string[]] $Arguments) {
  $output = & git -C $Root @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "git -C $Root $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  return ($output -join [Environment]::NewLine).Trim()
}

function Write-Utf8FileAtomically([string] $Path, [string] $Content, [switch] $NoOverwrite) {
  $directory = Split-Path -Parent $Path
  $leaf = Split-Path -Leaf $Path
  $temporaryPath = Join-Path $directory ".$leaf.tmp.$([guid]::NewGuid().ToString('N'))"
  $replacementBackupPath = Join-Path $directory ".$leaf.backup.$([guid]::NewGuid().ToString('N')).tmp"
  $stream = $null
  try {
    $stream = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $bytes = $utf8NoBom.GetBytes($Content)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
    $stream.Dispose()
    $stream = $null
    if ($NoOverwrite) {
      [System.IO.File]::Move($temporaryPath, $Path)
    } elseif ([System.IO.File]::Exists($Path)) {
      [System.IO.File]::Replace($temporaryPath, $Path, $replacementBackupPath)
      Remove-Item -LiteralPath $replacementBackupPath -Force
    } else {
      [System.IO.File]::Move($temporaryPath, $Path)
    }
  } finally {
    if ($stream) { $stream.Dispose() }
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    if (Test-Path -LiteralPath $replacementBackupPath) { Remove-Item -LiteralPath $replacementBackupPath -Force }
  }
}

function Enter-ControlLifecycleGuard([string] $Root) {
  $guardDirectory = Assert-ControlPath $Root (Join-Path $Root '.yefeng\local\locks') 'Lifecycle-guard directory'
  New-Item -ItemType Directory -Path $guardDirectory -Force | Out-Null
  $guardDirectory = Assert-ControlPath $Root $guardDirectory 'Lifecycle-guard directory'
  $guardPath = Assert-ControlPath $Root (Join-Path $guardDirectory 'control-repo.lifecycle.guard') 'Lifecycle guard'
  try {
    return [System.IO.File]::Open(
      $guardPath,
      [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None
    )
  } catch [System.IO.IOException] {
    throw 'Another control lock lifecycle operation is already in progress.'
  }
}

if ($ScopeId -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw "Invalid ScopeId: $ScopeId" }
if ($WriterId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw "Invalid WriterId: $WriterId" }

$controlRootPath = Normalize-Path ((Resolve-Path -LiteralPath $ControlRoot).Path)
$unsupportedControlRoot = Find-UnsupportedPathRoot $controlRootPath
if ($unsupportedControlRoot) { throw "Control repository uses an unsupported path root: $unsupportedControlRoot" }
$controlRootReparsePoint = Find-ReparsePointInExistingPathChain $controlRootPath
if ($controlRootReparsePoint) { throw "ControlRoot traverses a reparse point: $controlRootReparsePoint" }
Assert-NoReparsePointInTree $controlRootPath
$gitTopLevel = Normalize-Path (Invoke-Git $controlRootPath @('rev-parse', '--show-toplevel'))
if (-not $gitTopLevel.Equals($controlRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "ControlRoot is not the control repository top level: $gitTopLevel"
}

$lifecycleGuard = Enter-ControlLifecycleGuard $controlRootPath
try {
Assert-NoReparsePointInTree $controlRootPath
$status = Invoke-Git $controlRootPath @('status', '--short')
if ($status) { throw "Control repository must be clean before acquiring the writer fence: $status" }

$scopeRoot = Assert-ControlPath $controlRootPath (Join-Path $controlRootPath ".yefeng\series\$ScopeId") 'Scope root'
$controlStatePath = Assert-ControlPath $controlRootPath (Join-Path $scopeRoot 'state\control.json') 'Control state'
$localFencePath = Assert-ControlPath $controlRootPath (Join-Path $controlRootPath ".yefeng\local\writer-fences\$ScopeId.json") 'Local writer fence'
$controlHeadPath = Assert-ControlPath $controlRootPath (Join-Path $controlRootPath '.yefeng\local\control-head.json') 'Repository control HEAD state'
if (-not (Test-Path -LiteralPath $controlStatePath -PathType Leaf)) { throw "Missing control state: $controlStatePath" }
if (-not (Test-Path -LiteralPath $localFencePath -PathType Leaf)) { throw "Missing local writer fence: $localFencePath" }
if (-not (Test-Path -LiteralPath $controlHeadPath -PathType Leaf)) { throw "Missing repository control HEAD state: $controlHeadPath" }

$controlState = Get-Content -LiteralPath $controlStatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$originalLocalFenceJson = Get-Content -LiteralPath $localFencePath -Raw -Encoding UTF8
$originalControlHeadJson = Get-Content -LiteralPath $controlHeadPath -Raw -Encoding UTF8
$localFence = ConvertFrom-ControlJson $originalLocalFenceJson
Assert-LocalFenceSchema $localFence
$controlHeadState = $originalControlHeadJson | ConvertFrom-Json -ErrorAction Stop
$actualHead = Invoke-Git $controlRootPath @('rev-parse', 'HEAD')

if ($controlState.scope_id -ne $ScopeId -or $localFence.scope_id -ne $ScopeId) { throw 'Writer fence scope mismatch.' }
if ($controlHeadState.control_repo_id -ne $controlState.control_repo_id) { throw 'Repository control HEAD identity mismatch.' }
if ($controlState.writer_fence.writer_id -ne $WriterId -or $localFence.writer_id -ne $WriterId) { throw 'Writer identity does not own this scope.' }
if ($controlState.run_epoch -ne $controlState.writer_fence.fence_epoch -or $localFence.run_epoch -ne $controlState.run_epoch) {
  throw 'Writer fence epoch mismatch.'
}
if ($controlHeadState.expected_control_head -and $controlHeadState.expected_control_head -ne $actualHead) {
  throw "Control HEAD drift: expected=$($controlHeadState.expected_control_head) actual=$actualHead"
}
if ($localFence.lease_expires_at -or $localFence.lock_token) {
  throw 'A local writer lease already exists; recover or release it before takeover.'
}
if ($localFence.recovery_required -ne [bool] $RecoveryTransition) {
  throw 'Recovery-transition mode does not match the local writer-fence recovery state.'
}

$bootstrapHeadBinding = (
  -not [bool] $RecoveryTransition -and
  [string]::IsNullOrWhiteSpace([string] $controlHeadState.expected_control_head) -and
  [string] $controlState.startup_level -eq 'LEVEL_1_GOVERNANCE_BOOTSTRAP' -and
  [string] $controlState.lifecycle_state -eq 'ACTIVE' -and
  [int] $controlState.run_epoch -eq 1
)

$lockDirectory = Assert-ControlPath $controlRootPath (Join-Path $controlRootPath '.yefeng\local\locks') 'Writer-lock directory'
New-Item -ItemType Directory -Path $lockDirectory -Force | Out-Null
$lockDirectory = Assert-ControlPath $controlRootPath $lockDirectory 'Writer-lock directory'
$lockPath = Assert-ControlPath $controlRootPath (Join-Path $lockDirectory 'control-repo.write.lock') 'Writer lock'
$lockToken = [guid]::NewGuid().ToString('N')
$leaseExpiresAt = [DateTimeOffset]::UtcNow.AddSeconds($LeaseSeconds).ToString('o')
$writerProcess = Get-Process -Id $PID -ErrorAction Stop
if ([int64] $writerProcess.Id -lt 1 -or [int64] $writerProcess.Id -gt [int]::MaxValue) { throw 'Current writer process ID is outside the supported range.' }
$lockPayload = [ordered]@{
  version = 1
  control_repo_id = [string] $controlState.control_repo_id
  scope_id = $ScopeId
  run_epoch = [int] $controlState.run_epoch
  writer_id = $WriterId
  lock_token = $lockToken
  expected_control_head = $actualHead
  lease_expires_at = $leaseExpiresAt
  process_id = [int] $writerProcess.Id
  process_start_time = $writerProcess.StartTime.ToUniversalTime().ToString('o')
  machine_name = [Environment]::MachineName
  recovery_transition = [bool] $RecoveryTransition
  bootstrap_head_binding = [bool] $bootstrapHeadBinding
  acquired_at = [DateTimeOffset]::UtcNow.ToString('o')
}
$lockJson = ($lockPayload | ConvertTo-Json -Depth 10) + "`n"

$lockCreated = $false
try {
  Write-Utf8FileAtomically $lockPath $lockJson -NoOverwrite
  $lockCreated = $true

  $localFence.lease_expires_at = $leaseExpiresAt
  $localFence.lock_token = $lockToken
  $controlHeadState.expected_control_head = $actualHead
  $controlHeadState.updated_at = [DateTimeOffset]::UtcNow.ToString('o')
  Write-Utf8FileAtomically $localFencePath (($localFence | ConvertTo-Json -Depth 10) + "`n")
  Write-Utf8FileAtomically $controlHeadPath (($controlHeadState | ConvertTo-Json -Depth 10) + "`n")
} catch {
  if ($lockCreated) {
    Write-Utf8FileAtomically $localFencePath $originalLocalFenceJson
    Write-Utf8FileAtomically $controlHeadPath $originalControlHeadJson
    if (Test-Path -LiteralPath $lockPath) {
      $createdLock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      if ($createdLock.lock_token -eq $lockToken) { Remove-Item -LiteralPath $lockPath -Force }
    }
  }
  throw
}

$lockPayload | ConvertTo-Json -Depth 10
} finally {
  $lifecycleGuard.Dispose()
}
