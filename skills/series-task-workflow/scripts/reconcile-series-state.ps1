[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StatePath
)

$ErrorActionPreference = 'Stop'
$issues = [System.Collections.Generic.List[object]]::new()
$resultContext = [ordered]@{
    state_path = $null
    repository_git_common_dir = $null
    main_revision = $null
    declared_candidate_count = 0
    active_candidate_count = 0
    pending_review_count = 0
}

function Add-Issue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [AllowNull()]
        [object]$Expected,

        [AllowNull()]
        [object]$Actual
    )

    $record = [ordered]@{
        code = $Code
        subject = $Subject
        message = $Message
    }
    if ($PSBoundParameters.ContainsKey('Expected')) {
        $record.expected = $Expected
    }
    if ($PSBoundParameters.ContainsKey('Actual')) {
        $record.actual = $Actual
    }
    $script:issues.Add([pscustomobject]$record)
}

function Complete-Reconciliation {
    param([int]$ExitCode)

    $sortedIssues = @($script:issues | Sort-Object code, subject, message)
    $payload = [ordered]@{
        ok = ($sortedIssues.Count -eq 0)
        state_path = $script:resultContext.state_path
        repository_git_common_dir = $script:resultContext.repository_git_common_dir
        main_revision = $script:resultContext.main_revision
        declared_candidate_count = $script:resultContext.declared_candidate_count
        active_candidate_count = $script:resultContext.active_candidate_count
        pending_review_count = $script:resultContext.pending_review_count
        issues = $sortedIssues
    }

    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 10))
    exit $ExitCode
}

function Test-Property {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return $null -ne $InputObject -and $InputObject.PSObject.Properties.Name -contains $Name
}

function Get-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,

        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Normalize-PathValue {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    return ([System.IO.Path]::GetFullPath($PathValue)).TrimEnd([char[]]@('\', '/')).ToLowerInvariant()
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = @(& git -C $WorkingDirectory @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Get-WorktreeRecords {
    param([Parameter(Mandatory = $true)][string]$WorkingDirectory)

    $lines = @(Invoke-Git -WorkingDirectory $WorkingDirectory -Arguments @('worktree', 'list', '--porcelain'))
    $lines += ''
    $records = [System.Collections.Generic.List[object]]::new()
    $current = $null

    foreach ($line in $lines) {
        if ($line -like 'worktree *') {
            if ($null -ne $current) {
                $records.Add([pscustomobject]$current)
            }
            $current = [ordered]@{
                path = $line.Substring(9)
                head = $null
                branch = $null
                prunable = $false
                prunable_reason = $null
            }
        }
        elseif ($null -ne $current -and $line -like 'HEAD *') {
            $current.head = $line.Substring(5)
        }
        elseif ($null -ne $current -and $line -like 'branch *') {
            $current.branch = $line.Substring(7)
        }
        elseif ($null -ne $current -and $line -like 'prunable*') {
            $current.prunable = $true
            $current.prunable_reason = $line.Substring(8).Trim()
        }
        elseif ([string]::IsNullOrWhiteSpace($line) -and $null -ne $current) {
            $records.Add([pscustomobject]$current)
            $current = $null
        }
    }

    return @($records)
}

$stateFullPath = Get-AbsolutePath -PathValue $StatePath -BasePath (Get-Location).Path
$resultContext.state_path = Normalize-PathValue $stateFullPath

if (-not (Test-Path -LiteralPath $stateFullPath -PathType Leaf)) {
    Add-Issue -Code 'state_file_not_found' -Subject 'state' -Message 'State file does not exist.' -Expected $stateFullPath -Actual $null
    Complete-Reconciliation -ExitCode 2
}

try {
    $rawState = Get-Content -LiteralPath $stateFullPath -Raw -Encoding UTF8
    $jsonArguments = @{}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $jsonArguments.DateKind = 'String'
    }
    $state = $rawState | ConvertFrom-Json @jsonArguments
}
catch {
    Add-Issue -Code 'state_json_invalid' -Subject 'state' -Message 'State file is not valid JSON.' -Expected 'valid JSON' -Actual $_.Exception.Message
    Complete-Reconciliation -ExitCode 2
}

$requiredStateFields = @('run_epoch', 'status', 'main_revision', 'cycle_budget', 'claims', 'candidates')
foreach ($field in $requiredStateFields) {
    if (-not (Test-Property -InputObject $state -Name $field)) {
        Add-Issue -Code 'state_schema_invalid' -Subject 'state' -Message "State field '$field' is required."
    }
}

$allowedControlStatuses = @('active', 'paused', 'handed-off', 'cancelled', 'closed')
if (Test-Property -InputObject $state -Name 'status') {
    if ([string]::IsNullOrWhiteSpace([string]$state.status) -or $state.status -notin $allowedControlStatuses) {
        Add-Issue -Code 'state_schema_invalid' -Subject 'state' -Message 'State status is invalid.' -Expected ($allowedControlStatuses -join ',') -Actual $state.status
    }
}

$epochValue = 0L
if (Test-Property -InputObject $state -Name 'run_epoch') {
    if (-not [long]::TryParse([string]$state.run_epoch, [ref]$epochValue) -or $epochValue -lt 0) {
        Add-Issue -Code 'state_schema_invalid' -Subject 'state' -Message 'run_epoch must be a non-negative integer.' -Actual $state.run_epoch
    }
}

if (Test-Property -InputObject $state -Name 'main_revision') {
    if ([string]::IsNullOrWhiteSpace([string]$state.main_revision)) {
        Add-Issue -Code 'state_schema_invalid' -Subject 'state' -Message 'main_revision is required.'
    }
}

$cycleBudgetValues = [ordered]@{
    candidate_attempt_limit = 0
    review_failure_limit = 0
    candidate_attempts = 0
    review_failures = 0
    reset_count = 0
}
if (Test-Property -InputObject $state -Name 'cycle_budget') {
    $cycleBudget = $state.cycle_budget
    foreach ($field in @('candidate_attempt_limit', 'review_failure_limit', 'candidate_attempts', 'review_failures', 'reset_count')) {
        if (-not (Test-Property -InputObject $cycleBudget -Name $field)) {
            Add-Issue -Code 'state_schema_invalid' -Subject 'cycle_budget' -Message "Cycle budget field '$field' is required."
            continue
        }

        $parsedValue = 0
        $valueParsed = [int]::TryParse([string]$cycleBudget.$field, [ref]$parsedValue)
        $minimumValue = if ($field -in @('candidate_attempt_limit', 'review_failure_limit')) { 1 } else { 0 }
        if (-not $valueParsed -or $parsedValue -lt $minimumValue) {
            Add-Issue -Code 'state_schema_invalid' -Subject 'cycle_budget' -Message "Cycle budget field '$field' must be an integer greater than or equal to $minimumValue." -Actual $cycleBudget.$field
        }
        else {
            $cycleBudgetValues[$field] = $parsedValue
        }
    }

    $hasLastReset = Test-Property -InputObject $cycleBudget -Name 'last_reset'
    if (-not $hasLastReset) {
        Add-Issue -Code 'state_schema_invalid' -Subject 'cycle_budget' -Message "Cycle budget field 'last_reset' is required."
    }
    elseif ($cycleBudgetValues.reset_count -eq 0 -and $null -ne $cycleBudget.last_reset) {
        Add-Issue -Code 'state_schema_invalid' -Subject 'cycle_budget' -Message 'last_reset must be null when reset_count is zero.' -Expected $null -Actual $cycleBudget.last_reset
    }
    elseif ($cycleBudgetValues.reset_count -gt 0) {
        if ($null -eq $cycleBudget.last_reset) {
            Add-Issue -Code 'state_schema_invalid' -Subject 'cycle_budget' -Message 'A positive reset_count requires last_reset evidence.'
        }
        else {
            foreach ($field in @('at', 'reason', 'changed_direction', 'acceptance_matrix', 'authorized_by')) {
                if (-not (Test-Property -InputObject $cycleBudget.last_reset -Name $field) -or [string]::IsNullOrWhiteSpace([string]$cycleBudget.last_reset.$field)) {
                    Add-Issue -Code 'state_schema_invalid' -Subject 'cycle_budget' -Message "last_reset field '$field' is required after a cycle reset."
                }
            }

            if (Test-Property -InputObject $cycleBudget.last_reset -Name 'at') {
                $resetAtText = ([string]$cycleBudget.last_reset.at).Trim()
                $resetAt = [DateTimeOffset]::MinValue
                $hasExplicitZone = $resetAtText.EndsWith('Z', [StringComparison]::OrdinalIgnoreCase) -or $resetAtText -match '[+-]\d{2}:\d{2}$'
                if (-not $hasExplicitZone -or -not [DateTimeOffset]::TryParse($resetAtText, [ref]$resetAt)) {
                    Add-Issue -Code 'state_schema_invalid' -Subject 'cycle_budget' -Message 'last_reset.at must be an RFC3339 timestamp with a timezone.' -Actual $cycleBudget.last_reset.at
                }
            }
        }
    }
}

if (Test-Property -InputObject $state -Name 'candidates') {
    $candidates = @($state.candidates)
}
else {
    $candidates = @()
}
if (Test-Property -InputObject $state -Name 'claims') {
    $claims = @($state.claims)
}
else {
    $claims = @()
}
$resultContext.declared_candidate_count = $candidates.Count

$candidateIds = @{}
$candidatePaths = @{}
$candidateRequiredFields = @('id', 'status', 'worktree', 'branch', 'revision', 'validations', 'reviews')
$allowedCandidateStatuses = @(
    'claimed', 'implementation', 'running', 'validation', 'review',
    'implementation-review', 'blocked', 'done', 'merged', 'paused',
    'handed-off', 'cancelled', 'expired', 'abandoned', 'closed'
)
for ($index = 0; $index -lt $candidates.Count; $index++) {
    $candidate = $candidates[$index]
    $candidateId = if (Test-Property -InputObject $candidate -Name 'id') { [string]$candidate.id } else { "index:$index" }
    $subject = "candidate:$candidateId"

    foreach ($field in $candidateRequiredFields) {
        if (-not (Test-Property -InputObject $candidate -Name $field)) {
            Add-Issue -Code 'candidate_schema_invalid' -Subject $subject -Message "Candidate field '$field' is required."
        }
    }

    if (Test-Property -InputObject $candidate -Name 'id') {
        if ([string]::IsNullOrWhiteSpace([string]$candidate.id)) {
            Add-Issue -Code 'candidate_schema_invalid' -Subject $subject -Message 'Candidate id must not be empty.'
        }
        elseif ($candidateIds.ContainsKey([string]$candidate.id)) {
            Add-Issue -Code 'candidate_schema_invalid' -Subject $subject -Message 'Candidate id must be unique.' -Actual $candidate.id
        }
        else {
            $candidateIds[[string]$candidate.id] = $true
        }
    }

    if ((Test-Property -InputObject $candidate -Name 'worktree') -and -not [string]::IsNullOrWhiteSpace([string]$candidate.worktree)) {
        if (-not [System.IO.Path]::IsPathRooted([string]$candidate.worktree)) {
            Add-Issue -Code 'candidate_schema_invalid' -Subject $subject -Message 'Candidate worktree must be an absolute path.' -Actual $candidate.worktree
        }
        else {
            $pathKey = Normalize-PathValue ([string]$candidate.worktree)
            if ($candidatePaths.ContainsKey($pathKey)) {
                Add-Issue -Code 'candidate_schema_invalid' -Subject $subject -Message 'Candidate worktree must be unique.' -Actual $candidate.worktree
            }
            else {
                $candidatePaths[$pathKey] = $true
            }
        }
    }

    foreach ($field in @('status', 'branch', 'revision')) {
        if ((Test-Property -InputObject $candidate -Name $field) -and [string]::IsNullOrWhiteSpace([string]$candidate.$field)) {
            Add-Issue -Code 'candidate_schema_invalid' -Subject $subject -Message "Candidate field '$field' must not be empty."
        }
    }
    if ((Test-Property -InputObject $candidate -Name 'status') -and $candidate.status -notin $allowedCandidateStatuses) {
        Add-Issue -Code 'candidate_schema_invalid' -Subject $subject -Message "Candidate status '$($candidate.status)' is not recognized." -Expected ($allowedCandidateStatuses -join ',') -Actual $candidate.status
    }
}

$allowedClaimStatuses = @('claimed', 'running', 'reviewing', 'blocked', 'released', 'expired', 'completed', 'cancelled')
for ($index = 0; $index -lt $claims.Count; $index++) {
    $claim = $claims[$index]
    $claimId = if (Test-Property -InputObject $claim -Name 'id') { [string]$claim.id } else { "index:$index" }
    $subject = "claim:$claimId"
    foreach ($field in @('id', 'status')) {
        if (-not (Test-Property -InputObject $claim -Name $field) -or [string]::IsNullOrWhiteSpace([string]$claim.$field)) {
            Add-Issue -Code 'claim_schema_invalid' -Subject $subject -Message "Claim field '$field' is required."
        }
    }
    if ((Test-Property -InputObject $claim -Name 'status') -and $claim.status -notin $allowedClaimStatuses) {
        Add-Issue -Code 'claim_schema_invalid' -Subject $subject -Message "Claim status '$($claim.status)' is not recognized." -Expected ($allowedClaimStatuses -join ',') -Actual $claim.status
    }
}

$budgetValues = @{
    active_repairs = 2
    pending_reviews = 2
    integration_batches = 1
}
if (Test-Property -InputObject $state -Name 'wip_budget') {
    foreach ($field in @('active_repairs', 'pending_reviews', 'integration_batches')) {
        if (Test-Property -InputObject $state.wip_budget -Name $field) {
            $parsedBudget = 0
            $budgetParsed = [int]::TryParse([string]$state.wip_budget.$field, [ref]$parsedBudget)
            if (-not $budgetParsed -or $parsedBudget -lt 0) {
                Add-Issue -Code 'state_schema_invalid' -Subject 'wip' -Message "WIP field '$field' must be a non-negative integer." -Actual $state.wip_budget.$field
            }
            else {
                $budgetValues[$field] = $parsedBudget
            }
        }
    }
}

if ($issues.Count -gt 0) {
    Complete-Reconciliation -ExitCode 2
}

$workingDirectory = (Get-Location).Path
try {
    $commonDirectoryRaw = @(Invoke-Git -WorkingDirectory $workingDirectory -Arguments @('rev-parse', '--git-common-dir'))[0]
    $commonDirectory = Get-AbsolutePath -PathValue $commonDirectoryRaw -BasePath $workingDirectory
    $resultContext.repository_git_common_dir = Normalize-PathValue $commonDirectory
    $actualMainRevision = @(Invoke-Git -WorkingDirectory $workingDirectory -Arguments @('rev-parse', '--verify', 'refs/heads/main'))[0]
    $resultContext.main_revision = $actualMainRevision
    $worktrees = @(Get-WorktreeRecords -WorkingDirectory $workingDirectory)
}
catch {
    Add-Issue -Code 'repository_not_found' -Subject 'repository' -Message 'The current directory is not a usable Git worktree for this state.' -Actual $_.Exception.Message
    Complete-Reconciliation -ExitCode 2
}

if ([string]$state.main_revision -ne $actualMainRevision) {
    Add-Issue -Code 'main_revision_mismatch' -Subject 'main' -Message 'Recorded main revision does not match refs/heads/main.' -Expected $state.main_revision -Actual $actualMainRevision
}

$worktreeMap = @{}
foreach ($worktree in $worktrees) {
    $worktreeMap[(Normalize-PathValue $worktree.path)] = $worktree
}

$activeCandidateStatuses = @('claimed', 'implementation', 'running', 'validation', 'review', 'implementation-review', 'blocked')
$activeCandidatePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$activeCandidates = [System.Collections.Generic.List[object]]::new()
$pendingReviewCount = 0

foreach ($candidate in $candidates) {
    $candidateId = [string]$candidate.id
    $subject = "candidate:$candidateId"
    $candidatePathKey = Normalize-PathValue ([string]$candidate.worktree)
    $isActiveCandidate = [string]$candidate.status -in $activeCandidateStatuses
    if ($isActiveCandidate) {
        $null = $activeCandidatePaths.Add($candidatePathKey)
        $activeCandidates.Add([pscustomobject]@{ id = $candidateId; status = [string]$candidate.status })
    }

    if (-not $worktreeMap.ContainsKey($candidatePathKey)) {
        Add-Issue -Code 'candidate_worktree_not_in_repository' -Subject $subject -Message 'Candidate worktree is not registered in this Git repository.' -Expected $candidate.worktree -Actual $null
        continue
    }

    $actualWorktree = $worktreeMap[$candidatePathKey]
    if ($actualWorktree.prunable -or -not (Test-Path -LiteralPath $actualWorktree.path -PathType Container)) {
        Add-Issue -Code 'candidate_worktree_unavailable' -Subject $subject -Message 'Candidate worktree is registered but unavailable or prunable.' -Expected $candidate.worktree -Actual $actualWorktree.prunable_reason
        continue
    }
    $expectedBranch = if ([string]$candidate.branch -like 'refs/heads/*') { [string]$candidate.branch } else { "refs/heads/$($candidate.branch)" }
    if ($actualWorktree.branch -ne $expectedBranch) {
        Add-Issue -Code 'candidate_branch_mismatch' -Subject $subject -Message 'Candidate branch does not match the registered worktree branch.' -Expected $expectedBranch -Actual $actualWorktree.branch
    }
    if ($actualWorktree.head -ne [string]$candidate.revision) {
        Add-Issue -Code 'candidate_revision_mismatch' -Subject $subject -Message 'Candidate revision does not match the worktree HEAD revision.' -Expected $candidate.revision -Actual $actualWorktree.head
    }

    $hasPassedValidation = $false
    $validationFailureMarkers = @('interrupted', 'cancelled', 'timed_out', 'incomplete')
    foreach ($validation in @($candidate.validations)) {
        if ($validation.status -eq 'passed') {
            $invalidMarkers = @(
                $validationFailureMarkers | Where-Object {
                    (Test-Property -InputObject $validation -Name $_) -and $validation.$_ -eq $true
                }
            )
            $validationIsCurrent = $invalidMarkers.Count -eq 0 -and [string]$validation.revision -eq [string]$candidate.revision
            foreach ($marker in $invalidMarkers) {
                Add-Issue -Code "validation_${marker}_marked_passed" -Subject $subject -Message "Validation '$($validation.name)' is both $marker and passed."
            }
            if ([string]$validation.revision -ne [string]$candidate.revision) {
                Add-Issue -Code 'validation_revision_mismatch' -Subject $subject -Message "Passed validation '$($validation.name)' does not bind the candidate revision." -Expected $candidate.revision -Actual $validation.revision
            }
            if ($validationIsCurrent) {
                $hasPassedValidation = $true
            }
        }
    }

    $candidateReviews = @($candidate.reviews)
    foreach ($review in $candidateReviews) {
        if ($review.status -in @('pending', 'reviewing')) {
            $pendingReviewCount++
        }
        if ($review.status -eq 'passed' -and $review.verdict -ne 'review passed') {
            Add-Issue -Code 'review_verdict_invalid' -Subject $subject -Message 'A passed review requires the literal verdict review passed.' -Expected 'review passed' -Actual $review.verdict
        }
        if ($review.verdict -eq 'review passed' -and $review.status -ne 'passed') {
            Add-Issue -Code 'review_status_invalid' -Subject $subject -Message 'The verdict review passed requires review status passed.' -Expected 'passed' -Actual $review.status
        }
        if ($review.verdict -eq 'review passed' -and [string]$review.reviewed_revision -ne [string]$candidate.revision) {
            Add-Issue -Code 'review_revision_mismatch' -Subject $subject -Message 'Passed review does not bind the candidate revision.' -Expected $candidate.revision -Actual $review.reviewed_revision
        }
    }
    $latestReview = if ($candidateReviews.Count -gt 0) { $candidateReviews[-1] } else { $null }
    $hasPassedReview = $null -ne $latestReview -and
        $latestReview.status -eq 'passed' -and
        $latestReview.verdict -eq 'review passed' -and
        [string]$latestReview.reviewed_revision -eq [string]$candidate.revision

    if ($candidate.status -in @('done', 'merged', 'closed')) {
        if (-not $hasPassedValidation) {
            Add-Issue -Code 'terminal_candidate_missing_validation' -Subject $subject -Message "Candidate status '$($candidate.status)' requires a current passed validation."
        }
        if (-not $hasPassedReview) {
            Add-Issue -Code 'terminal_candidate_missing_review' -Subject $subject -Message "Candidate status '$($candidate.status)' requires a current review passed verdict."
        }
    }
}

$resultContext.active_candidate_count = $activeCandidatePaths.Count
$resultContext.pending_review_count = $pendingReviewCount

$activeRepairLimit = $budgetValues.active_repairs
$pendingReviewLimit = $budgetValues.pending_reviews

if ($activeCandidatePaths.Count -gt $activeRepairLimit) {
    Add-Issue -Code 'wip_active_repairs_exceeded' -Subject 'wip' -Message 'Active candidate count exceeds the recorded WIP budget.' -Expected $activeRepairLimit -Actual $activeCandidatePaths.Count
}
if ($pendingReviewCount -gt $pendingReviewLimit) {
    Add-Issue -Code 'wip_pending_reviews_exceeded' -Subject 'wip' -Message 'Pending review count exceeds the recorded WIP budget.' -Expected $pendingReviewLimit -Actual $pendingReviewCount
}

$activeClaimStatuses = @('claimed', 'running', 'reviewing', 'blocked')
$activeClaims = @($claims | Where-Object { $_.status -in $activeClaimStatuses })
$cycleBudgetExhausted =
    $cycleBudgetValues.candidate_attempts -ge $cycleBudgetValues.candidate_attempt_limit -or
    $cycleBudgetValues.review_failures -ge $cycleBudgetValues.review_failure_limit
if ($cycleBudgetExhausted) {
    foreach ($candidate in @($candidates | Where-Object { $_.status -in $activeCandidateStatuses -and $_.status -ne 'blocked' })) {
        Add-Issue -Code 'cycle_budget_exhausted' -Subject "candidate:$($candidate.id)" -Message 'Cycle budget is exhausted; block active work and record root-cause reassessment evidence before resetting counters.' -Expected 'blocked' -Actual $candidate.status
    }
    foreach ($claim in @($claims | Where-Object { $_.status -in $activeClaimStatuses -and $_.status -ne 'blocked' })) {
        Add-Issue -Code 'cycle_budget_exhausted' -Subject "claim:$($claim.id)" -Message 'Cycle budget is exhausted; block active work and record root-cause reassessment evidence before resetting counters.' -Expected 'blocked' -Actual $claim.status
    }
}
foreach ($claim in $activeClaims) {
    $claimId = if (Test-Property -InputObject $claim -Name 'id') { [string]$claim.id } else { 'unknown' }
    $subject = "claim:$claimId"

    if (-not (Test-Property -InputObject $claim -Name 'run_epoch') -or $claim.run_epoch -ne $state.run_epoch) {
        Add-Issue -Code 'claim_epoch_mismatch' -Subject $subject -Message 'Active claim run_epoch does not match the current series run_epoch.' -Expected $state.run_epoch -Actual $claim.run_epoch
    }

    if (-not (Test-Property -InputObject $claim -Name 'lease_expires') -or [string]::IsNullOrWhiteSpace([string]$claim.lease_expires)) {
        Add-Issue -Code 'claim_lease_missing' -Subject $subject -Message 'Active claim requires lease_expires.'
        continue
    }

    $leaseValue = $claim.lease_expires
    $lease = [DateTimeOffset]::MinValue
    if ($leaseValue -is [DateTimeOffset]) {
        $hasExplicitZone = $true
        $leaseParsed = $true
        $lease = [DateTimeOffset]$leaseValue
    }
    elseif ($leaseValue -is [DateTime]) {
        $hasExplicitZone = $leaseValue.Kind -ne [DateTimeKind]::Unspecified
        $leaseParsed = $true
        $lease = [DateTimeOffset]$leaseValue
    }
    else {
        $leaseText = ([string]$leaseValue).Trim()
        $hasExplicitZone = ($leaseText.EndsWith('Z', [StringComparison]::OrdinalIgnoreCase)) -or ($leaseText -match '[+-]\d{2}:\d{2}$')
        $leaseParsed = [DateTimeOffset]::TryParse($leaseText, [ref]$lease)
    }
    if (-not $hasExplicitZone -or -not $leaseParsed) {
        Add-Issue -Code 'claim_lease_invalid' -Subject $subject -Message 'Active claim lease_expires must be an RFC3339 timestamp with a timezone.' -Actual $claim.lease_expires
    }
    elseif ($lease -le [DateTimeOffset]::UtcNow) {
        Add-Issue -Code 'claim_lease_expired' -Subject $subject -Message 'Active claim lease has expired.' -Expected 'future timestamp' -Actual $claim.lease_expires
    }
}

$inactiveControlStatuses = @('paused', 'handed-off', 'cancelled', 'closed')
if ($state.status -in $inactiveControlStatuses) {
    if ($activeClaims.Count -gt 0) {
        Add-Issue -Code 'claim_active_while_series_inactive' -Subject "series:$($state.status)" -Message "Control status '$($state.status)' cannot retain active claims." -Expected 0 -Actual $activeClaims.Count
    }
    foreach ($candidate in $activeCandidates) {
        Add-Issue -Code 'candidate_active_while_series_inactive' -Subject "candidate:$($candidate.id)" -Message "Candidate status '$($candidate.status)' is active while the series control status is '$($state.status)'." -Expected 'inactive candidate status' -Actual $candidate.status
    }
}

if ($state.status -eq 'closed') {
    $terminalCandidateStatuses = @('done', 'merged', 'cancelled', 'expired', 'abandoned', 'closed')
    foreach ($candidate in $candidates) {
        if ($candidate.status -notin $terminalCandidateStatuses) {
            Add-Issue -Code 'candidate_nonterminal_while_series_closed' -Subject "candidate:$($candidate.id)" -Message "Candidate status '$($candidate.status)' is not terminal while the series control status is 'closed'." -Expected ($terminalCandidateStatuses -join ',') -Actual $candidate.status
        }
    }
}

if ($state.status -eq 'closed' -and $state.cleanup_state -ne 'cleaned') {
    Add-Issue -Code 'closed_cleanup_incomplete' -Subject 'series:closed' -Message 'Closed series requires cleanup_state=cleaned.' -Expected 'cleaned' -Actual $state.cleanup_state
}

if ($issues.Count -gt 0) {
    Complete-Reconciliation -ExitCode 2
}
Complete-Reconciliation -ExitCode 0
