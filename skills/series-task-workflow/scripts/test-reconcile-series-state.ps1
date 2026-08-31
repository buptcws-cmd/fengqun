[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$reconcilerPath = Join-Path $PSScriptRoot 'reconcile-series-state.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "series-reconcile-$([Guid]::NewGuid().ToString('N'))"
$passedCases = 0
$executedCases = 0

function Invoke-GitText {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& git -C $Repository @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Invoke-GitBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.WorkingDirectory = $Repository
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($argument in @('-C', $Repository) + $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $memory = [System.IO.MemoryStream]::new()
    try {
        if (-not $process.Start()) {
            throw 'Unable to start git.'
        }
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $null = $copyTask.GetAwaiter().GetResult()
        $errorOutput = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed: $errorOutput"
        }
        return ,$memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-RawDiffSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$SourceRevision,
        [Parameter(Mandatory = $true)][string]$TargetRevision
    )

    $bytes = Invoke-GitBytes -Repository $Repository -Arguments @(
        'diff-tree', '--no-commit-id', '--raw', '-r', '-z', $SourceRevision, $TargetRevision, '--'
    )
    return Get-Sha256Hex -Bytes $bytes
}

function Get-ScopedSurfaceSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Revision,
        [Parameter(Mandatory = $true)][string[]]$ExcludedPaths
    )

    $excluded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in $ExcludedPaths) {
        $null = $excluded.Add($path)
    }
    $treeBytes = Invoke-GitBytes -Repository $Repository -Arguments @('ls-tree', '-r', '-z', '--full-tree', $Revision)
    $treeText = [System.Text.UTF8Encoding]::new($false, $true).GetString($treeBytes)
    $records = @($treeText.Split([char[]]@([char]0), [System.StringSplitOptions]::RemoveEmptyEntries))
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    $surface = [System.IO.MemoryStream]::new()
    try {
        foreach ($record in $records) {
            $tabIndex = $record.IndexOf("`t")
            if ($tabIndex -le 0) {
                throw "Invalid git ls-tree record at revision '$Revision'."
            }
            if ($excluded.Contains($record.Substring($tabIndex + 1))) {
                continue
            }
            $recordBytes = $encoding.GetBytes($record)
            $surface.Write($recordBytes, 0, $recordBytes.Length)
            $surface.WriteByte(0)
        }
        return Get-Sha256Hex -Bytes $surface.ToArray()
    }
    finally {
        $surface.Dispose()
    }
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function New-Fixture {
    param([Parameter(Mandatory = $true)][string]$Name)

    $fixtureRoot = Join-Path $testRoot $Name
    $repository = Join-Path $fixtureRoot 'repo'
    $worktree = Join-Path $fixtureRoot 'candidate'
    $null = New-Item -ItemType Directory -Path $repository -Force
    $null = Invoke-GitText -Repository $repository -Arguments @('init', '-b', 'main')
    $null = Invoke-GitText -Repository $repository -Arguments @('config', 'user.name', 'Series Test')
    $null = Invoke-GitText -Repository $repository -Arguments @('config', 'user.email', 'series-test@example.invalid')

    Write-Utf8File -Path (Join-Path $repository 'product.txt') -Content "product-v1`n"
    Write-Utf8File -Path (Join-Path $repository 'admin.md') -Content "admin-v1`n"
    Write-Utf8File -Path (Join-Path $repository 'mixed.json') -Content "{`"product`":`"stable`",`"status`":`"draft`"}`n"
    $null = Invoke-GitText -Repository $repository -Arguments @('add', '--', '.')
    $null = Invoke-GitText -Repository $repository -Arguments @('commit', '-m', 'old')
    $oldRevision = @(Invoke-GitText -Repository $repository -Arguments @('rev-parse', 'HEAD'))[0]

    Write-Utf8File -Path (Join-Path $repository 'product.txt') -Content "product-v2`n"
    $null = Invoke-GitText -Repository $repository -Arguments @('add', '--', 'product.txt')
    $null = Invoke-GitText -Repository $repository -Arguments @('commit', '-m', 'base')
    $mainRevision = @(Invoke-GitText -Repository $repository -Arguments @('rev-parse', 'HEAD'))[0]
    $branch = "candidate-$Name"
    $null = Invoke-GitText -Repository $repository -Arguments @('worktree', 'add', '-b', $branch, $worktree, 'main')

    return [pscustomobject]@{
        Root = $fixtureRoot
        Repository = $repository
        Worktree = $worktree
        Branch = $branch
        OldRevision = $oldRevision
        MainRevision = $mainRevision
        CandidateRevision = $mainRevision
    }
}

function Add-CandidateCommit {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content,
        [string]$Message = 'candidate'
    )

    Write-Utf8File -Path (Join-Path $Fixture.Worktree $Path) -Content $Content
    $null = Invoke-GitText -Repository $Fixture.Worktree -Arguments @('add', '--', $Path)
    $null = Invoke-GitText -Repository $Fixture.Worktree -Arguments @('commit', '-m', $Message)
    $Fixture.CandidateRevision = @(Invoke-GitText -Repository $Fixture.Worktree -Arguments @('rev-parse', 'HEAD'))[0]
    return $Fixture.CandidateRevision
}

function New-State {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Reviews,
        [AllowNull()][object]$ReviewGate,
        [ValidateSet(1, 2)][int]$SchemaVersion = 2,
        [string]$CandidateStatus = 'done',
        [hashtable]$WipBudget = @{ active_repairs = 2; pending_reviews = 2; integration_batches = 1 },
        [AllowNull()][object[]]$IntegrationIntents = $null
    )

    $candidate = [ordered]@{
        id = 'candidate-1'
        status = $CandidateStatus
        worktree = $Fixture.Worktree
        branch = $Fixture.Branch
        revision = $Fixture.CandidateRevision
        validations = @(
            [ordered]@{
                name = 'targeted-tests'
                revision = $Fixture.CandidateRevision
                status = 'passed'
                interrupted = $false
            }
        )
        reviews = $Reviews
    }
    if ($SchemaVersion -ge 2) {
        $candidate.review_gate = $ReviewGate
    }

    $state = [ordered]@{
        run_epoch = 1
        status = 'active'
        execution_mode = 'solo'
        main_revision = $Fixture.MainRevision
        wip_budget = $WipBudget
        cycle_budget = [ordered]@{
            candidate_attempt_limit = 2
            review_failure_limit = 2
            candidate_attempts = 0
            review_failures = 0
            reset_count = 0
            last_reset = $null
        }
        claims = @()
        candidates = @($candidate)
        cleanup_state = 'pending'
    }
    if ($SchemaVersion -ge 2) {
        $state.schema_version = $SchemaVersion
    }
    if ($null -ne $IntegrationIntents) {
        $state.integration_intents = $IntegrationIntents
    }
    return $state
}

function New-HistoricalCandidate {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Reviews,
        [string]$Status = 'closed'
    )

    $worktree = Join-Path $Fixture.Root "historical-$Name"
    $branch = "historical-$Name"
    $null = Invoke-GitText -Repository $Fixture.Repository -Arguments @('worktree', 'add', '-b', $branch, $worktree, 'main')
    return [ordered]@{
        id = "historical-$Name"
        status = $Status
        worktree = $worktree
        branch = $branch
        revision = $Fixture.MainRevision
        validations = @(
            [ordered]@{ name = 'historical-validation'; revision = $Fixture.MainRevision; status = 'passed'; interrupted = $false }
        )
        reviews = $Reviews
    }
}

function New-ExactGate {
    param(
        [Parameter(Mandatory = $true)][string]$ReviewId,
        [Parameter(Mandatory = $true)][string]$CandidateRevision,
        [Parameter(Mandatory = $true)][string]$ReviewedRevision
    )

    return [ordered]@{
        review_id = $ReviewId
        candidate_revision = $CandidateRevision
        binding = 'exact'
        proof = [ordered]@{ reviewed_revision = $ReviewedRevision }
    }
}

function New-AdministrativeGate {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter(Mandatory = $true)][string]$ReviewId,
        [Parameter(Mandatory = $true)][string]$ReviewedRevision,
        [Parameter(Mandatory = $true)][string[]]$Paths
    )

    return [ordered]@{
        review_id = $ReviewId
        candidate_revision = $Fixture.CandidateRevision
        binding = 'administrative-descendant'
        proof = [ordered]@{
            reviewed_revision = $ReviewedRevision
            scoped_surface_digest = [ordered]@{
                source_sha256 = Get-ScopedSurfaceSha256 -Repository $Fixture.Repository -Revision $ReviewedRevision -ExcludedPaths $Paths
                target_sha256 = Get-ScopedSurfaceSha256 -Repository $Fixture.Repository -Revision $Fixture.CandidateRevision -ExcludedPaths $Paths
            }
            raw_diff_sha256 = Get-RawDiffSha256 -Repository $Fixture.Repository -SourceRevision $ReviewedRevision -TargetRevision $Fixture.CandidateRevision
        }
    }
}

function Invoke-Reconciler {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter(Mandatory = $true)][object]$State
    )

    $statePath = Join-Path $Fixture.Root 'state.json'
    Write-Utf8File -Path $statePath -Content ($State | ConvertTo-Json -Depth 30)
    $pwshPath = (Get-Process -Id $PID).Path
    Push-Location $Fixture.Repository
    try {
        $output = @(& $pwshPath -NoProfile -File $reconcilerPath -StatePath $statePath 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    $payloadText = $output -join [Environment]::NewLine
    try {
        $payload = $payloadText | ConvertFrom-Json
    }
    catch {
        throw "Reconciler did not return JSON. Exit=$exitCode Output=$payloadText"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Payload = $payload; Output = $payloadText }
}

function Invoke-ReconcilerPath {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [switch]$AuditArchive
    )

    $pwshPath = (Get-Process -Id $PID).Path
    Push-Location $Fixture.Repository
    try {
        $arguments = @('-NoProfile', '-File', $reconcilerPath, '-StatePath', $StatePath)
        if ($AuditArchive) {
            $arguments += '-AuditArchive'
        }
        $output = @(& $pwshPath @arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    $payloadText = $output -join [Environment]::NewLine
    try {
        $payload = $payloadText | ConvertFrom-Json
    }
    catch {
        throw "Reconciler did not return JSON. Exit=$exitCode Output=$payloadText"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Payload = $payload; Output = $payloadText }
}

function New-V3StateRoot {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [string]$Name = 'series-v3'
    )

    $stateRoot = Join-Path $Fixture.Root $Name
    $archiveRoot = Join-Path $Fixture.Root "archive\$Name"
    $snapshotRoot = Join-Path $archiveRoot 'snapshots\snapshot-1'
    $candidateRoot = Join-Path $stateRoot 'active\candidate-1'
    $null = New-Item -ItemType Directory -Path $candidateRoot -Force
    $null = New-Item -ItemType Directory -Path $snapshotRoot -Force
    Write-Utf8File -Path (Join-Path $stateRoot 'HOT.md') -Content "# Current series`n`n- Candidate: candidate-1`n"
    Write-Utf8File -Path (Join-Path $stateRoot 'archive-index.md') -Content "# Archive index`n`n- ../archive/$Name/snapshots/snapshot-1/original-control-state.zip`n"

    $originalBytes = [System.Text.UTF8Encoding]::new($false).GetBytes("{`"cold`":true}`n")
    $originalHash = Get-Sha256Hex -Bytes $originalBytes
    $manifest = [ordered]@{
        schema_version = 1
        snapshot_id = 'snapshot-1'
        source_sha256 = $originalHash
        source_bytes = $originalBytes.Length
    }
    Write-Utf8File -Path (Join-Path $snapshotRoot 'manifest.json') -Content ($manifest | ConvertTo-Json -Depth 10)
    Write-Utf8File -Path (Join-Path $snapshotRoot 'candidate-1.json') -Content "{`"cold_candidate`":true}`n"
    # This unreferenced invalid cold file proves default reconciliation does not recursively load the archive.
    Write-Utf8File -Path (Join-Path $snapshotRoot 'unreferenced-invalid.json') -Content "{not-json`n"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $bundlePath = Join-Path $snapshotRoot 'original-control-state.zip'
    $bundleStream = [System.IO.File]::Open($bundlePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $zip = [System.IO.Compression.ZipArchive]::new($bundleStream, [System.IO.Compression.ZipArchiveMode]::Create, $true, [System.Text.UTF8Encoding]::new($false))
        try {
            $entry = $zip.CreateEntry('original-control-state.json')
            $entryStream = $entry.Open()
            try { $entryStream.Write($originalBytes, 0, $originalBytes.Length) } finally { $entryStream.Dispose() }
        }
        finally { $zip.Dispose() }
    }
    finally { $bundleStream.Dispose() }

    $candidate = [ordered]@{
        id = 'candidate-1'
        status = 'implementation'
        worktree = $Fixture.Worktree
        branch = $Fixture.Branch
        revision = $Fixture.CandidateRevision
        validations = @(
            [ordered]@{
                name = 'targeted-tests'
                revision = $Fixture.CandidateRevision
                status = 'passed'
                interrupted = $false
            }
        )
        reviews = @()
        review_gate = $null
        archive_ref_base = 'state_root'
        archive_ref = "../archive/$Name/snapshots/snapshot-1/candidate-1.json"
    }
    $candidatePath = Join-Path $candidateRoot 'state.json'
    Write-Utf8File -Path $candidatePath -Content ($candidate | ConvertTo-Json -Depth 30)
    $candidateHash = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($candidatePath))

    $control = [ordered]@{
        schema_version = 3
        state_format = 'series-directory-v3'
        run_epoch = 1
        status = 'active'
        execution_mode = 'solo'
        main_revision = $Fixture.MainRevision
        wip_budget = [ordered]@{ active_repairs = 2; pending_reviews = 2; integration_batches = 1 }
        cycle_budget = [ordered]@{
            candidate_attempt_limit = 2
            review_failure_limit = 2
            candidate_attempts = 0
            review_failures = 0
            reset_count = 0
            last_reset = $null
        }
        claims = @()
        candidate_refs = @(
            [ordered]@{
                id = 'candidate-1'
                path = 'active/candidate-1/state.json'
                sha256 = $candidateHash
            }
        )
        cleanup_state = 'pending'
        archive_index = 'archive-index.md'
        archive_root = "../archive/$Name"
        archive_snapshot = [ordered]@{
            reference_base = 'state_root'
            id = 'snapshot-1'
            original_sha256 = $originalHash
            manifest = "../archive/$Name/snapshots/snapshot-1/manifest.json"
            bundle = "../archive/$Name/snapshots/snapshot-1/original-control-state.zip"
        }
        shelves_ref_base = 'state_root'
        shelves_ref = "../archive/$Name/snapshots/snapshot-1/original-control-state.zip#original-control-state.json"
        next_safe_action = 'Continue the active candidate.'
    }
    Write-Utf8File -Path (Join-Path $stateRoot 'control.json') -Content ($control | ConvertTo-Json -Depth 30)

    return [pscustomobject]@{
        Root = $stateRoot
        CandidatePath = $candidatePath
        Control = $control
        ArchiveRoot = $archiveRoot
        SnapshotRoot = $snapshotRoot
        OriginalHash = $originalHash
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Issue {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$Code
    )
    $codes = @($Result.Payload.issues | ForEach-Object { [string]$_.code })
    Assert-True -Condition ($Code -in $codes) -Message "Expected issue '$Code'; actual: $($codes -join ', '). Output: $($Result.Output)"
}

function Invoke-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    $script:executedCases++
    & $Body
    $script:passedCases++
    Write-Host "PASS $Name"
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot -Force

    Invoke-Case -Name 'v1 ignores historical passed reviews and uses last exact record' -Body {
        $fixture = New-Fixture -Name 'v1-history'
        $reviews = @(
            [ordered]@{ reviewed_revision = $fixture.OldRevision; status = 'passed'; verdict = 'review passed' },
            [ordered]@{ reviewed_revision = $fixture.MainRevision; status = 'passed'; verdict = 'review passed' }
        )
        $state = New-State -Fixture $fixture -Reviews $reviews -ReviewGate $null -SchemaVersion 1
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 0) -Message $result.Output
        Assert-True -Condition ($result.Payload.wip_usage.pending_reviews -eq 0) -Message 'Historical reviews must not consume pending-review WIP.'
    }

    Invoke-Case -Name 'v1 ignores legacy status and verdict vocabulary on non-current history' -Body {
        $fixture = New-Fixture -Name 'v1-legacy-history'
        $reviews = @(
            [ordered]@{ reviewed_revision = $fixture.OldRevision; status = 'completed'; verdict = 'review failed' },
            [ordered]@{ reviewed_revision = $fixture.OldRevision; status = 'failed'; verdict = 'changes requested' },
            [ordered]@{ reviewed_revision = $fixture.MainRevision; status = 'passed'; verdict = 'review passed' }
        )
        $state = New-State -Fixture $fixture -Reviews $reviews -ReviewGate $null -SchemaVersion 1
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 0) -Message $result.Output
    }

    Invoke-Case -Name 'v1 fails closed without a current exact review' -Body {
        $fixture = New-Fixture -Name 'v1-no-current'
        $reviews = @([ordered]@{ reviewed_revision = $fixture.OldRevision; status = 'passed'; verdict = 'review passed' })
        $state = New-State -Fixture $fixture -Reviews $reviews -ReviewGate $null -SchemaVersion 1
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Missing current exact review must fail.'
        Assert-Issue -Result $result -Code 'current_review_binding_missing'
    }

    Invoke-Case -Name 'v2 explicit exact gate ignores unrelated historical pending review' -Body {
        $fixture = New-Fixture -Name 'v2-exact'
        $reviews = @(
            [ordered]@{ review_id = 'historical-pending'; reviewed_revision = $fixture.OldRevision; status = 'pending' },
            [ordered]@{ review_id = 'current-pass'; reviewed_revision = $fixture.MainRevision; status = 'passed'; verdict = 'review passed' }
        )
        $gate = New-ExactGate -ReviewId 'current-pass' -CandidateRevision $fixture.MainRevision -ReviewedRevision $fixture.MainRevision
        $state = New-State -Fixture $fixture -Reviews $reviews -ReviewGate $gate -WipBudget @{ active_repairs = 2; pending_reviews = 0; integration_batches = 1 }
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 0) -Message $result.Output
        Assert-True -Condition ($result.Payload.wip_usage.pending_reviews -eq 0) -Message 'Only the explicit current gate may consume review WIP.'
    }

    Invoke-Case -Name 'v2 active gate coexists with closed legacy exact fallback' -Body {
        $fixture = New-Fixture -Name 'v2-legacy-closed'
        $activeReview = [ordered]@{ review_id = 'active-exact'; reviewed_revision = $fixture.MainRevision; status = 'passed'; verdict = 'review passed' }
        $activeGate = New-ExactGate -ReviewId 'active-exact' -CandidateRevision $fixture.MainRevision -ReviewedRevision $fixture.MainRevision
        $state = New-State -Fixture $fixture -Reviews @($activeReview) -ReviewGate $activeGate -CandidateStatus 'review'
        $legacyReview = [ordered]@{ reviewed_revision = $fixture.MainRevision; status = 'passed'; verdict = 'review passed' }
        $legacyCandidate = New-HistoricalCandidate -Fixture $fixture -Name 'closed-pass' -Reviews @($legacyReview)
        $state.candidates = @($state.candidates) + @($legacyCandidate)
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 0) -Message $result.Output
    }

    Invoke-Case -Name 'v2 closed legacy fallback still requires an exact pass' -Body {
        $fixture = New-Fixture -Name 'v2-legacy-closed-no-pass'
        $activeReview = [ordered]@{ review_id = 'active-exact'; reviewed_revision = $fixture.MainRevision; status = 'passed'; verdict = 'review passed' }
        $activeGate = New-ExactGate -ReviewId 'active-exact' -CandidateRevision $fixture.MainRevision -ReviewedRevision $fixture.MainRevision
        $state = New-State -Fixture $fixture -Reviews @($activeReview) -ReviewGate $activeGate -CandidateStatus 'review'
        $legacyReview = [ordered]@{ reviewed_revision = $fixture.OldRevision; status = 'passed'; verdict = 'review passed' }
        $legacyCandidate = New-HistoricalCandidate -Fixture $fixture -Name 'closed-no-pass' -Reviews @($legacyReview)
        $state.candidates = @($state.candidates) + @($legacyCandidate)
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Closed legacy candidate without an exact pass must fail.'
        Assert-Issue -Result $result -Code 'legacy_current_review_binding_missing'
        Assert-Issue -Result $result -Code 'terminal_candidate_missing_review'
    }

    Invoke-Case -Name 'v2 inactive legacy exact pending review does not consume WIP' -Body {
        $fixture = New-Fixture -Name 'v2-legacy-paused-pending'
        $activeReview = [ordered]@{ review_id = 'active-exact'; reviewed_revision = $fixture.MainRevision; status = 'passed'; verdict = 'review passed' }
        $activeGate = New-ExactGate -ReviewId 'active-exact' -CandidateRevision $fixture.MainRevision -ReviewedRevision $fixture.MainRevision
        $state = New-State -Fixture $fixture -Reviews @($activeReview) -ReviewGate $activeGate -CandidateStatus 'review' -WipBudget @{ active_repairs = 2; pending_reviews = 0; integration_batches = 1 }
        $legacyPending = [ordered]@{ reviewed_revision = $fixture.MainRevision; status = 'pending' }
        $legacyCandidate = New-HistoricalCandidate -Fixture $fixture -Name 'paused-pending' -Reviews @($legacyPending) -Status 'paused'
        $state.candidates = @($state.candidates) + @($legacyCandidate)
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 0) -Message $result.Output
        Assert-True -Condition ($result.Payload.wip_usage.pending_reviews -eq 0) -Message 'Inactive legacy exact fallback must not consume pending-review WIP.'
        $issueCodes = @($result.Payload.issues | ForEach-Object { [string]$_.code })
        Assert-True -Condition ('wip_pending_reviews_exceeded' -notin $issueCodes) -Message 'Inactive legacy fallback caused ghost pending-review WIP.'
    }

    Invoke-Case -Name 'v2 hot review candidate requires explicit gate' -Body {
        $fixture = New-Fixture -Name 'v2-gate-missing'
        $reviews = @([ordered]@{ review_id = 'current-pass'; reviewed_revision = $fixture.MainRevision; status = 'passed'; verdict = 'review passed' })
        $state = New-State -Fixture $fixture -Reviews $reviews -ReviewGate $null -CandidateStatus 'review'
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Missing v2 gate must fail.'
        Assert-Issue -Result $result -Code 'review_gate_missing'
    }

    Invoke-Case -Name 'administrative direct child inherits an independent reviewed whole-file surface' -Body {
        $fixture = New-Fixture -Name 'admin-pass'
        $null = Add-CandidateCommit -Fixture $fixture -Path 'admin.md' -Content "admin-v2`n"
        $review = [ordered]@{
            review_id = 'admin-pass'
            reviewed_revision = $fixture.MainRevision
            status = 'passed'
            verdict = 'review passed'
            independent = $true
            review_surface = [ordered]@{
                path_semantics = 'whole-file-administrative'
                administrative_paths = @('admin.md')
            }
        }
        $gate = New-AdministrativeGate -Fixture $fixture -ReviewId 'admin-pass' -ReviewedRevision $fixture.MainRevision -Paths @('admin.md')
        $state = New-State -Fixture $fixture -Reviews @($review) -ReviewGate $gate
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 0) -Message $result.Output
    }

    Invoke-Case -Name 'candidate self-declared administrative list cannot replace reviewed surface' -Body {
        $fixture = New-Fixture -Name 'admin-self-declared'
        $null = Add-CandidateCommit -Fixture $fixture -Path 'admin.md' -Content "admin-v2`n"
        $review = [ordered]@{ review_id = 'admin-source'; reviewed_revision = $fixture.MainRevision; status = 'passed'; verdict = 'review passed'; independent = $true }
        $gate = New-AdministrativeGate -Fixture $fixture -ReviewId 'admin-source' -ReviewedRevision $fixture.MainRevision -Paths @('admin.md')
        $gate.proof.administrative_paths = @('admin.md')
        $state = New-State -Fixture $fixture -Reviews @($review) -ReviewGate $gate
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Gate-local path declaration must not be trusted.'
        Assert-Issue -Result $result -Code 'review_gate_administrative_surface_missing'
    }

    Invoke-Case -Name 'mixed-semantic path cannot inherit from a path list' -Body {
        $fixture = New-Fixture -Name 'mixed-reject'
        $null = Add-CandidateCommit -Fixture $fixture -Path 'mixed.json' -Content "{`"product`":`"stable`",`"status`":`"ready`"}`n"
        $review = [ordered]@{
            review_id = 'mixed-source'
            reviewed_revision = $fixture.MainRevision
            status = 'passed'
            verdict = 'review passed'
            independent = $true
            review_surface = [ordered]@{ path_semantics = 'mixed-semantic'; administrative_paths = @('mixed.json') }
        }
        $gate = New-AdministrativeGate -Fixture $fixture -ReviewId 'mixed-source' -ReviewedRevision $fixture.MainRevision -Paths @('mixed.json')
        $state = New-State -Fixture $fixture -Reviews @($review) -ReviewGate $gate
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Mixed semantic path inheritance must fail.'
        Assert-Issue -Result $result -Code 'review_gate_administrative_scope_invalid'
    }

    Invoke-Case -Name 'administrative proof rejects a non-direct descendant' -Body {
        $fixture = New-Fixture -Name 'admin-not-direct'
        $null = Add-CandidateCommit -Fixture $fixture -Path 'admin.md' -Content "admin-v2`n" -Message 'admin one'
        $null = Add-CandidateCommit -Fixture $fixture -Path 'admin.md' -Content "admin-v3`n" -Message 'admin two'
        $review = [ordered]@{
            review_id = 'admin-source'
            reviewed_revision = $fixture.MainRevision
            status = 'passed'
            verdict = 'review passed'
            independent = $true
            review_surface = [ordered]@{ path_semantics = 'whole-file-administrative'; administrative_paths = @('admin.md') }
        }
        $gate = New-AdministrativeGate -Fixture $fixture -ReviewId 'admin-source' -ReviewedRevision $fixture.MainRevision -Paths @('admin.md')
        $state = New-State -Fixture $fixture -Reviews @($review) -ReviewGate $gate
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Non-direct descendant inheritance must fail.'
        Assert-Issue -Result $result -Code 'review_gate_administrative_parent_invalid'
    }

    Invoke-Case -Name 'administrative proof rejects non-administrative mode and blob drift' -Body {
        $fixture = New-Fixture -Name 'admin-product-drift'
        Write-Utf8File -Path (Join-Path $fixture.Worktree 'admin.md') -Content "admin-v2`n"
        Write-Utf8File -Path (Join-Path $fixture.Worktree 'product.txt') -Content "product-tampered`n"
        $null = Invoke-GitText -Repository $fixture.Worktree -Arguments @('add', '--', 'admin.md', 'product.txt')
        $null = Invoke-GitText -Repository $fixture.Worktree -Arguments @('update-index', '--chmod=+x', 'product.txt')
        $null = Invoke-GitText -Repository $fixture.Worktree -Arguments @('commit', '-m', 'admin plus product drift')
        $fixture.CandidateRevision = @(Invoke-GitText -Repository $fixture.Worktree -Arguments @('rev-parse', 'HEAD'))[0]
        $review = [ordered]@{
            review_id = 'admin-source'
            reviewed_revision = $fixture.MainRevision
            status = 'passed'
            verdict = 'review passed'
            independent = $true
            review_surface = [ordered]@{ path_semantics = 'whole-file-administrative'; administrative_paths = @('admin.md') }
        }
        $gate = New-AdministrativeGate -Fixture $fixture -ReviewId 'admin-source' -ReviewedRevision $fixture.MainRevision -Paths @('admin.md')
        $state = New-State -Fixture $fixture -Reviews @($review) -ReviewGate $gate
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Non-administrative mode/blob drift must fail.'
        Assert-Issue -Result $result -Code 'review_gate_administrative_diff_scope_mismatch'
        Assert-Issue -Result $result -Code 'review_gate_administrative_surface_changed'
        Assert-Issue -Result $result -Code 'review_gate_administrative_digest_mismatch'
    }

    Invoke-Case -Name 'repository verifier extension fails closed until executable verification exists' -Body {
        $fixture = New-Fixture -Name 'verifier-unsupported'
        $null = Add-CandidateCommit -Fixture $fixture -Path 'mixed.json' -Content "{`"product`":`"stable`",`"status`":`"ready`"}`n"
        $review = [ordered]@{ review_id = 'mixed-source'; reviewed_revision = $fixture.MainRevision; status = 'passed'; verdict = 'review passed' }
        $gate = [ordered]@{
            review_id = 'mixed-source'
            candidate_revision = $fixture.CandidateRevision
            binding = 'repository-verifier'
            proof = [ordered]@{ reviewed_revision = $fixture.MainRevision; receipt = [ordered]@{ verdict = 'passed' } }
        }
        $state = New-State -Fixture $fixture -Reviews @($review) -ReviewGate $gate
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Unimplemented verifier binding must fail closed.'
        Assert-Issue -Result $result -Code 'review_gate_verifier_unsupported'
    }

    Invoke-Case -Name 'wip usage counts only the current pending review gate' -Body {
        $fixture = New-Fixture -Name 'wip-review'
        $reviews = @(
            [ordered]@{ review_id = 'old-pending'; reviewed_revision = $fixture.OldRevision; status = 'pending' },
            [ordered]@{ review_id = 'current-pending'; reviewed_revision = $fixture.MainRevision; status = 'pending' }
        )
        $gate = New-ExactGate -ReviewId 'current-pending' -CandidateRevision $fixture.MainRevision -ReviewedRevision $fixture.MainRevision
        $state = New-State -Fixture $fixture -Reviews $reviews -ReviewGate $gate -CandidateStatus 'review' -WipBudget @{ active_repairs = 2; pending_reviews = 0; integration_batches = 1 }
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Current pending gate must consume WIP.'
        Assert-Issue -Result $result -Code 'wip_pending_reviews_exceeded'
        Assert-True -Condition ($result.Payload.wip_usage.pending_reviews -eq 1) -Message 'Only one current pending gate should be counted.'
    }

    Invoke-Case -Name 'integration usage derives from current-epoch active intents' -Body {
        $fixture = New-Fixture -Name 'wip-integration'
        $state = New-State -Fixture $fixture -Reviews @() -ReviewGate $null -CandidateStatus 'implementation' -WipBudget @{ active_repairs = 2; pending_reviews = 2; integration_batches = 1 } -IntegrationIntents @(
            [ordered]@{ id = 'batch-a'; status = 'running'; run_epoch = 1 },
            [ordered]@{ id = 'batch-b'; status = 'committing'; run_epoch = 1 },
            [ordered]@{ id = 'old-done'; status = 'completed'; run_epoch = 0 }
        )
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Two active integration intents must exceed a limit of one.'
        Assert-Issue -Result $result -Code 'wip_integration_batches_exceeded'
        Assert-True -Condition ($result.Payload.wip_usage.integration_batches -eq 2) -Message 'Derived integration usage should be two.'
    }

    Invoke-Case -Name 'ambiguous stale active integration intent reports unknown usage' -Body {
        $fixture = New-Fixture -Name 'wip-integration-stale'
        $state = New-State -Fixture $fixture -Reviews @() -ReviewGate $null -CandidateStatus 'implementation' -IntegrationIntents @(
            [ordered]@{ id = 'stale-batch'; status = 'running'; run_epoch = 0 }
        )
        $result = Invoke-Reconciler -Fixture $fixture -State $state
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Stale active integration intent must fail.'
        Assert-Issue -Result $result -Code 'integration_intent_epoch_mismatch'
        Assert-True -Condition ($null -eq $result.Payload.wip_usage.integration_batches) -Message 'Ambiguous integration usage must be null/unknown.'
    }

    Invoke-Case -Name 'v3 directory resolves only bounded hot control and active candidate refs' -Body {
        $fixture = New-Fixture -Name 'v3-directory'
        $v3 = New-V3StateRoot -Fixture $fixture
        $result = Invoke-ReconcilerPath -Fixture $fixture -StatePath $v3.Root
        Assert-True -Condition ($result.ExitCode -eq 0) -Message $result.Output
        Assert-True -Condition ($result.Payload.declared_candidate_count -eq 1) -Message 'One active candidate ref should be materialized.'
        Assert-True -Condition ([string]$result.Payload.state_root -eq $v3.Root.ToLowerInvariant()) -Message 'Resolved v3 state root must be reported.'
    }

    Invoke-Case -Name 'v3 pointer resolves the directory entrypoint' -Body {
        $fixture = New-Fixture -Name 'v3-pointer'
        $v3 = New-V3StateRoot -Fixture $fixture -Name 'state-root'
        $pointerPath = Join-Path $fixture.Root 'legacy-state.json'
        $pointer = [ordered]@{
            schema_version = 3
            pointer_format = 'series-directory-pointer-v3'
            state_root = 'state-root'
            control = 'control.json'
            migrated_from_sha256 = $v3.OriginalHash
            archive_manifest = 'archive/state-root/snapshots/snapshot-1/manifest.json'
        }
        Write-Utf8File -Path $pointerPath -Content ($pointer | ConvertTo-Json -Depth 10)
        $result = Invoke-ReconcilerPath -Fixture $fixture -StatePath $pointerPath
        Assert-True -Condition ($result.ExitCode -eq 0) -Message $result.Output
        Assert-True -Condition ([string]$result.Payload.state_root -eq $v3.Root.ToLowerInvariant()) -Message 'Pointer must resolve beneath its own directory.'
    }

    Invoke-Case -Name 'v3 default reconciliation rejects unreachable declared cold evidence' -Body {
        $fixture = New-Fixture -Name 'v3-cold-missing'
        $v3 = New-V3StateRoot -Fixture $fixture
        Remove-Item -LiteralPath (Join-Path $v3.SnapshotRoot 'manifest.json') -Force
        $result = Invoke-ReconcilerPath -Fixture $fixture -StatePath $v3.Root
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Missing declared archive evidence must fail.'
        Assert-Issue -Result $result -Code 'state_archive_ref_missing'
    }

    Invoke-Case -Name 'v3 pointer identity must match the directory archive snapshot' -Body {
        $fixture = New-Fixture -Name 'v3-pointer-identity'
        $v3 = New-V3StateRoot -Fixture $fixture -Name 'state-root'
        $pointerPath = Join-Path $fixture.Root 'legacy-state.json'
        $pointer = [ordered]@{
            schema_version = 3
            pointer_format = 'series-directory-pointer-v3'
            state_root = 'state-root'
            control = 'control.json'
            migrated_from_sha256 = ('f' * 64)
            archive_manifest = 'archive/state-root/snapshots/snapshot-1/manifest.json'
        }
        Write-Utf8File -Path $pointerPath -Content ($pointer | ConvertTo-Json -Depth 10)
        $result = Invoke-ReconcilerPath -Fixture $fixture -StatePath $pointerPath
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Pointer/control archive identity mismatch must fail.'
        Assert-Issue -Result $result -Code 'state_archive_identity_mismatch'
    }

    Invoke-Case -Name 'v3 explicit cold audit verifies the manifest and bundled original hash' -Body {
        $fixture = New-Fixture -Name 'v3-cold-audit'
        $v3 = New-V3StateRoot -Fixture $fixture
        $result = Invoke-ReconcilerPath -Fixture $fixture -StatePath $v3.Root -AuditArchive
        Assert-True -Condition ($result.ExitCode -eq 0) -Message $result.Output
        $manifestPath = Join-Path $v3.SnapshotRoot 'manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.source_sha256 = ('0' * 64)
        Write-Utf8File -Path $manifestPath -Content ($manifest | ConvertTo-Json -Depth 10)
        $tampered = Invoke-ReconcilerPath -Fixture $fixture -StatePath $v3.Root -AuditArchive
        Assert-True -Condition ($tampered.ExitCode -eq 2) -Message 'Tampered archive manifest must fail the explicit audit.'
        Assert-Issue -Result $tampered -Code 'state_archive_integrity_mismatch'
    }

    Invoke-Case -Name 'v3 rejects candidate refs that traverse a Windows junction' -Body {
        $fixture = New-Fixture -Name 'v3-junction'
        $v3 = New-V3StateRoot -Fixture $fixture
        $candidateRoot = Split-Path -Parent $v3.CandidatePath
        $externalRoot = Join-Path $fixture.Root 'external-candidate-state'
        Move-Item -LiteralPath $candidateRoot -Destination $externalRoot
        $null = New-Item -ItemType Junction -Path $candidateRoot -Target $externalRoot
        $result = Invoke-ReconcilerPath -Fixture $fixture -StatePath $v3.Root
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'A junction-backed candidate ref must fail closed.'
        Assert-Issue -Result $result -Code 'state_reparse_point_forbidden'
    }

    Invoke-Case -Name 'v3 fails closed when an active candidate hash drifts' -Body {
        $fixture = New-Fixture -Name 'v3-hash-drift'
        $v3 = New-V3StateRoot -Fixture $fixture
        Write-Utf8File -Path $v3.CandidatePath -Content "{}`n"
        $result = Invoke-ReconcilerPath -Fixture $fixture -StatePath $v3.Root
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Hash drift must fail.'
        Assert-Issue -Result $result -Code 'candidate_ref_hash_mismatch'
    }

    Invoke-Case -Name 'v3 rejects cold history arrays in the hot control' -Body {
        $fixture = New-Fixture -Name 'v3-hot-history'
        $v3 = New-V3StateRoot -Fixture $fixture
        $v3.Control.closed_candidate_history = @([ordered]@{ id = 'cold-candidate' })
        Write-Utf8File -Path (Join-Path $v3.Root 'control.json') -Content ($v3.Control | ConvertTo-Json -Depth 30)
        $result = Invoke-ReconcilerPath -Fixture $fixture -StatePath $v3.Root
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Cold history in hot control must fail.'
        Assert-Issue -Result $result -Code 'state_hot_history_forbidden'
    }

    Invoke-Case -Name 'v3 enforces the human hot entry line budget' -Body {
        $fixture = New-Fixture -Name 'v3-hot-lines'
        $v3 = New-V3StateRoot -Fixture $fixture
        Write-Utf8File -Path (Join-Path $v3.Root 'HOT.md') -Content ((1..121 | ForEach-Object { "line $_" }) -join "`n")
        $result = Invoke-ReconcilerPath -Fixture $fixture -StatePath $v3.Root
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Oversized HOT.md must fail.'
        Assert-Issue -Result $result -Code 'state_hot_entry_too_large'
    }

    Invoke-Case -Name 'v3 enforces the human hot entry byte budget' -Body {
        $fixture = New-Fixture -Name 'v3-hot-bytes'
        $v3 = New-V3StateRoot -Fixture $fixture
        Write-Utf8File -Path (Join-Path $v3.Root 'HOT.md') -Content ('x' * 16385)
        $result = Invoke-ReconcilerPath -Fixture $fixture -StatePath $v3.Root
        Assert-True -Condition ($result.ExitCode -eq 2) -Message 'Oversized HOT.md bytes must fail.'
        Assert-Issue -Result $result -Code 'state_hot_entry_too_large'
    }

    Write-Host "All $passedCases/$executedCases reconciliation cases passed."
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if (-not $resolvedTestRoot.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($resolvedTestRoot) -notlike 'series-reconcile-*') {
            throw "Refusing to remove unexpected test path: $resolvedTestRoot"
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
