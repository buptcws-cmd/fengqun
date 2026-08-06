[CmdletBinding()]
param(
  [switch]$SkipInstalledChainIntegration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$compactorPath = Join-Path $PSScriptRoot 'compact-run-evidence.ps1'
$installerPath = Join-Path $PSScriptRoot 'install-governed-runner.ps1'
$validatorPath = Join-Path $PSScriptRoot 'validate-run-evidence-retention.ps1'
$defaultPolicyPath = Join-Path $PSScriptRoot 'run-retention-policy.json'
$trustedCompactHash = (Get-FileHash -LiteralPath $compactorPath -Algorithm SHA256).Hash.ToLowerInvariant()
$enginePath = (Get-Process -Id $PID).Path
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('yefeng-retention-test-' + [Guid]::NewGuid().ToString('N'))
$script:assertionCount = 0
$script:installedChainExercised = $false

function Assert-True([bool]$Condition, [string]$Message) {
  $script:assertionCount++
  if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Write-Utf8([string]$PathValue, [string]$Text) {
  $parent = Split-Path -Parent $PathValue
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  [System.IO.File]::WriteAllText($PathValue, $Text, $utf8NoBom)
}

function Write-JsonFile([string]$PathValue, [object]$Value) {
  Write-Utf8 $PathValue ($Value | ConvertTo-Json -Depth 40)
}

function ConvertFrom-TestJson([string]$Json) {
  $command = Get-Command ConvertFrom-Json -ErrorAction Stop
  if ($command.Parameters.ContainsKey('DateKind')) { return $Json | ConvertFrom-Json -DateKind String }
  return $Json | ConvertFrom-Json
}

function ConvertTo-CompactJson([object]$Value) {
  return $Value | ConvertTo-Json -Depth 40 -Compress
}

function Get-Sha256Text([string]$Text) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($utf8NoBom.GetBytes($Text)))).Replace('-', '').ToLowerInvariant()
  } finally { $sha.Dispose() }
}

function Get-ManifestCarrierSlotCount([string]$PathValue) {
  $text = [System.IO.File]::ReadAllText($PathValue, [System.Text.UTF8Encoding]::new($false, $true))
  $start = [regex]::Match($text, '(?m)^# RETENTION_TRUST_MANIFEST_START\r?$')
  $end = [regex]::Match($text, '(?m)^# RETENTION_TRUST_MANIFEST_END\r?$')
  if (-not $start.Success -or -not $end.Success -or $end.Index -le $start.Index) { return -1 }
  $length = ($end.Index + $end.Length) - $start.Index
  return [regex]::Matches($text.Substring($start.Index, $length), "(?i)'[0-9a-f]{64}'").Count
}

function Invoke-Git([string]$Root, [string[]]$Arguments) {
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = @(& git -C $Root @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join ' ')" }
  return ($output -join [Environment]::NewLine).Trim()
}

function Initialize-GitRoot([string]$Root) {
  New-Item -ItemType Directory -Path $Root -Force | Out-Null
  $null = Invoke-Git $Root @('init', '-b', 'main')
  $null = Invoke-Git $Root @('config', 'user.name', 'Yefeng Retention Test')
  $null = Invoke-Git $Root @('config', 'user.email', 'retention-test@example.invalid')
  $null = Invoke-Git $Root @('config', 'core.autocrlf', 'false')
}

function New-TestPolicy([string]$PathValue, [int64]$ReceiptCap = 65536) {
  $policy = Get-Content -LiteralPath $defaultPolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $policy.receipt_max_bytes = $ReceiptCap
  Write-JsonFile $PathValue $policy
}

function New-Run(
  [string]$RunId,
  [string]$Status,
  [string]$Group,
  [string]$ReviewGate,
  [string]$Disposition,
  [DateTimeOffset]$EndedAt,
  [bool]$Structured = $true,
  [string]$ProductRepoId = 'product'
) {
  $run = [ordered]@{
    run_id = $RunId
    role_id = 'WORKER'
    assignment_id = "assign-$RunId"
    scope_id = 'scope'
    run_epoch = 1
    control_repo_id = 'control'
    product_repo_id = $ProductRepoId
    product_baseline_commit = ('a' * 40)
    product_branch = 'main'
    product_worktree = 'D:/fixture'
    transport_mode = 'control-spool'
    session_id = "session-$RunId"
    process_id = 10
    command = 'fixture'
    cwd = 'D:/fixture'
    started_at = $EndedAt.AddHours(-1).ToString('o')
    ended_at = $(if ($Status -in @('DONE', 'FAILED', 'EXIT_UNKNOWN', 'EXPIRED')) { $EndedAt.ToString('o') } else { '' })
    exit_code = $(if ($Status -eq 'DONE') { 0 } else { 1 })
    status = $Status
  }
  if ($Structured) {
    $run.run_root = ".yefeng/runs/scope/WORKER/$RunId"
    $run.retention_group_id = $Group
    $run.parent_run_id = $null
    $run.review_gate = $ReviewGate
    $run.control_disposition = $Disposition
  }
  return [pscustomobject]$run
}

function Write-LargeLog([string]$PathValue) {
  $parent = Split-Path -Parent $PathValue
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  $stream = [System.IO.File]::Open($PathValue, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  try { $stream.SetLength(1048577) } finally { $stream.Dispose() }
}

function New-ControlFixture([string]$Name, [object[]]$Runs, [string[]]$RoleReferences = @()) {
  $root = Join-Path $testRoot $Name
  Initialize-GitRoot $root
  Write-Utf8 (Join-Path $root '.gitignore') ".yefeng/runs/`n"
  $stateRoot = Join-Path $root '.yefeng\series\scope\state'
  Write-JsonFile (Join-Path $stateRoot 'runs.json') ([ordered]@{
    version = 2; scope_id = 'scope'; run_epoch = 1; control_repo_id = 'control'; runs = $Runs
  })
  $roles = @()
  foreach ($runId in $RoleReferences) { $roles += [pscustomobject]@{ role_id = 'REF'; run_id = $runId; blocked_by = '' } }
  Write-JsonFile (Join-Path $stateRoot 'roles.json') ([ordered]@{
    version = 2; scope_id = 'scope'; run_epoch = 1; control_repo_id = 'control'; roles = $roles
  })
  Write-JsonFile (Join-Path $stateRoot 'control.json') ([ordered]@{
    version = 2; scope_id = 'scope'; run_epoch = 1; control_repo_id = 'control'
    lifecycle_state = 'ACTIVE'; recovery_state = 'NONE'; blocker_state = 'CLEAR'; current_run_id = $null
  })
  Write-JsonFile (Join-Path $stateRoot 'transport.json') ([ordered]@{
    version = 2; scope_id = 'scope'; run_epoch = 1; control_repo_id = 'control'
    referenced_run_ids = @(); imported_messages = @()
  })
  Write-Utf8 (Join-Path $root '.yefeng\series\scope\events.jsonl') ''
  foreach ($run in $Runs) {
    if (-not $run.PSObject.Properties['run_root']) { continue }
    $runRoot = Join-Path $root ([string]$run.run_root)
    Write-LargeLog (Join-Path $runRoot 'stdout.jsonl')
    Write-Utf8 (Join-Path $runRoot 'prompt.txt') "prompt-$($run.run_id)"
  }
  $null = Invoke-Git $root @('add', '--all')
  $null = Invoke-Git $root @('commit', '-m', 'fixture baseline')
  return $root
}

function Invoke-DryRun([string]$Root, [string]$Policy, [string[]]$References = @()) {
  $raw = & $compactorPath -ControlRoot $Root -ScopeId scope -PolicyPath $Policy -ReferencedRunId $References
  return [pscustomobject]@{ raw = [string]$raw; receipt = ($raw | ConvertFrom-Json) }
}

function Save-Plan([string]$Name, [object]$DryResult) {
  $path = Join-Path $testRoot "plans\$Name.json"
  Write-Utf8 $path $DryResult.raw
  return $path
}

function New-ForgedCandidate([string]$Root, [object]$Run) {
  $path = Join-Path $Root ([string]$Run.run_root)
  $path = Join-Path $path 'stdout.jsonl'
  $item = Get-Item -LiteralPath $path -Force
  $policy = Get-Content -LiteralPath $defaultPolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $endedAtProperty = $Run.PSObject.Properties['ended_at']
  $forgedEndedAt = if ($endedAtProperty) { [string]$endedAtProperty.Value } else { '' }
  return [ordered]@{
    run_id = [string]$Run.run_id
    role_id = [string]$Run.role_id
    scope_id = [string]$Run.scope_id
    product_repo_id = [string]$Run.product_repo_id
    run_epoch = [int64]$Run.run_epoch
    retention_group_id = [string]$Run.retention_group_id
    run_root = [string]$Run.run_root
    status = [string]$Run.status
    review_gate = [string]$Run.review_gate
    control_disposition = [string]$Run.control_disposition
    ended_at = $forgedEndedAt
    eligibility_basis = [ordered]@{
      last_failure = $false
      final_pass = $false
      terminal_age_hours = [int64]$policy.terminal_age_hours
      superseded_retention_days = [int64]$policy.superseded_retention_days
      long_log_threshold_bytes = [int64]$policy.long_log_threshold_bytes
      selected_by_long_log = [bool]([int64]$item.Length -ge [int64]$policy.long_log_threshold_bytes)
      selected_by_scope_cap = $false
      selected_by_overall_cap = $false
    }
    relative_path = (([string]$Run.run_root).TrimEnd('/') + '/stdout.jsonl')
    leaf_name = 'stdout.jsonl'
    size = [int64]$item.Length
    last_write_utc = $item.LastWriteTimeUtc.ToString('o')
    sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}

function New-ForgedDryPlan([object]$DryResult, [string]$Root, [object]$ProtectedRun) {
  $receipt = ConvertFrom-TestJson $DryResult.raw
  $candidate = New-ForgedCandidate $Root $ProtectedRun
  $receipt.plan.candidates = @($candidate)
  $receipt.plan.summary.candidate_count = 1
  $receipt.plan.summary.candidate_bytes = [int64]$candidate.size
  $receipt.plan.candidate_summary.count = 1
  $receipt.plan.candidate_summary.bytes = [int64]$candidate.size
  $receipt.plan.candidate_summary.sha256 = Get-Sha256Text (ConvertTo-CompactJson @($candidate))
  $receipt.plan_digest = Get-Sha256Text (ConvertTo-CompactJson $receipt.plan)
  return [pscustomobject]@{
    raw = ConvertTo-CompactJson $receipt
    receipt = $receipt
  }
}

function New-PreparedEvent([object]$PlanReceipt, [string]$Suffix, [hashtable]$Overrides = @{}) {
  $plan = $PlanReceipt.plan
  $event = [ordered]@{
    event_id = "retention-prepared-$Suffix"
    type = 'RUN_EVIDENCE_RETENTION_PREPARED'
    operation_id = "retention-operation-$Suffix"
    created_at = [DateTimeOffset]::UtcNow.ToString('o')
    scope_id = [string]$plan.scope_id
    run_epoch = [int64]$plan.run_epoch
    control_repo_id = [string]$plan.control_repo_id
    product_repo_id = [string]$plan.product_repo_id
    prepared_parent_control_head = [string]$plan.base_control_head
    plan_digest = [string]$PlanReceipt.plan_digest
    policy_sha256 = [string]$plan.policy_sha256
    state_hashes = $plan.state_hashes
    apply_token_sha256 = [string]$plan.apply_token_sha256
    candidate_summary = $plan.candidate_summary
    reference_set_sha256 = [string]$plan.reference_set_sha256
  }
  foreach ($entry in $Overrides.GetEnumerator()) { $event[$entry.Key] = $entry.Value }
  return [pscustomobject]$event
}

function Commit-Prepared([string]$Root, [object[]]$Events, [scriptblock]$BeforeCommit = $null) {
  if ($BeforeCommit) { & $BeforeCommit $Root }
  $eventsPath = Join-Path $Root '.yefeng\series\scope\events.jsonl'
  $lines = @()
  foreach ($event in $Events) { $lines += ($event | ConvertTo-Json -Depth 30 -Compress) }
  [System.IO.File]::AppendAllText($eventsPath, (($lines -join "`n") + "`n"), $utf8NoBom)
  $null = Invoke-Git $Root @('add', '--all')
  $null = Invoke-Git $Root @('commit', '-m', 'prepare retention apply')
}

function Invoke-Apply([string]$Root, [string]$Policy, [string]$PlanPath, [object]$Receipt) {
  return & $compactorPath -ControlRoot $Root -ScopeId scope -Mode Apply -PolicyPath $Policy `
    -PlanPath $PlanPath -ApplyToken ([string]$Receipt.apply_token) `
    -ExpectedPlanDigest ([string]$Receipt.plan_digest)
}

function Assert-ApplyRejected(
  [string]$Root,
  [string]$Policy,
  [string]$PlanPath,
  [object]$Receipt,
  [string]$Pattern,
  [string]$Message
) {
  $rejected = $false
  try { Invoke-Apply $Root $Policy $PlanPath $Receipt | Out-Null }
  catch { $rejected = $_.Exception.Message -match $Pattern }
  Assert-True $rejected $Message
}

function New-ApplyFixture([string]$Name, [string]$PolicyPath) {
  $old = [DateTimeOffset]::UtcNow.AddDays(-10)
  $runs = @(
    (New-Run 'candidate' 'DONE' 'group' 'NOT_REQUIRED' 'DISCARDABLE' $old $true),
    (New-Run 'final' 'DONE' 'group' 'PASSED' 'ACCEPTED' $old.AddDays(1) $true)
  )
  $root = New-ControlFixture $Name $runs
  $dry = Invoke-DryRun $root $PolicyPath
  $planPath = Save-Plan $Name $dry
  return [pscustomobject]@{ root = $root; dry = $dry; plan_path = $planPath }
}

function Invoke-Validator([string]$Root, [string]$ScriptPath = $validatorPath) {
  $output = @(& $enginePath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -ControlRoot $Root 2>$null)
  $json = ($output -join [Environment]::NewLine).Trim()
  return $json | ConvertFrom-Json
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
  $policyPath = Join-Path $testRoot 'policy.json'
  New-TestPolicy $policyPath
  $old = [DateTimeOffset]::UtcNow.AddDays(-10)

  # RED regression fixtures: the previous Apply trusted a forged, fully
  # self-consistent plan/PREPARED pair and would delete these protected logs.
  $forgeryCases = @(
    [pscustomobject]@{
      name = 'forged-active'
      run = (New-Run 'protected-active' 'RUNNING' 'active-group' 'PENDING' 'ACTIVE' $old $true)
      references = @()
    },
    [pscustomobject]@{
      name = 'forged-referenced'
      run = (New-Run 'protected-reference' 'DONE' 'reference-group' 'NOT_REQUIRED' 'DISCARDABLE' $old $true)
      references = @('protected-reference')
    },
    [pscustomobject]@{
      name = 'forged-final-pass'
      run = (New-Run 'protected-final' 'DONE' 'final-group' 'PASSED' 'SUPERSEDED' $old $true)
      references = @()
    }
  )
  foreach ($case in $forgeryCases) {
    $forgedRoot = New-ControlFixture $case.name @($case.run) @($case.references)
    $honestDry = Invoke-DryRun $forgedRoot $policyPath
    Assert-True (@($honestDry.receipt.plan.candidates).Count -eq 0) "$($case.name) honest plan must protect the run"
    $forgedDry = New-ForgedDryPlan $honestDry $forgedRoot $case.run
    $forgedPlanPath = Save-Plan $case.name $forgedDry
    Commit-Prepared $forgedRoot @((New-PreparedEvent $forgedDry.receipt $case.name))
    Assert-ApplyRejected $forgedRoot $policyPath $forgedPlanPath $forgedDry.receipt 'deterministic eligible|safe prefix' "$($case.name) forged semantic authorization must reject"
    Assert-True (Test-Path -LiteralPath (Join-Path $forgedRoot "$($case.run.run_root)\stdout.jsonl")) "$($case.name) rejection must occur before deletion"
  }

  # Every governed state reference shape must protect a run before planning,
  # not merely invalidate Apply later through a state-hash mismatch.
  $stateReferenceCases = @(
    [pscustomobject]@{ name = 'control-current-run'; file = 'control.json'; property = 'current_run_id' },
    [pscustomobject]@{ name = 'transport-referenced-runs'; file = 'transport.json'; property = 'referenced_run_ids' }
  )
  foreach ($case in $stateReferenceCases) {
    $referenceRun = New-Run "$($case.name)-candidate" 'DONE' "$($case.name)-group" 'NOT_REQUIRED' 'DISCARDABLE' $old $true
    $referenceFinal = New-Run "$($case.name)-final" 'DONE' "$($case.name)-group" 'PASSED' 'ACCEPTED' $old.AddDays(1) $true
    $referenceRoot = New-ControlFixture $case.name @($referenceRun, $referenceFinal)
    $statePath = Join-Path $referenceRoot ".yefeng\series\scope\state\$($case.file)"
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($case.property -eq 'referenced_run_ids') { $state.($case.property) = @($referenceRun.run_id) }
    else { $state.($case.property) = [string]$referenceRun.run_id }
    Write-JsonFile $statePath $state
    $null = Invoke-Git $referenceRoot @('add', '--all')
    $null = Invoke-Git $referenceRoot @('commit', '-m', "fixture reference $($case.name)")
    $referenceDry = Invoke-DryRun $referenceRoot $policyPath
    Assert-True (
      @($referenceDry.receipt.plan.candidates | Where-Object { $_.run_id -eq $referenceRun.run_id }).Count -eq 0
    ) "$($case.name) must protect its run before planning"
    Assert-True (
      @($referenceDry.receipt.plan.summary.protected_examples | Where-Object { $_.run_id -eq $referenceRun.run_id -and $_.reasons -contains 'referenced' }).Count -eq 1
    ) "$($case.name) protection must be receipted"
  }

  # A single PREPARED plan may cover only one exact product repository.
  $multiProductRuns = @(
    (New-Run 'product-a-candidate' 'DONE' 'product-a-delete' 'NOT_REQUIRED' 'DISCARDABLE' $old $true 'product-a'),
    (New-Run 'product-a-final' 'DONE' 'product-a-delete' 'PASSED' 'ACCEPTED' $old.AddDays(1) $true 'product-a'),
    (New-Run 'product-b-candidate' 'DONE' 'product-b-delete' 'NOT_REQUIRED' 'DISCARDABLE' $old $true 'product-b'),
    (New-Run 'product-b-final' 'DONE' 'product-b-delete' 'PASSED' 'ACCEPTED' $old.AddDays(1) $true 'product-b')
  )
  $multiProductRoot = New-ControlFixture 'multi-product' $multiProductRuns
  $multiProductDry = Invoke-DryRun $multiProductRoot $policyPath
  $plannedProductIds = @($multiProductDry.receipt.plan.candidates | ForEach-Object { $_.product_repo_id } | Sort-Object -Unique)
  Assert-True ($plannedProductIds.Count -eq 1) 'one retention plan must bind candidates from exactly one product repository'
  Assert-True ([string]$multiProductDry.receipt.plan.product_repo_id -ceq [string]$plannedProductIds[0]) 'plan product identity must equal every candidate product identity'
  Assert-True ([int]$multiProductDry.receipt.plan.summary.deferred_candidate_count -ge 1) 'other-product candidates must remain deferred for a later plan'

  # RED regression fixtures: terminal retention age must never fall back to
  # started_at when ended_at is blank, invalid, or absent. The pre-fix planner
  # selected each stale run and Apply accepted the matching forged authorization.
  $endedAtCases = @(
    [pscustomobject]@{ name = 'blank-ended-at'; mutate = {
      param($run)
      $run.ended_at = ''
    }},
    [pscustomobject]@{ name = 'invalid-ended-at'; mutate = {
      param($run)
      $run.ended_at = 'not-a-date'
    }},
    [pscustomobject]@{ name = 'missing-ended-at'; mutate = {
      param($run)
      $run.PSObject.Properties.Remove('ended_at')
    }},
    [pscustomobject]@{ name = 'noncanonical-ended-at'; mutate = {
      param($run)
      $parsed = [DateTimeOffset]::Parse([string]$run.started_at)
      $run.ended_at = $parsed.AddHours(1).ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture)
    }}
  )
  foreach ($case in $endedAtCases) {
    $dryCandidate = New-Run "$($case.name)-candidate" 'DONE' "$($case.name)-group" 'NOT_REQUIRED' 'DISCARDABLE' $old $true
    & $case.mutate $dryCandidate
    $dryFinal = New-Run "$($case.name)-final" 'DONE' "$($case.name)-group" 'PASSED' 'ACCEPTED' $old.AddDays(1) $true
    $endedAtDryRoot = New-ControlFixture "$($case.name)-dry" @($dryCandidate, $dryFinal)
    $endedAtDry = Invoke-DryRun $endedAtDryRoot $policyPath
    $dryProtected = @($endedAtDry.receipt.plan.candidates | Where-Object { $_.run_id -eq $dryCandidate.run_id }).Count -eq 0
    $dryProtectionReceipted = @(
      $endedAtDry.receipt.plan.summary.protected_examples |
        Where-Object { $_.run_id -eq $dryCandidate.run_id -and $_.reasons -contains 'invalid-terminal-ended-at' }
    ).Count -eq 1

    $applyCandidate = New-Run "$($case.name)-apply-candidate" 'DONE' "$($case.name)-apply-group" 'NOT_REQUIRED' 'DISCARDABLE' $old $true
    & $case.mutate $applyCandidate
    $applyFinal = New-Run "$($case.name)-apply-final" 'DONE' "$($case.name)-apply-group" 'PASSED' 'ACCEPTED' $old.AddDays(1) $true
    $endedAtApplyRoot = New-ControlFixture "$($case.name)-apply" @($applyCandidate, $applyFinal)
    $endedAtHonest = Invoke-DryRun $endedAtApplyRoot $policyPath
    $endedAtForged = New-ForgedDryPlan $endedAtHonest $endedAtApplyRoot $applyCandidate
    $endedAtPlanPath = Save-Plan "$($case.name)-apply" $endedAtForged
    Commit-Prepared $endedAtApplyRoot @((New-PreparedEvent $endedAtForged.receipt "$($case.name)-apply"))
    $applyRejected = $false
    try { Invoke-Apply $endedAtApplyRoot $policyPath $endedAtPlanPath $endedAtForged.receipt | Out-Null }
    catch { $applyRejected = $_.Exception.Message -match 'terminal-ended-at|deterministic eligible|safe prefix' }
    $applyLeaf = Join-Path $endedAtApplyRoot "$($applyCandidate.run_root)\stdout.jsonl"

    Assert-True ($dryProtected -and $dryProtectionReceipted) "$($case.name) DryRun must protect and receipt the whole terminal run"
    Assert-True ($applyRejected -and (Test-Path -LiteralPath $applyLeaf)) "$($case.name) Apply must reject before first deletion"
  }

  # Semantic protection and exact-leaf Apply with a real committed PREPARED record.
  $runs = @(
    (New-Run 'active' 'RUNNING' 'active-group' 'PENDING' 'ACTIVE' $old $true),
    (New-Run 'legacy' 'DONE' 'legacy-group' 'PASSED' 'SUPERSEDED' $old $false),
    (New-Run 'fail-old' 'FAILED' 'failure-group' 'FAILED' 'SUPERSEDED' $old.AddDays(-2) $true),
    (New-Run 'fail-last' 'FAILED' 'failure-group' 'FAILED' 'SUPERSEDED' $old $true),
    (New-Run 'pass-old' 'DONE' 'pass-group' 'PASSED' 'SUPERSEDED' $old.AddDays(-2) $true),
    (New-Run 'pass-final' 'DONE' 'pass-group' 'PASSED' 'SUPERSEDED' $old $true),
    (New-Run 'referenced' 'DONE' 'reference-group' 'NOT_REQUIRED' 'DISCARDABLE' $old $true),
    (New-Run 'reference-final' 'DONE' 'reference-group' 'PASSED' 'ACCEPTED' $old.AddDays(1) $true),
    (New-Run 'deletable' 'DONE' 'delete-group' 'NOT_REQUIRED' 'DISCARDABLE' $old $true),
    (New-Run 'delete-final' 'DONE' 'delete-group' 'PASSED' 'ACCEPTED' $old.AddDays(1) $true)
  )
  $mainRoot = New-ControlFixture 'main' $runs @('referenced')
  $mainDry = Invoke-DryRun $mainRoot $policyPath
  $mainPlan = Save-Plan 'main' $mainDry
  $candidateIds = @($mainDry.receipt.plan.candidates | ForEach-Object { $_.run_id })
  Assert-True ($candidateIds -contains 'deletable') 'discardable terminal run should be eligible'
  Assert-True ($candidateIds -notcontains 'active') 'active run must be protected'
  Assert-True ($candidateIds -notcontains 'legacy') 'legacy run must be protected'
  Assert-True ($candidateIds -notcontains 'fail-last') 'last failure must be protected'
  Assert-True ($candidateIds -notcontains 'pass-final') 'final pass must be protected'
  Assert-True ($candidateIds -notcontains 'referenced') 'referenced run must be protected'
  $deletableCandidate = @($mainDry.receipt.plan.candidates | Where-Object { $_.run_id -eq 'deletable' })[0]
  Assert-True (
    $deletableCandidate.eligibility_basis.last_failure -eq $false -and
    $deletableCandidate.eligibility_basis.final_pass -eq $false -and
    [int64]$deletableCandidate.eligibility_basis.terminal_age_hours -gt 0 -and
    (
      $deletableCandidate.eligibility_basis.selected_by_long_log -or
      $deletableCandidate.eligibility_basis.selected_by_scope_cap -or
      $deletableCandidate.eligibility_basis.selected_by_overall_cap
    )
  ) 'candidate receipt must bind group, age, and threshold-or-cap eligibility'
  $targetLog = Join-Path $mainRoot '.yefeng\runs\scope\WORKER\deletable\stdout.jsonl'
  $targetHash = (Get-FileHash -LiteralPath $targetLog -Algorithm SHA256).Hash
  Assert-True ((Get-FileHash -LiteralPath $targetLog -Algorithm SHA256).Hash -eq $targetHash) 'dry-run must not mutate logs'
  Commit-Prepared $mainRoot @((New-PreparedEvent $mainDry.receipt 'main'))
  $applyReceipt = (Invoke-Apply $mainRoot $policyPath $mainPlan $mainDry.receipt) | ConvertFrom-Json
  Assert-True ($applyReceipt.applied -and $applyReceipt.prepared_control_head -eq (Invoke-Git $mainRoot @('rev-parse', 'HEAD'))) 'Apply must bind the committed PREPARED HEAD'
  Assert-True (-not (Test-Path -LiteralPath $targetLog)) 'planned exact stdout leaf should be deleted'
  Assert-True (Test-Path -LiteralPath (Join-Path $mainRoot '.yefeng\runs\scope\WORKER\deletable\prompt.txt')) 'prompt must be retained'

  # Missing, mismatched, and duplicate committed PREPARED gates.
  $missing = New-ApplyFixture 'prepared-missing' $policyPath
  Assert-ApplyRejected $missing.root $policyPath $missing.plan_path $missing.dry.receipt 'PREPARED|single-parent|direct child' 'missing PREPARED must reject'
  $mismatch = New-ApplyFixture 'prepared-mismatch' $policyPath
  Commit-Prepared $mismatch.root @((New-PreparedEvent $mismatch.dry.receipt 'mismatch' @{ apply_token_sha256 = ('f' * 64) }))
  Assert-ApplyRejected $mismatch.root $policyPath $mismatch.plan_path $mismatch.dry.receipt 'binding mismatch' 'mismatched PREPARED must reject'
  $duplicate = New-ApplyFixture 'prepared-duplicate' $policyPath
  Commit-Prepared $duplicate.root @(
    (New-PreparedEvent $duplicate.dry.receipt 'duplicate-a'),
    (New-PreparedEvent $duplicate.dry.receipt 'duplicate-b')
  )
  Assert-ApplyRejected $duplicate.root $policyPath $duplicate.plan_path $duplicate.dry.receipt 'exactly one' 'duplicate PREPARED must reject'

  # Every committed state surface is bound; review, blocker, recovery, and reference drift reject.
  $driftCases = @(
    [pscustomobject]@{ name = 'review-drift'; file = 'runs.json'; mutate = {
      param($state)
      $state.runs[0].review_gate = 'PENDING'
    }},
    [pscustomobject]@{ name = 'roles-blocker-drift'; file = 'roles.json'; mutate = {
      param($state)
      $state.roles = @([pscustomobject]@{ role_id = 'BLOCKED'; run_id = 'candidate'; blocked_by = 'review' })
    }},
    [pscustomobject]@{ name = 'control-recovery-drift'; file = 'control.json'; mutate = {
      param($state)
      $state.recovery_state = 'RECONCILIATION'
    }},
    [pscustomobject]@{ name = 'transport-reference-drift'; file = 'transport.json'; mutate = {
      param($state)
      $state.referenced_run_ids = @('candidate')
    }}
  )
  foreach ($case in $driftCases) {
    $fixture = New-ApplyFixture $case.name $policyPath
    $beforeCommit = {
      param($root)
      $path = Join-Path $root ".yefeng\series\scope\state\$($case.file)"
      $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
      & $case.mutate $state
      Write-JsonFile $path $state
    }
    Commit-Prepared $fixture.root @((New-PreparedEvent $fixture.dry.receipt $case.name)) $beforeCommit
    Assert-ApplyRejected $fixture.root $policyPath $fixture.plan_path $fixture.dry.receipt 'state drifted' "$($case.name) must reject"
  }

  # Caller clock rollback is impossible because no production clock parameter exists.
  $clockFixture = New-ApplyFixture 'clock' $policyPath
  $clockRejected = $false
  try {
    & $compactorPath -ControlRoot $clockFixture.root -ScopeId scope -Mode Apply -PolicyPath $policyPath `
      -PlanPath $clockFixture.plan_path -ApplyToken $clockFixture.dry.receipt.apply_token `
      -ExpectedPlanDigest $clockFixture.dry.receipt.plan_digest -Now ([DateTimeOffset]::MinValue) | Out-Null
  } catch { $clockRejected = $_.Exception.Message -match 'parameter.*Now|cannot be found' }
  Assert-True $clockRejected 'caller-supplied rollback clock must be unreachable'

  # Policy downgrade and malformed structured state fail closed.
  $downgradePolicyPath = Join-Path $testRoot 'downgrade-policy.json'
  $downgradePolicy = Get-Content -LiteralPath $defaultPolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $downgradePolicy.terminal_age_hours = 1
  Write-JsonFile $downgradePolicyPath $downgradePolicy
  $policyRejected = $false
  try { Invoke-DryRun $clockFixture.root $downgradePolicyPath | Out-Null }
  catch { $policyRejected = $_.Exception.Message -match '24 hours' }
  Assert-True $policyRejected 'policy downgrade must reject'

  $blankRunId = New-Run '' 'DONE' 'blank-run-group' 'NOT_REQUIRED' 'DISCARDABLE' $old $true
  $blankRoleId = New-Run 'blank-role' 'DONE' 'blank-role-group' 'NOT_REQUIRED' 'DISCARDABLE' $old $true
  $blankRoleId.role_id = ''
  $blankRoleId.run_root = '.yefeng/runs/scope//blank-role'
  $duplicateRunA = New-Run 'duplicate-run' 'DONE' 'duplicate-a' 'NOT_REQUIRED' 'DISCARDABLE' $old $true
  $duplicateRunB = New-Run 'duplicate-run' 'DONE' 'duplicate-b' 'NOT_REQUIRED' 'DISCARDABLE' $old $true
  $invalidRuns = @(
    (New-Run 'unknown-review' 'DONE' 'invalid-a' 'MAYBE' 'DISCARDABLE' $old $true),
    (New-Run 'empty-disposition' 'DONE' 'invalid-b' 'NOT_REQUIRED' '' $old $true),
    (New-Run 'unknown-status' 'MYSTERY' 'invalid-c' 'NOT_REQUIRED' 'DISCARDABLE' $old $true),
    (New-Run 'invalid-group' 'DONE' '' 'NOT_REQUIRED' 'DISCARDABLE' $old $true),
    $blankRunId,
    $blankRoleId,
    $duplicateRunA,
    $duplicateRunB
  )
  $invalidRoot = New-ControlFixture 'invalid-enums' $invalidRuns
  $invalidDry = Invoke-DryRun $invalidRoot $policyPath
  Assert-True (@($invalidDry.receipt.plan.candidates).Count -eq 0) 'unknown/empty enum and ID bindings must produce no candidates'
  $invalidReasons = @($invalidDry.receipt.plan.summary.protected_examples | ForEach-Object { @($_.reasons) })
  Assert-True ($invalidReasons -contains 'unknown-review-gate') 'unknown review gate must be explicitly protected'
  Assert-True ($invalidReasons -contains 'unknown-control-disposition') 'empty disposition must be explicitly protected'
  Assert-True ($invalidReasons -contains 'active-or-unknown-status') 'unknown status must be explicitly protected'
  Assert-True ($invalidReasons -contains 'invalid-identity-binding') 'empty retention group must be explicitly protected'
  Assert-True (@($invalidDry.receipt.plan.candidates | Where-Object { $_.relative_path -eq '.yefeng/runs/scope/WORKER/stdout.jsonl' }).Count -eq 0) 'blank run_id must never collapse to a role-root log candidate'
  Assert-True (@($invalidDry.receipt.plan.summary.protected_examples | Where-Object { $_.run_id -eq 'blank-role' -and $_.reasons -contains 'invalid-identity-binding' }).Count -eq 1) 'blank role_id must be excluded before structured candidate processing'
  Assert-True (@($invalidDry.receipt.plan.summary.protected_examples | Where-Object { $_.run_id -eq 'duplicate-run' -and $_.reasons -contains 'invalid-identity-binding' }).Count -eq 1) 'duplicate run_id must be excluded before structured candidate processing'

  # A reparse point anywhere in a run protects the whole run, including an ordinary log seen first.
  $mixedRuns = @(
    (New-Run 'mixed' 'DONE' 'mixed-group' 'NOT_REQUIRED' 'DISCARDABLE' $old $true),
    (New-Run 'mixed-final' 'DONE' 'mixed-group' 'PASSED' 'ACCEPTED' $old.AddDays(1) $true)
  )
  $mixedRoot = New-ControlFixture 'mixed-reparse' $mixedRuns
  $externalTarget = Join-Path $testRoot 'junction-target'
  New-Item -ItemType Directory -Path $externalTarget -Force | Out-Null
  Write-Utf8 (Join-Path $externalTarget 'outside.txt') 'outside'
  New-Item -ItemType Junction -Path (Join-Path $mixedRoot '.yefeng\runs\scope\WORKER\mixed\nested-link') -Target $externalTarget | Out-Null
  $mixedDry = Invoke-DryRun $mixedRoot $policyPath
  Assert-True (@($mixedDry.receipt.plan.candidates | Where-Object { $_.run_id -eq 'mixed' }).Count -eq 0) 'mixed ordinary/reparse run must be wholly protected'
  Assert-True (@($mixedDry.receipt.plan.summary.protected_examples | Where-Object { $_.run_id -eq 'mixed' -and $_.reasons -contains 'reparse' }).Count -eq 1) 'mixed reparse protection must be receipted'

  $lateReparse = New-ApplyFixture 'late-reparse' $policyPath
  Commit-Prepared $lateReparse.root @((New-PreparedEvent $lateReparse.dry.receipt 'late-reparse'))
  $lateTarget = Join-Path $testRoot 'late-junction-target'
  New-Item -ItemType Directory -Path $lateTarget -Force | Out-Null
  Write-Utf8 (Join-Path $lateTarget 'outside.txt') 'outside'
  New-Item -ItemType Junction -Path (Join-Path $lateReparse.root '.yefeng\runs\scope\WORKER\candidate\late-link') -Target $lateTarget | Out-Null
  Assert-ApplyRejected $lateReparse.root $policyPath $lateReparse.plan_path $lateReparse.dry.receipt 'run audit failed|reparse|deterministic eligible|safe prefix' 'reparse introduced after planning must reject Apply'
  Assert-True (Test-Path -LiteralPath (Join-Path $lateReparse.root '.yefeng\runs\scope\WORKER\candidate\stdout.jsonl')) 'late reparse rejection must happen before deletion'

  # Drift still rejects before deletion.
  $fileDrift = New-ApplyFixture 'file-drift' $policyPath
  Commit-Prepared $fileDrift.root @((New-PreparedEvent $fileDrift.dry.receipt 'file-drift'))
  $fileDriftLeaf = Join-Path $fileDrift.root '.yefeng\runs\scope\WORKER\candidate\stdout.jsonl'
  [System.IO.File]::AppendAllText($fileDriftLeaf, 'drift', $utf8NoBom)
  Assert-ApplyRejected $fileDrift.root $policyPath $fileDrift.plan_path $fileDrift.dry.receipt 'drifted|deterministic eligible|safe prefix' 'file drift must reject'
  Assert-True (Test-Path -LiteralPath $fileDriftLeaf) 'file drift rejection must happen before deletion'

  # Receipt bounding with a stricter cap.
  $boundedPolicyPath = Join-Path $testRoot 'bounded-policy.json'
  New-TestPolicy $boundedPolicyPath 4096
  $manyRuns = [System.Collections.Generic.List[object]]::new()
  for ($index = 0; $index -lt 12; $index++) {
    $manyRuns.Add((New-Run ("candidate-{0:D2}" -f $index) 'DONE' ("group-{0:D2}" -f $index) 'NOT_REQUIRED' 'DISCARDABLE' $old $true))
    $manyRuns.Add((New-Run ("final-{0:D2}" -f $index) 'DONE' ("group-{0:D2}" -f $index) 'PASSED' 'ACCEPTED' $old.AddDays(1) $true))
  }
  $boundedRoot = New-ControlFixture 'bounded' @($manyRuns)
  $boundedRaw = & $compactorPath -ControlRoot $boundedRoot -ScopeId scope -PolicyPath $boundedPolicyPath
  $bounded = $boundedRaw | ConvertFrom-Json
  $boundedBytes = $utf8NoBom.GetByteCount([string]$boundedRaw)
  Assert-True ($boundedBytes -le 4096) 'dry-run receipt must respect a stricter receipt cap'
  Assert-True ([int]$bounded.plan.summary.deferred_candidate_count -gt 0) 'bounded receipt must defer overflow candidates'

  # RED integration fixture: retention-only must not replace or migrate an
  # existing global control validator, even when the destination has legacy
  # state and no message stack.
  $legacyShapeRoot = Join-Path $testRoot 'legacy-shape-destination'
  Initialize-GitRoot $legacyShapeRoot
  $legacyGlobalValidator = Join-Path $legacyShapeRoot 'scripts\yefeng\validate-external-control-repo.ps1'
  Write-Utf8 $legacyGlobalValidator @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ControlRoot)
[pscustomobject]@{ valid = $true; validator_semantics = 'legacy-preserved'; control_root = $ControlRoot } | ConvertTo-Json
'@
  $legacyRolesPath = Join-Path $legacyShapeRoot '.yefeng\series\legacy\state\roles.json'
  $legacyRunsPath = Join-Path $legacyShapeRoot '.yefeng\series\legacy\state\runs.json'
  Write-JsonFile $legacyRolesPath ([ordered]@{
    version = 1
    roles = @([ordered]@{ role_id = 'OLD'; state = 'DONE' })
  })
  Write-JsonFile $legacyRunsPath ([ordered]@{
    version = 1
    runs = @([ordered]@{ run_id = 'old-run'; role_id = 'OLD'; status = 'DONE' })
  })
  $null = Invoke-Git $legacyShapeRoot @('add', '--all')
  $null = Invoke-Git $legacyShapeRoot @('commit', '-m', 'legacy control shape')
  $legacyValidatorHash = (Get-FileHash -LiteralPath $legacyGlobalValidator -Algorithm SHA256).Hash
  $legacyRolesHash = (Get-FileHash -LiteralPath $legacyRolesPath -Algorithm SHA256).Hash
  $legacyRunsHash = (Get-FileHash -LiteralPath $legacyRunsPath -Algorithm SHA256).Hash
  & $installerPath -DestinationControlRoot $legacyShapeRoot -InstallRetentionOnly | Out-Null
  Assert-True (
    (Get-FileHash -LiteralPath $legacyGlobalValidator -Algorithm SHA256).Hash -eq $legacyValidatorHash
  ) 'retention-only install must preserve arbitrary existing global validator bytes'
  Assert-True (
    (Get-FileHash -LiteralPath $legacyRolesPath -Algorithm SHA256).Hash -eq $legacyRolesHash -and
    (Get-FileHash -LiteralPath $legacyRunsPath -Algorithm SHA256).Hash -eq $legacyRunsHash
  ) 'retention-only install must preserve legacy roles and runs bytes without schema migration'
  $legacyRetentionValidator = Join-Path $legacyShapeRoot 'scripts\yefeng\validate-run-evidence-retention.ps1'
  $legacyRetentionValidation = Invoke-Validator $legacyShapeRoot $legacyRetentionValidator
  Assert-True (
    $legacyRetentionValidation.valid -and
    $legacyRetentionValidation.validator_scope -eq 'run-evidence-retention-only'
  ) 'dedicated retention validator must accept a legacy-shaped destination without message files'
  $legacyGlobalOutput = @(
    & $enginePath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $legacyGlobalValidator -ControlRoot $legacyShapeRoot
  )
  $legacyGlobalResult = (($legacyGlobalOutput -join [Environment]::NewLine).Trim() | ConvertFrom-Json)
  Assert-True (
    $legacyGlobalResult.valid -and
    $legacyGlobalResult.validator_semantics -eq 'legacy-preserved'
  ) 'existing global validator must remain executable with its original semantics'
  Assert-True (
    -not (Test-Path -LiteralPath (Join-Path $legacyShapeRoot 'scripts\yefeng\message-common.ps1')) -and
    -not (Test-Path -LiteralPath (Join-Path $legacyShapeRoot 'scripts\yefeng\publish-role-message.ps1')) -and
    -not (Test-Path -LiteralPath (Join-Path $legacyShapeRoot 'scripts\yefeng\message-broker.ps1')) -and
    -not (Test-Path -LiteralPath (Join-Path $legacyShapeRoot 'scripts\yefeng\receive-role-message.ps1'))
  ) 'retention-only install must not require or silently install the message stack'

  $carrierInvariantComment = '# RETENTION TRUST INVARIANT (keep this comment identical in both carriers):'
  Assert-True (
    (Get-ManifestCarrierSlotCount $installerPath) -eq 5 -and
    (Get-ManifestCarrierSlotCount $validatorPath) -eq 5 -and
    ([System.IO.File]::ReadAllText($installerPath, $utf8NoBom)).Contains($carrierInvariantComment) -and
    ([System.IO.File]::ReadAllText($validatorPath, $utf8NoBom)).Contains($carrierInvariantComment)
  ) 'installer and validator manifest carriers must each contain exactly five quoted SHA-256 slots'

  # A cleanup failure after a successful five-file transaction is diagnostic,
  # not an installation failure. The installed result must remain observable.
  $cleanupSuccessRoot = Join-Path $testRoot 'cleanup-success-destination'
  Initialize-GitRoot $cleanupSuccessRoot
  $null = Invoke-Git $cleanupSuccessRoot @('commit', '--allow-empty', '-m', 'cleanup success baseline')
  $cleanupSuccessWarnings = @()
  $cleanupSuccessRaw = & $installerPath -DestinationControlRoot $cleanupSuccessRoot -InstallRetentionOnly `
    -TestFailStagingCleanup -WarningVariable +cleanupSuccessWarnings -WarningAction SilentlyContinue
  $cleanupSuccessResult = $cleanupSuccessRaw | ConvertFrom-Json
  Assert-True (
    $cleanupSuccessResult.installed -and
    [string]$cleanupSuccessResult.staging_cleanup_warning -match 'Injected staging cleanup failure'
  ) 'staging cleanup failure must not rewrite a completed installation as failed'
  Assert-True (
    @(
      'compact-run-evidence.ps1',
      'run-retention-policy.json',
      'test-run-evidence-retention.ps1',
      'install-governed-runner.ps1',
      'validate-run-evidence-retention.ps1' |
        Where-Object { -not (Test-Path -LiteralPath (Join-Path $cleanupSuccessRoot "scripts\yefeng\$_") -PathType Leaf) }
    ).Count -eq 0
  ) 'cleanup failure after success must leave the completed five-file install intact'

  # RED integration fixture: a control repository containing only an old runner
  # directory must receive the complete five-file trust chain. The installed
  # test and validator must be runnable from that destination, and an installed
  # installer must safely refresh its own directory.
  if (-not $SkipInstalledChainIntegration) {
    $installedRoot = Join-Path $testRoot 'installed-chain-destination'
    Initialize-GitRoot $installedRoot
    $oldRunnerPath = Join-Path $installedRoot 'scripts\yefeng\role-runner.ps1'
    Write-Utf8 $oldRunnerPath 'old-runner'
    $null = Invoke-Git $installedRoot @('add', '--all')
    $null = Invoke-Git $installedRoot @('commit', '-m', 'old runner only')
    $oldRunnerHash = (Get-FileHash -LiteralPath $oldRunnerPath -Algorithm SHA256).Hash
    & $installerPath -DestinationControlRoot $installedRoot -InstallRetentionOnly | Out-Null
    $installedScripts = Join-Path $installedRoot 'scripts\yefeng'
    $trustChainNames = @(
      'compact-run-evidence.ps1',
      'run-retention-policy.json',
      'test-run-evidence-retention.ps1',
      'install-governed-runner.ps1',
      'validate-run-evidence-retention.ps1'
    )
    Assert-True (
      @($trustChainNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $installedScripts $_) -PathType Leaf) }).Count -eq 0
    ) 'retention-only install must place the complete five-file trust chain'
    Assert-True (
      (Get-FileHash -LiteralPath $oldRunnerPath -Algorithm SHA256).Hash -eq $oldRunnerHash
    ) 'retention-only install must preserve an existing runner byte-for-byte'
    Assert-True (
      @(
        'lib\runner-common.ps1',
        'run-backend-worker.ps1',
        'runner-policy.json',
        'test-runner-contract.ps1',
        'test-runner-governance.ps1',
        'test-runner-process-cleanup.ps1' |
          Where-Object { Test-Path -LiteralPath (Join-Path $installedScripts $_) }
      ).Count -eq 0
    ) 'retention-only install must not silently install the remaining runner stack'

    $installedInstaller = Join-Path $installedScripts 'install-governed-runner.ps1'
    & $installedInstaller -DestinationControlRoot $installedRoot -InstallRetentionOnly | Out-Null
    $destinationValidation = Invoke-Validator $installedRoot (Join-Path $installedScripts 'validate-run-evidence-retention.ps1')
    Assert-True (
      @($destinationValidation.issues | Where-Object { $_ -match 'Retention helper|retention helper' }).Count -eq 0
    ) 'validator installed at destination must accept the complete five-file manifest'

    $installedTest = Join-Path $installedScripts 'test-run-evidence-retention.ps1'
    $testEngines = @(
      (Get-Command pwsh -ErrorAction Stop).Source,
      (Get-Command powershell.exe -ErrorAction Stop).Source
    )
    foreach ($testEngine in $testEngines) {
      $installedOutput = @(& $testEngine -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installedTest -SkipInstalledChainIntegration)
      $installedExitCode = $LASTEXITCODE
      Assert-True ($installedExitCode -eq 0) "installed retention test must run from destination with $testEngine"
      $installedResult = (($installedOutput -join [Environment]::NewLine).Trim() | ConvertFrom-Json)
      Assert-True ([bool]$installedResult.passed) "installed retention test must pass from destination with $testEngine"
    }
    $script:installedChainExercised = $true
  }

  # Retention-only installer detects tamper before writes and rolls back a mid-replace failure.
  $tamperedSource = Join-Path $testRoot 'tampered-installer-source'
  New-Item -ItemType Directory -Path $tamperedSource -Force | Out-Null
  foreach ($name in @(
    'install-governed-runner.ps1',
    'validate-run-evidence-retention.ps1',
    'compact-run-evidence.ps1',
    'run-retention-policy.json',
    'test-run-evidence-retention.ps1'
  )) {
    [System.IO.File]::Copy((Join-Path $PSScriptRoot $name), (Join-Path $tamperedSource $name), $false)
  }
  [System.IO.File]::AppendAllText((Join-Path $tamperedSource 'run-retention-policy.json'), 'tamper', $utf8NoBom)
  $tamperDestination = Join-Path $testRoot 'installer-tamper-destination'
  Initialize-GitRoot $tamperDestination
  $null = Invoke-Git $tamperDestination @('commit', '--allow-empty', '-m', 'baseline')
  $installerTamperRejected = $false
  try { & (Join-Path $tamperedSource 'install-governed-runner.ps1') -DestinationControlRoot $tamperDestination -InstallRetentionOnly | Out-Null }
  catch { $installerTamperRejected = $_.Exception.Message -match 'hash mismatch' }
  Assert-True $installerTamperRejected 'installer must reject tampered source manifest'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $tamperDestination 'scripts\yefeng'))) 'tamper rejection must occur before destination writes'

  $carrierDriftSource = Join-Path $testRoot 'carrier-drift-source'
  New-Item -ItemType Directory -Path $carrierDriftSource -Force | Out-Null
  foreach ($name in @(
    'install-governed-runner.ps1',
    'validate-run-evidence-retention.ps1',
    'compact-run-evidence.ps1',
    'run-retention-policy.json',
    'test-run-evidence-retention.ps1'
  )) {
    [System.IO.File]::Copy((Join-Path $PSScriptRoot $name), (Join-Path $carrierDriftSource $name), $false)
  }
  $driftValidatorPath = Join-Path $carrierDriftSource 'validate-run-evidence-retention.ps1'
  $driftValidatorText = [System.IO.File]::ReadAllText($driftValidatorPath, $utf8NoBom)
  $driftValidatorText = $driftValidatorText.Replace(
    "'compact-run-evidence.ps1' = '$trustedCompactHash'",
    "'compact-run-evidence.ps1' = '$('f' * 64)'"
  )
  [System.IO.File]::WriteAllText($driftValidatorPath, $driftValidatorText, $utf8NoBom)
  $carrierDriftDestination = Join-Path $testRoot 'carrier-drift-destination'
  Initialize-GitRoot $carrierDriftDestination
  $null = Invoke-Git $carrierDriftDestination @('commit', '--allow-empty', '-m', 'carrier drift baseline')
  $carrierDriftRejected = $false
  try {
    & (Join-Path $carrierDriftSource 'install-governed-runner.ps1') `
      -DestinationControlRoot $carrierDriftDestination -InstallRetentionOnly | Out-Null
  } catch {
    $carrierDriftRejected = $_.Exception.Message -match 'manifest carrier values disagree'
  }
  Assert-True $carrierDriftRejected 'installer must reject disagreement between the two source carrier manifests'
  Assert-True (
    -not (Test-Path -LiteralPath (Join-Path $carrierDriftDestination 'scripts\yefeng'))
  ) 'source carrier disagreement must be rejected before destination writes'

  $sixSlotSource = Join-Path $testRoot 'six-slot-installer-source'
  New-Item -ItemType Directory -Path $sixSlotSource -Force | Out-Null
  foreach ($name in @(
    'install-governed-runner.ps1',
    'validate-run-evidence-retention.ps1',
    'compact-run-evidence.ps1',
    'run-retention-policy.json',
    'test-run-evidence-retention.ps1'
  )) {
    [System.IO.File]::Copy((Join-Path $PSScriptRoot $name), (Join-Path $sixSlotSource $name), $false)
  }
  $sixSlotInstallerPath = Join-Path $sixSlotSource 'install-governed-runner.ps1'
  $sixSlotText = [System.IO.File]::ReadAllText($sixSlotInstallerPath, $utf8NoBom)
  $sixSlotEnd = [regex]::Match($sixSlotText, '(?m)^# RETENTION_TRUST_MANIFEST_END\r?$')
  if (-not $sixSlotEnd.Success) { throw 'Test fixture could not find the exact retention manifest end marker.' }
  $sixSlotText = (
    $sixSlotText.Substring(0, $sixSlotEnd.Index) +
    ("# unexpected sixth hash slot '" + ('a' * 64) + "'`r`n") +
    $sixSlotText.Substring($sixSlotEnd.Index)
  )
  [System.IO.File]::WriteAllText($sixSlotInstallerPath, $sixSlotText, $utf8NoBom)
  $sixSlotDestination = Join-Path $testRoot 'six-slot-destination'
  Initialize-GitRoot $sixSlotDestination
  $null = Invoke-Git $sixSlotDestination @('commit', '--allow-empty', '-m', 'six slot baseline')
  $sixSlotRejected = $false
  try { & $sixSlotInstallerPath -DestinationControlRoot $sixSlotDestination -InstallRetentionOnly | Out-Null }
  catch { $sixSlotRejected = $_.Exception.Message -match 'exactly five fixed hash slots' }
  Assert-True $sixSlotRejected 'a sixth quoted SHA-256 slot inside either carrier manifest block must fail closed'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $sixSlotDestination 'scripts\yefeng'))) 'six-slot rejection must occur before destination writes'

  $atomicDestination = Join-Path $testRoot 'installer-atomic-destination'
  Initialize-GitRoot $atomicDestination
  $atomicScripts = Join-Path $atomicDestination 'scripts\yefeng'
  $originalHashes = @{}
  foreach ($name in @(
    'compact-run-evidence.ps1',
    'run-retention-policy.json',
    'test-run-evidence-retention.ps1',
    'install-governed-runner.ps1',
    'validate-run-evidence-retention.ps1'
  )) {
    $path = Join-Path $atomicScripts $name
    Write-Utf8 $path "original-$name"
    $originalHashes[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
  }
  $null = Invoke-Git $atomicDestination @('add', '--all')
  $null = Invoke-Git $atomicDestination @('commit', '-m', 'original retention files')
  $lockedPath = Join-Path $atomicScripts 'validate-run-evidence-retention.ps1'
  $lockStream = [System.IO.File]::Open($lockedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  $atomicRejected = $false
  $atomicErrorMessage = ''
  $atomicWarnings = @()
  try {
    try {
      & $installerPath -DestinationControlRoot $atomicDestination -InstallRetentionOnly `
        -TestFailStagingCleanup -WarningVariable +atomicWarnings -WarningAction SilentlyContinue | Out-Null
    } catch {
      $atomicRejected = $true
      $atomicErrorMessage = $_.Exception.Message
    }
  } finally { $lockStream.Dispose() }
  Assert-True (
    $atomicRejected -and
    $atomicErrorMessage -notmatch 'Injected staging cleanup failure' -and
    @($atomicWarnings | Where-Object { $_.Message -match 'Injected staging cleanup failure' }).Count -eq 1
  ) 'staging cleanup failure must not mask the primary mid-replace installation error'
  foreach ($name in $originalHashes.Keys) {
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $atomicScripts $name) -Algorithm SHA256).Hash -eq $originalHashes[$name]) "installer rollback must restore $name"
  }

  # Validator accepts the complete manifest and rejects missing/tampered artifacts.
  $validatorRoot = Join-Path $testRoot 'validator-artifacts'
  Initialize-GitRoot $validatorRoot
  $null = Invoke-Git $validatorRoot @('commit', '--allow-empty', '-m', 'baseline')
  & $installerPath -DestinationControlRoot $validatorRoot -InstallRetentionOnly | Out-Null
  $installedValidatorPath = Join-Path $validatorRoot 'scripts\yefeng\validate-run-evidence-retention.ps1'
  $validArtifactResult = Invoke-Validator $validatorRoot $installedValidatorPath
  Assert-True (@($validArtifactResult.issues | Where-Object { $_ -match 'Retention helper|retention helper' }).Count -eq 0) 'validator must accept the complete trusted retention manifest'
  $installedInstallerPath = Join-Path $validatorRoot 'scripts\yefeng\install-governed-runner.ps1'
  $installedInstallerText = [System.IO.File]::ReadAllText($installedInstallerPath, $utf8NoBom)
  $installedInstallerText = $installedInstallerText.Replace(
    "'compact-run-evidence.ps1' = '$trustedCompactHash'",
    "'compact-run-evidence.ps1' = '$('f' * 64)'"
  )
  [System.IO.File]::WriteAllText($installedInstallerPath, $installedInstallerText, $utf8NoBom)
  $carrierMismatchResult = Invoke-Validator $validatorRoot $installedValidatorPath
  Assert-True (
    @($carrierMismatchResult.issues | Where-Object { $_ -match 'Retention carrier manifest mismatch.*install-governed-runner' }).Count -eq 1
  ) 'installed validator must reject disagreement in the installer carrier manifest values'
  & $installerPath -DestinationControlRoot $validatorRoot -InstallRetentionOnly | Out-Null
  Remove-Item -LiteralPath (Join-Path $validatorRoot 'scripts\yefeng\test-run-evidence-retention.ps1') -Force
  $missingArtifactResult = Invoke-Validator $validatorRoot
  Assert-True (@($missingArtifactResult.issues | Where-Object { $_ -match 'Partial retention helper.*test-run-evidence-retention' }).Count -eq 1) 'validator must reject a missing retention test artifact'
  & $installerPath -DestinationControlRoot $validatorRoot -InstallRetentionOnly | Out-Null
  [System.IO.File]::AppendAllText((Join-Path $validatorRoot 'scripts\yefeng\compact-run-evidence.ps1'), 'tamper', $utf8NoBom)
  $tamperedArtifactResult = Invoke-Validator $validatorRoot
  Assert-True (@($tamperedArtifactResult.issues | Where-Object { $_ -match 'Retention helper hash mismatch.*compact-run-evidence' }).Count -eq 1) 'validator must reject a tampered retention artifact'

  [pscustomobject]@{
    passed = $true
    assertions = $script:assertionCount
    prepared_git_gate = $true
    committed_state_binding = $true
    caller_clock_unreachable = $true
    policy_downgrade_rejected = $true
    whole_run_reparse_protection = $true
    installed_five_file_chain = $script:installedChainExercised
    installer_tamper_and_rollback = $true
    validator_manifest_checks = $true
    bounded_receipt_bytes = $boundedBytes
  } | ConvertTo-Json -Depth 5
} finally {
  if (Test-Path -LiteralPath $testRoot) {
    $resolved = [System.IO.Path]::GetFullPath($testRoot)
    $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($temp, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing non-temporary cleanup: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}
