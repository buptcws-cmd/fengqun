[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $ControlRoot,

  [string] $ProductRoot = "",
  [string] $ExpectedScopeId = "",
  [switch] $RequireCommitted,
  [switch] $RequireProductBinding
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
$issues = [System.Collections.Generic.List[string]]::new()
$knownEventTypes = @(
  'CONTROL_BOOTSTRAPPED', 'ROLE_ASSIGNED', 'ROLE_STARTED', 'ROLE_OUTPUT', 'ROLE_BLOCKED',
  'ROLE_READY_TO_RESUME', 'ROLE_DONE', 'QUESTION', 'ANSWER', 'BLOCKER', 'CONTRACT_CHANGE',
  'REVIEW_REQUEST', 'REVIEW_RESULT', 'HANDOFF', 'BASELINE_UPDATED', 'INTEGRATION_INTENT',
  'PRODUCT_COMMITTED', 'PRODUCT_VERIFIED', 'CONTROL_COMMITTED', 'RECONCILIATION_REQUIRED',
  'IMPORT_RECEIPT', 'RECOVERY_STARTED', 'RECOVERY_COMPLETED', 'RESUME_NOTICE',
  'USER_DECISION_REQUIRED', 'DIRECTIVE', 'RUN_EVIDENCE_RETENTION_PREPARED',
  'RUN_EVIDENCE_RETENTION_APPLIED'
)
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
$structuredRetentionRunFields = @(
  'run_root', 'retention_group_id', 'parent_run_id', 'review_gate', 'control_disposition'
)
$allowedReviewGates = @('PENDING', 'PASSED', 'FAILED', 'NOT_REQUIRED')
$allowedControlDispositions = @(
  'ACTIVE', 'UNREVIEWED', 'BLOCKING', 'RECOVERY', 'RECONCILIATION',
  'SUPERSEDED', 'ACCEPTED', 'ARCHIVED', 'DISCARDABLE'
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

function Test-CanonicalDateTimeOffsetText([object] $Value) {
  if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $Value)) { return $false }
  $parsed = [DateTimeOffset]::MinValue
  $valid = [DateTimeOffset]::TryParseExact(
    [string] $Value,
    'o',
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind,
    [ref] $parsed
  )
  return (
    $valid -and
    $parsed.ToString('o', [Globalization.CultureInfo]::InvariantCulture) -ceq [string] $Value
  )
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

function Invoke-GitRead([string] $Root, [string[]] $Arguments) {
  $output = & git -C $Root @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    $issues.Add("git -C $Root $($Arguments -join ' ') failed: $($output -join ' ')")
    return ""
  }
  return ($output -join [Environment]::NewLine).Trim()
}

function Invoke-GitOptional([string] $Root, [string[]] $Arguments) {
  $output = & git -C $Root @Arguments 2>$null
  if ($LASTEXITCODE -ne 0) { return "" }
  return ($output -join [Environment]::NewLine).Trim()
}

function Invoke-GitProbe([string] $Root, [string[]] $Arguments) {
  $output = @(& git -C $Root @Arguments 2>&1)
  $exitCode = $LASTEXITCODE
  return [pscustomobject]@{
    exit_code = $exitCode
    lines = @($output | ForEach-Object { [string] $_ })
  }
}

function Invoke-ProductGitRead([string] $Root, [string[]] $Arguments) {
  $hadValue = Test-Path Env:GIT_OPTIONAL_LOCKS
  $previousValue = $env:GIT_OPTIONAL_LOCKS
  try {
    $env:GIT_OPTIONAL_LOCKS = '0'
    return Invoke-GitRead $Root $Arguments
  } finally {
    if ($hadValue) { $env:GIT_OPTIONAL_LOCKS = $previousValue }
    else { Remove-Item Env:GIT_OPTIONAL_LOCKS -ErrorAction SilentlyContinue }
  }
}

function Invoke-ProductGitOptional([string] $Root, [string[]] $Arguments) {
  $hadValue = Test-Path Env:GIT_OPTIONAL_LOCKS
  $previousValue = $env:GIT_OPTIONAL_LOCKS
  try {
    $env:GIT_OPTIONAL_LOCKS = '0'
    return Invoke-GitOptional $Root $Arguments
  } finally {
    if ($hadValue) { $env:GIT_OPTIONAL_LOCKS = $previousValue }
    else { Remove-Item Env:GIT_OPTIONAL_LOCKS -ErrorAction SilentlyContinue }
  }
}

function Get-CompactJsonByteCount($Value) {
  $json = $Value | ConvertTo-Json -Depth 30 -Compress
  return [System.Text.Encoding]::UTF8.GetByteCount($json)
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
  if (-not [DateTimeOffset]::TryParse(
    $Value,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::RoundtripKind,
    [ref] $parsed
  )) { throw "$Label is not parseable." }
}

function Assert-ExactProperties([string] $Label, [object] $Value, [string[]] $RequiredProperties) {
  if ($null -eq $Value) { throw "$Label must be a JSON object." }
  $actualProperties = @($Value.PSObject.Properties | ForEach-Object { [string] $_.Name })
  $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($name in $RequiredProperties) { $null = $expectedSet.Add($name) }
  foreach ($name in $actualProperties) {
    if (-not $expectedSet.Remove($name)) { throw "$Label has an unknown or duplicated property: $name" }
  }
  if ($expectedSet.Count -ne 0 -or $actualProperties.Count -ne $RequiredProperties.Count) {
    throw "$Label is missing required properties: $(@($expectedSet) -join ', ')"
  }
}

function Assert-LocalFenceSchema([object] $LocalFence) {
  $requiredProperties = @(
    'version', 'control_repo_id', 'scope_id', 'run_epoch', 'writer_id',
    'lease_expires_at', 'lock_token', 'recovery_required', 'created_at'
  )
  Assert-ExactProperties 'Local writer fence' $LocalFence $requiredProperties
  if (-not (Test-IsInteger $LocalFence.version) -or [int64] $LocalFence.version -ne 1) {
    throw 'Local writer fence version must be integer 1.'
  }
  if (
    -not (Test-IsInteger $LocalFence.run_epoch) -or
    [int64] $LocalFence.run_epoch -lt 1 -or
    [int64] $LocalFence.run_epoch -gt [int]::MaxValue
  ) { throw 'Local writer fence run_epoch must be a positive 32-bit integer.' }
  foreach ($name in @('control_repo_id', 'scope_id', 'writer_id', 'created_at')) {
    if ($LocalFence.$name -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $LocalFence.$name)) {
      throw "Local writer fence $name must be a non-empty native String."
    }
  }
  if ([string] $LocalFence.control_repo_id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Local writer fence control_repo_id is not a stable ID.' }
  if ([string] $LocalFence.scope_id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Local writer fence scope_id is not a stable ID.' }
  if ([string] $LocalFence.writer_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw 'Local writer fence writer_id is invalid.' }
  if ($LocalFence.recovery_required -isnot [bool]) { throw 'Local writer fence recovery_required must be a native Boolean.' }
  foreach ($name in @('lease_expires_at', 'lock_token')) {
    if ($null -ne $LocalFence.$name -and $LocalFence.$name -isnot [string]) {
      throw "Local writer fence $name must be null or a native String."
    }
  }
  if (-not [string]::IsNullOrEmpty([string] $LocalFence.lease_expires_at)) {
    Assert-ExplicitOffsetTimestamp 'Local writer fence lease_expires_at' $LocalFence.lease_expires_at
  }
  if (
    -not [string]::IsNullOrEmpty([string] $LocalFence.lock_token) -and
    [string] $LocalFence.lock_token -notmatch '^[A-Fa-f0-9]{32}$'
  ) { throw 'Local writer fence lock_token must be 32 hexadecimal characters when present.' }
  Assert-ExplicitOffsetTimestamp 'Local writer fence created_at' $LocalFence.created_at
}

function Get-NullSeparatedEntries([object] $Probe) {
  if ($Probe.exit_code -ne 0) { return @() }
  $rawOutput = @($Probe.lines) -join [Environment]::NewLine
  if ([string]::IsNullOrEmpty($rawOutput)) { return @() }
  return @($rawOutput.Split([char] 0) | Where-Object { $_.Length -gt 0 })
}

function Test-InternalPathSafety([string] $PathValue, [string] $Root, [string] $Label) {
  $normalizedPath = Normalize-Path $PathValue
  if (-not (Test-PathWithin $normalizedPath $Root)) {
    $issues.Add("Internal path escapes the control repository for ${Label}: $normalizedPath")
    return $false
  }
  $reparsePoint = Find-ReparsePointInExistingPathChain $normalizedPath
  if ($reparsePoint) {
    $issues.Add("Internal path traverses a reparse point for ${Label}: $reparsePoint")
    return $false
  }
  return $true
}

$controlRootPath = Normalize-Path ((Resolve-Path -LiteralPath $ControlRoot).Path)
$unsupportedControlRoot = Find-UnsupportedPathRoot $controlRootPath
if ($unsupportedControlRoot) { $issues.Add("Control repository uses an unsupported path root: $unsupportedControlRoot") }
$controlReparsePoint = Find-ReparsePointInExistingPathChain $controlRootPath
if ($controlReparsePoint) {
  $issues.Add("Control repository path traverses a reparse point: $controlReparsePoint")
  [ordered]@{
    valid = $false
    control_root = $controlRootPath
    control_status = ''
    product_head = ''
    product_status = ''
    product_heads = [ordered]@{}
    product_statuses = [ordered]@{}
    scopes = @()
    issues = @($issues)
  } | ConvertTo-Json -Depth 20
  exit 1
}
$gitMetadataPath = Join-Path $controlRootPath '.git'
if ((Test-Path -LiteralPath $gitMetadataPath) -and -not (Test-InternalPathSafety $gitMetadataPath $controlRootPath '.git metadata')) {
  [ordered]@{
    valid = $false
    control_root = $controlRootPath
    control_status = ''
    product_head = ''
    product_status = ''
    product_heads = [ordered]@{}
    product_statuses = [ordered]@{}
    scopes = @()
    issues = @($issues)
  } | ConvertTo-Json -Depth 20
  exit 1
}
$requiredFiles = @(
  'AGENTS.md',
  'README.md',
  '.gitattributes',
  '.gitignore',
  '.yefeng/control-plane.json',
  'docs/authorization.md',
  'docs/total-control.md',
  'docs/status.md',
  'docs/roles.md',
  'docs/directives.md',
  'archive/README.md',
  'docs/shared/contract-change-requests/README.md',
  'docs/shared/decisions/README.md',
  'docs/shared/integration-queue.md',
  'scripts/yefeng/enter-control-write.ps1',
  'scripts/yefeng/exit-control-write.ps1',
  'scripts/yefeng/recover-control-write.ps1',
  'scripts/yefeng/prepare-control-writer-takeover.ps1',
  'scripts/yefeng/validate-external-control-repo.ps1',
  'scripts/yefeng/message-common.ps1',
  'scripts/yefeng/publish-role-message.ps1',
  'scripts/yefeng/message-broker.ps1',
  'scripts/yefeng/receive-role-message.ps1'
)

$requiredPathSafety = @{}
foreach ($relative in $requiredFiles) {
  $requiredPath = Join-Path $controlRootPath $relative
  $requiredPathSafety[$relative] = Test-InternalPathSafety $requiredPath $controlRootPath $relative
  if ($requiredPathSafety[$relative] -and -not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    $issues.Add("Missing required file: $relative")
  }
}

$gitTopLevel = Invoke-GitRead $controlRootPath @('rev-parse', '--show-toplevel')
if ($gitTopLevel) {
  if (-not (Normalize-Path $gitTopLevel).Equals($controlRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    $issues.Add("ControlRoot is nested in another Git repository: $gitTopLevel")
  }
}

$topology = $null
$declaredScopeIds = @()
$scopeIds = @()
$scopeStableRelativePaths = @()
$scopeIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$productRepoIds = @()
$productRepoIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$topologyPath = Join-Path $controlRootPath '.yefeng\control-plane.json'
if ($requiredPathSafety['.yefeng/control-plane.json'] -and (Test-Path -LiteralPath $topologyPath)) {
  try {
    $topology = ConvertFrom-ControlJson (Get-Content -LiteralPath $topologyPath -Raw -Encoding UTF8)
  } catch {
    $issues.Add("Invalid control-plane.json: $($_.Exception.Message)")
  }
}

if ($topology) {
  if ($topology.version -lt 2) { $issues.Add('External control-plane schema must be version 2 or later.') }
  if ($topology.control_plane_mode -ne 'external-git') { $issues.Add('control_plane_mode must be external-git.') }
  if ([string]::IsNullOrWhiteSpace($topology.control_repo_id)) { $issues.Add('control_repo_id is required.') }
  if ($topology.control_repo_id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { $issues.Add('control_repo_id is not a stable ID.') }
  if ($topology.locator_mode -notin @('prompt-required', 'product-local-git-config', 'tracked-pointer')) { $issues.Add('Invalid locator_mode.') }
  if ($topology.default_transport_mode -notin @('control-spool', 'worktree-local')) { $issues.Add('Invalid default_transport_mode.') }
  if (@($topology.active_scopes).Count -lt 1) { $issues.Add('At least one active scope is required.') }
  foreach ($rawScopeId in @($topology.active_scopes)) {
    $scopeIdValue = [string] $rawScopeId
    if ($scopeIdValue -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
      $issues.Add("Invalid active scope ID: $scopeIdValue")
      continue
    }
    if (-not $scopeIdSet.Add($scopeIdValue)) {
      $issues.Add("Duplicate active scope ID: $scopeIdValue")
      continue
    }
    $declaredScopeIds += $scopeIdValue
  }
  if (@($topology.product_repositories).Count -lt 1) { $issues.Add('At least one product repository is required.') }
  foreach ($productRepo in @($topology.product_repositories)) {
    $repoIdValue = [string] $productRepo.repo_id
    if ($repoIdValue -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
      $issues.Add("Invalid product repository ID: $repoIdValue")
      continue
    }
    if (-not $productRepoIdSet.Add($repoIdValue)) {
      $issues.Add("Duplicate product repository ID: $repoIdValue")
      continue
    }
    $productRepoIds += $repoIdValue
  }
  if (-not $topology.shared_writer -or $topology.active_scopes -notcontains $topology.shared_writer.scope_id -or [string]::IsNullOrWhiteSpace($topology.shared_writer.role_id)) {
    $issues.Add('shared_writer must identify a role in an active scope.')
  }
  if ($ExpectedScopeId) {
    if ($ExpectedScopeId -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { $issues.Add("Expected scope ID is invalid: $ExpectedScopeId") }
    elseif (-not $scopeIdSet.Contains($ExpectedScopeId)) { $issues.Add("Expected scope is not active: $ExpectedScopeId") }
  }
}

foreach ($scopeId in $declaredScopeIds) {
  $scopeStablePaths = @(
    ".yefeng/series/$scopeId/state/control.json",
    ".yefeng/series/$scopeId/state/roles.json",
    ".yefeng/series/$scopeId/state/runs.json",
    ".yefeng/series/$scopeId/state/transport.json",
    ".yefeng/series/$scopeId/events.jsonl",
    ".yefeng/series/$scopeId/messages/.gitkeep",
    "docs/modules/$scopeId/budget.md",
    "docs/modules/$scopeId/charter.md",
    "docs/modules/$scopeId/plan.md",
    "docs/modules/$scopeId/registry.md",
    "docs/modules/$scopeId/decisions/README.md",
    "docs/modules/$scopeId/handoffs/README.md",
    "docs/modules/$scopeId/messages/README.md"
  )
  $scopeStableRelativePaths += $scopeStablePaths
  $scopeRoot = Join-Path $controlRootPath ".yefeng\series\$scopeId"
  if (-not (Test-InternalPathSafety $scopeRoot $controlRootPath "scope $scopeId")) { continue }
  $scopePathsAreSafe = $true
  foreach ($relativePath in $scopeStablePaths) {
    $stablePath = Join-Path $controlRootPath $relativePath
    if (-not (Test-InternalPathSafety $stablePath $controlRootPath $relativePath)) {
      $scopePathsAreSafe = $false
      continue
    }
    if (-not (Test-Path -LiteralPath $stablePath -PathType Leaf)) {
      $issues.Add("Missing stable scope file for ${scopeId}: $relativePath")
    }
  }
  if ($scopePathsAreSafe) { $scopeIds += $scopeId }
}

$controlStateByScope = @{}
foreach ($scopeId in $scopeIds) {
  $scopeRoot = Join-Path $controlRootPath ".yefeng\series\$scopeId"
  foreach ($relative in @('state/control.json', 'state/roles.json', 'state/runs.json', 'state/transport.json', 'events.jsonl')) {
    if (-not (Test-Path -LiteralPath (Join-Path $scopeRoot $relative) -PathType Leaf)) {
      $issues.Add("Missing scope file for ${scopeId}: $relative")
    }
  }

  $controlState = $null
  $controlStatePath = Join-Path $scopeRoot 'state\control.json'
  if (Test-Path -LiteralPath $controlStatePath) {
    try {
      $controlState = ConvertFrom-ControlJson (Get-Content -LiteralPath $controlStatePath -Raw -Encoding UTF8)
    } catch {
      $issues.Add("Invalid control state for ${scopeId}: $($_.Exception.Message)")
    }
  }
  if ($controlState) {
    $controlStateByScope[$scopeId] = $controlState
    if ([int] $controlState.version -ne 2) { $issues.Add("Control state version must be 2 for $scopeId") }
    if ($controlState.scope_id -ne $scopeId) { $issues.Add("Control state scope mismatch: $scopeId") }
    if ($controlState.control_repo_id -ne $topology.control_repo_id) { $issues.Add("Control state repository identity mismatch: $scopeId") }
    if ($controlState.run_epoch -lt 1) { $issues.Add("run_epoch must be positive for $scopeId") }
    if (-not $controlState.writer_fence) { $issues.Add("writer_fence is required for $scopeId") }
    if ($controlState.writer_fence -and $controlState.writer_fence.fence_epoch -ne $controlState.run_epoch) {
      $issues.Add("writer fence/control epoch mismatch for $scopeId")
    }
    if ($controlState.lifecycle_state -notin @('ACTIVE', 'PAUSING', 'PAUSED', 'RECOVERING', 'ARCHIVED')) {
      $issues.Add("Invalid lifecycle_state for $scopeId")
    }
    if ($controlState.startup_level -notin @('LEVEL_1_GOVERNANCE_BOOTSTRAP', 'LEVEL_2_SINGLE_THREAD_TOTAL_CONTROL', 'LEVEL_3_FULL_PARALLEL_YEFENG')) {
      $issues.Add("Invalid startup_level for $scopeId")
    }
    $controlBaselineProperties = @()
    if ($controlState.product_baselines) { $controlBaselineProperties = @($controlState.product_baselines.PSObject.Properties) }
    $controlBaselineIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($controlBaselineProperties.Count -lt 1) { $issues.Add("At least one product baseline is required for $scopeId") }
    foreach ($baselineProperty in $controlBaselineProperties) {
      $baselineRepoId = [string] $baselineProperty.Name
      $baseline = $baselineProperty.Value
      if (-not $controlBaselineIds.Add($baselineRepoId) -or $productRepoIds -notcontains $baselineRepoId) {
        $issues.Add("Control state has an unknown or duplicate product baseline for ${scopeId}: $baselineRepoId")
      }
      if ([string]::IsNullOrWhiteSpace([string] $baseline.branch) -or [string] $baseline.commit -notmatch '^[A-Fa-f0-9]{40,64}$') {
        $issues.Add("Control state has an incomplete product baseline for ${scopeId}: $baselineRepoId")
      }
      $topologyProduct = @($topology.product_repositories | Where-Object { [string] $_.repo_id -eq $baselineRepoId })
      if ($topologyProduct.Count -eq 1 -and [string] $baseline.branch -ne [string] $topologyProduct[0].integration_branch) {
        $issues.Add("Control state baseline branch does not match topology for ${scopeId}: $baselineRepoId")
      }
    }
    $controlBaselineSetIsExact = ($controlBaselineIds.Count -eq $productRepoIdSet.Count)
    foreach ($productRepoId in $productRepoIds) {
      if (-not $controlBaselineIds.Contains($productRepoId)) {
        $controlBaselineSetIsExact = $false
        $issues.Add("Control state is missing a topology product baseline for ${scopeId}: $productRepoId")
      }
    }
    if (-not $controlBaselineSetIsExact) {
      $issues.Add("Control state must contain the exact topology product baseline set for $scopeId")
    }
    if ($controlState.startup_level -eq 'LEVEL_1_GOVERNANCE_BOOTSTRAP') {
      if (
        [int] $controlState.wip_budget.active_implementation_worktrees -ne 0 -or
        [int] $controlState.wip_budget.pending_reviews -ne 0 -or
        [int] $controlState.wip_budget.integration_batches -ne 0 -or
        $controlState.writer_fence.lease_expires_at
      ) {
        $issues.Add("Level 1 has active implementation capacity or a tracked writer lease for $scopeId")
      }
    }
  }

  $rolesState = $null
  $rolesById = @{}
  $roleByRunId = @{}
  $roleAssignmentIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $rolesPath = Join-Path $scopeRoot 'state\roles.json'
  if (Test-Path -LiteralPath $rolesPath) {
    try {
      $rolesState = ConvertFrom-ControlJson (Get-Content -LiteralPath $rolesPath -Raw -Encoding UTF8)
      if ([int] $rolesState.version -ne 2) { $issues.Add("Roles state version must be 2 for $scopeId") }
      if ($rolesState.run_epoch -ne $controlState.run_epoch) { $issues.Add("roles/control epoch mismatch for $scopeId") }
      if ($rolesState.scope_id -ne $scopeId -or $rolesState.control_repo_id -ne $topology.control_repo_id) { $issues.Add("roles file identity mismatch for $scopeId") }
      foreach ($role in @($rolesState.roles)) {
        $rolePropertyNames = @($role.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($requiredField in $requiredRoleFields) {
          if ($rolePropertyNames -notcontains $requiredField) {
            $issues.Add("Role schema is missing ${requiredField} for ${scopeId}: $($role.role_id)")
          }
        }
        $roleId = [string] $role.role_id
        if ($roleId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $rolesById.ContainsKey($roleId)) {
          $issues.Add("Role identity is missing or duplicated for ${scopeId}: $roleId")
          continue
        }
        $rolesById[$roleId] = $role
        $roleEpoch = [int] $role.run_epoch
        $roleState = [string] $role.state
        if ($role.scope_id -ne $scopeId -or $role.control_repo_id -ne $topology.control_repo_id -or $roleEpoch -lt 1 -or $roleEpoch -gt [int] $rolesState.run_epoch) {
          $issues.Add("Role identity/epoch mismatch for ${scopeId}: $roleId")
        }
        if ($allowedRoleStates -notcontains $roleState) { $issues.Add("Invalid role state for ${scopeId}: $roleId / $roleState") }
        $hasLease = -not [string]::IsNullOrWhiteSpace([string] $role.lease_expires_at)
        if ($roleEpoch -lt [int] $rolesState.run_epoch -and ($terminalRoleStates -notcontains $roleState -or $hasLease)) {
          $issues.Add("Stale role is active or leased for ${scopeId}: $roleId")
        }
        if ($terminalRoleStates -contains $roleState -and $hasLease) { $issues.Add("Terminal role still has a lease for ${scopeId}: $roleId") }
        if ($roleState -eq 'PLANNED') {
          $runtimeFields = @($role.assigned_by, $role.assignment_id, $role.session_id, $role.process_id, $role.run_id, $role.product_worktree, $role.lease_expires_at)
          if (@($runtimeFields | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string] $_) }).Count -gt 0) {
            $issues.Add("PLANNED role contains runtime assignment/session/worktree state for ${scopeId}: $roleId")
          }
        } elseif ($roleEpoch -eq [int] $rolesState.run_epoch -and $terminalRoleStates -notcontains $roleState) {
          if ([string]::IsNullOrWhiteSpace([string] $role.assigned_by) -or [string]::IsNullOrWhiteSpace([string] $role.assignment_id)) {
            $issues.Add("Active role assignment identity is incomplete for ${scopeId}: $roleId")
          } elseif (-not $roleAssignmentIds.Add([string] $role.assignment_id)) {
            $issues.Add("Active role assignment_id is duplicated for ${scopeId}: $($role.assignment_id)")
          }
          if ($launchedRoleStates -contains $roleState) {
            if (
              [string]::IsNullOrWhiteSpace([string] $role.run_id) -or
              [string]::IsNullOrWhiteSpace([string] $role.session_id) -or
              [string]::IsNullOrWhiteSpace([string] $role.product_worktree) -or
              -not $hasLease
            ) {
              $issues.Add("Launched role execution identity is incomplete for ${scopeId}: $roleId")
            }
          }
        }
        $roleRunId = [string] $role.run_id
        if (-not [string]::IsNullOrWhiteSpace($roleRunId)) {
          if ($roleByRunId.ContainsKey($roleRunId)) { $issues.Add("Multiple roles reference the same run for ${scopeId}: $roleRunId") }
          else { $roleByRunId[$roleRunId] = $role }
        }
        $roleProductRepoId = [string] $role.product_repo_id
        if ($productRepoIds -notcontains $roleProductRepoId) {
          $issues.Add("Role product_repo_id mismatch for ${scopeId}: $roleId")
        } else {
          $roleBaselineProperty = $controlState.product_baselines.PSObject.Properties[$roleProductRepoId]
          if (-not $roleBaselineProperty) {
            $issues.Add("Role product baseline is not registered for ${scopeId}: $roleId")
          } elseif ($roleEpoch -eq [int] $rolesState.run_epoch -and (
            [string] $role.product_baseline_commit -ne [string] $roleBaselineProperty.Value.commit -or
            [string] $role.product_branch -ne [string] $roleBaselineProperty.Value.branch
          )) {
            $issues.Add("Current role product baseline identity mismatch for ${scopeId}: $roleId")
          }
        }
        if ([string] $role.transport_mode -notin @('control-spool', 'worktree-local')) {
          $issues.Add("Role transport_mode is invalid for ${scopeId}: $roleId")
        }
      }
      if ($topology.shared_writer.scope_id -eq $scopeId -and @($rolesState.roles | Where-Object { $_.role_id -eq $topology.shared_writer.role_id }).Count -ne 1) {
        $issues.Add("Shared writer role is missing or duplicated in $scopeId")
      }
      if ($controlState.lifecycle_state -eq 'ACTIVE' -and $topology.shared_writer.scope_id -eq $scopeId) {
        $sharedWriterRole = $rolesById[[string] $topology.shared_writer.role_id]
        if ($sharedWriterRole -and [int] $sharedWriterRole.run_epoch -ne [int] $rolesState.run_epoch) {
          $issues.Add("ACTIVE shared writer role is stale for $scopeId")
        }
      }
      if ($controlState.startup_level -eq 'LEVEL_1_GOVERNANCE_BOOTSTRAP') {
        $activeRoles = @($rolesState.roles | Where-Object { $_.state -ne 'PLANNED' })
        if ($activeRoles.Count -gt 0) { $issues.Add("Level 1 contains non-PLANNED roles for $scopeId") }
      }
    } catch {
      $issues.Add("Invalid roles state for ${scopeId}: $($_.Exception.Message)")
    }
  }

  $runsState = $null
  $runsById = @{}
  $runAssignmentIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $runsPath = Join-Path $scopeRoot 'state\runs.json'
  if (Test-Path -LiteralPath $runsPath) {
    try {
      $runsState = ConvertFrom-ControlJson (Get-Content -LiteralPath $runsPath -Raw -Encoding UTF8)
      if ([int] $runsState.version -ne 2) { $issues.Add("Runs state version must be 2 for $scopeId") }
      if ($runsState.run_epoch -ne $controlState.run_epoch) { $issues.Add("runs/control epoch mismatch for $scopeId") }
      if ($runsState.scope_id -ne $scopeId -or $runsState.control_repo_id -ne $topology.control_repo_id) { $issues.Add("runs file identity mismatch for $scopeId") }
      foreach ($run in @($runsState.runs)) {
        $runPropertyNames = @($run.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($requiredField in $requiredRunFields) {
          if ($runPropertyNames -notcontains $requiredField) {
            $issues.Add("Run schema is missing ${requiredField} for ${scopeId}: $($run.run_id)")
          }
        }
        $runId = [string] $run.run_id
        if ($runId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' -or $runsById.ContainsKey($runId)) {
          $issues.Add("Run identity is missing or duplicated for ${scopeId}: $runId")
          continue
        }
        $runsById[$runId] = $run
        $hasCompleteRetentionBinding = $true
        foreach ($retentionField in $structuredRetentionRunFields) {
          if ($runPropertyNames -notcontains $retentionField) {
            $hasCompleteRetentionBinding = $false
            break
          }
        }
        if ($hasCompleteRetentionBinding) {
          $retentionPathIdPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
          if ($runId -notmatch $retentionPathIdPattern -or [string] $run.role_id -notmatch $retentionPathIdPattern) {
            $issues.Add("Structured retention binding uses a path-unsafe role/run ID for ${scopeId}: $runId")
          }
          if ([string] $run.retention_group_id -notmatch $retentionPathIdPattern) {
            $issues.Add("Structured retention_group_id is invalid for ${scopeId}: $runId")
          }
          $parentRunId = [string] $run.parent_run_id
          if (
            -not [string]::IsNullOrWhiteSpace($parentRunId) -and
            ($parentRunId -notmatch $retentionPathIdPattern -or $parentRunId -eq $runId)
          ) {
            $issues.Add("Structured parent_run_id is invalid for ${scopeId}: $runId")
          }
          if ($allowedReviewGates -notcontains [string] $run.review_gate) {
            $issues.Add("Structured review_gate is invalid for ${scopeId}: $runId")
          }
          if ($allowedControlDispositions -notcontains [string] $run.control_disposition) {
            $issues.Add("Structured control_disposition is invalid for ${scopeId}: $runId")
          }
          $normalizedRunRoot = ([string] $run.run_root).Replace('\', '/').TrimEnd('/')
          $expectedRunRoot = ".yefeng/runs/$scopeId/$($run.role_id)/$runId"
          if ($normalizedRunRoot -cne $expectedRunRoot) {
            $issues.Add("Structured run_root binding mismatch for ${scopeId}: $runId")
          }
          if (
            [string] $run.review_gate -eq 'PENDING' -and
            [string] $run.control_disposition -in @('SUPERSEDED', 'ARCHIVED', 'DISCARDABLE')
          ) {
            $issues.Add("Pending review is marked compactable for ${scopeId}: $runId")
          }
        }
        $runEpoch = [int] $run.run_epoch
        $runState = [string] $run.status
        if ($run.scope_id -ne $scopeId -or $run.control_repo_id -ne $topology.control_repo_id -or $runEpoch -lt 1 -or $runEpoch -gt [int] $runsState.run_epoch) {
          $issues.Add("Run identity/epoch mismatch for ${scopeId}: $runId")
        }
        if ($allowedRunStates -notcontains $runState) { $issues.Add("Invalid run state for ${scopeId}: $runId / $runState") }
        if ($runEpoch -lt [int] $runsState.run_epoch -and $terminalRunStates -notcontains $runState) {
          $issues.Add("Stale run is not terminal for ${scopeId}: $runId")
        }
        if ([string]::IsNullOrWhiteSpace([string] $run.role_id) -or [string]::IsNullOrWhiteSpace([string] $run.assignment_id)) {
          $issues.Add("Run role/assignment identity is incomplete for ${scopeId}: $runId")
        } elseif (-not $runAssignmentIds.Add([string] $run.assignment_id)) {
          $issues.Add("Run assignment_id is duplicated for ${scopeId}: $($run.assignment_id)")
        }
        if (
          [string]::IsNullOrWhiteSpace([string] $run.product_worktree) -or
          [string]::IsNullOrWhiteSpace([string] $run.session_id) -or
          [string]::IsNullOrWhiteSpace([string] $run.command) -or
          [string]::IsNullOrWhiteSpace([string] $run.cwd) -or
          [string]::IsNullOrWhiteSpace([string] $run.started_at)
        ) {
          $issues.Add("Run execution identity is incomplete for ${scopeId}: $runId")
        }
        try { $null = [DateTimeOffset]::Parse([string] $run.started_at) }
        catch { $issues.Add("Run started_at is invalid for ${scopeId}: $runId") }
        if ($terminalRunStates -contains $runState) {
          if (-not (Test-CanonicalDateTimeOffsetText $run.ended_at)) {
            $issues.Add("Terminal run ended_at must be canonical DateTimeOffset.ToString('o') for ${scopeId}: $runId")
          }
        }
        if ([string] $run.product_worktree -ne [string] $run.cwd) {
          $issues.Add("Run cwd/worktree identity mismatch for ${scopeId}: $runId")
        }
        $runProductRepoId = [string] $run.product_repo_id
        if ($productRepoIds -notcontains $runProductRepoId) {
          $issues.Add("Run product_repo_id mismatch for ${scopeId}: $runId")
        } else {
          $runBaselineProperty = $controlState.product_baselines.PSObject.Properties[$runProductRepoId]
          if (-not $runBaselineProperty) {
            $issues.Add("Run product baseline is not registered for ${scopeId}: $runId")
          } elseif ($runEpoch -eq [int] $runsState.run_epoch -and (
            [string] $run.product_baseline_commit -ne [string] $runBaselineProperty.Value.commit -or
            [string] $run.product_branch -ne [string] $runBaselineProperty.Value.branch
          )) {
            $issues.Add("Current run product baseline identity mismatch for ${scopeId}: $runId")
          }
        }
        if ([string] $run.transport_mode -notin @('control-spool', 'worktree-local')) {
          $issues.Add("Run transport_mode is invalid for ${scopeId}: $runId")
        }
        $linkedRole = $roleByRunId[$runId]
        if ($linkedRole) {
          if ([string] $run.role_id -ne [string] $linkedRole.role_id -or [string] $run.assignment_id -ne [string] $linkedRole.assignment_id) {
            $issues.Add("Role/run assignment identity mismatch for ${scopeId}: $runId")
          }
          if (
            [int] $run.run_epoch -ne [int] $linkedRole.run_epoch -or
            [string] $run.product_repo_id -ne [string] $linkedRole.product_repo_id -or
            [string] $run.product_baseline_commit -ne [string] $linkedRole.product_baseline_commit -or
            [string] $run.product_branch -ne [string] $linkedRole.product_branch -or
            [string] $run.product_worktree -ne [string] $linkedRole.product_worktree -or
            [string] $run.transport_mode -ne [string] $linkedRole.transport_mode -or
            [string] $run.session_id -ne [string] $linkedRole.session_id -or
            [string] $run.process_id -ne [string] $linkedRole.process_id
          ) {
            $issues.Add("Role/run execution identity mismatch for ${scopeId}: $runId")
          }
          if (($terminalRoleStates -contains [string] $linkedRole.state) -ne ($terminalRunStates -contains $runState)) {
            $issues.Add("Role/run lifecycle state mismatch for ${scopeId}: $runId")
          }
        } elseif ($runEpoch -eq [int] $runsState.run_epoch -and $terminalRunStates -notcontains $runState) {
          $issues.Add("Current active run has no owning role for ${scopeId}: $runId")
        }
      }
      foreach ($roleRunEntry in $roleByRunId.GetEnumerator()) {
        if (-not $runsById.ContainsKey([string] $roleRunEntry.Key)) {
          $issues.Add("Role references a missing run for ${scopeId}: $($roleRunEntry.Value.role_id) / $($roleRunEntry.Key)")
        }
      }
      foreach ($run in @($runsState.runs)) {
        $runPropertyNames = @($run.PSObject.Properties | ForEach-Object { $_.Name })
        $hasCompleteRetentionBinding = @($structuredRetentionRunFields | Where-Object { $runPropertyNames -contains $_ }).Count -eq $structuredRetentionRunFields.Count
        if ($hasCompleteRetentionBinding) {
          $parentRunId = [string] $run.parent_run_id
          if (-not [string]::IsNullOrWhiteSpace($parentRunId) -and -not $runsById.ContainsKey($parentRunId)) {
            $issues.Add("Structured parent run is missing for ${scopeId}: $($run.run_id) / $parentRunId")
          }
        }
      }
      if ($controlState.startup_level -eq 'LEVEL_1_GOVERNANCE_BOOTSTRAP' -and @($runsState.runs).Count -gt 0) {
        $issues.Add("Level 1 contains run records for $scopeId")
      }
    } catch {
      $issues.Add("Invalid runs state for ${scopeId}: $($_.Exception.Message)")
    }
  }

  $transportState = $null
  $transportPath = Join-Path $scopeRoot 'state\transport.json'
  if (Test-Path -LiteralPath $transportPath) {
    try {
      $transportState = ConvertFrom-ControlJson (Get-Content -LiteralPath $transportPath -Raw -Encoding UTF8)
      if ([int] $transportState.version -ne 2) { $issues.Add("Transport state version must be 2 for $scopeId") }
      if ($transportState.scope_id -ne $scopeId) { $issues.Add("Transport state scope mismatch: $scopeId") }
      if ($transportState.control_repo_id -ne $topology.control_repo_id) { $issues.Add("Transport control_repo_id mismatch: $scopeId") }
      if ($transportState.run_epoch -ne $controlState.run_epoch) { $issues.Add("transport/control epoch mismatch for $scopeId") }
      if ($controlState.startup_level -eq 'LEVEL_1_GOVERNANCE_BOOTSTRAP' -and @($transportState.imported_messages).Count -gt 0) {
        $issues.Add("Level 1 contains imported messages for $scopeId")
      }
      if ($controlState.startup_level -eq 'LEVEL_1_GOVERNANCE_BOOTSTRAP' -and @($transportState.quarantined_messages).Count -gt 0) {
        $issues.Add("Level 1 contains quarantined messages for $scopeId")
      }
    } catch {
      $issues.Add("Invalid transport state for ${scopeId}: $($_.Exception.Message)")
    }
  }

  $eventsPath = Join-Path $scopeRoot 'events.jsonl'
  $eventIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $receiptByMessageId = @{}
  $retentionPreparedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  if (Test-Path -LiteralPath $eventsPath) {
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $eventsPath -Encoding UTF8) {
      $lineNumber++
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      if ([System.Text.Encoding]::UTF8.GetByteCount($line) -gt 65536) {
        $issues.Add("Event exceeds 64 KiB at $scopeId line $lineNumber")
        continue
      }
      try {
        $event = ConvertFrom-ControlJson $line
        if ([string]::IsNullOrWhiteSpace($event.event_id)) { $issues.Add("Missing event_id at $scopeId line $lineNumber") }
        elseif ($event.event_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') { $issues.Add("Invalid event_id at $scopeId line $lineNumber") }
        elseif (-not $eventIds.Add([string] $event.event_id)) { $issues.Add("Duplicate event_id at $scopeId line ${lineNumber}: $($event.event_id)") }
        if ($knownEventTypes -notcontains $event.type) { $issues.Add("Unknown event type at $scopeId line ${lineNumber}: $($event.type)") }
        if ($event.scope_id -ne $scopeId) { $issues.Add("Event scope mismatch at $scopeId line $lineNumber") }
        if ($event.run_epoch -lt 1 -or $event.run_epoch -gt $controlState.run_epoch) { $issues.Add("Event epoch is invalid at $scopeId line $lineNumber") }
        if ($event.control_repo_id -ne $topology.control_repo_id) { $issues.Add("Event control_repo_id mismatch at $scopeId line $lineNumber") }
        $isScopeRecoveryEvent = $event.type -in @('RECOVERY_STARTED', 'RECOVERY_COMPLETED')
        if ($isScopeRecoveryEvent) {
          $eventBaselineProperties = @($event.product_baselines.PSObject.Properties)
          if ($eventBaselineProperties.Count -lt 1) {
            $issues.Add("Scope recovery event lacks product_baselines at $scopeId line $lineNumber")
          }
          $eventBaselineIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
          foreach ($baselineProperty in $eventBaselineProperties) {
            $baselineRepoId = [string] $baselineProperty.Name
            $baseline = $baselineProperty.Value
            if (-not $eventBaselineIds.Add($baselineRepoId) -or $productRepoIds -notcontains $baselineRepoId) {
              $issues.Add("Scope recovery event has an invalid product baseline ID at $scopeId line ${lineNumber}: $baselineRepoId")
            }
            if ([string]::IsNullOrWhiteSpace([string] $baseline.branch) -or [string] $baseline.commit -notmatch '^[A-Fa-f0-9]{40,64}$') {
              $issues.Add("Scope recovery event has an incomplete product baseline at $scopeId line ${lineNumber}: $baselineRepoId")
            }
          }
          $eventBaselineSetIsExact = ($eventBaselineIds.Count -eq $productRepoIdSet.Count)
          foreach ($productRepoId in $productRepoIds) {
            if (-not $eventBaselineIds.Contains($productRepoId)) { $eventBaselineSetIsExact = $false }
          }
          if (-not $eventBaselineSetIsExact) {
            $issues.Add("Scope recovery event must contain the exact product baseline set at $scopeId line $lineNumber")
          }
          foreach ($rawTokenField in @('lock_token', 'recovery_lock_token')) {
            if ($event.PSObject.Properties.Name -contains $rawTokenField) {
              $issues.Add("Scope recovery event exposes raw lock token field $rawTokenField at $scopeId line $lineNumber")
            }
          }
        } elseif ($productRepoIds -notcontains $event.product_repo_id) {
          $issues.Add("Event product_repo_id mismatch at $scopeId line $lineNumber")
        }
        try { $null = [DateTimeOffset]::Parse([string] $event.created_at) }
        catch { $issues.Add("Invalid event created_at at $scopeId line $lineNumber") }
        if ($event.type -in @('CONTROL_BOOTSTRAPPED', 'INTEGRATION_INTENT', 'PRODUCT_COMMITTED', 'PRODUCT_VERIFIED', 'CONTROL_COMMITTED', 'RECONCILIATION_REQUIRED', 'RECOVERY_STARTED', 'RECOVERY_COMPLETED', 'RUN_EVIDENCE_RETENTION_PREPARED', 'RUN_EVIDENCE_RETENTION_APPLIED') -and [string]::IsNullOrWhiteSpace($event.operation_id)) {
          $issues.Add("Event operation_id is required for $($event.type) at $scopeId line $lineNumber")
        }
        if ($event.type -in @('CONTROL_BOOTSTRAPPED', 'PRODUCT_COMMITTED', 'PRODUCT_VERIFIED', 'CONTROL_COMMITTED', 'BASELINE_UPDATED') -and [string]::IsNullOrWhiteSpace($event.product_baseline_commit) -and [string]::IsNullOrWhiteSpace($event.product_commit)) {
          $issues.Add("Product commit identity is required for $($event.type) at $scopeId line $lineNumber")
        }
        if ($event.type -eq 'IMPORT_RECEIPT') {
          if (
            [string]::IsNullOrWhiteSpace($event.message_id) -or
            [string]::IsNullOrWhiteSpace($event.assignment_id) -or
            [string]::IsNullOrWhiteSpace($event.run_id) -or
            [string]::IsNullOrWhiteSpace($event.source_sha256) -or
            $event.source_sha256 -notmatch '^[A-Fa-f0-9]{64}$'
          ) {
            $issues.Add("IMPORT_RECEIPT identity is incomplete at $scopeId line $lineNumber")
          } elseif ($receiptByMessageId.ContainsKey([string] $event.message_id)) {
            $issues.Add("Duplicate IMPORT_RECEIPT message_id at $scopeId line ${lineNumber}: $($event.message_id)")
          } else {
            $receiptByMessageId[[string] $event.message_id] = [ordered]@{
              event_id = [string] $event.event_id
              assignment_id = [string] $event.assignment_id
              run_id = [string] $event.run_id
              run_epoch = [int] $event.run_epoch
              source_sha256 = ([string] $event.source_sha256).ToLowerInvariant()
            }
          }
        }
        if ($event.type -eq 'RECOVERY_STARTED') {
          if (
            $event.recovery_lock_sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            [string]::IsNullOrWhiteSpace($event.previous_writer_id) -or
            [string]::IsNullOrWhiteSpace($event.replacement_writer_id) -or
            $event.previous_writer_id -eq $event.replacement_writer_id
          ) {
            $issues.Add("RECOVERY_STARTED transition identity is incomplete at $scopeId line $lineNumber")
          }
        }
        if ($event.type -eq 'RUN_EVIDENCE_RETENTION_PREPARED') {
          $preparedFields = @(
            'event_id', 'type', 'operation_id', 'created_at', 'scope_id', 'run_epoch',
            'control_repo_id', 'product_repo_id', 'prepared_parent_control_head',
            'plan_digest', 'policy_sha256', 'state_hashes', 'apply_token_sha256',
            'candidate_summary', 'reference_set_sha256'
          )
          Assert-ExactProperties "RUN_EVIDENCE_RETENTION_PREPARED at $scopeId line $lineNumber" $event $preparedFields
          foreach ($digestField in @('plan_digest', 'policy_sha256', 'apply_token_sha256', 'reference_set_sha256')) {
            if ([string] $event.$digestField -notmatch '^[A-Fa-f0-9]{64}$') {
              $issues.Add("PREPARED digest is invalid for $digestField at $scopeId line $lineNumber")
            }
          }
          if ([string] $event.prepared_parent_control_head -notmatch '^[A-Fa-f0-9]{40,64}$') {
            $issues.Add("PREPARED parent control HEAD is invalid at $scopeId line $lineNumber")
          }
          foreach ($stateName in @('runs', 'roles', 'control', 'transport')) {
            if ([string] $event.state_hashes.$stateName -notmatch '^[A-Fa-f0-9]{64}$') {
              $issues.Add("PREPARED state hash is invalid for $stateName at $scopeId line $lineNumber")
            }
          }
          if (
            -not (Test-IsInteger $event.candidate_summary.count) -or
            -not (Test-IsInteger $event.candidate_summary.bytes) -or
            [int64] $event.candidate_summary.count -lt 0 -or
            [int64] $event.candidate_summary.bytes -lt 0 -or
            [string] $event.candidate_summary.sha256 -notmatch '^[A-Fa-f0-9]{64}$'
          ) {
            $issues.Add("PREPARED candidate summary is invalid at $scopeId line $lineNumber")
          }
          $preparedKey = "$($event.scope_id):$($event.run_epoch):$($event.plan_digest)"
          if (-not $retentionPreparedKeys.Add($preparedKey)) {
            $issues.Add("Duplicate PREPARED plan binding at $scopeId line ${lineNumber}: $($event.plan_digest)")
          }
        }
      }
      catch { $issues.Add("Invalid events JSONL at $scopeId line ${lineNumber}: $($_.Exception.Message)") }
    }
  }

  if ($transportState) {
    $messageIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($message in @($transportState.imported_messages)) {
      if ((Get-CompactJsonByteCount $message) -gt 65536) {
        $issues.Add("Imported transport record exceeds 64 KiB for ${scopeId}: $($message.message_id)")
      }
      if ([string]::IsNullOrWhiteSpace($message.message_id) -or $message.message_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
        $issues.Add("Invalid imported message_id for $scopeId")
        continue
      }
      if (-not $messageIds.Add([string] $message.message_id)) { $issues.Add("Duplicate transport message_id for ${scopeId}: $($message.message_id)") }
      if ($message.run_epoch -lt 1 -or $message.run_epoch -gt $controlState.run_epoch -or [string]::IsNullOrWhiteSpace($message.assignment_id) -or [string]::IsNullOrWhiteSpace($message.run_id)) {
        $issues.Add("Imported message identity/epoch is incomplete for ${scopeId}: $($message.message_id)")
      }
      if ([string]::IsNullOrWhiteSpace($message.source_sha256) -or $message.source_sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        $issues.Add("Imported message source digest is invalid for ${scopeId}: $($message.message_id)")
      }
      $receipt = $receiptByMessageId[[string] $message.message_id]
      if (
        [string]::IsNullOrWhiteSpace($message.receipt_event_id) -or
        -not $eventIds.Contains([string] $message.receipt_event_id) -or
        -not $receipt -or
        $receipt.event_id -ne $message.receipt_event_id -or
        $receipt.assignment_id -ne $message.assignment_id -or
        $receipt.run_id -ne $message.run_id -or
        $receipt.run_epoch -ne $message.run_epoch -or
        $receipt.source_sha256 -ne ([string] $message.source_sha256).ToLowerInvariant()
      ) {
        $issues.Add("Imported message has no matching committed receipt for ${scopeId}: $($message.message_id)")
      }
      try { $null = [DateTimeOffset]::Parse([string] $message.imported_at) }
      catch { $issues.Add("Imported message timestamp is invalid for ${scopeId}: $($message.message_id)") }
    }
    foreach ($message in @($transportState.quarantined_messages)) {
      if ((Get-CompactJsonByteCount $message) -gt 65536) {
        $issues.Add("Quarantined transport record exceeds 64 KiB for ${scopeId}: $($message.message_id)")
      }
      if ([string]::IsNullOrWhiteSpace($message.message_id) -or $message.message_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
        $issues.Add("Invalid quarantined message_id for $scopeId")
        continue
      }
      if (-not $messageIds.Add([string] $message.message_id)) { $issues.Add("Duplicate transport message_id for ${scopeId}: $($message.message_id)") }
      if ([string]::IsNullOrWhiteSpace($message.reason) -or [string]::IsNullOrWhiteSpace($message.source_sha256) -or $message.source_sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        $issues.Add("Quarantined message evidence is incomplete for ${scopeId}: $($message.message_id)")
      }
      try { $null = [DateTimeOffset]::Parse([string] $message.quarantined_at) }
      catch { $issues.Add("Quarantined message timestamp is invalid for ${scopeId}: $($message.message_id)") }
    }
  }
}

$boundedStableTextRelativePaths = @(
  '.yefeng/control-plane.json',
  'README.md',
  'docs/authorization.md',
  'docs/total-control.md',
  'docs/status.md',
  'docs/roles.md',
  'docs/directives.md',
  'docs/shared/integration-queue.md'
)
foreach ($scopeId in $scopeIds) {
  $boundedStableTextRelativePaths += @(
    "docs/modules/$scopeId/charter.md",
    "docs/modules/$scopeId/budget.md",
    "docs/modules/$scopeId/plan.md",
    "docs/modules/$scopeId/registry.md",
    "docs/modules/$scopeId/messages/README.md"
  )
}
foreach ($relativePath in $boundedStableTextRelativePaths) {
  $scanPath = Join-Path $controlRootPath $relativePath
  if (-not (Test-InternalPathSafety $scanPath $controlRootPath $relativePath)) { continue }
  if (-not (Test-Path -LiteralPath $scanPath -PathType Leaf)) { continue }
  $scanFile = Get-Item -LiteralPath $scanPath -Force
  if ($scanFile.Length -gt 1048576) {
    $issues.Add("Stable template file exceeds the 1 MiB validation limit: $relativePath")
  }
}

# Template replacement is proven by init-external-control-repo.ps1 while it still
# has the original template and replacement map. After rendering, a lexical token
# such as __PRODUCT_BASELINE__ may be intentional user data inside a legal branch,
# project name, or module goal, so the runtime validator must not guess from text.
# Structural JSON, topology, scope, identity, and baseline contracts above remain
# authoritative for rendered control state.

foreach ($probe in @('.yefeng/local/roots.json', '.yefeng/local/locks/control-repo.lifecycle.guard', '.yefeng/runs/probe.txt', '.yefeng/outbox/probe.txt', '.yefeng/broker/probe.txt', '.yefeng/quarantine/probe.txt', '.runtime/probe.txt')) {
  & git -C $controlRootPath check-ignore -q --no-index $probe
  if ($LASTEXITCODE -ne 0) { $issues.Add("Expected ignored path is not ignored: $probe") }
}

$localRootsPath = Join-Path $controlRootPath '.yefeng\local\roots.json'
$localRoots = $null
if ((Test-InternalPathSafety $localRootsPath $controlRootPath 'local roots') -and (Test-Path -LiteralPath $localRootsPath)) {
  try { $localRoots = ConvertFrom-ControlJson (Get-Content -LiteralPath $localRootsPath -Raw -Encoding UTF8) }
  catch { $issues.Add("Invalid local roots JSON: $($_.Exception.Message)") }
}

$productStatus = ""
$productHead = ""
$productHeads = [ordered]@{}
$productStatuses = [ordered]@{}
$productRootsById = @{}
if ($localRoots -and $topology) {
  if ($localRoots.control_repo_id -and $localRoots.control_repo_id -ne $topology.control_repo_id) { $issues.Add('Local roots control_repo_id mismatch.') }
  foreach ($productRepo in @($topology.product_repositories)) {
    $localRootProperty = $localRoots.product_roots.PSObject.Properties[[string] $productRepo.repo_id]
    if ($localRootProperty -and -not [string]::IsNullOrWhiteSpace([string] $localRootProperty.Value)) {
      $productRootsById[[string] $productRepo.repo_id] = [string] $localRootProperty.Value
    }
  }
}
if ($ProductRoot -and $topology) {
  $firstProduct = @($topology.product_repositories)[0]
  $productRootsById[[string] $firstProduct.repo_id] = $ProductRoot
}

if ($topology) {
  foreach ($productRepo in @($topology.product_repositories)) {
    $productRepoId = [string] $productRepo.repo_id
    $productRootValue = $productRootsById[$productRepoId]
    if ([string]::IsNullOrWhiteSpace($productRootValue)) {
      $issues.Add("Missing local product root mapping for product repository: $productRepoId")
      continue
    }
    try {
      $productRootPath = Normalize-Path ((Resolve-Path -LiteralPath $productRootValue).Path)
      $unsupportedProductRoot = Find-UnsupportedPathRoot $productRootPath
      if ($unsupportedProductRoot) { $issues.Add("Product repository uses an unsupported path root for ${productRepoId}: $unsupportedProductRoot") }
      $productReparsePoint = Find-ReparsePointInExistingPathChain $productRootPath
      if ($productReparsePoint) { $issues.Add("Product repository path traverses a reparse point for ${productRepoId}: $productReparsePoint") }
      if ((Test-PathWithin $controlRootPath $productRootPath) -or (Test-PathWithin $productRootPath $controlRootPath)) {
        $issues.Add("Control and product repositories must not be nested: $productRepoId")
      }
      $productTopLevel = Invoke-ProductGitRead $productRootPath @('rev-parse', '--show-toplevel')
      if ($productTopLevel -and -not (Normalize-Path $productTopLevel).Equals($productRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $issues.Add("Product root is not its Git top level for ${productRepoId}: $productTopLevel")
      }

      $productBranch = [string] $productRepo.integration_branch
      $validatedBranch = Invoke-ProductGitRead $productRootPath @('check-ref-format', '--branch', $productBranch)
      if (-not $validatedBranch) { continue }
      $branchHead = Invoke-ProductGitRead $productRootPath @('rev-parse', '--verify', "refs/heads/$validatedBranch^{commit}")
      $currentStatus = Invoke-ProductGitRead $productRootPath @('status', '--short')
      $productHeads[$productRepoId] = $branchHead
      $productStatuses[$productRepoId] = $currentStatus
      if (-not $productHead) { $productHead = $branchHead; $productStatus = $currentStatus }

      foreach ($scopeId in $scopeIds) {
        $state = $controlStateByScope[$scopeId]
        if (-not $state) { continue }
        $baselineProperty = $state.product_baselines.PSObject.Properties[$productRepoId]
        if (-not $baselineProperty) {
          $issues.Add("Missing product baseline for ${scopeId}/${productRepoId}")
          continue
        }
        $recordedBaseline = $baselineProperty.Value
        if ($recordedBaseline.branch -ne $validatedBranch) {
          $issues.Add("Product branch mismatch for ${scopeId}/${productRepoId}: recorded=$($recordedBaseline.branch) topology=$validatedBranch")
        }
        if ($recordedBaseline.commit -ne $branchHead) {
          $issues.Add("Product baseline drift for ${scopeId}/${productRepoId}: recorded=$($recordedBaseline.commit) actual=$branchHead")
        }
      }

      if ($RequireProductBinding) {
        if ($topology.locator_mode -ne 'product-local-git-config') { $issues.Add('RequireProductBinding conflicts with topology locator_mode.') }
        $boundId = Invoke-ProductGitRead $productRootPath @('config', '--local', '--get', 'yefeng.controlRepoId')
        $boundRoot = Invoke-ProductGitRead $productRootPath @('config', '--local', '--get', 'yefeng.controlRoot')
        $boundScope = Invoke-ProductGitRead $productRootPath @('config', '--local', '--get', 'yefeng.scopeId')
        if ($boundId -ne $topology.control_repo_id) { $issues.Add("Product local Git controlRepoId binding mismatch: $productRepoId") }
        if (-not $boundRoot -or -not (Normalize-Path $boundRoot).Equals($controlRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
          $issues.Add("Product local Git controlRoot binding mismatch: $productRepoId")
        }
        if ($ExpectedScopeId -and $boundScope -ne $ExpectedScopeId) { $issues.Add("Product local Git scopeId binding mismatch: $productRepoId") }
      } elseif ($topology.locator_mode -eq 'prompt-required') {
        $unexpectedId = Invoke-ProductGitOptional $productRootPath @('config', '--local', '--get', 'yefeng.controlRepoId')
        $unexpectedRoot = Invoke-ProductGitOptional $productRootPath @('config', '--local', '--get', 'yefeng.controlRoot')
        $unexpectedScope = Invoke-ProductGitOptional $productRootPath @('config', '--local', '--get', 'yefeng.scopeId')
        if ($unexpectedId -or $unexpectedRoot -or $unexpectedScope) {
          $issues.Add("prompt-required locator mode conflicts with existing product-local yefeng Git config: $productRepoId")
        }
      }
    } catch {
      $issues.Add("Product repository validation failed for ${productRepoId}: $($_.Exception.Message)")
    }
  }
}

$controlStatus = Invoke-GitRead $controlRootPath @('status', '--short')
if ($RequireCommitted) {
  $controlHead = Invoke-GitRead $controlRootPath @('rev-parse', 'HEAD')
  if (-not $controlHead) { $issues.Add('Control repository has no commit.') }
  if ($controlStatus) { $issues.Add("Control repository is not clean: $controlStatus") }
  $controlHeadPath = Join-Path $controlRootPath '.yefeng\local\control-head.json'
  $lockPath = Join-Path $controlRootPath '.yefeng\local\locks\control-repo.write.lock'
  $controlHeadPathIsSafe = Test-InternalPathSafety $controlHeadPath $controlRootPath 'repository control HEAD state'
  $lockPathIsSafe = Test-InternalPathSafety $lockPath $controlRootPath 'repository writer lock'
  if (-not $controlHeadPathIsSafe -or -not (Test-Path -LiteralPath $controlHeadPath -PathType Leaf)) {
    $issues.Add('Missing repository control HEAD state.')
  } else {
    try {
      $controlHeadState = ConvertFrom-ControlJson (Get-Content -LiteralPath $controlHeadPath -Raw -Encoding UTF8)
      if ($controlHeadState.control_repo_id -ne $topology.control_repo_id) { $issues.Add('Repository control HEAD identity mismatch.') }
      if ($controlHeadState.expected_control_head -ne $controlHead) { $issues.Add('Repository control HEAD is not reconciled.') }
    } catch {
      $issues.Add("Invalid repository control HEAD state: $($_.Exception.Message)")
    }
  }
  if ($lockPathIsSafe -and (Test-Path -LiteralPath $lockPath)) { $issues.Add('Control repository still has an active or unreleased commit lock.') }
  foreach ($scopeId in $scopeIds) {
    $localFencePath = Join-Path $controlRootPath ".yefeng\local\writer-fences\$scopeId.json"
    if (-not (Test-InternalPathSafety $localFencePath $controlRootPath "local writer fence $scopeId") -or -not (Test-Path -LiteralPath $localFencePath -PathType Leaf)) {
      $issues.Add("Missing local writer fence for committed scope: $scopeId")
      continue
    }
    try {
      $localFence = ConvertFrom-ControlJson (Get-Content -LiteralPath $localFencePath -Raw -Encoding UTF8)
      Assert-LocalFenceSchema $localFence
      $state = $controlStateByScope[$scopeId]
      if (-not $state) { throw "Missing parsed control state for committed scope: $scopeId" }
      if ($localFence.control_repo_id -ne $topology.control_repo_id) {
        $issues.Add("Local writer fence repository identity mismatch for $scopeId")
      }
      if ($localFence.scope_id -ne $scopeId -or $localFence.writer_id -ne $state.writer_fence.writer_id) {
        $issues.Add("Local/tracked writer identity mismatch for $scopeId")
      }
      if ($localFence.run_epoch -ne $state.run_epoch) { $issues.Add("Local/tracked writer epoch mismatch for $scopeId") }
      if (
        -not [string]::IsNullOrEmpty([string] $localFence.lease_expires_at) -or
        -not [string]::IsNullOrEmpty([string] $localFence.lock_token) -or
        $localFence.recovery_required
      ) {
        $issues.Add("Committed scope still has an active or unreleased writer lease: $scopeId")
      }
    } catch {
      $issues.Add("Invalid local writer fence for ${scopeId}: $($_.Exception.Message)")
    }
  }
  $indexEntriesByPath = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
  $ordinaryIndexByPath = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
  $indexProbe = Invoke-GitProbe $controlRootPath @('ls-files', '--stage', '-z')
  if ($indexProbe.exit_code -ne 0) {
    $issues.Add("Unable to enumerate tracked index entries: $($indexProbe.lines -join ' ')")
  } else {
    foreach ($rawIndexEntry in @(Get-NullSeparatedEntries $indexProbe)) {
      if ([string] $rawIndexEntry -notmatch '(?s)^([0-7]{6}) ([0-9a-f]{40,64}) ([0-3])\t(.+)$') {
        $issues.Add('Tracked index contains an entry that cannot be audited.')
        continue
      }
      $indexMode = [string] $Matches[1]
      $indexObjectId = [string] $Matches[2]
      $indexStage = [string] $Matches[3]
      $relative = [string] $Matches[4]
      if (-not $indexEntriesByPath.ContainsKey($relative)) {
        $indexEntriesByPath[$relative] = [System.Collections.Generic.List[object]]::new()
      }
      $indexEntriesByPath[$relative].Add([pscustomobject]@{
        mode = $indexMode
        object_id = $indexObjectId
        stage = $indexStage
      })
    }
  }

  foreach ($relative in @($indexEntriesByPath.Keys)) {
    $pathEntries = @($indexEntriesByPath[$relative])
    $stageZeroEntries = @($pathEntries | Where-Object { $_.stage -eq '0' })
    if ($pathEntries.Count -ne 1 -or $stageZeroEntries.Count -ne 1) {
      $issues.Add("Tracked file does not have exactly one stage-zero index entry: $relative")
      continue
    }
    $ordinaryIndexByPath[$relative] = $stageZeroEntries[0]
  }

  $indexTagsByPath = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
  $tagProbe = Invoke-GitProbe $controlRootPath @('ls-files', '-v', '-z')
  if ($tagProbe.exit_code -ne 0) {
    $issues.Add("Unable to enumerate tracked-file index flags: $($tagProbe.lines -join ' ')")
  } else {
    foreach ($rawTagEntry in @(Get-NullSeparatedEntries $tagProbe)) {
      if ([string] $rawTagEntry -notmatch '(?s)^(.{1}) (.+)$') {
        $issues.Add('Tracked index contains a flag entry that cannot be audited.')
        continue
      }
      $indexTagsByPath[[string] $Matches[2]] = [string] $Matches[1]
    }
  }

  $headEntriesByPath = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
  $headProbe = Invoke-GitProbe $controlRootPath @('ls-tree', '-r', '-z', 'HEAD')
  if ($headProbe.exit_code -ne 0) {
    $issues.Add("Unable to enumerate tracked HEAD entries: $($headProbe.lines -join ' ')")
  } else {
    foreach ($rawHeadEntry in @(Get-NullSeparatedEntries $headProbe)) {
      if ([string] $rawHeadEntry -notmatch '(?s)^([0-7]{6}) ([^ ]+) ([0-9a-f]{40,64})\t(.+)$') {
        $issues.Add('HEAD contains an entry that cannot be audited.')
        continue
      }
      $headEntriesByPath[[string] $Matches[4]] = [pscustomobject]@{
        mode = [string] $Matches[1]
        type = [string] $Matches[2]
        object_id = [string] $Matches[3]
      }
    }
  }

  foreach ($relative in @($ordinaryIndexByPath.Keys)) {
    $tag = if ($indexTagsByPath.ContainsKey($relative)) { $indexTagsByPath[$relative] } else { '' }
    if ($tag -cne 'H') {
      $displayTag = if ($tag) { $tag } else { '<missing>' }
      $issues.Add("Tracked file does not have an ordinary index entry: $relative (tag=$displayTag)")
    }

    if (-not $headEntriesByPath.ContainsKey($relative)) {
      $issues.Add("Tracked file is missing from HEAD: $relative")
    } else {
      $indexEntry = $ordinaryIndexByPath[$relative]
      $headEntry = $headEntriesByPath[$relative]
      if ($headEntry.type -cne 'blob') {
        $issues.Add("Tracked file does not have an ordinary HEAD blob: $relative")
      } elseif ($headEntry.mode -cne $indexEntry.mode -or $headEntry.object_id -cne $indexEntry.object_id) {
        $issues.Add("Tracked file index content does not match HEAD: $relative")
      }
    }

    $worktreeProbe = Invoke-GitProbe $controlRootPath @('hash-object', "--path=$relative", '--', $relative)
    if ($worktreeProbe.exit_code -ne 0 -or @($worktreeProbe.lines).Count -ne 1) {
      $issues.Add("Unable to hash tracked file worktree content: $relative")
    } elseif ([string] $worktreeProbe.lines[0] -cne [string] $ordinaryIndexByPath[$relative].object_id) {
      $issues.Add("Tracked file worktree content does not match index: $relative")
    }
  }

  $stableRequiredFiles = @(@($requiredFiles) + @($scopeStableRelativePaths) + @($presentRetentionFiles) | Select-Object -Unique)
  foreach ($relative in $stableRequiredFiles) {
    if (-not $ordinaryIndexByPath.ContainsKey($relative)) {
      $issues.Add("Required stable file is not tracked: $relative")
    }
    & git -C $controlRootPath check-ignore -q --no-index -- $relative
    if ($LASTEXITCODE -eq 0) {
      $issues.Add("Required stable file is ignored: $relative")
    } elseif ($LASTEXITCODE -ne 1) {
      $issues.Add("Unable to determine ignore status for required stable file: $relative")
    }
  }
  $trackedRuntime = Invoke-GitRead $controlRootPath @('ls-files', '.yefeng/local', '.yefeng/runs', '.yefeng/outbox', '.yefeng/broker', '.yefeng/quarantine', '.runtime')
  if ($trackedRuntime) { $issues.Add("Runtime/local files are tracked: $trackedRuntime") }
  $fsck = & git -C $controlRootPath fsck --no-dangling 2>&1
  if ($LASTEXITCODE -ne 0) { $issues.Add("git fsck failed: $($fsck -join ' ')") }
}

$result = [ordered]@{
  valid = ($issues.Count -eq 0)
  control_root = $controlRootPath
  control_status = $controlStatus
  product_head = $productHead
  product_status = $productStatus
  product_heads = $productHeads
  product_statuses = $productStatuses
  scopes = $scopeIds
  issues = @($issues)
}

$result | ConvertTo-Json -Depth 20
if ($issues.Count -gt 0) { exit 1 }
