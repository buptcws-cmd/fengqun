<#
.SYNOPSIS
Verifies one fenced control commit and releases the repository-wide writer lock.

.DESCRIPTION
Normal writers must publish exactly one direct-child control commit. The sole
zero-commit exception is a lock explicitly marked bootstrap_head_binding by
enter-control-write.ps1 while binding the first Level 1 bootstrap HEAD.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $ControlRoot,

  [Parameter(Mandatory = $true)]
  [string] $ScopeId,

  [Parameter(Mandatory = $true)]
  [string] $WriterId,

  [Parameter(Mandatory = $true)]
  [string] $LockToken,

  [Parameter(Mandatory = $true)]
  [string] $ExpectedControlHead,

  [string] $ReplacementWriterId = "",
  [int] $ReplacementRunEpoch = 0
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$terminalRoleStates = @('DONE', 'FAILED', 'EXPIRED')
$terminalRunStates = @('DONE', 'FAILED', 'EXIT_UNKNOWN', 'EXPIRED')
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

function Assert-StableId([string] $Name, [string] $Value) {
  if ($Value -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw "Invalid ${Name}: $Value" }
}

function Assert-WriterId([string] $Name, [string] $Value) {
  if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw "Invalid ${Name}: $Value" }
}

function Test-IsInteger([object] $Value) {
  return (
    $Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or
    $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
  )
}

function ConvertFrom-LockTimestamp([string] $Name, [object] $Value) {
  if (
    $Value -isnot [string] -or
    $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$'
  ) { throw "Writer lock $Name must be an ISO-8601 timestamp with an explicit offset." }
  $parsed = [DateTimeOffset]::MinValue
  $parsedSuccessfully = [DateTimeOffset]::TryParse(
    $Value,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::RoundtripKind,
    [ref] $parsed
  )
  if (-not $parsedSuccessfully) { throw "Writer lock $Name is not parseable." }
  return $parsed
}

function ConvertFrom-WriterLockJson([string] $Json) {
  $convertCommand = Get-Command ConvertFrom-Json -ErrorAction Stop
  if ($convertCommand.Parameters.ContainsKey('DateKind')) {
    return $Json | ConvertFrom-Json -DateKind String -ErrorAction Stop
  }
  return $Json | ConvertFrom-Json -ErrorAction Stop
}

function Assert-WriterLockSchema([object] $Lock) {
  $requiredProperties = @(
    'version', 'control_repo_id', 'scope_id', 'run_epoch', 'writer_id', 'lock_token',
    'expected_control_head', 'lease_expires_at', 'process_id', 'process_start_time',
    'machine_name', 'recovery_transition', 'bootstrap_head_binding', 'acquired_at'
  )
  $actualProperties = @($Lock.PSObject.Properties | ForEach-Object { $_.Name })
  $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($name in $requiredProperties) { $null = $expectedSet.Add($name) }
  foreach ($name in $actualProperties) {
    if (-not $expectedSet.Remove([string] $name)) { throw "Writer lock has an unknown or duplicated property: $name" }
  }
  if ($expectedSet.Count -ne 0 -or $actualProperties.Count -ne $requiredProperties.Count) {
    throw "Writer lock is missing required properties: $(@($expectedSet) -join ', ')"
  }
  if (-not (Test-IsInteger $Lock.version) -or [int64] $Lock.version -ne 1) { throw 'Writer lock version must be integer 1.' }
  if (-not (Test-IsInteger $Lock.run_epoch) -or [int64] $Lock.run_epoch -lt 1 -or [int64] $Lock.run_epoch -gt [int]::MaxValue) { throw 'Writer lock run_epoch must be a positive 32-bit integer.' }
  if (-not (Test-IsInteger $Lock.process_id) -or [int64] $Lock.process_id -lt 1 -or [int64] $Lock.process_id -gt [int]::MaxValue) { throw 'Writer lock process_id must be a positive 32-bit integer.' }
  foreach ($name in @('control_repo_id', 'scope_id', 'writer_id', 'lock_token', 'expected_control_head', 'lease_expires_at', 'process_start_time', 'machine_name', 'acquired_at')) {
    if ($Lock.$name -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $Lock.$name)) { throw "Writer lock $name must be a non-empty native String." }
  }
  Assert-StableId 'control_repo_id' ([string] $Lock.control_repo_id)
  Assert-StableId 'scope_id' ([string] $Lock.scope_id)
  Assert-WriterId 'writer_id' ([string] $Lock.writer_id)
  if ([string] $Lock.lock_token -notmatch '^[A-Fa-f0-9]{32}$') { throw 'Writer lock lock_token must be 32 hexadecimal characters.' }
  if ([string] $Lock.expected_control_head -notmatch '^[A-Fa-f0-9]{40,64}$') { throw 'Writer lock expected_control_head must be a full Git object ID.' }
  if ($Lock.recovery_transition -isnot [bool]) { throw 'Writer lock recovery_transition must be a native Boolean.' }
  if ($Lock.bootstrap_head_binding -isnot [bool]) { throw 'Writer lock bootstrap_head_binding must be a native Boolean.' }
  $null = ConvertFrom-LockTimestamp 'lease_expires_at' $Lock.lease_expires_at
  $null = ConvertFrom-LockTimestamp 'process_start_time' $Lock.process_start_time
  $null = ConvertFrom-LockTimestamp 'acquired_at' $Lock.acquired_at
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
  Assert-StableId 'local writer fence control_repo_id' ([string] $LocalFence.control_repo_id)
  Assert-StableId 'local writer fence scope_id' ([string] $LocalFence.scope_id)
  Assert-WriterId 'local writer fence writer_id' ([string] $LocalFence.writer_id)
  if ($LocalFence.recovery_required -isnot [bool]) { throw 'Local writer fence recovery_required must be a native Boolean.' }
  foreach ($name in @('lease_expires_at', 'lock_token')) {
    if ($null -ne $LocalFence.$name -and $LocalFence.$name -isnot [string]) { throw "Local writer fence $name must be null or a native String." }
  }
  if (-not [string]::IsNullOrWhiteSpace([string] $LocalFence.lease_expires_at)) { $null = ConvertFrom-LockTimestamp 'local writer fence lease_expires_at' $LocalFence.lease_expires_at }
  if (-not [string]::IsNullOrWhiteSpace([string] $LocalFence.lock_token) -and [string] $LocalFence.lock_token -notmatch '^[A-Fa-f0-9]{32}$') { throw 'Local writer fence lock_token must be 32 hexadecimal characters when present.' }
  $null = ConvertFrom-LockTimestamp 'local writer fence created_at' $LocalFence.created_at
}

function Get-Sha256Hex([string] $Value) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($utf8NoBom.GetBytes($Value)))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Get-PropertyNames([object] $Object) {
  if ($null -eq $Object) { return @() }
  return @($Object.PSObject.Properties | ForEach-Object { [string] $_.Name })
}

function Assert-ExactIdSet([string] $Label, [string[]] $Expected, [string[]] $Actual) {
  $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($id in $Expected) {
    if (-not $expectedSet.Add($id)) { throw "$Label expected identity is duplicated: $id" }
  }
  $actualSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($id in $Actual) {
    if (-not $actualSet.Add($id)) { throw "$Label actual identity is duplicated: $id" }
  }
  if (-not $expectedSet.SetEquals($actualSet)) {
    throw "$Label identity set mismatch: expected=$(@($expectedSet) -join ',') actual=$(@($actualSet) -join ',')"
  }
}

function Invoke-Git([string] $Root, [string[]] $Arguments) {
  $output = & git -C $Root @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "git -C $Root $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  return ($output -join [Environment]::NewLine).Trim()
}

function Write-Utf8FileAtomically([string] $Path, [string] $Content) {
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
    if ([System.IO.File]::Exists($Path)) {
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

Assert-StableId 'ScopeId' $ScopeId
Assert-WriterId 'WriterId' $WriterId
if ($LockToken -notmatch '^[A-Fa-f0-9]{32}$') { throw 'LockToken must be a 32-character hexadecimal token.' }
if ($ExpectedControlHead -notmatch '^[A-Fa-f0-9]{40,64}$') { throw 'ExpectedControlHead must be a full Git object ID.' }
if (-not [string]::IsNullOrWhiteSpace($ReplacementWriterId)) { Assert-WriterId 'ReplacementWriterId' $ReplacementWriterId }
if ($ReplacementRunEpoch -lt 0) { throw 'ReplacementRunEpoch cannot be negative.' }

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
$scopeRoot = Assert-ControlPath $controlRootPath (Join-Path $controlRootPath ".yefeng\series\$ScopeId") 'Scope root'
$controlStatePath = Assert-ControlPath $controlRootPath (Join-Path $scopeRoot 'state\control.json') 'Control state'
$localFencePath = Assert-ControlPath $controlRootPath (Join-Path $controlRootPath ".yefeng\local\writer-fences\$ScopeId.json") 'Local writer fence'
$controlHeadPath = Assert-ControlPath $controlRootPath (Join-Path $controlRootPath '.yefeng\local\control-head.json') 'Repository control HEAD state'
$lockPath = Assert-ControlPath $controlRootPath (Join-Path $controlRootPath '.yefeng\local\locks\control-repo.write.lock') 'Writer lock'
foreach ($required in @($controlStatePath, $localFencePath, $controlHeadPath, $lockPath)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing writer-fence file: $required" }
}

$controlState = Get-Content -LiteralPath $controlStatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$localFence = ConvertFrom-WriterLockJson (Get-Content -LiteralPath $localFencePath -Raw -Encoding UTF8)
Assert-LocalFenceSchema $localFence
$controlHeadState = Get-Content -LiteralPath $controlHeadPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$lockJson = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
$lock = ConvertFrom-WriterLockJson $lockJson
Assert-WriterLockSchema $lock
$authoritativeLockToken = [string] $lock.lock_token
$isRecoveryTransition = [bool] $lock.recovery_transition
$isBootstrapHeadBinding = [bool] $lock.bootstrap_head_binding

if ($lock.scope_id -ne $ScopeId -or $localFence.scope_id -ne $ScopeId -or $controlState.scope_id -ne $ScopeId) { throw 'Writer fence scope mismatch.' }
if ($lock.control_repo_id -ne $controlState.control_repo_id -or $controlHeadState.control_repo_id -ne $controlState.control_repo_id -or $localFence.control_repo_id -ne $controlState.control_repo_id) { throw 'Control repository identity mismatch.' }
if ($lock.machine_name -ne [Environment]::MachineName) { throw 'Writer lock belongs to a different machine.' }
if ($lock.writer_id -ne $WriterId -or $localFence.writer_id -ne $WriterId) { throw 'Writer identity mismatch.' }
if (
  -not [string]::Equals($authoritativeLockToken, $LockToken, [System.StringComparison]::Ordinal) -or
  -not [string]::Equals([string] $localFence.lock_token, $authoritativeLockToken, [System.StringComparison]::Ordinal)
) { throw 'Writer lock token mismatch.' }
if ($localFence.lease_expires_at -ne $lock.lease_expires_at -or $localFence.recovery_required -ne $isRecoveryTransition) { throw 'Local writer lease/recovery mode mismatch.' }
if ($lock.expected_control_head -ne $ExpectedControlHead -or $controlHeadState.expected_control_head -ne $ExpectedControlHead) { throw 'Expected control HEAD mismatch.' }
if ([int] $lock.run_epoch -ne [int] $localFence.run_epoch) { throw 'Local writer epoch mismatch.' }
if ($isBootstrapHeadBinding -and (
  $isRecoveryTransition -or
  [int] $lock.run_epoch -ne 1 -or
  [string] $controlState.startup_level -ne 'LEVEL_1_GOVERNANCE_BOOTSTRAP' -or
  [string] $controlState.lifecycle_state -ne 'ACTIVE'
)) { throw 'Bootstrap HEAD binding marker is inconsistent with tracked Level 1 state.' }

if ($isRecoveryTransition) {
  if ([string]::IsNullOrWhiteSpace($ReplacementWriterId) -or $ReplacementRunEpoch -ne ([int] $lock.run_epoch + 1)) {
    throw 'Recovery transition requires a replacement writer and exactly one epoch increment.'
  }
  if (
    $controlState.writer_fence.writer_id -ne $ReplacementWriterId -or
    -not (Test-IsInteger $controlState.run_epoch) -or [int] $controlState.run_epoch -ne $ReplacementRunEpoch -or
    -not (Test-IsInteger $controlState.writer_fence.fence_epoch) -or [int] $controlState.writer_fence.fence_epoch -ne $ReplacementRunEpoch -or
    [string] $controlState.lifecycle_state -ne 'RECOVERING' -or
    $null -ne $controlState.writer_fence.lease_expires_at
  ) { throw 'Tracked control state does not contain the declared recovery transition.' }

  $rolesPath = Assert-ControlPath $controlRootPath (Join-Path $scopeRoot 'state\roles.json') 'Roles state'
  $runsPath = Assert-ControlPath $controlRootPath (Join-Path $scopeRoot 'state\runs.json') 'Runs state'
  $transportPath = Assert-ControlPath $controlRootPath (Join-Path $scopeRoot 'state\transport.json') 'Transport state'
  $eventsPath = Assert-ControlPath $controlRootPath (Join-Path $scopeRoot 'events.jsonl') 'Scope events'
  $topologyPath = Assert-ControlPath $controlRootPath (Join-Path $controlRootPath '.yefeng\control-plane.json') 'Control topology'
  foreach ($required in @($rolesPath, $runsPath, $transportPath, $eventsPath, $topologyPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing recovery snapshot file: $required" }
  }

  $rolesState = Get-Content -LiteralPath $rolesPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $runsState = Get-Content -LiteralPath $runsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $transportState = Get-Content -LiteralPath $transportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $topology = Get-Content -LiteralPath $topologyPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop

  if (
    [string] $topology.control_plane_mode -ne 'external-git' -or
    [string] $topology.control_repo_id -ne [string] $controlState.control_repo_id -or
    @($topology.active_scopes) -notcontains $ScopeId
  ) { throw 'Recovery transition topology identity mismatch.' }
  foreach ($state in @($rolesState, $runsState, $transportState)) {
    if (
      [string] $state.scope_id -ne $ScopeId -or
      [string] $state.control_repo_id -ne [string] $controlState.control_repo_id -or
      -not (Test-IsInteger $state.run_epoch) -or
      [int] $state.run_epoch -ne $ReplacementRunEpoch
    ) { throw 'Recovery transition scope snapshot identity or epoch mismatch.' }
  }

  if (@($rolesState.roles).Count -lt 1) { throw 'Recovery transition must retain at least one governed role.' }
  foreach ($role in @($rolesState.roles)) {
    if ([string] $role.scope_id -ne $ScopeId -or [string] $role.control_repo_id -ne [string] $controlState.control_repo_id) { throw "Recovery role identity mismatch: $($role.role_id)" }
    if (-not (Test-IsInteger $role.run_epoch) -or [int] $role.run_epoch -lt 1 -or [int] $role.run_epoch -gt $ReplacementRunEpoch) { throw "Recovery role epoch is invalid: $($role.role_id)" }
    $roleEpoch = [int] $role.run_epoch
    $roleState = [string] $role.state
    $hasLease = -not [string]::IsNullOrWhiteSpace([string] $role.lease_expires_at)
    if ($roleEpoch -lt $ReplacementRunEpoch -and ($terminalRoleStates -notcontains $roleState -or $hasLease)) {
      throw "Recovery transition left an old role active or leased: $($role.role_id)"
    }
    if ($roleEpoch -eq $ReplacementRunEpoch) {
      $runtimeFields = @($role.assigned_by, $role.assignment_id, $role.session_id, $role.process_id, $role.run_id, $role.product_worktree, $role.lease_expires_at)
      if ($roleState -ne 'PLANNED' -or @($runtimeFields | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string] $_) }).Count -gt 0) {
        throw "Recovery transition introduced a non-PLANNED replacement-epoch role: $($role.role_id)"
      }
    }
  }
  foreach ($run in @($runsState.runs)) {
    if ([string] $run.scope_id -ne $ScopeId -or [string] $run.control_repo_id -ne [string] $controlState.control_repo_id) { throw "Recovery run identity mismatch: $($run.run_id)" }
    if (-not (Test-IsInteger $run.run_epoch) -or [int] $run.run_epoch -lt 1 -or [int] $run.run_epoch -ge $ReplacementRunEpoch) { throw "Recovery run epoch is invalid: $($run.run_id)" }
    if ($terminalRunStates -notcontains [string] $run.status) { throw "Recovery transition left an old run active: $($run.run_id)" }
  }

  $topologyProductIds = @()
  foreach ($product in @($topology.product_repositories)) {
    $productRepoId = [string] $product.repo_id
    Assert-StableId 'product repository ID' $productRepoId
    $topologyProductIds += $productRepoId
  }
  if ($topologyProductIds.Count -lt 1) { throw 'Recovery topology must register at least one product repository.' }
  $controlBaselineIds = Get-PropertyNames $controlState.product_baselines
  Assert-ExactIdSet 'Tracked recovery product baselines' $topologyProductIds $controlBaselineIds

  $expectedRecoveryLockHash = Get-Sha256Hex $authoritativeLockToken
  $epochRecoveryEvents = @()
  foreach ($line in Get-Content -LiteralPath $eventsPath -Encoding UTF8) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $event = $line | ConvertFrom-Json -ErrorAction Stop
    if ($event.type -eq 'RECOVERY_STARTED' -and (Test-IsInteger $event.run_epoch) -and [int] $event.run_epoch -eq $ReplacementRunEpoch) {
      $epochRecoveryEvents += $event
    }
  }
  if ($epochRecoveryEvents.Count -ne 1) { throw 'Recovery transition requires exactly one RECOVERY_STARTED event for the replacement epoch.' }
  $recoveryEvent = $epochRecoveryEvents[0]
  if (
    [string] $recoveryEvent.control_repo_id -ne [string] $controlState.control_repo_id -or
    [string] $recoveryEvent.scope_id -ne $ScopeId -or
    [string] $recoveryEvent.previous_writer_id -ne $WriterId -or
    [string] $recoveryEvent.replacement_writer_id -ne $ReplacementWriterId -or
    [string] $recoveryEvent.recovery_lock_sha256 -ne $expectedRecoveryLockHash -or
    $recoveryEvent.blocking -isnot [bool] -or -not [bool] $recoveryEvent.blocking -or
    [string] $recoveryEvent.status -ne 'OPEN'
  ) { throw 'RECOVERY_STARTED event does not match the lock-bound transition snapshot.' }
  if ($recoveryEvent.PSObject.Properties.Name -contains 'recovery_lock_token' -or $recoveryEvent.PSObject.Properties.Name -contains 'lock_token') {
    throw 'RECOVERY_STARTED event must not contain a raw lock token.'
  }
  $recoveryEventJson = $recoveryEvent | ConvertTo-Json -Compress -Depth 30
  if ($recoveryEventJson.IndexOf($authoritativeLockToken, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
    throw 'RECOVERY_STARTED event must not contain the raw writer lock token.'
  }
  $eventBaselineIds = Get-PropertyNames $recoveryEvent.product_baselines
  Assert-ExactIdSet 'RECOVERY_STARTED product baselines' $topologyProductIds $eventBaselineIds
  foreach ($productRepoId in $topologyProductIds) {
    $trackedBaseline = $controlState.product_baselines.PSObject.Properties[$productRepoId].Value
    $eventBaseline = $recoveryEvent.product_baselines.PSObject.Properties[$productRepoId].Value
    if (
      [string] $trackedBaseline.branch -ne [string] $eventBaseline.branch -or
      [string] $trackedBaseline.commit -ne [string] $eventBaseline.commit -or
      [string] $trackedBaseline.branch -eq '' -or
      [string] $trackedBaseline.commit -notmatch '^[A-Fa-f0-9]{40,64}$'
    ) { throw "RECOVERY_STARTED baseline does not match tracked control state: $productRepoId" }
  }
} else {
  if ($ReplacementWriterId -or $ReplacementRunEpoch -ne 0) { throw 'Replacement writer fields are only valid for a recovery transition.' }
  if ($controlState.writer_fence.writer_id -ne $WriterId -or -not (Test-IsInteger $controlState.run_epoch) -or [int] $controlState.run_epoch -ne [int] $lock.run_epoch) { throw 'Tracked writer identity or epoch changed during a normal fenced write.' }
}

$status = Invoke-Git $controlRootPath @('status', '--short')
if ($status) { throw "Control repository must be clean before releasing the writer fence: $status" }

$actualHead = Invoke-Git $controlRootPath @('rev-parse', 'HEAD')
if ($actualHead -eq $ExpectedControlHead) {
  if ($isRecoveryTransition) { throw 'Recovery transition did not publish its required tracked control commit.' }
  if (-not $isBootstrapHeadBinding) {
    throw 'A normal fenced write must publish exactly one control commit before release.'
  }
} else {
  $parentHead = Invoke-Git $controlRootPath @('rev-parse', "$actualHead^")
  if ($parentHead -ne $ExpectedControlHead) {
    throw "A fenced write must publish exactly one control commit: expected parent=$ExpectedControlHead actual parent=$parentHead"
  }
}

$localFence.lease_expires_at = $null
$localFence.lock_token = $null
$localFence.recovery_required = $false
if ($isRecoveryTransition) {
  $localFence.writer_id = $ReplacementWriterId
  $localFence.run_epoch = $ReplacementRunEpoch
}
$controlHeadState.expected_control_head = $actualHead
$controlHeadState.updated_at = [DateTimeOffset]::UtcNow.ToString('o')
Write-Utf8FileAtomically $controlHeadPath (($controlHeadState | ConvertTo-Json -Depth 10) + "`n")
Write-Utf8FileAtomically $localFencePath (($localFence | ConvertTo-Json -Depth 10) + "`n")
Assert-NoReparsePointInTree $controlRootPath
$lockPath = Assert-ControlPath $controlRootPath $lockPath 'Writer lock before deletion'
$lockBeforeDeleteJson = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
$lockBeforeDelete = ConvertFrom-WriterLockJson $lockBeforeDeleteJson
Assert-WriterLockSchema $lockBeforeDelete
if (
  -not [string]::Equals([string] $lockBeforeDelete.lock_token, $authoritativeLockToken, [System.StringComparison]::Ordinal) -or
  -not [string]::Equals($lockBeforeDeleteJson, $lockJson, [System.StringComparison]::Ordinal)
) { throw 'Writer lock changed during release; refusing deletion.' }
Remove-Item -LiteralPath $lockPath -Force

[ordered]@{
  released = $true
  control_head = $actualHead
  previous_control_head = $ExpectedControlHead
  scope_id = $ScopeId
  run_epoch = if ($isRecoveryTransition) { $ReplacementRunEpoch } else { [int] $controlState.run_epoch }
  writer_id = if ($isRecoveryTransition) { $ReplacementWriterId } else { $WriterId }
  bootstrap_head_binding = $isBootstrapHeadBinding
} | ConvertTo-Json -Depth 10
} finally {
  $lifecycleGuard.Dispose()
}
