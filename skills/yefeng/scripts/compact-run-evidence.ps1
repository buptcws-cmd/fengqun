[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $ControlRoot,

  [Parameter(Mandatory = $true)]
  [string] $ScopeId,

  [ValidateSet('DryRun', 'Apply')]
  [string] $Mode = 'DryRun',

  [string] $PolicyPath = (Join-Path $PSScriptRoot 'run-retention-policy.json'),
  [string] $PlanPath = '',
  [string] $ApplyToken = '',
  [string] $ExpectedPlanDigest = '',
  [string[]] $ReferencedRunId = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
$hardProtectedControlDispositions = @(
  'ACTIVE', 'UNREVIEWED', 'BLOCKING', 'RECOVERY', 'RECONCILIATION', 'ACCEPTED'
)
$hardCompactableControlDispositions = @('SUPERSEDED', 'ARCHIVED', 'DISCARDABLE')
$hardTerminalStates = @('DONE', 'FAILED', 'EXIT_UNKNOWN', 'EXPIRED')
$hardKnownRunStates = @('STARTING', 'RUNNING', 'DONE', 'FAILED', 'EXIT_UNKNOWN', 'EXPIRED')
$hardReviewGates = @('PENDING', 'PASSED', 'FAILED', 'NOT_REQUIRED')
$stateRelativePaths = [ordered]@{
  runs = ".yefeng/series/$ScopeId/state/runs.json"
  roles = ".yefeng/series/$ScopeId/state/roles.json"
  control = ".yefeng/series/$ScopeId/state/control.json"
  transport = ".yefeng/series/$ScopeId/state/transport.json"
}

function Normalize-Path([string] $Value) {
  $full = [System.IO.Path]::GetFullPath($Value)
  $root = [System.IO.Path]::GetPathRoot($full)
  if ($full.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $root }
  return $full.TrimEnd('\', '/')
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
  $existing = $null
  while ($true) {
    if (Test-Path -LiteralPath $probe) {
      $existing = $probe
      break
    }
    if ($probe.Equals($pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) { break }
    $parent = Split-Path -Parent $probe
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
    $probe = Normalize-Path $parent
  }
  if (-not $existing) { return $fullPath }
  $probe = $existing
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

function Get-Sha256Bytes([byte[]] $Bytes) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Get-Sha256Text([string] $Text) {
  return Get-Sha256Bytes $utf8NoBom.GetBytes($Text)
}

function Get-FileSha256([string] $PathValue) {
  return (Get-FileHash -LiteralPath $PathValue -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-GitText([string] $Root, [string[]] $Arguments) {
  $output = @(& git -C $Root @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "git -C $Root $($Arguments -join ' ') failed: $($output -join ' ')"
  }
  return ($output -join [Environment]::NewLine).Trim()
}

function Get-CommittedText([string] $Root, [string] $Revision, [string] $RelativePath) {
  return Invoke-GitText $Root @('show', "${Revision}:$RelativePath")
}

function Get-CommittedJsonHash([string] $Root, [string] $Revision, [string] $RelativePath) {
  $value = ConvertFrom-RetentionJson (Get-CommittedText $Root $Revision $RelativePath)
  return Get-Sha256Text (ConvertTo-CompactJson $value)
}

function Assert-ExactProperties([string] $Label, [object] $Value, [string[]] $Names) {
  if ($null -eq $Value) { throw "$Label must be an object." }
  $actual = @($Value.PSObject.Properties | ForEach-Object { [string] $_.Name })
  foreach ($name in $Names) {
    if ($actual -notcontains $name) { throw "$Label is missing required field: $name" }
  }
  foreach ($name in $actual) {
    if ($Names -notcontains $name) { throw "$Label contains unknown field: $name" }
  }
  if ($actual.Count -ne $Names.Count) { throw "$Label has duplicate or missing fields." }
}

function Test-NativeInteger([object] $Value) {
  return (
    $Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or
    $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
  )
}

function ConvertTo-CompactJson($Value) {
  return ($Value | ConvertTo-Json -Depth 40 -Compress)
}

function ConvertFrom-RetentionJson([string] $Json) {
  $command = Get-Command ConvertFrom-Json -ErrorAction Stop
  if ($command.Parameters.ContainsKey('DateKind')) {
    return $Json | ConvertFrom-Json -DateKind String -ErrorAction Stop
  }
  return $Json | ConvertFrom-Json -ErrorAction Stop
}

function Get-JsonByteCount($Value) {
  return $utf8NoBom.GetByteCount((ConvertTo-CompactJson $Value))
}

function Get-RelativeForwardPath([string] $PathValue, [string] $Root) {
  $rootUri = [Uri]::new((Normalize-Path $Root) + [System.IO.Path]::DirectorySeparatorChar)
  $pathUri = [Uri]::new((Normalize-Path $PathValue))
  return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString())
}

function Test-PathFreeId([object] $Value) {
  if ($Value -isnot [string]) { return $false }
  $text = [string] $Value
  if ($text -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $text.EndsWith('.')) { return $false }
  if ($text -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { return $false }
  return $true
}

function Get-StructuredProperty([object] $Object, [string] $Name) {
  $property = $Object.PSObject.Properties[$Name]
  if ($property) { return $property.Value }
  return $null
}

function Test-HasStructuredBinding([object] $Run) {
  foreach ($name in @('run_root', 'retention_group_id', 'parent_run_id', 'review_gate', 'control_disposition')) {
    if (-not $Run.PSObject.Properties[$name]) { return $false }
  }
  return $true
}

$singleRunReferenceFields = [System.Collections.Generic.HashSet[string]]::new(
  [string[]] @('run_id', 'current_run_id', 'parent_run_id'),
  [System.StringComparer]::Ordinal
)
$multipleRunReferenceFields = [System.Collections.Generic.HashSet[string]]::new(
  [string[]] @('run_ids', 'referenced_run_ids'),
  [System.StringComparer]::Ordinal
)

function Add-RunReferences([object] $Value, [System.Collections.Generic.HashSet[string]] $Set) {
  if ($null -eq $Value) { return }
  if ($Value -is [string] -or $Value.GetType().IsPrimitive) { return }
  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
    foreach ($entry in $Value) { Add-RunReferences $entry $Set }
    return
  }
  foreach ($property in @($Value.PSObject.Properties)) {
    if ($singleRunReferenceFields.Contains([string] $property.Name) -and $property.Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string] $property.Value)) {
      $null = $Set.Add([string] $property.Value)
    } elseif ($multipleRunReferenceFields.Contains([string] $property.Name) -and $property.Value -is [System.Collections.IEnumerable]) {
      foreach ($runId in @($property.Value)) {
        if ($runId -is [string] -and -not [string]::IsNullOrWhiteSpace([string] $runId)) { $null = $Set.Add([string] $runId) }
      }
    } else {
      Add-RunReferences $property.Value $Set
    }
  }
}

function Get-CanonicalEndedAt([object] $Run) {
  $property = $Run.PSObject.Properties['ended_at']
  if (-not $property -or $property.Value -isnot [string]) {
    return [DateTimeOffset]::MinValue
  }
  $raw = [string] $property.Value
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return [DateTimeOffset]::MinValue
  }
  $parsed = [DateTimeOffset]::MinValue
  $valid = [DateTimeOffset]::TryParseExact(
    $raw,
    'o',
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind,
    [ref] $parsed
  )
  if (
    -not $valid -or
    $parsed.ToString('o', [Globalization.CultureInfo]::InvariantCulture) -cne $raw
  ) {
    return [DateTimeOffset]::MinValue
  }
  return $parsed
}

function Get-SafeLogInventory([string] $Root, [System.Collections.Generic.HashSet[string]] $AllowedNames) {
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    return [pscustomobject]@{ bytes = [int64] 0; files = 0; reparse_items = 0 }
  }
  $rootPath = Normalize-Path $Root
  if (Find-ReparsePointInExistingPathChain $rootPath) {
    return [pscustomobject]@{ bytes = [int64] 0; files = 0; reparse_items = 1 }
  }
  $bytes = [int64] 0
  $files = 0
  $reparseItems = 0
  $stack = [System.Collections.Generic.Stack[string]]::new()
  $stack.Push($rootPath)
  while ($stack.Count -gt 0) {
    $directory = $stack.Pop()
    foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
      if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        $reparseItems++
        continue
      }
      $itemPath = Normalize-Path $item.FullName
      if (-not (Test-PathWithin $itemPath $rootPath)) { throw "Inventory item escaped runs root: $itemPath" }
      if ($item.PSIsContainer) {
        $stack.Push($itemPath)
      } elseif ($AllowedNames.Contains($item.Name)) {
        $bytes += [int64] $item.Length
        $files++
      }
    }
  }
  return [pscustomobject]@{ bytes = $bytes; files = $files; reparse_items = $reparseItems }
}

function New-FilePrecondition(
  [string] $PathValue,
  [string] $ControlRootPath,
  [object] $Run,
  [object] $Policy,
  [bool] $ScopeOverCap,
  [bool] $OverallOverCap
) {
  $item = Get-Item -LiteralPath $PathValue -Force -ErrorAction Stop
  return [ordered]@{
    run_id = [string] $Run.run_id
    role_id = [string] $Run.role_id
    scope_id = [string] $Run.scope_id
    product_repo_id = [string] $Run.product_repo_id
    run_epoch = [int64] $Run.run_epoch
    retention_group_id = [string] $Run.retention_group_id
    run_root = [string] $Run.run_root
    status = [string] $Run.status
    review_gate = [string] $Run.review_gate
    control_disposition = [string] $Run.control_disposition
    ended_at = [string] $Run.ended_at
    eligibility_basis = [ordered]@{
      last_failure = $false
      final_pass = $false
      terminal_age_hours = [int64] $Policy.terminal_age_hours
      superseded_retention_days = [int64] $Policy.superseded_retention_days
      long_log_threshold_bytes = [int64] $Policy.long_log_threshold_bytes
      selected_by_long_log = [bool] ([int64] $item.Length -ge [int64] $Policy.long_log_threshold_bytes)
      selected_by_scope_cap = $ScopeOverCap
      selected_by_overall_cap = $OverallOverCap
    }
    relative_path = Get-RelativeForwardPath $PathValue $ControlRootPath
    leaf_name = [string] $item.Name
    size = [int64] $item.Length
    last_write_utc = $item.LastWriteTimeUtc.ToString('o')
    sha256 = Get-FileSha256 $PathValue
  }
}

function Get-RunAudit(
  [string] $RunRoot,
  [string] $ScopeRunsRoot,
  [System.Collections.Generic.HashSet[string]] $AllowedNames
) {
  try {
    if (-not (Test-PathWithin $RunRoot $ScopeRunsRoot)) {
      return [pscustomobject]@{ valid = $false; reason = 'run-root-outside-scope'; log_items = @() }
    }
    $rootReparse = Find-ReparsePointInExistingPathChain $RunRoot
    if ($rootReparse) { return [pscustomobject]@{ valid = $false; reason = 'reparse'; log_items = @() } }
    if (-not (Test-Path -LiteralPath $RunRoot -PathType Container)) {
      return [pscustomobject]@{ valid = $true; reason = 'missing-run-root'; log_items = @() }
    }
    $logItems = [System.Collections.Generic.List[object]]::new()
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push((Normalize-Path $RunRoot))
    while ($stack.Count -gt 0) {
      $directory = $stack.Pop()
      foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
        $itemPath = Normalize-Path $item.FullName
        if (-not (Test-PathWithin $itemPath $RunRoot) -or -not (Test-PathWithin $itemPath $ScopeRunsRoot)) {
          return [pscustomobject]@{ valid = $false; reason = 'path-containment'; log_items = @() }
        }
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
          return [pscustomobject]@{ valid = $false; reason = 'reparse'; log_items = @() }
        }
        if ($item.PSIsContainer) {
          $stack.Push($itemPath)
          continue
        }
        if ($item -isnot [System.IO.FileInfo]) {
          return [pscustomobject]@{ valid = $false; reason = 'non-ordinary-leaf'; log_items = @() }
        }
        $parent = Normalize-Path (Split-Path -Parent $itemPath)
        if ($parent.Equals((Normalize-Path $RunRoot), [System.StringComparison]::OrdinalIgnoreCase) -and $AllowedNames.Contains($item.Name)) {
          $logItems.Add($item)
        }
      }
    }
    return [pscustomobject]@{ valid = $true; reason = ''; log_items = @($logItems) }
  } catch {
    return [pscustomobject]@{ valid = $false; reason = 'run-audit-error'; log_items = @() }
  }
}

function Assert-Policy([object] $Policy) {
  $fieldNames = @(
    'version', 'dry_run_default', 'terminal_age_hours', 'superseded_retention_days',
    'long_log_threshold_bytes', 'scope_soft_cap_bytes', 'overall_cap_bytes',
    'receipt_max_bytes', 'keep_last_failures_per_group', 'keep_final_passes_per_group',
    'apply_window_minutes', 'max_candidates_per_plan', 'allowed_leaf_logs'
  )
  Assert-ExactProperties 'Retention policy' $Policy $fieldNames
  if (-not (Test-NativeInteger $Policy.version) -or [int64] $Policy.version -ne 1) { throw 'Retention policy version must be integer 1.' }
  if ($Policy.dry_run_default -isnot [bool] -or -not $Policy.dry_run_default) { throw 'Retention policy must default to dry-run.' }
  foreach ($name in @(
    'terminal_age_hours', 'superseded_retention_days', 'long_log_threshold_bytes',
    'scope_soft_cap_bytes', 'overall_cap_bytes', 'receipt_max_bytes',
    'keep_last_failures_per_group', 'keep_final_passes_per_group',
    'apply_window_minutes', 'max_candidates_per_plan'
  )) {
    if (-not (Test-NativeInteger $Policy.$name) -or [int64] $Policy.$name -lt 1) {
      throw "Retention policy $name must be a positive native integer."
    }
  }
  if ([int64] $Policy.terminal_age_hours -lt 24) { throw 'Terminal age may not be less than 24 hours.' }
  if ([int64] $Policy.superseded_retention_days -lt 7) { throw 'Superseded retention may not be less than 7 days.' }
  if ([int64] $Policy.long_log_threshold_bytes -lt 1048576) { throw 'Long-log threshold may not be less than 1 MiB.' }
  if ([int64] $Policy.scope_soft_cap_bytes -lt 536870912) { throw 'Scope cap may not be less than 512 MiB.' }
  if ([int64] $Policy.overall_cap_bytes -lt 1073741824) { throw 'Overall cap may not be less than 1 GiB.' }
  if ([int64] $Policy.receipt_max_bytes -gt 65536) { throw 'Receipt cap may not exceed 64 KiB.' }
  if ([int64] $Policy.keep_last_failures_per_group -lt 1 -or [int64] $Policy.keep_final_passes_per_group -lt 1) {
    throw 'Retention policy must keep at least one failure and one final pass per group.'
  }
  if ([int64] $Policy.apply_window_minutes -gt 60) { throw 'Apply window may not exceed 60 minutes.' }
  if ([int64] $Policy.max_candidates_per_plan -gt 64) { throw 'Candidate batch may not exceed 64 leaves.' }
  $requiredLeaves = @('stdout.jsonl', 'stderr.log', 'worker-stdout.log', 'worker-stderr.log')
  if (@($Policy.allowed_leaf_logs).Count -ne $requiredLeaves.Count) { throw 'Allowed leaf log set must be exact.' }
  foreach ($leaf in $requiredLeaves) {
    if (@($Policy.allowed_leaf_logs) -notcontains $leaf) { throw "Allowed leaf log set is missing: $leaf" }
  }
}

function Assert-PlanFilePrecondition(
  [object] $Candidate,
  [string] $ControlRootPath,
  [string] $ScopeRunsRoot,
  [System.Collections.Generic.HashSet[string]] $AllowedNames
) {
  if (-not $AllowedNames.Contains([string] $Candidate.leaf_name)) { throw "Plan contains a forbidden leaf: $($Candidate.leaf_name)" }
  $candidatePath = Normalize-Path (Join-Path $ControlRootPath ([string] $Candidate.relative_path))
  if (-not (Test-PathWithin $candidatePath $ScopeRunsRoot)) { throw "Plan candidate escapes scope runs root: $candidatePath" }
  if ((Split-Path -Leaf $candidatePath) -cne [string] $Candidate.leaf_name) { throw "Plan leaf binding mismatch: $candidatePath" }
  $reparse = Find-ReparsePointInExistingPathChain $candidatePath
  if ($reparse) { throw "Plan candidate traverses a reparse point: $reparse" }
  if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { throw "Plan candidate is no longer an ordinary leaf: $candidatePath" }
  $item = Get-Item -LiteralPath $candidatePath -Force -ErrorAction Stop
  if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "Plan candidate is a reparse point: $candidatePath" }
  if ([int64] $item.Length -ne [int64] $Candidate.size) { throw "Plan candidate size drifted: $candidatePath" }
  if ($item.LastWriteTimeUtc.ToString('o') -cne [string] $Candidate.last_write_utc) { throw "Plan candidate mtime drifted: $candidatePath" }
  if ((Get-FileSha256 $candidatePath) -cne [string] $Candidate.sha256) { throw "Plan candidate hash drifted: $candidatePath" }
  return $candidatePath
}

function Write-BoundedJson([object] $Value, [int64] $MaximumBytes) {
  $json = ConvertTo-CompactJson $Value
  $byteCount = $utf8NoBom.GetByteCount($json)
  if ($byteCount -gt $MaximumBytes) { throw "JSON receipt exceeds configured cap: $byteCount > $MaximumBytes" }
  Write-Output $json
}

$controlRootPath = Normalize-Path ((Resolve-Path -LiteralPath $ControlRoot).Path)
if (Find-ReparsePointInExistingPathChain $controlRootPath) { throw "Control root traverses a reparse point: $controlRootPath" }
if ($ScopeId -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw "Invalid scope ID: $ScopeId" }
$gitTopLevel = Normalize-Path (Invoke-GitText $controlRootPath @('rev-parse', '--show-toplevel'))
if (-not $gitTopLevel.Equals($controlRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Control root is not an exact Git top level: $gitTopLevel"
}
$topologyPath = Normalize-Path (Join-Path $controlRootPath '.yefeng\control-plane.json')
if (Find-ReparsePointInExistingPathChain $topologyPath) { throw "Control topology traverses a reparse point: $topologyPath" }
if (-not (Test-Path -LiteralPath $topologyPath -PathType Leaf)) {
  throw 'Run-evidence compaction supports only an external-git control repository with .yefeng/control-plane.json.'
}
$topology = ConvertFrom-RetentionJson (Get-Content -LiteralPath $topologyPath -Raw -Encoding UTF8)
if ([string] $topology.control_plane_mode -cne 'external-git') {
  throw 'Run-evidence compaction supports only control_plane_mode external-git.'
}
if (@($topology.active_scopes) -notcontains $ScopeId) {
  throw "Scope is not active in the external control topology: $ScopeId"
}
$controlStatus = Invoke-GitText $controlRootPath @('status', '--porcelain=v1', '--untracked-files=all')
if (-not [string]::IsNullOrWhiteSpace($controlStatus)) { throw "Control repository must be clean: $controlStatus" }
$currentControlHead = Invoke-GitText $controlRootPath @('rev-parse', '--verify', 'HEAD^{commit}')
$policyResolvedPath = Normalize-Path ((Resolve-Path -LiteralPath $PolicyPath).Path)
if (Find-ReparsePointInExistingPathChain $policyResolvedPath) { throw "Policy path traverses a reparse point: $policyResolvedPath" }
$policyBytes = [System.IO.File]::ReadAllBytes($policyResolvedPath)
$policySha256 = Get-Sha256Bytes $policyBytes
$policy = ConvertFrom-RetentionJson $utf8NoBom.GetString($policyBytes)
Assert-Policy $policy
$allowedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($leaf in @($policy.allowed_leaf_logs)) { $null = $allowedNames.Add([string] $leaf) }

$runsStatePath = Normalize-Path (Join-Path $controlRootPath ".yefeng\series\$ScopeId\state\runs.json")
$scopeRunsRoot = Normalize-Path (Join-Path $controlRootPath ".yefeng\runs\$ScopeId")
$overallRunsRoot = Normalize-Path (Join-Path $controlRootPath '.yefeng\runs')
$eventsRelativePath = ".yefeng/series/$ScopeId/events.jsonl"
if (-not (Test-PathWithin $runsStatePath $controlRootPath)) { throw 'Runs state escaped control root.' }
if (-not (Test-PathWithin $scopeRunsRoot $overallRunsRoot)) { throw 'Scope runs root escaped overall runs root.' }
if (Find-ReparsePointInExistingPathChain $runsStatePath) { throw "Runs state traverses a reparse point: $runsStatePath" }
if (-not (Test-Path -LiteralPath $runsStatePath -PathType Leaf)) { throw "Missing runs state: $runsStatePath" }
$committedStateHashes = [ordered]@{}
$committedStateObjects = @{}
foreach ($entry in $stateRelativePaths.GetEnumerator()) {
  $committedText = Get-CommittedText $controlRootPath $currentControlHead $entry.Value
  $committedObject = ConvertFrom-RetentionJson $committedText
  $committedStateObjects[$entry.Key] = $committedObject
  $committedStateHashes[$entry.Key] = Get-Sha256Text (ConvertTo-CompactJson $committedObject)
}

$applyContext = $null
if ($Mode -eq 'Apply') {
  if ([string]::IsNullOrWhiteSpace($PlanPath) -or [string]::IsNullOrWhiteSpace($ApplyToken) -or [string]::IsNullOrWhiteSpace($ExpectedPlanDigest)) {
    throw 'Apply requires PlanPath, ApplyToken, and ExpectedPlanDigest.'
  }
  $planResolvedPath = Normalize-Path ((Resolve-Path -LiteralPath $PlanPath).Path)
  if (Test-PathWithin $planResolvedPath $overallRunsRoot) { throw 'Plan file must be stored outside the run-evidence tree.' }
  if (Find-ReparsePointInExistingPathChain $planResolvedPath) { throw "Plan path traverses a reparse point: $planResolvedPath" }
  $planReceipt = ConvertFrom-RetentionJson (Get-Content -LiteralPath $planResolvedPath -Raw -Encoding UTF8)
  if ([int] $planReceipt.version -ne 1 -or [string] $planReceipt.mode -ne 'dry-run') { throw 'Plan is not a supported dry-run receipt.' }
  if ([string] $planReceipt.apply_token -cne $ApplyToken) { throw 'Apply token mismatch.' }
  $calculatedDigest = Get-Sha256Text (ConvertTo-CompactJson $planReceipt.plan)
  if ($calculatedDigest -cne [string] $planReceipt.plan_digest -or $calculatedDigest -cne $ExpectedPlanDigest.ToLowerInvariant()) {
    throw 'Plan digest mismatch.'
  }
  if ([string] $planReceipt.plan.control_root -cne $controlRootPath -or [string] $planReceipt.plan.scope_id -cne $ScopeId) {
    throw 'Plan root or scope binding mismatch.'
  }
  if ([string] $planReceipt.plan.policy_sha256 -cne $policySha256) { throw 'Retention policy drifted after dry-run.' }
  $tokenSha256 = Get-Sha256Text $ApplyToken
  if ([string] $planReceipt.plan.apply_token_sha256 -cne $tokenSha256) { throw 'Apply token digest mismatch.' }
  if (
    (Get-Sha256Text (ConvertTo-CompactJson @($planReceipt.plan.referenced_run_ids))) -cne
    [string] $planReceipt.plan.reference_set_sha256
  ) { throw 'Plan reference-set digest mismatch.' }
  $plannedCandidates = @($planReceipt.plan.candidates)
  $recomputedCandidateBytes = [int64] 0
  foreach ($candidate in $plannedCandidates) { $recomputedCandidateBytes += [int64] $candidate.size }
  $recomputedCandidateSha256 = Get-Sha256Text (ConvertTo-CompactJson $plannedCandidates)
  if (
    [int64] $planReceipt.plan.candidate_summary.count -ne $plannedCandidates.Count -or
    [int64] $planReceipt.plan.candidate_summary.bytes -ne $recomputedCandidateBytes -or
    [string] $planReceipt.plan.candidate_summary.sha256 -cne $recomputedCandidateSha256
  ) { throw 'Plan candidate summary mismatch.' }
  foreach ($stateName in @('runs', 'roles', 'control', 'transport')) {
    if ([string] $planReceipt.plan.state_hashes.$stateName -cne [string] $committedStateHashes[$stateName]) {
      throw "Committed $stateName state drifted after dry-run."
    }
  }
  $parentLine = Invoke-GitText $controlRootPath @('rev-list', '--parents', '-n', '1', 'HEAD')
  $parentParts = @($parentLine -split '\s+')
  if ($parentParts.Count -ne 2) { throw 'Apply HEAD must be a single-parent PREPARED commit.' }
  $preparedParentHead = [string] $parentParts[1]
  if ([string] $planReceipt.plan.base_control_head -cne $preparedParentHead) {
    throw 'Current PREPARED commit is not the direct child of the planned control HEAD.'
  }
  $changedPaths = @(Invoke-GitText $controlRootPath @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD') -split "[`r`n]+" | Where-Object { $_ })
  if ($changedPaths -notcontains $eventsRelativePath) { throw 'Current control HEAD does not commit the PREPARED event.' }
  $preparedRecords = [System.Collections.Generic.List[object]]::new()
  $eventsText = Get-CommittedText $controlRootPath $currentControlHead $eventsRelativePath
  foreach ($line in @($eventsText -split "[`r`n]+")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $event = ConvertFrom-RetentionJson $line
    if (
      [string] $event.type -eq 'RUN_EVIDENCE_RETENTION_PREPARED' -and
      [string] $event.scope_id -eq $ScopeId -and
      [string] $event.plan_digest -eq $calculatedDigest
    ) { $preparedRecords.Add($event) }
  }
  if ($preparedRecords.Count -ne 1) { throw "Apply requires exactly one matching committed PREPARED record; found $($preparedRecords.Count)." }
  $prepared = $preparedRecords[0]
  $preparedFields = @(
    'event_id', 'type', 'operation_id', 'created_at', 'scope_id', 'run_epoch',
    'control_repo_id', 'product_repo_id', 'prepared_parent_control_head',
    'plan_digest', 'policy_sha256', 'state_hashes', 'apply_token_sha256',
    'candidate_summary', 'reference_set_sha256'
  )
  Assert-ExactProperties 'Committed PREPARED record' $prepared $preparedFields
  Assert-ExactProperties 'Committed PREPARED state_hashes' $prepared.state_hashes @('runs', 'roles', 'control', 'transport')
  Assert-ExactProperties 'Committed PREPARED candidate_summary' $prepared.candidate_summary @('count', 'bytes', 'sha256')
  if (
    [string] $prepared.prepared_parent_control_head -cne $preparedParentHead -or
    [string] $prepared.plan_digest -cne $calculatedDigest -or
    [string] $prepared.policy_sha256 -cne $policySha256 -or
    [string] $prepared.apply_token_sha256 -cne $tokenSha256 -or
    [string] $prepared.reference_set_sha256 -cne [string] $planReceipt.plan.reference_set_sha256 -or
    [int64] $prepared.run_epoch -ne [int64] $planReceipt.plan.run_epoch -or
    [string] $prepared.control_repo_id -cne [string] $planReceipt.plan.control_repo_id -or
    [string] $prepared.product_repo_id -cne [string] $planReceipt.plan.product_repo_id
  ) { throw 'Committed PREPARED identity binding mismatch.' }
  foreach ($stateName in @('runs', 'roles', 'control', 'transport')) {
    if ([string] $prepared.state_hashes.$stateName -cne [string] $planReceipt.plan.state_hashes.$stateName) {
      throw "Committed PREPARED $stateName hash mismatch."
    }
  }
  foreach ($summaryName in @('count', 'bytes', 'sha256')) {
    if ([string] $prepared.candidate_summary.$summaryName -cne [string] $planReceipt.plan.candidate_summary.$summaryName) {
      throw "Committed PREPARED candidate summary mismatch: $summaryName"
    }
  }
  $expiresAt = [DateTimeOffset]::Parse([string] $planReceipt.plan.expires_at)
  $applyNow = [DateTimeOffset]::UtcNow
  if ($applyNow -gt $expiresAt) { throw 'Dry-run plan expired.' }
  $applyContext = [pscustomobject]@{
    plan_receipt = $planReceipt
    plan_digest = $calculatedDigest
    token_sha256 = $tokenSha256
    planned_candidates = $plannedCandidates
    apply_now = $applyNow
  }
}

$runsState = $committedStateObjects['runs']
if ([string] $runsState.scope_id -cne $ScopeId) { throw 'Runs state scope binding mismatch.' }
$referenced = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$semanticReferencedRunIds = if ($applyContext) { @($applyContext.plan_receipt.plan.referenced_run_ids) } else { @($ReferencedRunId) }
foreach ($runId in $semanticReferencedRunIds) {
  if (-not (Test-PathFreeId $runId)) {
    throw "Explicit referenced run ID is invalid: $runId"
  }
  $null = $referenced.Add([string] $runId)
}
foreach ($referenceStateName in @('roles', 'control', 'transport')) {
  Add-RunReferences $committedStateObjects[$referenceStateName] $referenced
}
foreach ($run in @($runsState.runs)) {
  if (Test-HasStructuredBinding $run) {
    $parentRunId = [string] $run.parent_run_id
    if (-not [string]::IsNullOrWhiteSpace($parentRunId)) { $null = $referenced.Add($parentRunId) }
  }
}

$protectedReasons = @{}
function Protect-Run([string] $RunId, [string] $Reason) {
  if (-not $protectedReasons.ContainsKey($RunId)) {
    $protectedReasons[$RunId] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  }
  $null = $protectedReasons[$RunId].Add($Reason)
}

$structuredRuns = [System.Collections.Generic.List[object]]::new()
$groups = @{}
$runIdCounts = @{}
$terminalEndedAtByRunId = @{}
foreach ($run in @($runsState.runs)) {
  $countedRunId = [string] $run.run_id
  if (-not $runIdCounts.ContainsKey($countedRunId)) { $runIdCounts[$countedRunId] = 0 }
  $runIdCounts[$countedRunId] = [int] $runIdCounts[$countedRunId] + 1
}
$runIndex = 0
foreach ($run in @($runsState.runs)) {
  $runIndex++
  $rawRunId = $run.run_id
  $runId = [string] $rawRunId
  $protectionKey = if ([string]::IsNullOrWhiteSpace($runId)) { "<invalid-run-$runIndex>" } else { $runId }
  if (-not (Test-HasStructuredBinding $run)) {
    Protect-Run $protectionKey 'legacy-missing-structured-binding'
    continue
  }
  $rawRoleId = $run.role_id
  $roleId = [string] $rawRoleId
  $rawProductRepoId = $run.product_repo_id
  $groupId = [string] $run.retention_group_id
  if (
    -not (Test-PathFreeId $rawRunId) -or
    -not (Test-PathFreeId $rawRoleId) -or
    -not (Test-PathFreeId $rawProductRepoId) -or
    -not (Test-PathFreeId $run.retention_group_id) -or
    [int] $runIdCounts[$runId] -ne 1
  ) {
    Protect-Run $protectionKey 'invalid-identity-binding'
    continue
  }
  $expectedRelativeRunRoot = ".yefeng/runs/$ScopeId/$roleId/$runId"
  if (
    [string] $run.scope_id -cne $ScopeId -or
    -not (Test-NativeInteger $run.run_epoch) -or
    [int64] $run.run_epoch -ne [int64] $runsState.run_epoch -or
    [string] $run.control_repo_id -cne [string] $committedStateObjects['control'].control_repo_id -or
    $run.run_root -isnot [string] -or
    [string] $run.run_root -cne $expectedRelativeRunRoot
  ) {
    Protect-Run $protectionKey 'invalid-state-binding'
    continue
  }
  $rawParent = $run.parent_run_id
  if (
    $null -ne $rawParent -and
    (-not (Test-PathFreeId $rawParent) -or [string] $rawParent -eq $runId)
  ) {
    Protect-Run $protectionKey 'invalid-parent-binding'
    continue
  }
  $runStatus = [string] $run.status
  if ($hardKnownRunStates -notcontains $runStatus) {
    Protect-Run $protectionKey 'active-or-unknown-status'
    continue
  } elseif ($hardTerminalStates -notcontains $runStatus) {
    Protect-Run $protectionKey 'active-or-unknown-status'
    continue
  }
  $terminalEndedAt = Get-CanonicalEndedAt $run
  if ($terminalEndedAt -eq [DateTimeOffset]::MinValue) {
    Protect-Run $protectionKey 'invalid-terminal-ended-at'
    continue
  }
  $terminalEndedAtByRunId[$runId] = $terminalEndedAt
  $reviewGate = [string] $run.review_gate
  if ($hardReviewGates -notcontains $reviewGate) {
    Protect-Run $protectionKey 'unknown-review-gate'
    continue
  } elseif ($reviewGate -eq 'PENDING') {
    Protect-Run $protectionKey 'unreviewed'
  }
  $disposition = [string] $run.control_disposition
  if ($hardProtectedControlDispositions -contains $disposition) {
    Protect-Run $protectionKey ('control-' + $disposition.ToLowerInvariant())
  } elseif ($hardCompactableControlDispositions -notcontains $disposition) {
    Protect-Run $protectionKey 'unknown-control-disposition'
    continue
  }
  if ($referenced.Contains($runId)) { Protect-Run $protectionKey 'referenced' }
  $structuredRuns.Add($run)
  if (-not $groups.ContainsKey($groupId)) { $groups[$groupId] = [System.Collections.Generic.List[object]]::new() }
  $groups[$groupId].Add($run)
}

foreach ($group in $groups.GetEnumerator()) {
  $ordered = @($group.Value | Sort-Object `
    @{ Expression = { $terminalEndedAtByRunId[[string] $_.run_id] }; Descending = $true }, `
    @{ Expression = { [string] $_.run_id } })
  $failures = @($ordered | Where-Object {
    [string] $_.status -in @('FAILED', 'EXIT_UNKNOWN') -or [string] $_.review_gate -eq 'FAILED'
  } | Select-Object -First ([int] $policy.keep_last_failures_per_group))
  foreach ($run in $failures) { Protect-Run ([string] $run.run_id) 'last-failure' }
  $passes = @($ordered | Where-Object {
    [string] $_.status -eq 'DONE' -and [string] $_.review_gate -in @('PASSED', 'NOT_REQUIRED')
  } | Select-Object -First ([int] $policy.keep_final_passes_per_group))
  foreach ($run in $passes) { Protect-Run ([string] $run.run_id) 'final-pass' }
}

$scopeInventory = Get-SafeLogInventory $scopeRunsRoot $allowedNames
$overallInventory = Get-SafeLogInventory $overallRunsRoot $allowedNames
$scopeOverCap = [int64] $scopeInventory.bytes -gt [int64] $policy.scope_soft_cap_bytes
$overallOverCap = [int64] $overallInventory.bytes -gt [int64] $policy.overall_cap_bytes
$overCap = $scopeOverCap -or $overallOverCap
$baseCandidates = [System.Collections.Generic.List[object]]::new()
$dryRunNow = [DateTimeOffset]::UtcNow
foreach ($run in $structuredRuns) {
  $runId = [string] $run.run_id
  if ($protectedReasons.ContainsKey($runId)) { continue }
  if ($hardCompactableControlDispositions -notcontains [string] $run.control_disposition) {
    Protect-Run $runId 'not-explicitly-compactable'
    continue
  }
  $ended = $terminalEndedAtByRunId[$runId]
  if (($dryRunNow - $ended).TotalHours -lt [double] $policy.terminal_age_hours) {
    Protect-Run $runId 'terminal-age'
    continue
  }
  if ([string] $run.control_disposition -eq 'SUPERSEDED' -and ($dryRunNow - $ended).TotalDays -lt [double] $policy.superseded_retention_days) {
    Protect-Run $runId 'superseded-retention'
    continue
  }
  try {
    $runRoot = Normalize-Path (Join-Path $controlRootPath ([string] $run.run_root))
  } catch {
    Protect-Run $runId 'invalid-run-root'
    continue
  }
  if (-not (Test-PathWithin $runRoot $scopeRunsRoot)) {
    Protect-Run $runId 'run-root-outside-scope'
    continue
  }
  $expectedRunRoot = Normalize-Path (Join-Path $scopeRunsRoot (Join-Path ([string] $run.role_id) ([string] $run.run_id)))
  if (-not $runRoot.Equals($expectedRunRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    Protect-Run $runId 'run-root-binding-mismatch'
    continue
  }
  $audit = Get-RunAudit $runRoot $scopeRunsRoot $allowedNames
  if (-not $audit.valid) {
    Protect-Run $runId ([string] $audit.reason)
    continue
  }
  foreach ($leafItem in @($audit.log_items)) {
    if ([int64] $leafItem.Length -ge [int64] $policy.long_log_threshold_bytes -or $overCap) {
      $baseCandidates.Add((New-FilePrecondition $leafItem.FullName $controlRootPath $run $policy $scopeOverCap $overallOverCap))
    }
  }
}

$orderedCandidates = @($baseCandidates | Sort-Object `
  @{ Expression = { if ([int64] $_.size -ge [int64] $policy.long_log_threshold_bytes) { 0 } else { 1 } } }, `
  @{ Expression = { [int64] $_.size }; Descending = $true }, `
  @{ Expression = { [string] $_.relative_path } })

$planProductRepoId = if ($applyContext) {
  [string] $applyContext.plan_receipt.plan.product_repo_id
} elseif ($orderedCandidates.Count -gt 0) {
  [string] $orderedCandidates[0].product_repo_id
} else {
  ''
}
if (-not [string]::IsNullOrWhiteSpace($planProductRepoId) -and -not (Test-PathFreeId $planProductRepoId)) {
  throw "Plan product repository identity is invalid: $planProductRepoId"
}
$productCandidates = @(if (-not [string]::IsNullOrWhiteSpace($planProductRepoId)) {
  $orderedCandidates | Where-Object { [string] $_.product_repo_id -ceq $planProductRepoId }
})

if ($applyContext) {
  $candidates = @($applyContext.planned_candidates)
  if ($candidates.Count -gt [int] $policy.max_candidates_per_plan -or $candidates.Count -gt $productCandidates.Count) {
    throw 'Saved plan candidates are not a safe prefix of the current deterministic eligible set.'
  }
  for ($index = 0; $index -lt $candidates.Count; $index++) {
    if ((ConvertTo-CompactJson $candidates[$index]) -cne (ConvertTo-CompactJson $productCandidates[$index])) {
      throw "Saved plan candidate is not the exact current deterministic eligible prefix at index $index."
    }
  }

  # Complete the semantic and filesystem preflight for the entire batch before
  # the first destructive leaf operation.
  $preflightPaths = [System.Collections.Generic.List[string]]::new()
  $auditedRunRoots = @{}
  $candidatePathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($candidate in $candidates) {
    $candidateRunId = [string] $candidate.run_id
    $candidateRoleId = [string] $candidate.role_id
    if (
      -not (Test-PathFreeId $candidate.run_id) -or
      -not (Test-PathFreeId $candidate.role_id) -or
      -not (Test-PathFreeId $candidate.product_repo_id) -or
      [string] $candidate.product_repo_id -cne $planProductRepoId
    ) { throw "Plan candidate has an invalid role/run binding: $candidateRoleId/$candidateRunId" }
    $runKey = "$candidateRoleId/$candidateRunId"
    if (-not $auditedRunRoots.ContainsKey($runKey)) {
      $candidateRunRoot = Normalize-Path (Join-Path $scopeRunsRoot (Join-Path $candidateRoleId $candidateRunId))
      $runAudit = Get-RunAudit $candidateRunRoot $scopeRunsRoot $allowedNames
      if (-not $runAudit.valid) { throw "Plan candidate run audit failed for $runKey`: $($runAudit.reason)" }
      $auditedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
      foreach ($item in @($runAudit.log_items)) { $null = $auditedPaths.Add((Normalize-Path $item.FullName)) }
      $auditedRunRoots[$runKey] = [pscustomobject]@{ root = $candidateRunRoot; paths = $auditedPaths }
    }
    $plannedPath = Normalize-Path (Join-Path $controlRootPath ([string] $candidate.relative_path))
    if (-not $candidatePathSet.Add($plannedPath)) { throw "Plan contains a duplicate candidate leaf: $plannedPath" }
    if (-not $auditedRunRoots[$runKey].paths.Contains($plannedPath)) {
      throw "Plan candidate is not an audited ordinary root log leaf: $plannedPath"
    }
    $preflightPaths.Add((Assert-PlanFilePrecondition $candidate $controlRootPath $scopeRunsRoot $allowedNames))
  }

  $deleted = [System.Collections.Generic.List[object]]::new()
  for ($index = 0; $index -lt $candidates.Count; $index++) {
    $candidate = $candidates[$index]
    $runKey = "$($candidate.role_id)/$($candidate.run_id)"
    $repeatAudit = Get-RunAudit ([string] $auditedRunRoots[$runKey].root) $scopeRunsRoot $allowedNames
    if (-not $repeatAudit.valid) { throw "Plan candidate run changed before deletion for $runKey`: $($repeatAudit.reason)" }
    $candidatePath = Assert-PlanFilePrecondition $candidate $controlRootPath $scopeRunsRoot $allowedNames
    Remove-Item -LiteralPath $candidatePath -Force
    if (Test-Path -LiteralPath $candidatePath) { throw "Exact leaf deletion did not complete: $candidatePath" }
    $deleted.Add([ordered]@{
      relative_path = [string] $candidate.relative_path
      size = [int64] $candidate.size
      sha256 = [string] $candidate.sha256
    })
  }
  $deletedBytes = [int64] 0
  foreach ($entry in $deleted) { $deletedBytes += [int64] $entry.size }
  $receipt = [ordered]@{
    version = 1
    mode = 'apply'
    applied = $true
    scope_id = $ScopeId
    applied_at = $applyContext.apply_now.ToString('o')
    prepared_control_head = $currentControlHead
    plan_digest = $applyContext.plan_digest
    apply_token_sha256 = $applyContext.token_sha256
    deterministic_replan = 'exact-safe-prefix'
    deleted_count = $deleted.Count
    deleted_bytes = $deletedBytes
    deleted = @($deleted)
  }
  if ((Get-JsonByteCount $receipt) -gt [int64] $policy.receipt_max_bytes) {
    $receipt.deleted = @()
    $receipt['deleted_details_sha256'] = Get-Sha256Text (ConvertTo-CompactJson @($deleted))
  }
  Write-BoundedJson $receipt ([int64] $policy.receipt_max_bytes)
  return
}

$candidateLimit = [Math]::Min([int] $policy.max_candidates_per_plan, $productCandidates.Count)
$selected = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $candidateLimit; $index++) { $selected.Add($productCandidates[$index]) }
$protectedCounts = [ordered]@{}
foreach ($entry in $protectedReasons.GetEnumerator()) {
  foreach ($reason in $entry.Value) {
    if (-not $protectedCounts.Contains($reason)) { $protectedCounts[$reason] = 0 }
    $protectedCounts[$reason] = [int] $protectedCounts[$reason] + 1
  }
}
$protectedExamples = @($protectedReasons.GetEnumerator() | Sort-Object Key | Select-Object -First 16 | ForEach-Object {
  [ordered]@{ run_id = [string] $_.Key; reasons = @($_.Value | Sort-Object) }
})
$candidateBytes = [int64] 0
foreach ($candidate in $selected) { $candidateBytes += [int64] $candidate.size }
$applyTokenValue = [Guid]::NewGuid().ToString('N')
$referenceIds = @($referenced | Sort-Object)
$referenceSetSha256 = Get-Sha256Text (ConvertTo-CompactJson $referenceIds)
$candidateSummary = [ordered]@{
  count = $selected.Count
  bytes = $candidateBytes
  sha256 = Get-Sha256Text (ConvertTo-CompactJson @($selected))
}
$plan = [ordered]@{
  version = 1
  control_root = $controlRootPath
  scope_id = $ScopeId
  run_epoch = [int64] $runsState.run_epoch
  control_repo_id = [string] $runsState.control_repo_id
  product_repo_id = $planProductRepoId
  base_control_head = $currentControlHead
  generated_at = $dryRunNow.ToString('o')
  expires_at = $dryRunNow.AddMinutes([double] $policy.apply_window_minutes).ToString('o')
  policy_sha256 = $policySha256
  state_hashes = $committedStateHashes
  apply_token_sha256 = Get-Sha256Text $applyTokenValue
  reference_set_sha256 = $referenceSetSha256
  referenced_run_ids = $referenceIds
  candidate_summary = $candidateSummary
  inventory = [ordered]@{
    scope_bytes = [int64] $scopeInventory.bytes
    scope_files = [int] $scopeInventory.files
    overall_bytes = [int64] $overallInventory.bytes
    overall_files = [int] $overallInventory.files
    reparse_items = [int] $scopeInventory.reparse_items + [int] $overallInventory.reparse_items
    over_cap = [bool] $overCap
  }
  summary = [ordered]@{
    tracked_runs = @($runsState.runs).Count
    structured_runs = $structuredRuns.Count
    candidate_count = $selected.Count
    candidate_bytes = $candidateBytes
    deferred_candidate_count = $orderedCandidates.Count - $selected.Count
    protected_counts = $protectedCounts
    protected_examples = $protectedExamples
  }
  candidates = @($selected)
}
$planDigest = Get-Sha256Text (ConvertTo-CompactJson $plan)
$receipt = [ordered]@{
  version = 1
  mode = 'dry-run'
  dry_run = $true
  apply_token = $applyTokenValue
  plan_digest = $planDigest
  plan = $plan
}
while ((Get-JsonByteCount $receipt) -gt [int64] $policy.receipt_max_bytes -and $selected.Count -gt 0) {
  $selected.RemoveAt($selected.Count - 1)
  $candidateBytes = [int64] 0
  foreach ($candidate in $selected) { $candidateBytes += [int64] $candidate.size }
  $plan.candidates = @($selected)
  $plan.summary.candidate_count = $selected.Count
  $plan.summary.candidate_bytes = $candidateBytes
  $plan.summary.deferred_candidate_count = $orderedCandidates.Count - $selected.Count
  $plan.candidate_summary.count = $selected.Count
  $plan.candidate_summary.bytes = $candidateBytes
  $plan.candidate_summary.sha256 = Get-Sha256Text (ConvertTo-CompactJson @($selected))
  $planDigest = Get-Sha256Text (ConvertTo-CompactJson $plan)
  $receipt.plan_digest = $planDigest
}
Write-BoundedJson $receipt ([int64] $policy.receipt_max_bytes)
