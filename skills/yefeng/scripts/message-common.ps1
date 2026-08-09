Set-StrictMode -Version Latest

$script:YefengUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:YefengUtf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:YefengMaximumMessageBytes = 65536
$script:YefengActiveRoleStates = @(
  'RUNNING',
  'WAITING_REVIEW',
  'BLOCKED',
  'READY_TO_RESUME',
  'REPORT_READY',
  'MERGE_READY'
)
$script:YefengMessageTypes = @(
  'QUESTION',
  'ANSWER',
  'BLOCKER',
  'CONTRACT_CHANGE',
  'REVIEW_REQUEST',
  'REVIEW_RESULT',
  'HANDOFF',
  'BASELINE_UPDATED',
  'RESUME_NOTICE',
  'USER_DECISION_REQUIRED',
  'DIRECTIVE',
  'PROGRESS',
  'CHECKPOINT',
  'HEARTBEAT'
)

function Normalize-YefengPath([string] $Value) {
  $fullPath = [System.IO.Path]::GetFullPath($Value)
  $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
  if ($fullPath.Equals($pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $pathRoot
  }
  return $fullPath.TrimEnd('\', '/')
}

function Test-YefengPathWithin([string] $Child, [string] $Parent) {
  $childPath = (Normalize-YefengPath $Child) + [System.IO.Path]::DirectorySeparatorChar
  $parentPath = (Normalize-YefengPath $Parent) + [System.IO.Path]::DirectorySeparatorChar
  return $childPath.StartsWith(
    $parentPath,
    [System.StringComparison]::OrdinalIgnoreCase
  )
}

function Find-YefengReparsePointInExistingPathChain([string] $Value) {
  $fullPath = Normalize-YefengPath $Value
  $pathRoot = Normalize-YefengPath ([System.IO.Path]::GetPathRoot($fullPath))
  $probe = $fullPath
  while (-not (Test-Path -LiteralPath $probe)) {
    if ($probe.Equals($pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $fullPath
    }
    $parent = Split-Path -Parent $probe
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) {
      return $fullPath
    }
    $probe = Normalize-YefengPath $parent
  }
  while ($true) {
    $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
      return $probe
    }
    if ($probe.Equals($pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      break
    }
    $parent = Split-Path -Parent $probe
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) {
      break
    }
    $probe = Normalize-YefengPath $parent
  }
  return $null
}

function Assert-YefengPathInside(
  [string] $Root,
  [string] $Value,
  [string] $Label,
  [switch] $AllowRoot
) {
  $rootPath = Normalize-YefengPath $Root
  $fullPath = Normalize-YefengPath $Value
  $isRoot = $fullPath.Equals(
    $rootPath,
    [System.StringComparison]::OrdinalIgnoreCase
  )
  if ((-not $AllowRoot -and $isRoot) -or (-not $isRoot -and -not (Test-YefengPathWithin $fullPath $rootPath))) {
    throw "$Label escapes its allowed root: $fullPath"
  }
  $reparsePoint = Find-YefengReparsePointInExistingPathChain $fullPath
  if ($reparsePoint) {
    throw "$Label traverses a reparse point: $reparsePoint"
  }
  return $fullPath
}

function Assert-YefengStableId([string] $Label, [object] $Value) {
  if (
    $Value -isnot [string] -or
    [string]::IsNullOrWhiteSpace([string] $Value) -or
    [string] $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or
    [string] $Value -match '[\\/:]' -or
    [string] $Value -in @('.', '..') -or
    [string] $Value -match '[. ]$' -or
    [string] $Value -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
  ) {
    throw "$Label is not a path-free stable identifier."
  }
}

function Test-YefengInteger([object] $Value) {
  return (
    $Value -is [sbyte] -or $Value -is [byte] -or
    $Value -is [int16] -or $Value -is [uint16] -or
    $Value -is [int32] -or $Value -is [uint32] -or
    $Value -is [int64] -or $Value -is [uint64]
  )
}

function Assert-YefengRequiredProperties(
  [string] $Label,
  [object] $Value,
  [string[]] $Names
) {
  if ($null -eq $Value) {
    throw "$Label is null."
  }
  $properties = @($Value.PSObject.Properties | ForEach-Object { [string] $_.Name })
  foreach ($name in $Names) {
    if ($properties -notcontains $name) {
      throw "$Label is missing required property: $name"
    }
  }
}

function Assert-YefengExactProperties(
  [string] $Label,
  [object] $Value,
  [string[]] $Names
) {
  Assert-YefengRequiredProperties $Label $Value $Names
  $actual = @($Value.PSObject.Properties | ForEach-Object { [string] $_.Name })
  if ($actual.Count -ne $Names.Count) {
    throw "$Label contains an unknown or duplicated property."
  }
  foreach ($name in $actual) {
    if ($Names -cnotcontains $name) {
      throw "$Label contains an unknown property: $name"
    }
  }
}

function ConvertFrom-YefengJson([string] $Text) {
  $command = Get-Command ConvertFrom-Json -ErrorAction Stop
  if ($command.Parameters.ContainsKey('DateKind')) {
    return $Text | ConvertFrom-Json -DateKind String -ErrorAction Stop
  }
  return $Text | ConvertFrom-Json -ErrorAction Stop
}

function Read-YefengJsonFile(
  [string] $Path,
  [int] $MaximumBytes = 65536
) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Required JSON file does not exist: $Path"
  }
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw "JSON file is a reparse point: $Path"
  }
  if ($item.Length -gt $MaximumBytes) {
    throw "JSON file exceeds the $MaximumBytes byte limit: $Path"
  }
  $stream = $null
  try {
    $stream = [System.IO.File]::Open(
      $item.FullName,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::Read
    )
    $bytes = New-Object byte[] $stream.Length
    $read = 0
    while ($read -lt $bytes.Length) {
      $count = $stream.Read($bytes, $read, $bytes.Length - $read)
      if ($count -eq 0) {
        throw "Unexpected end of JSON file: $Path"
      }
      $read += $count
    }
  } finally {
    if ($null -ne $stream) {
      $stream.Dispose()
    }
  }
  $text = $script:YefengUtf8Strict.GetString($bytes)
  return ConvertFrom-YefengJson $text
}

function Write-YefengUtf8FileAtomically(
  [string] $Path,
  [string] $Content,
  [switch] $NoOverwrite
) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $leaf = Split-Path -Leaf $Path
  $temporaryPath = Join-Path $directory ".$leaf.tmp.$([guid]::NewGuid().ToString('N'))"
  $backupPath = Join-Path $directory ".$leaf.backup.$([guid]::NewGuid().ToString('N')).tmp"
  $stream = $null
  try {
    $stream = [System.IO.File]::Open(
      $temporaryPath,
      [System.IO.FileMode]::CreateNew,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None
    )
    $bytes = $script:YefengUtf8NoBom.GetBytes($Content)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
    $stream.Dispose()
    $stream = $null
    if ($NoOverwrite) {
      [System.IO.File]::Move($temporaryPath, $Path)
    } elseif ([System.IO.File]::Exists($Path)) {
      [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
      [System.IO.File]::Delete($backupPath)
    } else {
      [System.IO.File]::Move($temporaryPath, $Path)
    }
  } finally {
    if ($null -ne $stream) {
      $stream.Dispose()
    }
    if ([System.IO.File]::Exists($temporaryPath)) {
      [System.IO.File]::Delete($temporaryPath)
    }
    if ([System.IO.File]::Exists($backupPath)) {
      [System.IO.File]::Delete($backupPath)
    }
  }
}

function Get-YefengSha256Hex([byte[]] $Bytes) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-YefengFileSha256Hex([string] $Path) {
  $stream = $null
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $stream = [System.IO.File]::Open(
      $Path,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::Read
    )
    return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
  } finally {
    if ($null -ne $stream) {
      $stream.Dispose()
    }
    $sha.Dispose()
  }
}

function Get-YefengFileBytes([string] $Path, [int] $MaximumBytes = 65536) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if (-not $item.PSIsContainer -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "Message file is a reparse point: $Path"
  }
  if ($item.PSIsContainer) {
    throw "Expected a message file, found a directory: $Path"
  }
  if ($item.Length -gt $MaximumBytes) {
    throw "Message exceeds the $MaximumBytes byte limit."
  }
  return [System.IO.File]::ReadAllBytes($item.FullName)
}

function Assert-YefengTimestamp([string] $Label, [object] $Value) {
  if (
    $Value -isnot [string] -or
    [string] $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$'
  ) {
    throw "$Label must be an ISO-8601 timestamp with an explicit offset."
  }
  $parsed = [DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse(
    [string] $Value,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::RoundtripKind,
    [ref] $parsed
  )) {
    throw "$Label is not parseable."
  }
}

function Invoke-YefengGit([string] $Root, [string[]] $Arguments) {
  $output = & git -C $Root @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "git -C $Root $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  return ($output -join [Environment]::NewLine).Trim()
}

function Get-YefengControlSnapshot(
  [string] $ControlRoot,
  [string] $ScopeId,
  [switch] $RequireActiveExecution
) {
  Assert-YefengStableId 'ScopeId' $ScopeId
  $controlRootPath = Normalize-YefengPath ((Resolve-Path -LiteralPath $ControlRoot).Path)
  if ($controlRootPath.StartsWith('\\', [System.StringComparison]::Ordinal)) {
    throw 'UNC control roots are not supported by the broker.'
  }
  $reparsePoint = Find-YefengReparsePointInExistingPathChain $controlRootPath
  if ($reparsePoint) {
    throw "ControlRoot traverses a reparse point: $reparsePoint"
  }
  $gitTop = Normalize-YefengPath (Invoke-YefengGit $controlRootPath @('rev-parse', '--show-toplevel'))
  if (-not $gitTop.Equals($controlRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ControlRoot is not the exact Git top level: $gitTop"
  }
  $topologyPath = Assert-YefengPathInside $controlRootPath (Join-Path $controlRootPath '.yefeng\control-plane.json') 'Topology path'
  $scopeRoot = Assert-YefengPathInside $controlRootPath (Join-Path $controlRootPath ".yefeng\series\$ScopeId") 'Scope root'
  $stateRoot = Assert-YefengPathInside $controlRootPath (Join-Path $scopeRoot 'state') 'Scope state root'
  $topology = Read-YefengJsonFile $topologyPath
  $control = Read-YefengJsonFile (Join-Path $stateRoot 'control.json')
  $roles = Read-YefengJsonFile (Join-Path $stateRoot 'roles.json')
  $runs = Read-YefengJsonFile (Join-Path $stateRoot 'runs.json')
  Assert-YefengRequiredProperties 'Control topology' $topology @(
    'control_plane_mode',
    'control_repo_id',
    'active_scopes'
  )
  Assert-YefengRequiredProperties 'Control state' $control @(
    'scope_id',
    'run_epoch',
    'lifecycle_state',
    'startup_level',
    'control_repo_id'
  )
  foreach ($state in @($roles, $runs)) {
    Assert-YefengRequiredProperties 'Scope state' $state @(
      'scope_id',
      'run_epoch',
      'control_repo_id'
    )
  }
  if ([string] $topology.control_plane_mode -ne 'external-git') {
    throw 'The runtime broker currently supports external-git control planes only.'
  }
  if (@($topology.active_scopes) -cnotcontains $ScopeId) {
    throw "Scope is not active in the control topology: $ScopeId"
  }
  if (
    [string] $control.scope_id -cne $ScopeId -or
    [string] $roles.scope_id -cne $ScopeId -or
    [string] $runs.scope_id -cne $ScopeId
  ) {
    throw 'Scope identity mismatch across control state.'
  }
  if (
    [string] $control.control_repo_id -cne [string] $topology.control_repo_id -or
    [string] $roles.control_repo_id -cne [string] $topology.control_repo_id -or
    [string] $runs.control_repo_id -cne [string] $topology.control_repo_id
  ) {
    throw 'Control repository identity mismatch across scope state.'
  }
  if (
    -not (Test-YefengInteger $control.run_epoch) -or
    [int64] $control.run_epoch -lt 1 -or
    -not (Test-YefengInteger $roles.run_epoch) -or
    -not (Test-YefengInteger $runs.run_epoch) -or
    [int64] $roles.run_epoch -ne [int64] $control.run_epoch -or
    [int64] $runs.run_epoch -ne [int64] $control.run_epoch
  ) {
    throw 'Scope epoch mismatch across control state.'
  }
  if ($RequireActiveExecution) {
    if ([string] $control.lifecycle_state -cne 'ACTIVE') {
      throw "Scope lifecycle does not permit broker execution: $($control.lifecycle_state)"
    }
    if ([string] $control.startup_level -cne 'LEVEL_3_FULL_PARALLEL_YEFENG') {
      throw "Broker execution requires LEVEL_3_FULL_PARALLEL_YEFENG."
    }
  }
  return [pscustomobject]@{
    control_root = $controlRootPath
    scope_root = $scopeRoot
    topology = $topology
    control = $control
    roles = $roles
    runs = $runs
  }
}

function Get-YefengBrokerPaths([string] $ControlRoot, [string] $ScopeId) {
  $runtimeRoot = Assert-YefengPathInside $ControlRoot (Join-Path $ControlRoot ".yefeng\broker\$ScopeId") 'Broker runtime root'
  return [pscustomobject]@{
    runtime_root = $runtimeRoot
    journal_path = Join-Path $runtimeRoot 'journal\events.jsonl'
    inbox_root = Join-Path $runtimeRoot 'inbox'
    receipt_root = Join-Path $runtimeRoot 'receipts'
    logs_root = Join-Path $runtimeRoot 'logs'
    guard_path = Join-Path $runtimeRoot 'broker.guard'
    process_state_path = Join-Path $runtimeRoot 'process.json'
    stop_request_path = Join-Path $runtimeRoot 'stop-request.json'
    outbox_root = Assert-YefengPathInside $ControlRoot (Join-Path $ControlRoot ".yefeng\outbox\$ScopeId") 'Scope outbox root'
    quarantine_root = Assert-YefengPathInside $ControlRoot (Join-Path $ControlRoot ".yefeng\quarantine\$ScopeId") 'Scope quarantine root'
  }
}

function Get-YefengAssignmentContext([string] $AssignmentPath) {
  $assignmentFullPath = Normalize-YefengPath ((Resolve-Path -LiteralPath $AssignmentPath).Path)
  $assignment = Read-YefengJsonFile $assignmentFullPath
  Assert-YefengRequiredProperties 'Assignment manifest' $assignment @(
    'version',
    'control_plane_mode',
    'control_repo_id',
    'control_root',
    'scope_id',
    'run_epoch',
    'assignment_id',
    'run_id',
    'role_id',
    'transport_mode',
    'outbox_dir',
    'inbox_dir'
  )
  foreach ($name in @('control_repo_id', 'scope_id', 'assignment_id', 'run_id', 'role_id')) {
    Assert-YefengStableId "Assignment $name" $assignment.$name
  }
  if (
    -not (Test-YefengInteger $assignment.version) -or
    [int64] $assignment.version -ne 1
  ) {
    throw 'Assignment version must be integer 1.'
  }
  if (
    -not (Test-YefengInteger $assignment.run_epoch) -or
    [int64] $assignment.run_epoch -lt 1
  ) {
    throw 'Assignment run_epoch must be a positive integer.'
  }
  if ([string] $assignment.control_plane_mode -cne 'external-git') {
    throw 'The message client requires an external-git assignment.'
  }
  if ([string] $assignment.transport_mode -cne 'control-spool') {
    throw 'The first broker version requires transport_mode=control-spool.'
  }
  $snapshot = Get-YefengControlSnapshot ([string] $assignment.control_root) ([string] $assignment.scope_id) -RequireActiveExecution
  if ([string] $assignment.control_repo_id -cne [string] $snapshot.topology.control_repo_id) {
    throw 'Assignment control_repo_id does not match the control topology.'
  }
  if ([int64] $assignment.run_epoch -ne [int64] $snapshot.control.run_epoch) {
    throw 'Assignment run_epoch is stale.'
  }
  $paths = Get-YefengBrokerPaths $snapshot.control_root ([string] $assignment.scope_id)
  $expectedOutbox = Normalize-YefengPath (
    Join-Path $paths.outbox_root (
      Join-Path ([string] $assignment.role_id) ([string] $assignment.run_id)
    )
  )
  $declaredOutbox = Normalize-YefengPath ([string] $assignment.outbox_dir)
  if (-not $declaredOutbox.Equals($expectedOutbox, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Assignment outbox_dir does not match its exact control spool: $declaredOutbox"
  }
  $null = Assert-YefengPathInside $paths.outbox_root $declaredOutbox 'Assignment outbox'
  $expectedInbox = Normalize-YefengPath (
    Join-Path $paths.inbox_root ([string] $assignment.role_id)
  )
  $declaredInbox = Normalize-YefengPath ([string] $assignment.inbox_dir)
  if (-not $declaredInbox.Equals($expectedInbox, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Assignment inbox_dir does not match its exact broker inbox: $declaredInbox"
  }
  $null = Assert-YefengPathInside $paths.inbox_root $declaredInbox 'Assignment inbox'

  $matchingRoles = @($snapshot.roles.roles | Where-Object {
    [string] $_.role_id -ceq [string] $assignment.role_id
  })
  if ($matchingRoles.Count -ne 1) {
    throw 'Assignment role identity is absent or ambiguous in roles state.'
  }
  $role = $matchingRoles[0]
  if (
    [string] $role.assignment_id -cne [string] $assignment.assignment_id -or
    [string] $role.run_id -cne [string] $assignment.run_id -or
    [int64] $role.run_epoch -ne [int64] $assignment.run_epoch -or
    [string] $role.control_repo_id -cne [string] $assignment.control_repo_id -or
    $script:YefengActiveRoleStates -cnotcontains [string] $role.state
  ) {
    throw 'Assignment does not match one active governed role.'
  }
  $matchingRuns = @($snapshot.runs.runs | Where-Object {
    [string] $_.run_id -ceq [string] $assignment.run_id
  })
  if ($matchingRuns.Count -ne 1) {
    throw 'Assignment run identity is absent or ambiguous in runs state.'
  }
  $run = $matchingRuns[0]
  if (
    [string] $run.role_id -cne [string] $assignment.role_id -or
    [string] $run.assignment_id -cne [string] $assignment.assignment_id -or
    [int64] $run.run_epoch -ne [int64] $assignment.run_epoch -or
    [string] $run.control_repo_id -cne [string] $assignment.control_repo_id -or
    [string] $run.transport_mode -cne 'control-spool' -or
    [string] $run.status -cne 'RUNNING'
  ) {
    throw 'Assignment does not match one active governed run.'
  }
  return [pscustomobject]@{
    assignment_path = $assignmentFullPath
    assignment = $assignment
    snapshot = $snapshot
    paths = $paths
    role = $role
    run = $run
    outbox_dir = $declaredOutbox
    inbox_dir = $declaredInbox
  }
}
