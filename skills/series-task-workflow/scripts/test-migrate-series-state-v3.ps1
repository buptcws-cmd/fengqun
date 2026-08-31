[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$migrationPath = Join-Path $PSScriptRoot 'migrate-series-state-v3.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "series-migrate-$([Guid]::NewGuid().ToString('N'))"

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

function Invoke-Migration {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [Parameter(Mandatory = $true)][string]$ExpectedCurrentMainRevision,
        [switch]$ReplaceSourceWithPointer,
        [string]$PointerPath,
        [string]$ExpectedPointerHash
    )

    $pwshPath = (Get-Process -Id $PID).Path
    $arguments = @(
        '-NoProfile', '-File', $migrationPath,
        '-SourcePath', $SourcePath,
        '-DestinationRoot', $DestinationRoot,
        '-ArchiveRoot', $ArchiveRoot,
        '-ExpectedSourceSha256', $ExpectedHash,
        '-ExpectedCurrentMainRevision', $ExpectedCurrentMainRevision,
        '-NextSafeAction', 'Audit the interrupted writer state, then resume the active slice.'
    )
    if ($ReplaceSourceWithPointer) {
        $arguments += '-ReplaceSourceWithPointer'
    }
    if (-not [string]::IsNullOrWhiteSpace($PointerPath)) {
        $arguments += @('-PointerPath', $PointerPath, '-ExpectedPointerSha256', $ExpectedPointerHash)
    }
    Push-Location $Repository
    try {
        $output = @(& $pwshPath @arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Text = ($output -join [Environment]::NewLine) }
}

function Resolve-Reference {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Reference
    )

    $pathPart = $Reference.Split([char]'#', 2)[0]
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $pathPart))
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

try {
    $null = New-Item -ItemType Directory -Path $testRoot -Force
    $repository = Join-Path $testRoot 'repo'
    $worktree = Join-Path $testRoot 'candidate'
    $null = New-Item -ItemType Directory -Path $repository -Force
    $null = Invoke-GitText -Repository $repository -Arguments @('init', '-b', 'main')
    $null = Invoke-GitText -Repository $repository -Arguments @('config', 'user.name', 'Series Migration Test')
    $null = Invoke-GitText -Repository $repository -Arguments @('config', 'user.email', 'series-migration@example.invalid')
    Write-Utf8File -Path (Join-Path $repository 'product.txt') -Content "product`n"
    $null = Invoke-GitText -Repository $repository -Arguments @('add', '--', 'product.txt')
    $null = Invoke-GitText -Repository $repository -Arguments @('commit', '-m', 'fixture')
    $mainRevision = @(Invoke-GitText -Repository $repository -Arguments @('rev-parse', 'HEAD'))[0]
    $candidateBranch = 'candidate-active-one'
    $null = Invoke-GitText -Repository $repository -Arguments @('worktree', 'add', '-b', $candidateBranch, $worktree, 'main')

    $sourcePath = Join-Path $testRoot 'legacy-control-state.json'
    $destinationRoot = Join-Path $testRoot 'series-state'
    $archiveRoot = Join-Path $testRoot 'archive'
    $activeCandidate = [ordered]@{
        id = 'active-one'
        status = 'implementation'
        worktree = $worktree
        branch = $candidateBranch
        revision = $mainRevision
        tree = ('b' * 40)
        base_revision = ('c' * 40)
        owner_next_action = 'Continue the bounded implementation slice.'
        next_gate = 'Targeted validation, then one current review.'
        validations = @(
            [ordered]@{ name = 'old'; revision = ('c' * 40); status = 'passed'; interrupted = $false; evidence = ('x' * 2000) },
            [ordered]@{ name = 'current'; revision = $mainRevision; status = 'passed'; interrupted = $false; evidence = ('y' * 2000) }
        )
        reviews = @()
    }
    $terminalCandidate = [ordered]@{
        id = 'closed-one'
        status = 'merged'
        worktree = 'C:\fixture\closed-one'
        branch = 'candidate-closed-one'
        revision = ('d' * 40)
        validations = @()
        reviews = @([ordered]@{ reviewed_revision = ('d' * 40); status = 'passed'; verdict = 'review passed' })
    }
    $legacy = [ordered]@{
        schema_version = 1
        series_id = 'migration-test'
        run_epoch = 7
        status = 'active'
        updated_at = '2026-08-27T00:00:00Z'
        main_revision = ('e' * 40)
        execution_mode = 'multi'
        wip_budget = [ordered]@{ active_repairs = 1; pending_reviews = 1; integration_batches = 1 }
        cycle_budget = [ordered]@{
            candidate_attempt_limit = 2
            review_failure_limit = 2
            candidate_attempts = 0
            review_failures = 0
            reset_count = 0
            last_reset = $null
        }
        claims = @(
            [ordered]@{
                id = 'claim-active'
                candidate_id = 'active-one'
                status = 'running'
                run_epoch = 7
                worktree = $worktree
                branch = $candidateBranch
                claimed_at = '2026-08-27T00:00:00Z'
                lease_expires = '2099-01-01T00:00:00Z'
                scope = ('large scope ' * 500)
            },
            [ordered]@{ id = 'claim-closed'; candidate_id = 'closed-one'; status = 'released'; run_epoch = 7 }
        )
        candidates = @($activeCandidate, $terminalCandidate)
        closed_candidate_history = @([ordered]@{ id = 'older-cold-item'; notes = ('history ' * 500) })
        yefeng_parallelization = [ordered]@{
            active_surface_leases = @([ordered]@{ id = 'old-lease'; status = 'released' })
            role_pool = @([ordered]@{ id = 'old-role'; status = 'completed' })
        }
        cleanup_state = 'pending'
        next_safe_action = 'Legacy text that should be replaced.'
        shelved_items = @('second-host proof remains shelved')
    }
    Write-Utf8File -Path $sourcePath -Content ($legacy | ConvertTo-Json -Depth 40)
    $sourceBytes = [System.IO.File]::ReadAllBytes($sourcePath)
    $sourceHash = Get-Sha256Hex -Bytes $sourceBytes

    $migration = Invoke-Migration -Repository $repository -SourcePath $sourcePath -DestinationRoot $destinationRoot -ArchiveRoot $archiveRoot -ExpectedHash $sourceHash -ExpectedCurrentMainRevision $mainRevision -ReplaceSourceWithPointer
    Assert-True -Condition ($migration.ExitCode -eq 0) -Message $migration.Text
    $result = $migration.Text | ConvertFrom-Json

    $pointer = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ($pointer.pointer_format -ceq 'series-directory-pointer-v3') -Message 'Legacy source was not replaced by a v3 pointer.'
    Assert-True -Condition ((Get-Item -LiteralPath $sourcePath).Length -le 4096) -Message 'Pointer exceeds its byte budget.'
    Assert-True -Condition ((Get-Item -LiteralPath (Join-Path $destinationRoot 'control.json')).Length -le 32768) -Message 'control.json exceeds its byte budget.'
    Assert-True -Condition ((Get-Item -LiteralPath (Join-Path $destinationRoot 'HOT.md')).Length -le 16384) -Message 'HOT.md exceeds its byte budget.'
    Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $destinationRoot 'HOT.md') -Encoding UTF8).Count -le 120) -Message 'HOT.md exceeds its line budget.'

    $control = Get-Content -LiteralPath (Join-Path $destinationRoot 'control.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ($control.schema_version -eq 3) -Message 'Migrated control is not schema v3.'
    Assert-True -Condition (@($control.candidate_refs).Count -eq 1) -Message 'Only the active candidate should remain hot.'
    Assert-True -Condition (@($control.claims).Count -eq 1) -Message 'Only the active claim should remain hot.'
    Assert-True -Condition (-not ($control.PSObject.Properties.Name -contains 'candidates')) -Message 'Hot control embedded candidates.'
    Assert-True -Condition (-not ($control.PSObject.Properties.Name -contains 'closed_candidate_history')) -Message 'Hot control embedded closed history.'

    $candidateRef = @($control.candidate_refs)[0]
    $candidatePath = Join-Path $destinationRoot ([string]$candidateRef.path)
    $candidateBytes = [System.IO.File]::ReadAllBytes($candidatePath)
    Assert-True -Condition ((Get-Sha256Hex -Bytes $candidateBytes) -ceq [string]$candidateRef.sha256) -Message 'Active candidate ref hash is invalid.'
    $candidate = [System.Text.UTF8Encoding]::new($false, $true).GetString($candidateBytes) | ConvertFrom-Json
    Assert-True -Condition (@($candidate.validations).Count -le 5) -Message 'Active validation history was not compacted.'
    Assert-True -Condition (@($candidate.reviews).Count -le 1) -Message 'Active review history was not compacted.'
    Assert-True -Condition ((Resolve-Reference -BasePath (Split-Path -Parent $sourcePath) -Reference ([string]$pointer.archive_manifest)) -ceq (Join-Path ([string]$result.archive_snapshot_path) 'manifest.json')) -Message 'Pointer archive_manifest uses the wrong base.'
    Assert-True -Condition (Test-Path -LiteralPath (Resolve-Reference -BasePath (Split-Path -Parent $sourcePath) -Reference ([string]$pointer.archive_manifest)) -PathType Leaf) -Message 'Pointer archive_manifest is unreachable.'
    $resolvedArchiveRoot = Resolve-Reference -BasePath $destinationRoot -Reference ([string]$control.archive_root)
    Assert-True -Condition ($resolvedArchiveRoot -ceq [System.IO.Path]::GetFullPath($archiveRoot)) -Message 'control.archive_root does not resolve to the configured archive root.'
    foreach ($reference in @($control.archive_snapshot.manifest, $control.archive_snapshot.bundle, $control.shelves_ref, $candidate.archive_ref)) {
        Assert-True -Condition (Test-Path -LiteralPath (Resolve-Reference -BasePath $destinationRoot -Reference ([string]$reference)) -PathType Leaf) -Message "Generated archive reference is unreachable: $reference"
    }

    Assert-True -Condition (Test-Path -LiteralPath $result.bundle_path -PathType Leaf) -Message 'Lossless bundle is missing.'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead([string]$result.bundle_path)
    try {
        $entry = $zip.GetEntry('original-control-state.json')
        Assert-True -Condition ($null -ne $entry) -Message 'Bundle does not contain the original state.'
        $memory = [System.IO.MemoryStream]::new()
        try {
            $stream = $entry.Open()
            try { $stream.CopyTo($memory) } finally { $stream.Dispose() }
            Assert-True -Condition ((Get-Sha256Hex -Bytes $memory.ToArray()) -ceq $sourceHash) -Message 'Bundled original hash does not match.'
        }
        finally {
            $memory.Dispose()
        }
    }
    finally {
        $zip.Dispose()
    }

    Assert-True -Condition (@(Get-ChildItem -LiteralPath (Join-Path ([string]$result.archive_snapshot_path) 'candidates') -Filter '*.json').Count -eq 2) -Message 'Per-candidate cold archive is incomplete.'
    Assert-True -Condition ($result.original_sha256 -ceq $sourceHash) -Message 'Migration receipt source hash is wrong.'
    $reconciler = Join-Path $PSScriptRoot 'reconcile-series-state.ps1'
    Push-Location $repository
    try {
        $reconcileOutput = @(& (Get-Process -Id $PID).Path -NoProfile -File $reconciler -StatePath $sourcePath -AuditArchive 2>&1 | ForEach-Object { [string]$_ })
        $reconcileExit = $LASTEXITCODE
    }
    finally { Pop-Location }
    Assert-True -Condition ($reconcileExit -eq 0) -Message ($reconcileOutput -join [Environment]::NewLine)

    $nextDestination = Join-Path $testRoot 'series-state-next'
    $nextArchive = Join-Path $testRoot 'archive-next'
    $archivedOriginal = Join-Path ([string]$result.archive_snapshot_path) 'source-backup.json'
    $pointerHash = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($sourcePath))
    $nextMigration = Invoke-Migration -Repository $repository -SourcePath $archivedOriginal -DestinationRoot $nextDestination -ArchiveRoot $nextArchive -ExpectedHash $sourceHash -ExpectedCurrentMainRevision $mainRevision -PointerPath $sourcePath -ExpectedPointerHash $pointerHash
    Assert-True -Condition ($nextMigration.ExitCode -eq 0) -Message $nextMigration.Text
    $nextResult = $nextMigration.Text | ConvertFrom-Json
    Assert-True -Condition ($nextResult.pointer_replaced -eq $true) -Message 'External v3 pointer replacement was not recorded.'
    $nextPointer = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ($nextPointer.state_root -ceq 'series-state-next') -Message 'External v3 pointer did not switch to the new state root.'
    Push-Location $repository
    try {
        $nextReconcileOutput = @(& (Get-Process -Id $PID).Path -NoProfile -File $reconciler -StatePath $sourcePath -AuditArchive 2>&1 | ForEach-Object { [string]$_ })
        $nextReconcileExit = $LASTEXITCODE
    }
    finally { Pop-Location }
    Assert-True -Condition ($nextReconcileExit -eq 0) -Message ($nextReconcileOutput -join [Environment]::NewLine)

    $failedSource = Join-Path $testRoot 'failed-legacy.json'
    $failedDestination = Join-Path $testRoot 'failed-series'
    $failedArchive = Join-Path $testRoot 'failed-archive'
    $failedLegacy = ($legacy | ConvertTo-Json -Depth 40 | ConvertFrom-Json)
    $failedLegacy.candidates[0].worktree = 'C:\missing\candidate'
    Write-Utf8File -Path $failedSource -Content ($failedLegacy | ConvertTo-Json -Depth 40)
    $failedHash = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($failedSource))
    $failedMigration = Invoke-Migration -Repository $repository -SourcePath $failedSource -DestinationRoot $failedDestination -ArchiveRoot $failedArchive -ExpectedHash $failedHash -ExpectedCurrentMainRevision $mainRevision -ReplaceSourceWithPointer
    Assert-True -Condition ($failedMigration.ExitCode -ne 0) -Message 'A staging state that cannot reconcile must fail migration.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $failedDestination)) -Message 'Failed pre-pointer migration left a final state directory.'
    Assert-True -Condition ((Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($failedSource))) -ceq $failedHash) -Message 'Failed pre-pointer migration changed the source.'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $failedArchive 'snapshots')) -or @(Get-ChildItem -LiteralPath (Join-Path $failedArchive 'snapshots') -Force).Count -eq 0) -Message 'Failed pre-pointer migration left a committed archive snapshot.'

    $lockedSource = Join-Path $testRoot 'locked-legacy.json'
    $lockedDestination = Join-Path $testRoot 'locked-series'
    $lockedArchive = Join-Path $testRoot 'locked-archive'
    Write-Utf8File -Path $lockedSource -Content ($legacy | ConvertTo-Json -Depth 40)
    $lockedHash = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($lockedSource))
    $sourceLock = [System.IO.File]::Open($lockedSource, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $lockedMigration = Invoke-Migration -Repository $repository -SourcePath $lockedSource -DestinationRoot $lockedDestination -ArchiveRoot $lockedArchive -ExpectedHash $lockedHash -ExpectedCurrentMainRevision $mainRevision -ReplaceSourceWithPointer
    }
    finally { $sourceLock.Dispose() }
    Assert-True -Condition ($lockedMigration.ExitCode -ne 0) -Message 'A denied atomic pointer replacement must fail.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $lockedDestination)) -Message 'Failed pointer replacement left a final state directory.'
    Assert-True -Condition ((Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($lockedSource))) -ceq $lockedHash) -Message 'Failed pointer replacement changed the source.'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $lockedArchive 'snapshots')) -or @(Get-ChildItem -LiteralPath (Join-Path $lockedArchive 'snapshots') -Force).Count -eq 0) -Message 'Failed pointer replacement left a committed archive snapshot.'
    Write-Host 'PASS lossless v1 monolith to bounded v3 directory migration'
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if (-not $resolvedTestRoot.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($resolvedTestRoot) -notlike 'series-migrate-*') {
            throw "Refusing to remove unexpected test path: $resolvedTestRoot"
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
