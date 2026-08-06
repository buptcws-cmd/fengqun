[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $ControlRoot,

  [Parameter(Mandatory = $true)]
  [string] $ScopeId,

  [Parameter(Mandatory = $true)]
  [string] $CurrentWriterId,

  [Parameter(Mandatory = $true)]
  [string] $ReplacementWriterId,

  [Parameter(Mandatory = $true)]
  [string] $LockToken,

  [Parameter(Mandatory = $true)]
  [string] $Reason
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
$allowedRoleStates = @(
  'PLANNED', 'ASSIGNED', 'RUNNING', 'WAITING_REVIEW', 'BLOCKED', 'READY_TO_RESUME',
  'REPORT_READY', 'MERGE_READY', 'DONE', 'FAILED', 'EXPIRED'
)
$terminalRoleStates = @('DONE', 'FAILED', 'EXPIRED')
$launchedRoleStates = @('RUNNING', 'WAITING_REVIEW', 'BLOCKED', 'READY_TO_RESUME', 'REPORT_READY', 'MERGE_READY')
$allowedRunStates = @('STARTING', 'RUNNING', 'DONE', 'FAILED', 'EXIT_UNKNOWN', 'EXPIRED')
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
  if (-not $existingProbe) { return $fullPath }
  $probe = $existingProbe
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

function Assert-SafeInternalPath([string] $PathValue, [string] $Root, [string] $Label) {
  $normalizedPath = Normalize-Path $PathValue
  if (-not (Test-PathWithin $normalizedPath $Root)) { throw "Internal path escapes the control repository for ${Label}: $normalizedPath" }
  $reparsePoint = Find-ReparsePointInExistingPathChain $normalizedPath
  if ($reparsePoint) { throw "Internal path traverses a reparse point for ${Label}: $reparsePoint" }
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
  ) { throw "$Name must be an ISO-8601 timestamp with an explicit offset." }
  $parsed = [DateTimeOffset]::MinValue
  $parsedSuccessfully = [DateTimeOffset]::TryParse(
    $Value,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::RoundtripKind,
    [ref] $parsed
  )
  if (-not $parsedSuccessfully) { throw "$Name is not parseable." }
  return $parsed
}

function ConvertFrom-ControlJson([string] $Json) {
  $convertCommand = Get-Command ConvertFrom-Json -ErrorAction Stop
  if ($convertCommand.Parameters.ContainsKey('DateKind')) {
    return $Json | ConvertFrom-Json -DateKind String -ErrorAction Stop
  }
  return $Json | ConvertFrom-Json -ErrorAction Stop
}

function Assert-ExactProperties([string] $Label, [object] $Object, [string[]] $RequiredProperties) {
  if ($null -eq $Object) { throw "$Label must be a JSON object." }
  $actualProperties = @($Object.PSObject.Properties | ForEach-Object { [string] $_.Name })
  $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($name in $RequiredProperties) { $null = $expectedSet.Add($name) }
  foreach ($name in $actualProperties) {
    if (-not $expectedSet.Remove($name)) { throw "$Label has an unknown or duplicated property: $name" }
  }
  if ($expectedSet.Count -ne 0 -or $actualProperties.Count -ne $RequiredProperties.Count) {
    throw "$Label is missing required properties: $(@($expectedSet) -join ', ')"
  }
}

function Assert-WriterLockSchema([object] $Lock) {
  $requiredProperties = @(
    'version', 'control_repo_id', 'scope_id', 'run_epoch', 'writer_id', 'lock_token',
    'expected_control_head', 'lease_expires_at', 'process_id', 'process_start_time',
    'machine_name', 'recovery_transition', 'bootstrap_head_binding', 'acquired_at'
  )
  Assert-ExactProperties 'Writer lock' $Lock $requiredProperties
  if (-not (Test-IsInteger $Lock.version) -or [int64] $Lock.version -ne 1) { throw 'Writer lock version must be integer 1.' }
  if (-not (Test-IsInteger $Lock.run_epoch) -or [int64] $Lock.run_epoch -lt 1 -or [int64] $Lock.run_epoch -gt [int]::MaxValue) { throw 'Writer lock run_epoch must be a positive 32-bit integer.' }
  if (-not (Test-IsInteger $Lock.process_id) -or [int64] $Lock.process_id -lt 1 -or [int64] $Lock.process_id -gt [int]::MaxValue) { throw 'Writer lock process_id must be a positive 32-bit integer.' }
  foreach ($name in @('control_repo_id', 'scope_id', 'writer_id', 'lock_token', 'expected_control_head', 'lease_expires_at', 'process_start_time', 'machine_name', 'acquired_at')) {
    if ($Lock.$name -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $Lock.$name)) { throw "Writer lock $name must be a non-empty native String." }
  }
  Assert-StableId 'writer lock control_repo_id' ([string] $Lock.control_repo_id)
  Assert-StableId 'writer lock scope_id' ([string] $Lock.scope_id)
  Assert-WriterId 'writer lock writer_id' ([string] $Lock.writer_id)
  if ([string] $Lock.lock_token -notmatch '^[A-Fa-f0-9]{32}$') { throw 'Writer lock lock_token must be 32 hexadecimal characters.' }
  if ([string] $Lock.expected_control_head -notmatch '^[A-Fa-f0-9]{40,64}$') { throw 'Writer lock expected_control_head must be a full Git object ID.' }
  if ($Lock.recovery_transition -isnot [bool]) { throw 'Writer lock recovery_transition must be a native Boolean.' }
  if ($Lock.bootstrap_head_binding -isnot [bool]) { throw 'Writer lock bootstrap_head_binding must be a native Boolean.' }
  $null = ConvertFrom-LockTimestamp 'Writer lock lease_expires_at' $Lock.lease_expires_at
  $null = ConvertFrom-LockTimestamp 'Writer lock process_start_time' $Lock.process_start_time
  $null = ConvertFrom-LockTimestamp 'Writer lock acquired_at' $Lock.acquired_at
}

function Assert-LocalFenceSchema([object] $LocalFence) {
  $requiredProperties = @(
    'version', 'control_repo_id', 'scope_id', 'run_epoch', 'writer_id',
    'lease_expires_at', 'lock_token', 'recovery_required', 'created_at'
  )
  Assert-ExactProperties 'Local writer fence' $LocalFence $requiredProperties
  if (-not (Test-IsInteger $LocalFence.version) -or [int64] $LocalFence.version -ne 1) { throw 'Local writer fence version must be integer 1.' }
  if (-not (Test-IsInteger $LocalFence.run_epoch) -or [int64] $LocalFence.run_epoch -lt 1 -or [int64] $LocalFence.run_epoch -gt [int]::MaxValue) { throw 'Local writer fence run_epoch must be a positive 32-bit integer.' }
  foreach ($name in @('control_repo_id', 'scope_id', 'writer_id', 'lease_expires_at', 'lock_token', 'created_at')) {
    if ($LocalFence.$name -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $LocalFence.$name)) { throw "Local writer fence $name must be a non-empty native String." }
  }
  Assert-StableId 'local writer fence control_repo_id' ([string] $LocalFence.control_repo_id)
  Assert-StableId 'local writer fence scope_id' ([string] $LocalFence.scope_id)
  Assert-WriterId 'local writer fence writer_id' ([string] $LocalFence.writer_id)
  if ([string] $LocalFence.lock_token -notmatch '^[A-Fa-f0-9]{32}$') { throw 'Local writer fence lock_token must be 32 hexadecimal characters.' }
  if ($LocalFence.recovery_required -isnot [bool]) { throw 'Local writer fence recovery_required must be a native Boolean.' }
  $null = ConvertFrom-LockTimestamp 'Local writer fence lease_expires_at' $LocalFence.lease_expires_at
  $null = ConvertFrom-LockTimestamp 'Local writer fence created_at' $LocalFence.created_at
}

function Invoke-Git([string] $Root, [string[]] $Arguments) {
  $output = & git -C $Root @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "git -C $Root $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  return ($output -join [Environment]::NewLine).Trim()
}

function Enter-ControlLifecycleGuard([string] $Root) {
  $guardDirectory = Join-Path $Root '.yefeng\local\locks'
  Assert-SafeInternalPath $guardDirectory $Root 'lifecycle-guard directory'
  New-Item -ItemType Directory -Path $guardDirectory -Force | Out-Null
  Assert-SafeInternalPath $guardDirectory $Root 'lifecycle-guard directory'
  $guardPath = Join-Path $guardDirectory 'control-repo.lifecycle.guard'
  Assert-SafeInternalPath $guardPath $Root 'lifecycle guard'
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

function Assert-JsonText([string] $Label, [string] $Content) {
  try { $null = $Content | ConvertFrom-Json -ErrorAction Stop }
  catch { throw "Invalid prepared JSON for ${Label}: $($_.Exception.Message)" }
}

function Assert-JsonLinesText([string] $Label, [string] $Content) {
  $lineNumber = 0
  foreach ($line in $Content -split "`r?`n") {
    $lineNumber++
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $null = $line | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Invalid prepared JSONL for $Label at line ${lineNumber}: $($_.Exception.Message)" }
  }
}

function Write-ControlTransitionTransaction([object[]] $Writes) {
  $transactionId = [guid]::NewGuid().ToString('N')
  $entries = @()
  $succeeded = $false
  $rollbackFailed = $false
  try {
    foreach ($write in $Writes) {
      if (-not (Test-Path -LiteralPath $write.Path -PathType Leaf)) { throw "Transaction target is missing: $($write.Path)" }
      $currentContent = [System.IO.File]::ReadAllText([string] $write.Path, $utf8NoBom)
      if (-not [string]::Equals($currentContent, [string] $write.ExpectedContent, [System.StringComparison]::Ordinal)) { throw "Transaction target changed before staging: $($write.Path)" }
      $directory = Split-Path -Parent $write.Path
      $leaf = Split-Path -Leaf $write.Path
      $temporaryPath = Join-Path $directory ".$leaf.yefeng-$transactionId.new.tmp"
      $backupPath = Join-Path $directory ".$leaf.yefeng-$transactionId.backup.tmp"
      $rollbackDiscardPath = Join-Path $directory ".$leaf.yefeng-$transactionId.rollback-discard.tmp"
      $entry = [pscustomobject]@{
        target = [string] $write.Path
        temporary = $temporaryPath
        backup = $backupPath
        rollback_discard = $rollbackDiscardPath
        expected_content = [string] $write.ExpectedContent
        applied = $false
      }
      $entries += $entry
      $stream = $null
      try {
        $stream = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $bytes = $utf8NoBom.GetBytes([string] $write.Content)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
      } finally {
        if ($stream) { $stream.Dispose() }
      }
    }
    foreach ($entry in $entries) {
      if (-not [string]::Equals([System.IO.File]::ReadAllText($entry.target, $utf8NoBom), $entry.expected_content, [System.StringComparison]::Ordinal)) {
        throw "Transaction target changed before apply: $($entry.target)"
      }
    }
    foreach ($entry in $entries) {
      [System.IO.File]::Replace($entry.temporary, $entry.target, $entry.backup)
      $entry.applied = $true
    }
    $succeeded = $true
  } catch {
    $writeError = $_
    $rollbackErrors = @()
    $appliedEntries = @($entries | Where-Object { $_.applied })
    [array]::Reverse($appliedEntries)
    foreach ($entry in $appliedEntries) {
      try {
        if (-not (Test-Path -LiteralPath $entry.backup -PathType Leaf)) { throw "Missing rollback backup: $($entry.backup)" }
        [System.IO.File]::Replace($entry.backup, $entry.target, $entry.rollback_discard)
        Remove-Item -LiteralPath $entry.rollback_discard -Force
        $entry.applied = $false
      } catch {
        $rollbackErrors += $_.Exception.Message
      }
    }
    if ($rollbackErrors.Count -gt 0) {
      $rollbackFailed = $true
      throw "Recovery transition write failed ($($writeError.Exception.Message)); rollback also failed and manual Git reconciliation is required: $($rollbackErrors -join '; ')"
    }
    throw $writeError
  } finally {
    if (-not $rollbackFailed -and ($succeeded -or @($entries | Where-Object { $_.applied }).Count -eq 0)) {
      foreach ($entry in $entries) {
        foreach ($temporaryArtifact in @($entry.temporary, $entry.backup, $entry.rollback_discard)) {
          if (Test-Path -LiteralPath $temporaryArtifact -PathType Leaf) { Remove-Item -LiteralPath $temporaryArtifact -Force }
        }
      }
    }
  }
}

if ($ScopeId -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw "Invalid ScopeId: $ScopeId" }
if ($CurrentWriterId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw "Invalid CurrentWriterId: $CurrentWriterId" }
if ($ReplacementWriterId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw "Invalid ReplacementWriterId: $ReplacementWriterId" }
if ($ReplacementWriterId -eq $CurrentWriterId) { throw 'ReplacementWriterId must differ from CurrentWriterId.' }
if ($LockToken -notmatch '^[A-Fa-f0-9]{32}$') { throw 'LockToken must be a 32-character hexadecimal token.' }
if ([string]::IsNullOrWhiteSpace($Reason)) { throw 'A recovery reason is required.' }
if ($utf8NoBom.GetByteCount($Reason) -gt 32768) { throw 'Recovery reason exceeds the 32768-byte UTF-8 limit.' }

$controlRootPath = Normalize-Path ((Resolve-Path -LiteralPath $ControlRoot).Path)
$unsupportedControlRoot = Find-UnsupportedPathRoot $controlRootPath
if ($unsupportedControlRoot) { throw "Control repository uses an unsupported path root: $unsupportedControlRoot" }
$controlReparsePoint = Find-ReparsePointInExistingPathChain $controlRootPath
if ($controlReparsePoint) { throw "Control repository path traverses a reparse point: $controlReparsePoint" }
$gitMetadataPath = Join-Path $controlRootPath '.git'
if (Test-Path -LiteralPath $gitMetadataPath) { Assert-SafeInternalPath $gitMetadataPath $controlRootPath '.git metadata' }
$gitTopLevel = Normalize-Path (Invoke-Git $controlRootPath @('rev-parse', '--show-toplevel'))
if (-not $gitTopLevel.Equals($controlRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "ControlRoot is not the control repository top level: $gitTopLevel"
}
$controlRootPath = $gitTopLevel

$lifecycleGuard = Enter-ControlLifecycleGuard $controlRootPath
try {
  $status = Invoke-Git $controlRootPath @('status', '--short')
  if ($status) { throw "Recovery transition must start from a clean control repository: $status" }

  $scopeRoot = Join-Path $controlRootPath ".yefeng\series\$ScopeId"
  $controlStatePath = Join-Path $scopeRoot 'state\control.json'
  $rolesPath = Join-Path $scopeRoot 'state\roles.json'
  $runsPath = Join-Path $scopeRoot 'state\runs.json'
  $transportPath = Join-Path $scopeRoot 'state\transport.json'
  $eventsPath = Join-Path $scopeRoot 'events.jsonl'
  $topologyPath = Join-Path $controlRootPath '.yefeng\control-plane.json'
  $localFencePath = Join-Path $controlRootPath ".yefeng\local\writer-fences\$ScopeId.json"
  $controlHeadPath = Join-Path $controlRootPath '.yefeng\local\control-head.json'
  $lockPath = Join-Path $controlRootPath '.yefeng\local\locks\control-repo.write.lock'
  Assert-SafeInternalPath $scopeRoot $controlRootPath "scope $ScopeId"
  $requiredInputs = @($controlStatePath, $rolesPath, $runsPath, $transportPath, $eventsPath, $topologyPath, $localFencePath, $controlHeadPath, $lockPath)
  foreach ($required in $requiredInputs) {
    Assert-SafeInternalPath $required $controlRootPath "recovery transition input $required"
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing recovery transition input: $required" }
  }

  $controlStateText = [System.IO.File]::ReadAllText($controlStatePath, $utf8NoBom)
  $rolesStateText = [System.IO.File]::ReadAllText($rolesPath, $utf8NoBom)
  $runsStateText = [System.IO.File]::ReadAllText($runsPath, $utf8NoBom)
  $transportStateText = [System.IO.File]::ReadAllText($transportPath, $utf8NoBom)
  $eventsText = [System.IO.File]::ReadAllText($eventsPath, $utf8NoBom)
  $topologyText = [System.IO.File]::ReadAllText($topologyPath, $utf8NoBom)
  $localFenceText = [System.IO.File]::ReadAllText($localFencePath, $utf8NoBom)
  $controlHeadText = [System.IO.File]::ReadAllText($controlHeadPath, $utf8NoBom)
  $lockJson = [System.IO.File]::ReadAllText($lockPath, $utf8NoBom)
  $controlState = ConvertFrom-ControlJson $controlStateText
  $rolesState = ConvertFrom-ControlJson $rolesStateText
  $runsState = ConvertFrom-ControlJson $runsStateText
  $transportState = ConvertFrom-ControlJson $transportStateText
  $topology = ConvertFrom-ControlJson $topologyText
  $localFence = ConvertFrom-ControlJson $localFenceText
  $controlHeadState = ConvertFrom-ControlJson $controlHeadText
  $lock = ConvertFrom-ControlJson $lockJson
  Assert-LocalFenceSchema $localFence
  Assert-WriterLockSchema $lock
  $authoritativeLockToken = [string] $lock.lock_token
  if (-not $localFence.recovery_required) { throw 'Local writer fence recovery_required must be true for a recovery transition.' }
  if (-not $lock.recovery_transition -or $lock.bootstrap_head_binding) { throw 'Writer lock must be an armed recovery transition and not a bootstrap HEAD binding.' }
  $actualHead = Invoke-Git $controlRootPath @('rev-parse', 'HEAD')

  if ($topology.control_plane_mode -ne 'external-git' -or $topology.control_repo_id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or $topology.active_scopes -notcontains $ScopeId) {
    throw 'Recovery transition topology/scope mismatch.'
  }
  if ($controlState.scope_id -ne $ScopeId -or $rolesState.scope_id -ne $ScopeId -or $runsState.scope_id -ne $ScopeId -or $transportState.scope_id -ne $ScopeId -or $localFence.scope_id -ne $ScopeId -or $lock.scope_id -ne $ScopeId) {
    throw 'Recovery transition scope identity mismatch.'
  }
  if (
    $controlState.control_repo_id -ne $topology.control_repo_id -or
    $rolesState.control_repo_id -ne $topology.control_repo_id -or
    $runsState.control_repo_id -ne $topology.control_repo_id -or
    $transportState.control_repo_id -ne $topology.control_repo_id -or
    $localFence.control_repo_id -ne $topology.control_repo_id -or
    $controlHeadState.control_repo_id -ne $topology.control_repo_id -or
    $lock.control_repo_id -ne $topology.control_repo_id
  ) { throw 'Recovery transition control repository identity mismatch.' }
  if ($lock.machine_name -ne [Environment]::MachineName) { throw 'Recovery transition lock belongs to a different machine.' }
  if (
    -not [string]::Equals($authoritativeLockToken, $LockToken, [System.StringComparison]::Ordinal) -or
    -not [string]::Equals([string] $localFence.lock_token, $authoritativeLockToken, [System.StringComparison]::Ordinal) -or
    $localFence.lease_expires_at -ne $lock.lease_expires_at
  ) { throw 'Recovery transition lock token/lease mismatch.' }
  if ($lock.writer_id -ne $CurrentWriterId -or $localFence.writer_id -ne $CurrentWriterId -or $controlState.writer_fence.writer_id -ne $CurrentWriterId) { throw 'Current writer identity mismatch.' }
  if ($controlState.run_epoch -ne $lock.run_epoch -or $localFence.run_epoch -ne $lock.run_epoch -or $rolesState.run_epoch -ne $lock.run_epoch -or $runsState.run_epoch -ne $lock.run_epoch -or $transportState.run_epoch -ne $lock.run_epoch) {
    throw 'Recovery transition epoch mismatch.'
  }
  if ($controlState.writer_fence.fence_epoch -ne $lock.run_epoch) { throw 'Tracked writer fence epoch mismatch.' }
  if ($lock.expected_control_head -notmatch '^[A-Fa-f0-9]{40,64}$') { throw 'Recovery transition expected HEAD is invalid.' }
  if ($actualHead -ne $lock.expected_control_head -or $controlHeadState.expected_control_head -ne $lock.expected_control_head) {
    throw "Recovery transition HEAD CAS mismatch: lock=$($lock.expected_control_head) local=$($controlHeadState.expected_control_head) actual=$actualHead"
  }

  if ([int] $controlState.version -ne 2 -or [int] $rolesState.version -ne 2 -or [int] $runsState.version -ne 2 -or [int] $transportState.version -ne 2) {
    throw 'Recovery transition state files must all use schema version 2.'
  }
  foreach ($collectionContract in @(
    [pscustomobject]@{ Object = $rolesState; Property = 'roles'; Label = 'roles' },
    [pscustomobject]@{ Object = $runsState; Property = 'runs'; Label = 'runs' },
    [pscustomobject]@{ Object = $transportState; Property = 'imported_messages'; Label = 'imported_messages' },
    [pscustomobject]@{ Object = $transportState; Property = 'quarantined_messages'; Label = 'quarantined_messages' }
  )) {
    if ($collectionContract.Object.PSObject.Properties.Name -notcontains $collectionContract.Property) {
      throw "Recovery transition state is missing the $($collectionContract.Label) collection."
    }
  }

  $topologyProductIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $topologyProductById = @{}
  foreach ($productRepository in @($topology.product_repositories)) {
    $productRepoId = [string] $productRepository.repo_id
    if ($productRepoId -notmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or -not $topologyProductIds.Add($productRepoId)) {
      throw "Topology product repository identity is missing or duplicated: $productRepoId"
    }
    if ([string]::IsNullOrWhiteSpace([string] $productRepository.integration_branch)) {
      throw "Topology product integration branch is missing: $productRepoId"
    }
    $topologyProductById[$productRepoId] = $productRepository
  }
  if ($topologyProductIds.Count -lt 1) { throw 'Recovery transition requires at least one topology product repository.' }

  $baselineProperties = @()
  if ($controlState.product_baselines) { $baselineProperties = @($controlState.product_baselines.PSObject.Properties) }
  $baselineIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($baselineProperty in $baselineProperties) {
    $productRepoId = [string] $baselineProperty.Name
    if (-not $baselineIds.Add($productRepoId) -or -not $topologyProductIds.Contains($productRepoId)) {
      throw "Recovery baseline has an unknown or duplicated product repository identity: $productRepoId"
    }
    $baseline = $baselineProperty.Value
    if (
      [string]::IsNullOrWhiteSpace([string] $baseline.branch) -or
      [string] $baseline.commit -notmatch '^[A-Fa-f0-9]{40,64}$' -or
      [string] $baseline.branch -ne [string] $topologyProductById[$productRepoId].integration_branch
    ) {
      throw "Recovery baseline is incomplete or conflicts with topology for product repository: $productRepoId"
    }
  }
  $baselineSetIsExact = ($baselineIds.Count -eq $topologyProductIds.Count)
  foreach ($productRepoId in @($topologyProductIds)) {
    if (-not $baselineIds.Contains([string] $productRepoId)) { $baselineSetIsExact = $false }
  }
  if (-not $baselineSetIsExact) { throw 'Recovery transition requires the exact topology product set in control product_baselines.' }

  $oldEpoch = [int] $controlState.run_epoch
  $newEpoch = $oldEpoch + 1
  $now = [DateTimeOffset]::UtcNow
  $nowText = $now.ToString('o')
  $operationId = "writer-recovery-$($now.ToString('yyyyMMddHHmmssfff'))-$([guid]::NewGuid().ToString('N').Substring(0, 8))"

  $runById = @{}
  $runAssignmentIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($run in @($runsState.runs)) {
    $runPropertyNames = @($run.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($requiredField in $requiredRunFields) {
      if ($runPropertyNames -notcontains $requiredField) { throw "Run schema is missing ${requiredField} before takeover: $($run.run_id)" }
    }
    $runId = [string] $run.run_id
    if ($runId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' -or $runById.ContainsKey($runId)) { throw "Run identity is missing or duplicated before takeover: $runId" }
    if ($run.scope_id -ne $ScopeId -or $run.control_repo_id -ne $topology.control_repo_id) { throw "Run identity mismatch before takeover: $runId" }
    $runEpoch = [int] $run.run_epoch
    $runState = [string] $run.status
    if ($runEpoch -lt 1 -or $runEpoch -gt $oldEpoch) { throw "Run epoch is invalid before takeover: $runId" }
    if ($allowedRunStates -notcontains $runState) { throw "Run state is invalid before takeover: $runId / $runState" }
    if ($runEpoch -lt $oldEpoch -and $terminalRunStates -notcontains $runState) { throw "A stale run is still active before takeover: $runId" }
    if (
      [string]::IsNullOrWhiteSpace([string] $run.role_id) -or
      [string]::IsNullOrWhiteSpace([string] $run.assignment_id) -or
      -not $runAssignmentIds.Add([string] $run.assignment_id)
    ) { throw "Run role/assignment identity is incomplete or duplicated before takeover: $runId" }
    if (
      [string]::IsNullOrWhiteSpace([string] $run.session_id) -or
      [string]::IsNullOrWhiteSpace([string] $run.product_worktree) -or
      [string]::IsNullOrWhiteSpace([string] $run.command) -or
      [string]::IsNullOrWhiteSpace([string] $run.cwd) -or
      [string]::IsNullOrWhiteSpace([string] $run.started_at) -or
      [string] $run.cwd -ne [string] $run.product_worktree
    ) { throw "Run execution identity is incomplete before takeover: $runId" }
    try { $null = [DateTimeOffset]::Parse([string] $run.started_at) }
    catch { throw "Run started_at is invalid before takeover: $runId" }
    if ($terminalRunStates -contains $runState) {
      if ([string]::IsNullOrWhiteSpace([string] $run.ended_at)) { throw "Terminal run ended_at is missing before takeover: $runId" }
      try { $null = [DateTimeOffset]::Parse([string] $run.ended_at) }
      catch { throw "Terminal run ended_at is invalid before takeover: $runId" }
    }
    $runProductRepoId = [string] $run.product_repo_id
    if (-not $topologyProductIds.Contains($runProductRepoId)) { throw "Run product repository identity is invalid before takeover: $runId" }
    $runBaseline = $controlState.product_baselines.PSObject.Properties[$runProductRepoId].Value
    if ($runEpoch -eq $oldEpoch -and (
      [string] $run.product_baseline_commit -ne [string] $runBaseline.commit -or
      [string] $run.product_branch -ne [string] $runBaseline.branch
    )) { throw "Current run product baseline identity mismatch before takeover: $runId" }
    if ([string] $run.transport_mode -notin @('control-spool', 'worktree-local')) { throw "Run transport mode is invalid before takeover: $runId" }
    $runById[$runId] = $run
  }

  $roleIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $roleAssignmentIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $referencedRunIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($role in @($rolesState.roles)) {
    $rolePropertyNames = @($role.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($requiredField in $requiredRoleFields) {
      if ($rolePropertyNames -notcontains $requiredField) { throw "Role schema is missing ${requiredField} before takeover: $($role.role_id)" }
    }
    $roleId = [string] $role.role_id
    if ($roleId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or -not $roleIds.Add($roleId)) { throw "Role identity is missing or duplicated before takeover: $roleId" }
    if ($role.scope_id -ne $ScopeId -or $role.control_repo_id -ne $topology.control_repo_id) { throw "Role identity mismatch before takeover: $roleId" }
    $roleEpoch = [int] $role.run_epoch
    $roleState = [string] $role.state
    if ($roleEpoch -lt 1 -or $roleEpoch -gt $oldEpoch) { throw "Role epoch is invalid before takeover: $roleId" }
    if ($allowedRoleStates -notcontains $roleState) { throw "Role state is invalid before takeover: $roleId / $roleState" }
    $hasLease = -not [string]::IsNullOrWhiteSpace([string] $role.lease_expires_at)
    if ($roleEpoch -lt $oldEpoch -and ($terminalRoleStates -notcontains $roleState -or $hasLease)) { throw "A stale role is still active or leased before takeover: $roleId" }
    if ($terminalRoleStates -contains $roleState -and $hasLease) { throw "A terminal role still has a lease before takeover: $roleId" }

    $roleProductRepoId = [string] $role.product_repo_id
    if (-not $topologyProductIds.Contains($roleProductRepoId)) { throw "Role product repository identity is invalid before takeover: $roleId" }
    $roleBaseline = $controlState.product_baselines.PSObject.Properties[$roleProductRepoId].Value
    if ($roleEpoch -eq $oldEpoch -and (
      [string] $role.product_baseline_commit -ne [string] $roleBaseline.commit -or
      [string] $role.product_branch -ne [string] $roleBaseline.branch
    )) { throw "Current role product baseline identity mismatch before takeover: $roleId" }
    if ([string] $role.transport_mode -notin @('control-spool', 'worktree-local')) { throw "Role transport mode is invalid before takeover: $roleId" }

    $roleRunId = [string] $role.run_id
    if ($roleState -eq 'PLANNED') {
      $runtimeFields = @($role.assigned_by, $role.assignment_id, $role.session_id, $role.process_id, $role.run_id, $role.product_worktree, $role.lease_expires_at)
      if (@($runtimeFields | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string] $_) }).Count -gt 0) {
        throw "A PLANNED role contains runtime identity before takeover: $roleId"
      }
    } elseif ($roleEpoch -eq $oldEpoch -and $terminalRoleStates -notcontains $roleState) {
      if (
        [string]::IsNullOrWhiteSpace([string] $role.assigned_by) -or
        [string]::IsNullOrWhiteSpace([string] $role.assignment_id) -or
        -not $roleAssignmentIds.Add([string] $role.assignment_id)
      ) { throw "Active role assignment identity is incomplete or duplicated before takeover: $roleId" }
      if ($launchedRoleStates -contains $roleState -and (
        [string]::IsNullOrWhiteSpace($roleRunId) -or
        [string]::IsNullOrWhiteSpace([string] $role.session_id) -or
        [string]::IsNullOrWhiteSpace([string] $role.product_worktree) -or
        -not $hasLease
      )) { throw "Launched role execution identity is incomplete before takeover: $roleId" }
    }

    if (-not [string]::IsNullOrWhiteSpace($roleRunId)) {
      if (-not $runById.ContainsKey($roleRunId) -or -not $referencedRunIds.Add($roleRunId)) { throw "Role references a missing or multiply-owned run before takeover: $roleId / $roleRunId" }
      $matchingRun = $runById[$roleRunId]
      if (
        [string] $matchingRun.role_id -ne $roleId -or
        [string] $matchingRun.assignment_id -ne [string] $role.assignment_id -or
        [int] $matchingRun.run_epoch -ne $roleEpoch -or
        [string] $matchingRun.product_repo_id -ne $roleProductRepoId -or
        [string] $matchingRun.product_baseline_commit -ne [string] $role.product_baseline_commit -or
        [string] $matchingRun.product_branch -ne [string] $role.product_branch -or
        [string] $matchingRun.product_worktree -ne [string] $role.product_worktree -or
        [string] $matchingRun.transport_mode -ne [string] $role.transport_mode -or
        [string] $matchingRun.session_id -ne [string] $role.session_id -or
        [string] $matchingRun.process_id -ne [string] $role.process_id
      ) { throw "Role/run execution identity mismatch before takeover: $roleId / $roleRunId" }
      if (($terminalRoleStates -contains $roleState) -ne ($terminalRunStates -contains [string] $matchingRun.status)) {
        throw "Role/run lifecycle state mismatch before takeover: $roleId / $roleRunId"
      }
    }
  }

  foreach ($run in @($runsState.runs)) {
    if ([int] $run.run_epoch -eq $oldEpoch -and $terminalRunStates -notcontains [string] $run.status -and -not $referencedRunIds.Contains([string] $run.run_id)) {
      throw "An active run is not owned by a current role before takeover: $($run.run_id)"
    }
  }

  # Mutate only after every pre-takeover identity and association has passed validation.
  foreach ($role in @($rolesState.roles)) {
    $roleEpoch = [int] $role.run_epoch
    $roleState = [string] $role.state
    if ($roleEpoch -eq $oldEpoch -and $roleState -eq 'PLANNED') {
      $role.run_epoch = $newEpoch
    } elseif ($roleEpoch -eq $oldEpoch -and $terminalRoleStates -notcontains $roleState) {
      $role.state = 'EXPIRED'
      $role.lease_expires_at = ''
      $role.blocked_by = "writer takeover invalidated run_epoch $oldEpoch"
      $role.resume_when = "a new assignment is issued in run_epoch $newEpoch"
      $role.required_evidence = 'new assignment_id and run_id bound to the current epoch'
      $role.wake_target = 'TOTAL_CONTROL'
      $role.last_output = "Previous assignment expired during writer takeover at $nowText."
    }
  }

  foreach ($run in @($runsState.runs)) {
    if ([int] $run.run_epoch -eq $oldEpoch -and $terminalRunStates -notcontains [string] $run.status) {
      $run.status = 'EXPIRED'
      $run.ended_at = $nowText
      if ($run.PSObject.Properties.Name -contains 'termination_reason') {
        $run.termination_reason = "writer takeover invalidated run_epoch $oldEpoch"
      } else {
        $run | Add-Member -NotePropertyName termination_reason -NotePropertyValue "writer takeover invalidated run_epoch $oldEpoch"
      }
    }
  }

  $eventProductBaselines = [ordered]@{}
  foreach ($productRepository in @($topology.product_repositories)) {
    $productRepoId = [string] $productRepository.repo_id
    $baseline = $controlState.product_baselines.PSObject.Properties[$productRepoId].Value
    $eventProductBaselines[$productRepoId] = [ordered]@{
      branch = [string] $baseline.branch
      commit = [string] $baseline.commit
    }
  }
  if ($eventProductBaselines.Count -ne $topologyProductIds.Count) { throw 'Recovery event baseline map is not complete.' }

  $controlState.run_epoch = $newEpoch
  $controlState.lifecycle_state = 'RECOVERING'
  $controlState.writer_fence.writer_id = $ReplacementWriterId
  $controlState.writer_fence.fence_epoch = $newEpoch
  $controlState.writer_fence.lease_expires_at = $null
  $controlState.updated_at = $nowText
  $rolesState.run_epoch = $newEpoch
  $runsState.run_epoch = $newEpoch
  $transportState.run_epoch = $newEpoch
  $transportState.updated_at = $nowText

  $event = [ordered]@{
    event_id = "evt-$operationId"
    created_at = $nowText
    type = 'RECOVERY_STARTED'
    control_plane_mode = 'external-git'
    control_repo_id = $topology.control_repo_id
    scope_id = $ScopeId
    run_epoch = $newEpoch
    operation_id = $operationId
    recovery_lock_sha256 = Get-Sha256Hex $authoritativeLockToken
    previous_writer_id = $CurrentWriterId
    replacement_writer_id = $ReplacementWriterId
    assignment_id = $null
    run_id = $null
    from = 'TOTAL_CONTROL'
    to = 'TOTAL_CONTROL'
    blocking = $true
    status = 'OPEN'
    payload = $Reason
    product_baselines = $eventProductBaselines
    evidence = @()
  }

  $controlJson = ($controlState | ConvertTo-Json -Depth 30) + "`n"
  $rolesJson = ($rolesState | ConvertTo-Json -Depth 30) + "`n"
  $runsJson = ($runsState | ConvertTo-Json -Depth 30) + "`n"
  $transportJson = ($transportState | ConvertTo-Json -Depth 30) + "`n"
  $eventJsonLine = $event | ConvertTo-Json -Compress -Depth 30
  if ($eventJsonLine.IndexOf($authoritativeLockToken, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
    throw 'RECOVERY_STARTED event must not contain the raw writer lock token.'
  }
  if ($utf8NoBom.GetByteCount($eventJsonLine) -gt 65536) { throw 'RECOVERY_STARTED event exceeds the 65536-byte UTF-8 JSONL record limit.' }
  $newEventsText = $eventsText + $(if ($eventsText -and -not $eventsText.EndsWith("`n")) { "`n" } else { '' }) + $eventJsonLine + "`n"
  Assert-JsonText 'control state' $controlJson
  Assert-JsonText 'roles state' $rolesJson
  Assert-JsonText 'runs state' $runsJson
  Assert-JsonText 'transport state' $transportJson
  Assert-JsonLinesText 'events' $newEventsText

  $statusBeforeWrite = Invoke-Git $controlRootPath @('status', '--short')
  $headBeforeWrite = Invoke-Git $controlRootPath @('rev-parse', 'HEAD')
  $inputsAreUnchanged = (
    [string]::Equals([System.IO.File]::ReadAllText($controlStatePath, $utf8NoBom), $controlStateText, [System.StringComparison]::Ordinal) -and
    [string]::Equals([System.IO.File]::ReadAllText($rolesPath, $utf8NoBom), $rolesStateText, [System.StringComparison]::Ordinal) -and
    [string]::Equals([System.IO.File]::ReadAllText($runsPath, $utf8NoBom), $runsStateText, [System.StringComparison]::Ordinal) -and
    [string]::Equals([System.IO.File]::ReadAllText($transportPath, $utf8NoBom), $transportStateText, [System.StringComparison]::Ordinal) -and
    [string]::Equals([System.IO.File]::ReadAllText($eventsPath, $utf8NoBom), $eventsText, [System.StringComparison]::Ordinal) -and
    [string]::Equals([System.IO.File]::ReadAllText($topologyPath, $utf8NoBom), $topologyText, [System.StringComparison]::Ordinal) -and
    [string]::Equals([System.IO.File]::ReadAllText($localFencePath, $utf8NoBom), $localFenceText, [System.StringComparison]::Ordinal) -and
    [string]::Equals([System.IO.File]::ReadAllText($controlHeadPath, $utf8NoBom), $controlHeadText, [System.StringComparison]::Ordinal) -and
    [string]::Equals([System.IO.File]::ReadAllText($lockPath, $utf8NoBom), $lockJson, [System.StringComparison]::Ordinal)
  )
  if ($statusBeforeWrite -or $headBeforeWrite -ne $lock.expected_control_head -or -not $inputsAreUnchanged) {
    throw 'Recovery transition changed during preparation; refusing the state write.'
  }

  Write-ControlTransitionTransaction @(
    [pscustomobject]@{ Path = $controlStatePath; ExpectedContent = $controlStateText; Content = $controlJson },
    [pscustomobject]@{ Path = $rolesPath; ExpectedContent = $rolesStateText; Content = $rolesJson },
    [pscustomobject]@{ Path = $runsPath; ExpectedContent = $runsStateText; Content = $runsJson },
    [pscustomobject]@{ Path = $transportPath; ExpectedContent = $transportStateText; Content = $transportJson },
    [pscustomobject]@{ Path = $eventsPath; ExpectedContent = $eventsText; Content = $newEventsText }
  )

  [ordered]@{
    prepared = $true
    scope_id = $ScopeId
    previous_run_epoch = $oldEpoch
    replacement_run_epoch = $newEpoch
    previous_writer_id = $CurrentWriterId
    replacement_writer_id = $ReplacementWriterId
    operation_id = $operationId
    recovery_lock_sha256 = Get-Sha256Hex $authoritativeLockToken
    expected_control_head = $lock.expected_control_head
    next_action = 'Review the explicit state/event diff, commit it once, then call exit-control-write.ps1 with replacement fields.'
  } | ConvertTo-Json -Depth 10
} finally {
  $lifecycleGuard.Dispose()
}
