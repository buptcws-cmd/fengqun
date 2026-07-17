<#
.SYNOPSIS
Recovers an expired local writer lock only after proving its exact process identity is no longer authoritative.

.DESCRIPTION
The lock is treated as untrusted crash-recovery input. Its complete schema,
native types, timestamps, stable identities, path containment, and reparse-free
control-repository topology are verified before quarantine or deletion.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $ControlRoot,

  [Parameter(Mandatory = $true)]
  [string] $ScopeId,

  [Parameter(Mandatory = $true)]
  [string] $WriterId,

  [switch] $AcknowledgeExpiredLease
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$allowedStartupLevels = @(
  'LEVEL_1_GOVERNANCE_BOOTSTRAP', 'LEVEL_2_SINGLE_THREAD_TOTAL_CONTROL',
  'LEVEL_3_FULL_PARALLEL_YEFENG'
)
$allowedRoleStates = @(
  'PLANNED', 'ASSIGNED', 'RUNNING', 'WAITING_REVIEW', 'BLOCKED', 'READY_TO_RESUME',
  'REPORT_READY', 'MERGE_READY', 'DONE', 'FAILED', 'EXPIRED'
)
$terminalRoleStates = @('DONE', 'FAILED', 'EXPIRED')
$terminalRunStates = @('DONE', 'FAILED', 'EXIT_UNKNOWN', 'EXPIRED')
$requiredRoleFields = @(
  'role_id', 'role_name', 'scope_id', 'run_epoch', 'control_repo_id', 'state', 'assigned_by',
  'assignment_id', 'session_id', 'process_id', 'run_id', 'product_repo_id',
  'product_baseline_commit', 'product_branch', 'product_worktree', 'transport_mode',
  'current_checkpoint', 'owned_scope', 'forbidden_scope', 'blocked_by', 'resume_when',
  'required_evidence', 'wake_target', 'last_seen', 'lease_expires_at', 'last_output'
)
$requiredRunFields = @(
  'run_id', 'role_id', 'assignment_id', 'scope_id', 'run_epoch', 'control_repo_id',
  'product_repo_id', 'product_baseline_commit', 'product_branch', 'product_worktree',
  'transport_mode', 'session_id', 'process_id', 'command', 'cwd', 'started_at', 'ended_at',
  'exit_code', 'status'
)
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

function Get-PropertyNames([object] $Object) {
  if ($null -eq $Object) { return @() }
  return @($Object.PSObject.Properties | ForEach-Object { [string] $_.Name })
}

function Assert-RequiredProperties([string] $Label, [object] $Object, [string[]] $Required) {
  if ($null -eq $Object) { throw "$Label must be a JSON object." }
  $propertyNames = @(Get-PropertyNames $Object)
  foreach ($requiredProperty in $Required) {
    if ($propertyNames -notcontains $requiredProperty) { throw "$Label schema is missing $requiredProperty." }
  }
}

function Assert-JsonArray([string] $Label, [object] $Value) {
  if ($null -eq $Value -or $Value -is [string] -or $Value -isnot [System.Array]) {
    throw "$Label must be a native JSON array."
  }
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
  return [pscustomobject]@{
    lease_expires_at = ConvertFrom-LockTimestamp 'lease_expires_at' $Lock.lease_expires_at
    process_start_time = ConvertFrom-LockTimestamp 'process_start_time' $Lock.process_start_time
    acquired_at = ConvertFrom-LockTimestamp 'acquired_at' $Lock.acquired_at
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

function Get-Sha256Hex([string] $Value) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($utf8NoBom.GetBytes($Value)))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

Assert-StableId 'ScopeId' $ScopeId
Assert-WriterId 'WriterId' $WriterId

if (-not $AcknowledgeExpiredLease) {
  throw 'Recovery is an exceptional takeover path; pass -AcknowledgeExpiredLease after verifying the prior writer is no longer authoritative.'
}

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
  $rolesPath = Assert-ControlPath $controlRootPath (Join-Path $scopeRoot 'state\roles.json') 'Roles state'
  $runsPath = Assert-ControlPath $controlRootPath (Join-Path $scopeRoot 'state\runs.json') 'Runs state'
  $transportPath = Assert-ControlPath $controlRootPath (Join-Path $scopeRoot 'state\transport.json') 'Transport state'
  $eventsPath = Assert-ControlPath $controlRootPath (Join-Path $scopeRoot 'events.jsonl') 'Scope events'
  $topologyPath = Assert-ControlPath $controlRootPath (Join-Path $controlRootPath '.yefeng\control-plane.json') 'Control topology'
  $localFencePath = Assert-ControlPath $controlRootPath (Join-Path $controlRootPath ".yefeng\local\writer-fences\$ScopeId.json") 'Local writer fence'
  $controlHeadPath = Assert-ControlPath $controlRootPath (Join-Path $controlRootPath '.yefeng\local\control-head.json') 'Repository control HEAD state'
  $lockPath = Assert-ControlPath $controlRootPath (Join-Path $controlRootPath '.yefeng\local\locks\control-repo.write.lock') 'Writer lock'
  foreach ($required in @($controlStatePath, $rolesPath, $runsPath, $transportPath, $eventsPath, $topologyPath, $localFencePath, $controlHeadPath, $lockPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing recovery input: $required" }
  }

  $status = Invoke-Git $controlRootPath @('status', '--short')
  if ($status) { throw "Refusing writer recovery with uncommitted control state: $status" }

  $controlState = Get-Content -LiteralPath $controlStatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $localFence = ConvertFrom-WriterLockJson (Get-Content -LiteralPath $localFencePath -Raw -Encoding UTF8)
  Assert-LocalFenceSchema $localFence
  $controlHeadState = Get-Content -LiteralPath $controlHeadPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $lockJson = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
  $lock = ConvertFrom-WriterLockJson $lockJson
  $lockTimestamps = Assert-WriterLockSchema $lock
  $isRecoveryTransition = [bool] $lock.recovery_transition
  $actualHead = Invoke-Git $controlRootPath @('rev-parse', 'HEAD')

  if (
    $lock.control_repo_id -ne $controlState.control_repo_id -or
    $controlHeadState.control_repo_id -ne $controlState.control_repo_id -or
    $localFence.control_repo_id -ne $controlState.control_repo_id
  ) { throw 'Recovery control repository identity mismatch.' }
  if ($lock.scope_id -ne $ScopeId -or $controlState.scope_id -ne $ScopeId -or $localFence.scope_id -ne $ScopeId) { throw 'Recovery scope mismatch.' }
  if ($lock.writer_id -ne $WriterId) { throw 'Recovery writer identity does not match the authoritative lock.' }
  if ($lock.machine_name -ne [Environment]::MachineName) { throw 'Automatic recovery is forbidden for a lock created on a different machine.' }

  $globalExpected = [string] $controlHeadState.expected_control_head
  if (
    -not [string]::IsNullOrWhiteSpace($globalExpected) -and
    $globalExpected -ne $lock.expected_control_head -and
    $globalExpected -ne $actualHead
  ) { throw 'Repository control HEAD recovery state mismatch.' }

  $commitLanded = $actualHead -ne $lock.expected_control_head
  if ($commitLanded) {
    $parentHead = Invoke-Git $controlRootPath @('rev-parse', "$actualHead^")
    if ($parentHead -ne $lock.expected_control_head) {
      throw "Control HEAD drift requires manual reconciliation: expected parent=$($lock.expected_control_head) actual parent=$parentHead"
    }
  }

  $trackedOldWriter = (
    $controlState.writer_fence.writer_id -eq $WriterId -and
    [int] $controlState.run_epoch -eq [int] $lock.run_epoch -and
    [int] $controlState.writer_fence.fence_epoch -eq [int] $lock.run_epoch
  )
  $transitionAlreadyCommitted = $false
  if ($isRecoveryTransition) {
    $transitionAlreadyCommitted = (
      $commitLanded -and
      [int] $controlState.run_epoch -eq ([int] $lock.run_epoch + 1) -and
      [int] $controlState.writer_fence.fence_epoch -eq [int] $controlState.run_epoch -and
      $controlState.writer_fence.writer_id -ne $WriterId -and
      $controlState.lifecycle_state -eq 'RECOVERING'
    )
    if (-not $trackedOldWriter -and -not $transitionAlreadyCommitted) { throw 'Tracked state is not a valid recovery-transition state.' }
    if ($trackedOldWriter -and $commitLanded) { throw 'A recovery-transition commit landed without the required epoch/writer state.' }
  } elseif (-not $trackedOldWriter) {
    throw 'Tracked writer changed during a normal write lock.'
  }

  if ($transitionAlreadyCommitted) {
    $rolesState = Get-Content -LiteralPath $rolesPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $runsState = Get-Content -LiteralPath $runsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $transportState = Get-Content -LiteralPath $transportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $topology = Get-Content -LiteralPath $topologyPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $replacementRunEpoch = [int] $controlState.run_epoch
    $replacementWriterId = [string] $controlState.writer_fence.writer_id

    Assert-RequiredProperties 'Control topology' $topology @(
      'version', 'control_plane_mode', 'control_repo_id', 'active_scopes',
      'shared_writer', 'product_repositories'
    )
    if (-not (Test-IsInteger $topology.version) -or [int64] $topology.version -lt 2) {
      throw 'Committed recovery topology version must be integer 2 or later.'
    }
    if ([string] $topology.control_plane_mode -ne 'external-git') { throw 'Committed recovery topology mode must be external-git.' }
    if ($topology.control_repo_id -isnot [string]) { throw 'Control topology control_repo_id must be a native String.' }
    Assert-StableId 'topology control_repo_id' ([string] $topology.control_repo_id)
    if ([string] $topology.control_repo_id -ne [string] $controlState.control_repo_id) { throw 'Committed recovery topology repository identity mismatch.' }
    Assert-JsonArray 'Control topology active_scopes' $topology.active_scopes
    $activeScopeIds = @()
    foreach ($activeScope in @($topology.active_scopes)) {
      if ($activeScope -isnot [string]) { throw 'Control topology active scope IDs must be native Strings.' }
      $activeScopeId = [string] $activeScope
      Assert-StableId 'active scope ID' $activeScopeId
      $activeScopeIds += $activeScopeId
    }
    Assert-ExactIdSet 'Control topology active scopes' $activeScopeIds $activeScopeIds
    if (@($activeScopeIds | Where-Object { $_ -eq $ScopeId }).Count -ne 1) { throw 'Committed recovery scope is not uniquely active in topology.' }

    Assert-RequiredProperties 'Control topology shared_writer' $topology.shared_writer @('scope_id', 'role_id')
    if ($topology.shared_writer.scope_id -isnot [string] -or $topology.shared_writer.role_id -isnot [string]) {
      throw 'Control topology shared writer identities must be native Strings.'
    }
    $sharedWriterScopeId = [string] $topology.shared_writer.scope_id
    Assert-StableId 'shared writer scope ID' $sharedWriterScopeId
    Assert-WriterId 'shared writer role ID' ([string] $topology.shared_writer.role_id)
    if ($activeScopeIds -notcontains $sharedWriterScopeId) { throw 'Committed recovery topology shared writer scope is not active.' }

    Assert-JsonArray 'Control topology product_repositories' $topology.product_repositories
    $topologyProductIds = @()
    $topologyBranchByProductId = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    foreach ($product in @($topology.product_repositories)) {
      Assert-RequiredProperties 'Control topology product repository' $product @('repo_id', 'integration_branch')
      if ($product.repo_id -isnot [string]) { throw 'Control topology product repo_id must be a native String.' }
      $productRepoId = [string] $product.repo_id
      Assert-StableId 'product repository ID' $productRepoId
      if ($product.integration_branch -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $product.integration_branch)) {
        throw "Control topology product integration_branch is invalid: $productRepoId"
      }
      if ($topologyBranchByProductId.ContainsKey($productRepoId)) { throw "Control topology product repository identity is duplicated: $productRepoId" }
      $topologyBranchByProductId.Add($productRepoId, [string] $product.integration_branch)
      $topologyProductIds += $productRepoId
    }
    if ($topologyProductIds.Count -lt 1) { throw 'Committed recovery topology must register at least one product repository.' }

    Assert-RequiredProperties 'Committed recovery control state' $controlState @(
      'version', 'scope_id', 'run_epoch', 'lifecycle_state', 'startup_level',
      'control_plane_mode', 'control_repo_id', 'writer_fence', 'product_baselines'
    )
    if (-not (Test-IsInteger $controlState.version) -or [int64] $controlState.version -ne 2) { throw 'Committed recovery control state version must be integer 2.' }
    if (
      $controlState.scope_id -isnot [string] -or
      $controlState.control_repo_id -isnot [string] -or
      $controlState.control_plane_mode -isnot [string] -or
      [string] $controlState.scope_id -ne $ScopeId -or
      [string] $controlState.control_repo_id -ne [string] $topology.control_repo_id -or
      [string] $controlState.control_plane_mode -ne 'external-git'
    ) { throw 'Committed recovery control state identity or mode mismatch.' }
    if (-not (Test-IsInteger $controlState.run_epoch) -or [int64] $controlState.run_epoch -ne ([int64] $lock.run_epoch + 1)) {
      throw 'Committed recovery control state must advance exactly one native-integer epoch.'
    }
    if ([string] $controlState.lifecycle_state -ne 'RECOVERING' -or [string] $controlState.startup_level -notin $allowedStartupLevels) {
      throw 'Committed recovery control lifecycle or startup state is invalid.'
    }
    Assert-RequiredProperties 'Committed recovery writer_fence' $controlState.writer_fence @('writer_id', 'fence_epoch', 'lease_expires_at')
    if ($controlState.writer_fence.writer_id -isnot [string]) { throw 'Committed recovery writer_id must be a native String.' }
    Assert-WriterId 'replacement writer_id' $replacementWriterId
    if (
      $replacementWriterId -eq $WriterId -or
      -not (Test-IsInteger $controlState.writer_fence.fence_epoch) -or
      [int64] $controlState.writer_fence.fence_epoch -ne $replacementRunEpoch -or
      $null -ne $controlState.writer_fence.lease_expires_at
    ) { throw 'Committed recovery writer fence state is invalid.' }

    $controlBaselineIds = @(Get-PropertyNames $controlState.product_baselines)
    Assert-ExactIdSet 'Committed recovery product baselines' $topologyProductIds $controlBaselineIds
    foreach ($productRepoId in $topologyProductIds) {
      $trackedBaseline = $controlState.product_baselines.PSObject.Properties[$productRepoId].Value
      Assert-RequiredProperties "Committed recovery product baseline $productRepoId" $trackedBaseline @('branch', 'commit')
      if (
        $trackedBaseline.branch -isnot [string] -or
        [string] $trackedBaseline.branch -ne $topologyBranchByProductId[$productRepoId] -or
        $trackedBaseline.commit -isnot [string] -or
        [string] $trackedBaseline.commit -notmatch '^[A-Fa-f0-9]{40,64}$'
      ) { throw "Committed recovery product baseline does not match topology: $productRepoId" }
    }

    foreach ($scopeState in @(
      [pscustomobject]@{ label = 'roles'; value = $rolesState; collection = 'roles' },
      [pscustomobject]@{ label = 'runs'; value = $runsState; collection = 'runs' },
      [pscustomobject]@{ label = 'transport'; value = $transportState; collection = '' }
    )) {
      Assert-RequiredProperties "Committed recovery $($scopeState.label) state" $scopeState.value @('version', 'scope_id', 'run_epoch', 'control_repo_id')
      if (-not (Test-IsInteger $scopeState.value.version) -or [int64] $scopeState.value.version -ne 2) { throw "Committed recovery $($scopeState.label) state version must be integer 2." }
      if (
        [string] $scopeState.value.scope_id -ne $ScopeId -or
        [string] $scopeState.value.control_repo_id -ne [string] $topology.control_repo_id -or
        -not (Test-IsInteger $scopeState.value.run_epoch) -or
        [int64] $scopeState.value.run_epoch -ne $replacementRunEpoch
      ) { throw "Committed recovery $($scopeState.label) state identity or epoch mismatch." }
    }
    Assert-RequiredProperties 'Committed recovery roles state' $rolesState @('roles')
    Assert-RequiredProperties 'Committed recovery runs state' $runsState @('runs')
    Assert-RequiredProperties 'Committed recovery transport state' $transportState @('imported_messages', 'quarantined_messages')
    Assert-JsonArray 'Committed recovery roles' $rolesState.roles
    Assert-JsonArray 'Committed recovery runs' $runsState.runs
    Assert-JsonArray 'Committed recovery imported_messages' $transportState.imported_messages
    Assert-JsonArray 'Committed recovery quarantined_messages' $transportState.quarantined_messages

    if (@($rolesState.roles).Count -lt 1) { throw 'Committed recovery transition must retain at least one governed role.' }
    $roleIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($role in @($rolesState.roles)) {
      Assert-RequiredProperties "Committed recovery role $($role.role_id)" $role $requiredRoleFields
      $roleId = [string] $role.role_id
      if (
        $role.role_id -isnot [string] -or
        $role.scope_id -isnot [string] -or
        $role.control_repo_id -isnot [string] -or
        $role.state -isnot [string] -or
        $role.product_repo_id -isnot [string]
      ) { throw "Committed recovery role identity and state fields must be native Strings: $roleId" }
      Assert-WriterId 'role ID' $roleId
      if (-not $roleIds.Add($roleId)) { throw "Committed recovery role identity is duplicated: $roleId" }
      if ([string] $role.scope_id -ne $ScopeId -or [string] $role.control_repo_id -ne [string] $topology.control_repo_id) { throw "Committed recovery role identity mismatch: $roleId" }
      if (-not (Test-IsInteger $role.run_epoch)) { throw "Committed recovery role epoch must be a native integer: $roleId" }
      $roleEpoch = [int] $role.run_epoch
      $roleState = [string] $role.state
      if ($roleEpoch -lt 1 -or $roleEpoch -gt $replacementRunEpoch -or $allowedRoleStates -notcontains $roleState) {
        throw "Committed recovery transition has an invalid role epoch or state: $roleId"
      }
      $roleProductRepoId = [string] $role.product_repo_id
      if ($topologyProductIds -notcontains $roleProductRepoId) { throw "Committed recovery role product repository identity mismatch: $roleId" }
      $hasLease = -not [string]::IsNullOrWhiteSpace([string] $role.lease_expires_at)
      if ($roleEpoch -lt $replacementRunEpoch -and ($terminalRoleStates -notcontains $roleState -or $hasLease)) {
        throw "Committed recovery transition left a stale role active or leased: $roleId"
      }
      if ($roleEpoch -eq $replacementRunEpoch) {
        $runtimeFields = @($role.assigned_by, $role.assignment_id, $role.session_id, $role.process_id, $role.run_id, $role.product_worktree, $role.lease_expires_at)
        if ($roleState -ne 'PLANNED' -or @($runtimeFields | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string] $_) }).Count -gt 0) {
          throw "Committed recovery transition introduced a non-PLANNED replacement-epoch role: $roleId"
        }
        $roleBaseline = $controlState.product_baselines.PSObject.Properties[$roleProductRepoId].Value
        if (
          [string] $role.product_baseline_commit -ne [string] $roleBaseline.commit -or
          [string] $role.product_branch -ne [string] $roleBaseline.branch
        ) { throw "Committed recovery replacement-epoch role baseline mismatch: $roleId" }
      }
    }
    if ($sharedWriterScopeId -eq $ScopeId -and -not $roleIds.Contains([string] $topology.shared_writer.role_id)) {
      throw 'Committed recovery topology shared writer role is missing from scope roles.'
    }

    $runIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($run in @($runsState.runs)) {
      Assert-RequiredProperties "Committed recovery run $($run.run_id)" $run $requiredRunFields
      $runId = [string] $run.run_id
      if (
        $run.run_id -isnot [string] -or
        $run.scope_id -isnot [string] -or
        $run.control_repo_id -isnot [string] -or
        $run.status -isnot [string] -or
        $run.product_repo_id -isnot [string]
      ) { throw "Committed recovery run identity and state fields must be native Strings: $runId" }
      if ($runId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' -or -not $runIds.Add($runId)) { throw "Committed recovery run identity is missing or duplicated: $runId" }
      if ([string] $run.scope_id -ne $ScopeId -or [string] $run.control_repo_id -ne [string] $topology.control_repo_id) { throw "Committed recovery run identity mismatch: $runId" }
      if (-not (Test-IsInteger $run.run_epoch)) { throw "Committed recovery run epoch must be a native integer: $runId" }
      $runEpoch = [int] $run.run_epoch
      if ($runEpoch -lt 1 -or $runEpoch -ge $replacementRunEpoch) { throw "Committed recovery transition contains a replacement-epoch or invalid run: $runId" }
      if ($terminalRunStates -notcontains [string] $run.status) { throw "Committed recovery transition left a stale run active: $runId" }
      if ($topologyProductIds -notcontains [string] $run.product_repo_id) { throw "Committed recovery run product repository identity mismatch: $runId" }
    }

    $expectedRecoveryLockHash = Get-Sha256Hex ([string] $lock.lock_token)
    $epochRecoveryEvents = @()
    foreach ($line in Get-Content -LiteralPath $eventsPath -Encoding UTF8) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $event = $line | ConvertFrom-Json -ErrorAction Stop
      if ([string] $event.type -ne 'RECOVERY_STARTED') { continue }
      if (-not (Test-IsInteger $event.run_epoch)) { throw 'RECOVERY_STARTED run_epoch must be a native integer.' }
      if ([int] $event.run_epoch -eq $replacementRunEpoch) { $epochRecoveryEvents += $event }
    }
    if ($epochRecoveryEvents.Count -ne 1) { throw 'Committed recovery transition requires exactly one RECOVERY_STARTED event for the replacement epoch.' }
    $recoveryEvent = $epochRecoveryEvents[0]
    Assert-RequiredProperties 'Committed RECOVERY_STARTED event' $recoveryEvent @(
      'control_plane_mode', 'control_repo_id', 'scope_id', 'run_epoch',
      'recovery_lock_sha256', 'previous_writer_id', 'replacement_writer_id',
      'blocking', 'status', 'product_baselines'
    )
    if (
      $recoveryEvent.control_plane_mode -isnot [string] -or
      $recoveryEvent.control_repo_id -isnot [string] -or
      $recoveryEvent.scope_id -isnot [string] -or
      $recoveryEvent.previous_writer_id -isnot [string] -or
      $recoveryEvent.replacement_writer_id -isnot [string] -or
      $recoveryEvent.recovery_lock_sha256 -isnot [string] -or
      $recoveryEvent.status -isnot [string] -or
      [string] $recoveryEvent.control_plane_mode -ne 'external-git' -or
      [string] $recoveryEvent.control_repo_id -ne [string] $topology.control_repo_id -or
      [string] $recoveryEvent.scope_id -ne $ScopeId -or
      [string] $recoveryEvent.previous_writer_id -ne $WriterId -or
      [string] $recoveryEvent.replacement_writer_id -ne $replacementWriterId -or
      [string] $recoveryEvent.recovery_lock_sha256 -ne $expectedRecoveryLockHash -or
      $recoveryEvent.blocking -isnot [bool] -or -not [bool] $recoveryEvent.blocking -or
      [string] $recoveryEvent.status -ne 'OPEN'
    ) { throw 'Committed RECOVERY_STARTED event does not match the lock-bound transition snapshot.' }
    if (
      $recoveryEvent.PSObject.Properties.Name -contains 'recovery_lock_token' -or
      $recoveryEvent.PSObject.Properties.Name -contains 'lock_token' -or
      ($recoveryEvent | ConvertTo-Json -Compress -Depth 30).IndexOf([string] $lock.lock_token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    ) { throw 'Committed RECOVERY_STARTED event must not contain a raw lock token.' }
    $eventBaselineIds = @(Get-PropertyNames $recoveryEvent.product_baselines)
    Assert-ExactIdSet 'Committed RECOVERY_STARTED product baselines' $topologyProductIds $eventBaselineIds
    foreach ($productRepoId in $topologyProductIds) {
      $trackedBaseline = $controlState.product_baselines.PSObject.Properties[$productRepoId].Value
      $eventBaseline = $recoveryEvent.product_baselines.PSObject.Properties[$productRepoId].Value
      Assert-RequiredProperties "Committed RECOVERY_STARTED product baseline $productRepoId" $eventBaseline @('branch', 'commit')
      if (
        $eventBaseline.branch -isnot [string] -or
        $eventBaseline.commit -isnot [string] -or
        [string] $eventBaseline.branch -ne [string] $trackedBaseline.branch -or
        [string] $eventBaseline.commit -ne [string] $trackedBaseline.commit -or
        [string] $eventBaseline.branch -ne $topologyBranchByProductId[$productRepoId]
      ) { throw "Committed RECOVERY_STARTED baseline does not match control state and topology: $productRepoId" }
    }
  }

  $localTokenEmpty = [string]::IsNullOrWhiteSpace([string] $localFence.lock_token)
  $localLeaseEmpty = [string]::IsNullOrWhiteSpace([string] $localFence.lease_expires_at)
  $localIsEmpty = $localTokenEmpty -and $localLeaseEmpty
  $localIsHeld = (
    $localFence.writer_id -eq $WriterId -and
    [int] $localFence.run_epoch -eq [int] $lock.run_epoch -and
    [string]::Equals([string] $localFence.lock_token, [string] $lock.lock_token, [System.StringComparison]::Ordinal) -and
    [string]::Equals([string] $localFence.lease_expires_at, [string] $lock.lease_expires_at, [System.StringComparison]::Ordinal)
  )
  $localIsOldEmpty = $localIsEmpty -and $localFence.writer_id -eq $WriterId -and [int] $localFence.run_epoch -eq [int] $lock.run_epoch
  $localIsReplacementEmpty = (
    $transitionAlreadyCommitted -and
    $localIsEmpty -and
    $localFence.writer_id -eq $controlState.writer_fence.writer_id -and
    [int] $localFence.run_epoch -eq [int] $controlState.run_epoch
  )
  if (-not $localIsHeld -and -not $localIsOldEmpty -and -not $localIsReplacementEmpty) {
    throw 'Local writer fence is not an allowed pre-entry, held, post-exit, or committed-transition shape.'
  }
  if ($localIsReplacementEmpty) {
    if ($localFence.recovery_required) { throw 'Post-exit replacement fence must not require recovery.' }
  } elseif ($localIsHeld) {
    if ($localFence.recovery_required -ne $isRecoveryTransition) {
      throw 'Held local writer fence recovery mode does not match the authoritative lock.'
    }
  } elseif ($isRecoveryTransition -and -not $localFence.recovery_required) {
    throw 'An empty old-writer fence under a recovery-transition lock must require recovery.'
  }

  $leaseExpiry = [DateTimeOffset] $lockTimestamps.lease_expires_at
  if ($leaseExpiry -gt [DateTimeOffset]::UtcNow) { throw "Writer lease has not expired: $leaseExpiry" }

  $recordedProcess = $null
  try {
    $recordedProcess = Get-Process -Id ([int] $lock.process_id) -ErrorAction Stop
  } catch {
    if ($_.FullyQualifiedErrorId -notlike 'NoProcessFoundForGivenId,*') {
      throw "Cannot prove the recorded writer process is absent: $($_.Exception.Message)"
    }
  }
  if ($recordedProcess) {
    try {
      $actualStart = [DateTimeOffset]::new($recordedProcess.StartTime).ToUniversalTime()
      $recordedStart = ([DateTimeOffset] $lockTimestamps.process_start_time).ToUniversalTime()
    }
    catch { throw "Cannot inspect the recorded writer process start identity: $($_.Exception.Message)" }
    if ($actualStart.UtcDateTime.Ticks -eq $recordedStart.UtcDateTime.Ticks) {
      throw 'The recorded writer process identity is still alive; refusing takeover.'
    }
  }

  $quarantineRoot = Assert-ControlPath $controlRootPath (Join-Path $controlRootPath ".yefeng\quarantine\$ScopeId") 'Recovery quarantine root'
  New-Item -ItemType Directory -Path $quarantineRoot -Force | Out-Null
  $quarantineRoot = Assert-ControlPath $controlRootPath $quarantineRoot 'Recovery quarantine root'
  $archivePath = Assert-ControlPath $controlRootPath (Join-Path $quarantineRoot "writer-lock-$($lock.lock_token).json") 'Recovery evidence archive'
  if (Test-Path -LiteralPath $archivePath) {
    $existingArchive = Get-Content -LiteralPath $archivePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if (-not [string]::Equals([string] $existingArchive.lock.lock_token, [string] $lock.lock_token, [System.StringComparison]::Ordinal)) {
      throw 'Existing recovery evidence conflicts with the current lock token.'
    }
  } else {
    $archive = [ordered]@{
      version = 1
      recovered_at = [DateTimeOffset]::UtcNow.ToString('o')
      reason = 'expired lease and non-authoritative recorded process'
      actual_control_head = $actualHead
      lock = $lock
    }
    Write-Utf8FileAtomically $archivePath (($archive | ConvertTo-Json -Depth 20) + "`n") -NoOverwrite
  }

  $localFence.lease_expires_at = $null
  $localFence.lock_token = $null
  if ($transitionAlreadyCommitted) {
    $localFence.writer_id = $controlState.writer_fence.writer_id
    $localFence.run_epoch = $controlState.run_epoch
    $localFence.recovery_required = $false
  } else {
    $localFence.writer_id = $WriterId
    $localFence.run_epoch = [int] $lock.run_epoch
    $localFence.recovery_required = $true
  }
  $controlHeadState.expected_control_head = $actualHead
  $controlHeadState.updated_at = [DateTimeOffset]::UtcNow.ToString('o')
  Write-Utf8FileAtomically $controlHeadPath (($controlHeadState | ConvertTo-Json -Depth 10) + "`n")
  Write-Utf8FileAtomically $localFencePath (($localFence | ConvertTo-Json -Depth 10) + "`n")

  Assert-NoReparsePointInTree $controlRootPath
  $lockPath = Assert-ControlPath $controlRootPath $lockPath 'Writer lock before recovery deletion'
  $lockBeforeDeleteJson = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
  $lockBeforeDelete = ConvertFrom-WriterLockJson $lockBeforeDeleteJson
  $null = Assert-WriterLockSchema $lockBeforeDelete
  if (
    -not [string]::Equals([string] $lockBeforeDelete.lock_token, [string] $lock.lock_token, [System.StringComparison]::Ordinal) -or
    -not [string]::Equals($lockBeforeDeleteJson, $lockJson, [System.StringComparison]::Ordinal)
  ) {
    throw 'Writer lock changed during recovery; refusing deletion.'
  }
  Remove-Item -LiteralPath $lockPath -Force

  [ordered]@{
    recovered_local_lock = $true
    recovery_required = -not $transitionAlreadyCommitted
    control_head = $actualHead
    scope_id = $ScopeId
    current_run_epoch = [int] $controlState.run_epoch
    required_next_run_epoch = if ($transitionAlreadyCommitted) { [int] $controlState.run_epoch } else { [int] $lock.run_epoch + 1 }
    current_writer_id = if ($transitionAlreadyCommitted) { [string] $controlState.writer_fence.writer_id } else { $WriterId }
    quarantine_evidence = $archivePath
    next_action = if ($transitionAlreadyCommitted) { 'The committed transition was reconciled; validate before resuming.' } else { 'Acquire with -RecoveryTransition, publish one reviewed epoch/writer transition commit, then exit with replacement fields.' }
  } | ConvertTo-Json -Depth 10
} finally {
  $lifecycleGuard.Dispose()
}
