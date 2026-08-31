[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationRoot,
    [Parameter(Mandatory = $true)][string]$ArchiveRoot,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedSourceSha256,
    [ValidatePattern('^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$')][string]$ExpectedCurrentMainRevision,
    [string]$NextSafeAction,
    [switch]$ReplaceSourceWithPointer,
    [string]$PointerPath,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedPointerSha256
)

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$terminalCandidateStatuses = @('done', 'merged', 'cancelled', 'expired', 'abandoned', 'closed')
$activeClaimStatuses = @('claimed', 'running', 'reviewing', 'blocked')
$stagingPaths = [System.Collections.Generic.List[string]]::new()
$destinationCommitted = $false
$archiveCommitted = $false
$pointerCommitted = $false
$finalSnapshotRoot = $null
$sourceFullPath = $null
$sourceBytes = $null
$sourceHash = $null
$destinationFullPath = $null
$archiveFullPath = $null
$pointerTargetFullPath = $null
$pointerTargetBytes = $null
$pointerTargetHash = $null
$pointerTargetParent = $null
$hasPointerReplacement = $false

function Test-Property {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $null -ne $InputObject -and $InputObject.PSObject.Properties.Name -contains $Name
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

function Write-Utf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    [System.IO.File]::WriteAllText($Path, $Content, $script:utf8)
}

function Write-Utf8Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    Write-Utf8Text -Path $Path -Content ($Value | ConvertTo-Json -Depth 100)
}

function Get-SafeArchiveName {
    param([Parameter(Mandatory = $true)][string]$Id)

    $safe = ($Id -replace '[^A-Za-z0-9._-]', '_').Trim('._-')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = 'item'
    }
    if ($safe.Length -gt 80) {
        $safe = $safe.Substring(0, 80)
    }
    $idHash = Get-Sha256Hex -Bytes $script:utf8.GetBytes($Id)
    return "$safe-$($idHash.Substring(0, 12))"
}

function Get-OneLineText {
    param(
        [AllowNull()][object]$Value,
        [int]$MaximumLength = 1200,
        [string]$Fallback = 'See the cold snapshot for details.'
    )

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    $text = ($text -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Fallback
    }
    if ($text.Length -gt $MaximumLength) {
        return $text.Substring(0, $MaximumLength - 1) + '…'
    }
    return $text
}

function New-CompactValidation {
    param([Parameter(Mandatory = $true)][object]$Validation)

    $record = [ordered]@{}
    foreach ($field in @('name', 'revision', 'status', 'interrupted', 'cancelled', 'timed_out', 'incomplete', 'at')) {
        if (Test-Property -InputObject $Validation -Name $field) {
            $record[$field] = $Validation.$field
        }
    }
    return [pscustomobject]$record
}

function New-CompactReview {
    param(
        [Parameter(Mandatory = $true)][object]$Review,
        [Parameter(Mandatory = $true)][string]$ReviewId
    )

    $record = [ordered]@{ review_id = $ReviewId }
    foreach ($field in @('kind', 'reviewer', 'reviewed_revision', 'reviewed_tree', 'reviewed_parent', 'status', 'verdict', 'requested_at', 'started_at', 'completed_at', 'independent', 'review_surface', 'classification')) {
        if (Test-Property -InputObject $Review -Name $field) {
            $record[$field] = $Review.$field
        }
    }
    return [pscustomobject]$record
}

function New-CompactCandidate {
    param(
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][string]$ArchiveReference
    )

    $record = [ordered]@{}
    foreach ($field in @('id', 'status', 'worktree', 'branch', 'revision', 'tree', 'base_revision', 'classification', 'owner_next_action', 'package_verification_criteria', 'next_gate', 'pause_reason')) {
        if (Test-Property -InputObject $Candidate -Name $field) {
            $record[$field] = $Candidate.$field
        }
    }
    $record.archive_ref = $ArchiveReference

    $sourceValidations = if (Test-Property -InputObject $Candidate -Name 'validations') { @($Candidate.validations) } else { @() }
    $record.validations = @($sourceValidations | Select-Object -Last 5 | ForEach-Object { New-CompactValidation -Validation $_ })

    $record.reviews = @()
    $record.review_gate = $null
    $status = [string]$Candidate.status
    if ($status -in @('review', 'implementation-review')) {
        $currentReview = $null
        if ((Test-Property -InputObject $Candidate -Name 'review_gate') -and $null -ne $Candidate.review_gate -and
            (Test-Property -InputObject $Candidate.review_gate -Name 'review_id')) {
            $gateReviewId = [string]$Candidate.review_gate.review_id
            $matches = @($Candidate.reviews | Where-Object { (Test-Property -InputObject $_ -Name 'review_id') -and [string]$_.review_id -ceq $gateReviewId })
            if ($matches.Count -eq 1) {
                $currentReview = $matches[0]
                $record.review_gate = $Candidate.review_gate
            }
        }
        if ($null -eq $currentReview) {
            foreach ($review in @($Candidate.reviews)) {
                if ((Test-Property -InputObject $review -Name 'reviewed_revision') -and [string]$review.reviewed_revision -ceq [string]$Candidate.revision) {
                    $currentReview = $review
                }
            }
            if ($null -ne $currentReview) {
                $reviewId = if ((Test-Property -InputObject $currentReview -Name 'review_id') -and -not [string]::IsNullOrWhiteSpace([string]$currentReview.review_id)) {
                    [string]$currentReview.review_id
                }
                else {
                    "migrated-$([string]$Candidate.id)-$(([string]$Candidate.revision).Substring(0, [Math]::Min(12, ([string]$Candidate.revision).Length)))"
                }
                $record.review_gate = [ordered]@{
                    review_id = $reviewId
                    candidate_revision = [string]$Candidate.revision
                    binding = 'exact'
                    proof = [ordered]@{ reviewed_revision = [string]$Candidate.revision }
                }
            }
        }
        if ($null -ne $currentReview) {
            $reviewId = if ($null -ne $record.review_gate) { [string]$record.review_gate.review_id } else { [string]$currentReview.review_id }
            $record.reviews = @((New-CompactReview -Review $currentReview -ReviewId $reviewId))
        }
    }
    return [pscustomobject]$record
}

function Remove-ValidatedStagingPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $name = [System.IO.Path]::GetFileName($fullPath)
    if ($name -notlike '*.staging-*' -and $name -notlike '.staging-*') {
        throw "Refusing to remove a non-staging path: $fullPath"
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

function Test-ExistingPathContainsReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $rootFullPath = [System.IO.Path]::GetFullPath($RootPath).TrimEnd([char[]]@('\', '/'))
    $targetFullPath = [System.IO.Path]::GetFullPath($TargetPath)
    $prefix = $rootFullPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $targetFullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $relative = [System.IO.Path]::GetRelativePath($rootFullPath, $targetFullPath)
    $current = $rootFullPath
    foreach ($segment in @($relative -split '[\\/]')) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            continue
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $true
        }
    }
    return $false
}

function Remove-ValidatedCommittedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedParent,
        [Parameter(Mandatory = $true)][string]$ExpectedName
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    $parent = [System.IO.Path]::GetFullPath((Split-Path -Parent $fullPath)).TrimEnd([char[]]@('\', '/'))
    if (-not $parent.Equals([System.IO.Path]::GetFullPath($ExpectedParent).TrimEnd([char[]]@('\', '/')), [System.StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($fullPath) -cne $ExpectedName) {
        throw "Refusing to remove unexpected committed directory: $fullPath"
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

function Invoke-StagedReconciliation {
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [switch]$AuditArchive
    )

    $reconcilerPath = Join-Path $PSScriptRoot 'reconcile-series-state.ps1'
    if (-not (Test-Path -LiteralPath $reconcilerPath -PathType Leaf)) {
        throw "Reconciler not found: $reconcilerPath"
    }
    $arguments = @('-NoProfile', '-File', $reconcilerPath, '-StatePath', $StatePath)
    if ($AuditArchive) {
        $arguments += '-AuditArchive'
    }
    $output = @(& (Get-Process -Id $PID).Path @arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Staged v3 reconciliation failed (exit $exitCode): $($output -join [Environment]::NewLine)"
    }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json)
}

try {
    $sourceFullPath = [System.IO.Path]::GetFullPath($SourcePath)
    $destinationFullPath = [System.IO.Path]::GetFullPath($DestinationRoot).TrimEnd([char[]]@('\', '/'))
    $archiveFullPath = [System.IO.Path]::GetFullPath($ArchiveRoot).TrimEnd([char[]]@('\', '/'))
    $sourceParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $sourceFullPath)).TrimEnd([char[]]@('\', '/'))
    $destinationParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $destinationFullPath)).TrimEnd([char[]]@('\', '/'))
    if (-not (Test-Path -LiteralPath $sourceFullPath -PathType Leaf)) {
        throw "Source state does not exist: $sourceFullPath"
    }
    if (Test-Path -LiteralPath $destinationFullPath) {
        throw "Destination state root already exists: $destinationFullPath"
    }
    if ($destinationFullPath -eq $archiveFullPath -or $destinationFullPath -eq $sourceParent) {
        throw 'DestinationRoot must be a new child directory and must differ from ArchiveRoot and the source parent.'
    }
    if ($ReplaceSourceWithPointer -and -not [string]::IsNullOrWhiteSpace($PointerPath)) {
        throw 'ReplaceSourceWithPointer and PointerPath are mutually exclusive.'
    }
    if (-not [string]::IsNullOrWhiteSpace($PointerPath) -and [string]::IsNullOrWhiteSpace($ExpectedPointerSha256)) {
        throw 'PointerPath requires ExpectedPointerSha256.'
    }
    if ([string]::IsNullOrWhiteSpace($PointerPath) -and -not [string]::IsNullOrWhiteSpace($ExpectedPointerSha256)) {
        throw 'ExpectedPointerSha256 requires PointerPath.'
    }
    if ($ReplaceSourceWithPointer) {
        $pointerTargetFullPath = $sourceFullPath
        $pointerTargetBytes = [System.IO.File]::ReadAllBytes($sourceFullPath)
        $pointerTargetHash = Get-Sha256Hex -Bytes $pointerTargetBytes
        $pointerTargetParent = $sourceParent
        $hasPointerReplacement = $true
    }
    elseif (-not [string]::IsNullOrWhiteSpace($PointerPath)) {
        $pointerTargetFullPath = [System.IO.Path]::GetFullPath($PointerPath)
        if (-not (Test-Path -LiteralPath $pointerTargetFullPath -PathType Leaf)) {
            throw "PointerPath does not exist: $pointerTargetFullPath"
        }
        $pointerTargetBytes = [System.IO.File]::ReadAllBytes($pointerTargetFullPath)
        $pointerTargetHash = Get-Sha256Hex -Bytes $pointerTargetBytes
        if ($pointerTargetHash -cne $ExpectedPointerSha256.ToLowerInvariant()) {
            throw "Pointer SHA-256 mismatch. Expected $($ExpectedPointerSha256.ToLowerInvariant()); actual $pointerTargetHash."
        }
        try {
            $existingPointer = $script:utf8.GetString($pointerTargetBytes) | ConvertFrom-Json
        }
        catch {
            throw "PointerPath is not valid strict UTF-8 JSON: $($_.Exception.Message)"
        }
        if (-not (Test-Property -InputObject $existingPointer -Name 'pointer_format') -or [string]$existingPointer.pointer_format -cne 'series-directory-pointer-v3') {
            throw 'PointerPath must contain an existing series-directory-pointer-v3 document.'
        }
        $pointerTargetParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $pointerTargetFullPath)).TrimEnd([char[]]@('\', '/'))
        $hasPointerReplacement = $true
    }
    if ($hasPointerReplacement -and -not $pointerTargetParent.Equals($destinationParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'A replaced pointer and DestinationRoot must share the same direct parent.'
    }
    $archiveChildReference = [System.IO.Path]::GetRelativePath($destinationParent, $archiveFullPath).Replace('\', '/')
    if ([System.IO.Path]::IsPathRooted($archiveChildReference) -or $archiveChildReference -eq '.' -or
        $archiveChildReference -match '(^|/)(\.|\.\.)($|/)' -or $archiveChildReference.StartsWith('../', [System.StringComparison]::Ordinal)) {
        throw 'ArchiveRoot must be a non-reparse descendant of DestinationRoot parent.'
    }
    if ($archiveFullPath.StartsWith($destinationFullPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
        $destinationFullPath.StartsWith($archiveFullPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'DestinationRoot and ArchiveRoot must not contain one another.'
    }
    if (Test-ExistingPathContainsReparsePoint -RootPath $destinationParent -TargetPath $archiveFullPath) {
        throw 'ArchiveRoot must not traverse a Windows reparse point.'
    }
    if (Test-ExistingPathContainsReparsePoint -RootPath $destinationParent -TargetPath $destinationFullPath) {
        throw 'DestinationRoot must not traverse a Windows reparse point.'
    }
    $archiveRelativeFromStateRoot = [System.IO.Path]::GetRelativePath($destinationFullPath, $archiveFullPath).Replace('\', '/')
    if ([System.IO.Path]::IsPathRooted($archiveRelativeFromStateRoot) -or -not $archiveRelativeFromStateRoot.StartsWith('../', [System.StringComparison]::Ordinal)) {
        throw 'ArchiveRoot must have a stable relative path from DestinationRoot.'
    }

    $sourceBytes = [System.IO.File]::ReadAllBytes($sourceFullPath)
    $sourceHash = Get-Sha256Hex -Bytes $sourceBytes
    if ($sourceHash -cne $ExpectedSourceSha256.ToLowerInvariant()) {
        throw "Source SHA-256 mismatch. Expected $($ExpectedSourceSha256.ToLowerInvariant()); actual $sourceHash."
    }
    $source = $script:utf8.GetString($sourceBytes) | ConvertFrom-Json
    if (-not (Test-Property -InputObject $source -Name 'schema_version') -or [int]$source.schema_version -notin @(1, 2) -or
        -not (Test-Property -InputObject $source -Name 'candidates') -or -not (Test-Property -InputObject $source -Name 'claims')) {
        throw 'Source must be a schema v1/v2 monolithic series state with candidates and claims.'
    }
    $effectiveMainRevision = [string]$source.main_revision
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCurrentMainRevision)) {
        $actualMainOutput = @(& git -C (Get-Location).Path rev-parse --verify refs/heads/main 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0 -or $actualMainOutput.Count -ne 1) {
            throw "Unable to resolve current refs/heads/main: $($actualMainOutput -join [Environment]::NewLine)"
        }
        $actualMainRevision = $actualMainOutput[0].Trim()
        if ($actualMainRevision -cne $ExpectedCurrentMainRevision.ToLowerInvariant()) {
            throw "Current main revision mismatch. Expected $($ExpectedCurrentMainRevision.ToLowerInvariant()); actual $actualMainRevision."
        }
        $effectiveMainRevision = $actualMainRevision
    }

    $activeCandidates = @($source.candidates | Where-Object { [string]$_.status -notin $terminalCandidateStatuses })
    if ($activeCandidates.Count -gt 3) {
        throw "Refusing to migrate $($activeCandidates.Count) active candidates; v3 permits at most three."
    }
    $activeClaims = @($source.claims | Where-Object { [string]$_.status -in $activeClaimStatuses })
    if ($activeClaims.Count -gt 3) {
        throw "Refusing to migrate $($activeClaims.Count) active claims; v3 permits at most three."
    }

    $now = [DateTimeOffset]::UtcNow
    $snapshotId = "$($now.ToString('yyyyMMddTHHmmssZ'))-$($sourceHash.Substring(0, 12))"
    $archiveSnapshotReference = "$archiveRelativeFromStateRoot/snapshots/$snapshotId"
    $destinationStaging = "$destinationFullPath.staging-$([Guid]::NewGuid().ToString('N'))"
    $archiveParent = Split-Path -Parent $archiveFullPath
    if (-not (Test-Path -LiteralPath $archiveParent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $archiveParent -Force
    }
    if (-not (Test-Path -LiteralPath $archiveFullPath -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $archiveFullPath -Force
    }
    $archiveStaging = Join-Path $archiveFullPath ".staging-$snapshotId-$([Guid]::NewGuid().ToString('N'))"
    $stagingPaths.Add($destinationStaging)
    $stagingPaths.Add($archiveStaging)
    $null = New-Item -ItemType Directory -Path $destinationStaging -Force
    $null = New-Item -ItemType Directory -Path $archiveStaging -Force

    $manifest = [ordered]@{
        schema_version = 1
        snapshot_id = $snapshotId
        created_at = $now.ToString('o')
        source_path = $sourceFullPath
        source_sha256 = $sourceHash
        source_bytes = $sourceBytes.Length
        source_schema_version = [int]$source.schema_version
        source_main_revision = $source.main_revision
        effective_main_revision = $effectiveMainRevision
        run_epoch = $source.run_epoch
        candidate_count = @($source.candidates).Count
        active_candidate_count = $activeCandidates.Count
        claim_count = @($source.claims).Count
        active_claim_count = $activeClaims.Count
    }
    Write-Utf8Json -Path (Join-Path $archiveStaging 'manifest.json') -Value $manifest
    Write-Utf8Json -Path (Join-Path $archiveStaging 'claims.json') -Value @($source.claims)
    if (Test-Property -InputObject $source -Name 'yefeng_parallelization') {
        Write-Utf8Json -Path (Join-Path $archiveStaging 'yefeng-parallelization.json') -Value $source.yefeng_parallelization
    }
    $candidateArchiveIndex = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in @($source.candidates)) {
        $candidateId = [string]$candidate.id
        $archiveName = Get-SafeArchiveName -Id $candidateId
        $candidateArchivePath = Join-Path $archiveStaging "candidates\$archiveName.json"
        Write-Utf8Json -Path $candidateArchivePath -Value $candidate
        $candidateArchiveIndex.Add([pscustomobject]@{
            id = $candidateId
            status = [string]$candidate.status
            file = "candidates/$archiveName.json"
        })
    }
    Write-Utf8Json -Path (Join-Path $archiveStaging 'candidate-index.json') -Value @($candidateArchiveIndex)

    $bundleStagingPath = Join-Path $archiveStaging 'original-control-state.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $bundleStream = [System.IO.File]::Open($bundleStagingPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $zip = [System.IO.Compression.ZipArchive]::new($bundleStream, [System.IO.Compression.ZipArchiveMode]::Create, $true, $script:utf8)
        try {
            $stateEntry = $zip.CreateEntry('original-control-state.json', [System.IO.Compression.CompressionLevel]::Optimal)
            $stateEntryStream = $stateEntry.Open()
            try { $stateEntryStream.Write($sourceBytes, 0, $sourceBytes.Length) } finally { $stateEntryStream.Dispose() }
            $manifestBytes = $script:utf8.GetBytes(($manifest | ConvertTo-Json -Depth 20))
            $manifestEntry = $zip.CreateEntry('manifest.json', [System.IO.Compression.CompressionLevel]::Optimal)
            $manifestEntryStream = $manifestEntry.Open()
            try { $manifestEntryStream.Write($manifestBytes, 0, $manifestBytes.Length) } finally { $manifestEntryStream.Dispose() }
        }
        finally {
            $zip.Dispose()
        }
    }
    finally {
        $bundleStream.Dispose()
    }

    $verifyZip = [System.IO.Compression.ZipFile]::OpenRead($bundleStagingPath)
    try {
        $stateEntry = $verifyZip.GetEntry('original-control-state.json')
        if ($null -eq $stateEntry) {
            throw 'Lossless bundle is missing original-control-state.json.'
        }
        $verifyMemory = [System.IO.MemoryStream]::new()
        try {
            $entryStream = $stateEntry.Open()
            try { $entryStream.CopyTo($verifyMemory) } finally { $entryStream.Dispose() }
            $bundledHash = Get-Sha256Hex -Bytes $verifyMemory.ToArray()
        }
        finally {
            $verifyMemory.Dispose()
        }
    }
    finally {
        $verifyZip.Dispose()
    }
    if ($bundledHash -cne $sourceHash) {
        throw "Lossless bundle verification failed. Expected $sourceHash; actual $bundledHash."
    }

    $candidateRefs = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $activeCandidates) {
        $candidateId = [string]$candidate.id
        if ($candidateId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
            throw "Active candidate id is not v3-path-safe: $candidateId"
        }
        $archiveName = Get-SafeArchiveName -Id $candidateId
        $archiveReference = "$archiveSnapshotReference/candidates/$archiveName.json"
        $compactCandidate = New-CompactCandidate -Candidate $candidate -ArchiveReference $archiveReference
        $compactCandidate | Add-Member -NotePropertyName archive_ref_base -NotePropertyValue 'state_root' -Force
        $relativeCandidatePath = "active/$candidateId/state.json"
        $candidatePath = Join-Path $destinationStaging ($relativeCandidatePath.Replace('/', '\'))
        Write-Utf8Json -Path $candidatePath -Value $compactCandidate
        $candidateLength = (Get-Item -LiteralPath $candidatePath).Length
        if ($candidateLength -gt 65536) {
            throw "Compacted candidate '$candidateId' still exceeds 65536 bytes ($candidateLength)."
        }
        $candidateRefs.Add([pscustomobject]@{
            id = $candidateId
            path = $relativeCandidatePath
            sha256 = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($candidatePath))
        })
    }

    $compactClaims = @($activeClaims | ForEach-Object {
        $claim = [ordered]@{}
        foreach ($field in @('id', 'candidate_id', 'status', 'run_epoch', 'worktree', 'branch', 'claimed_at', 'lease_expires')) {
            if (Test-Property -InputObject $_ -Name $field) {
                $claim[$field] = $_.$field
            }
        }
        $claim.archive_ref_base = 'state_root'
        $claim.archive_ref = "$archiveSnapshotReference/claims.json"
        [pscustomobject]$claim
    })

    $sourceCycle = $source.cycle_budget
    $compactCycle = [ordered]@{
        candidate_attempt_limit = $sourceCycle.candidate_attempt_limit
        review_failure_limit = $sourceCycle.review_failure_limit
        candidate_attempts = $sourceCycle.candidate_attempts
        review_failures = $sourceCycle.review_failures
        reset_count = $sourceCycle.reset_count
        last_reset = $null
    }
    if ([int]$sourceCycle.reset_count -gt 0) {
        $resetAt = if ((Test-Property -InputObject $sourceCycle -Name 'last_reset') -and $null -ne $sourceCycle.last_reset -and (Test-Property -InputObject $sourceCycle.last_reset -Name 'at')) {
            $sourceCycle.last_reset.at
        }
        else {
            $now.ToString('o')
        }
        $resetReference = "Cold reset evidence: $archiveSnapshotReference/original-control-state.zip#original-control-state.json"
        $compactCycle.last_reset = [ordered]@{
            at = $resetAt
            reason = $resetReference
            changed_direction = $resetReference
            acceptance_matrix = $resetReference
            authorized_by = $resetReference
        }
    }

    $effectiveNextAction = if (-not [string]::IsNullOrWhiteSpace($NextSafeAction)) {
        Get-OneLineText -Value $NextSafeAction -MaximumLength 4096
    }
    elseif (Test-Property -InputObject $source -Name 'next_safe_action') {
        Get-OneLineText -Value $source.next_safe_action -MaximumLength 4096
    }
    else {
        'Reconcile the v3 directory state before resuming work.'
    }
    $control = [ordered]@{
        schema_version = 3
        state_format = 'series-directory-v3'
        series_id = if (Test-Property -InputObject $source -Name 'series_id') { $source.series_id } else { 'series' }
        run_epoch = $source.run_epoch
        status = $source.status
        updated_at = $now.ToString('o')
        main_revision = $effectiveMainRevision
        execution_mode = if (Test-Property -InputObject $source -Name 'execution_mode') { $source.execution_mode } else { 'solo' }
        wip_budget = $source.wip_budget
        cycle_budget = $compactCycle
        claims = $compactClaims
        candidate_refs = @($candidateRefs)
        integration_intents = @()
        cleanup_state = if ([string]$source.status -eq 'closed') { $source.cleanup_state } else { 'pending' }
        archive_index = 'archive-index.md'
        archive_root = $archiveRelativeFromStateRoot
        archive_snapshot = [ordered]@{
            reference_base = 'state_root'
            id = $snapshotId
            original_sha256 = $sourceHash
            manifest = "$archiveSnapshotReference/manifest.json"
            bundle = "$archiveSnapshotReference/original-control-state.zip"
        }
        next_safe_action = $effectiveNextAction
        shelves_ref_base = 'state_root'
        shelves_ref = "$archiveSnapshotReference/original-control-state.zip#original-control-state.json"
    }
    $controlPath = Join-Path $destinationStaging 'control.json'
    Write-Utf8Json -Path $controlPath -Value $control
    $controlLength = (Get-Item -LiteralPath $controlPath).Length
    if ($controlLength -gt 32768) {
        throw "Compacted control.json exceeds 32768 bytes ($controlLength)."
    }

    $hotLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(
        '# Series current truth (v3)',
        '',
        '> Default read boundary. Load this file and control.json only; follow archive pointers on demand.',
        '',
        "- Series: $($control.series_id)",
        "- Run epoch: $($control.run_epoch)",
        "- Status: $($control.status)",
        "- Main revision: $($control.main_revision)",
        "- Active candidates: $($activeCandidates.Count)",
        "- Active claims: $($activeClaims.Count)",
        "- Lossless source SHA-256: $sourceHash",
        '',
        '## Next safe action',
        '',
        $effectiveNextAction,
        '',
        '## Active candidates',
        ''
    )) { $hotLines.Add($line) }
    if ($activeCandidates.Count -eq 0) {
        $hotLines.Add('- None.')
    }
    else {
        foreach ($candidate in $activeCandidates) {
            $hotLines.Add("- $($candidate.id): status=$($candidate.status); revision=$($candidate.revision)")
            $hotLines.Add("  - Next: $(Get-OneLineText -Value $candidate.owner_next_action -MaximumLength 1200)")
            $hotLines.Add("  - Gate: $(Get-OneLineText -Value $candidate.next_gate -MaximumLength 1200)")
            $hotLines.Add("  - State: active/$($candidate.id)/state.json")
        }
    }
    foreach ($line in @(
        '',
        '## Cold history',
        '',
        "- Index: archive-index.md",
        "- Snapshot: $snapshotId",
        "- Bundle: $($control.archive_snapshot.bundle)",
        '',
        '## Loader rules',
        '',
        '- Never recursively load this directory.',
        '- Load an active candidate state only when operating that candidate.',
        '- Load archive material only for an explicit historical question or exact evidence check.',
        '- Archive terminal candidates and superseded evidence immediately.'
    )) { $hotLines.Add($line) }
    $hotPath = Join-Path $destinationStaging 'HOT.md'
    Write-Utf8Text -Path $hotPath -Content (($hotLines -join "`n") + "`n")
    $hotLength = (Get-Item -LiteralPath $hotPath).Length
    if ($hotLines.Count -gt 120 -or $hotLength -gt 16384) {
        throw "HOT.md exceeds its budget: $($hotLines.Count) lines, $hotLength bytes."
    }

    $archiveIndexLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(
        '# Series archive index',
        '',
        '> Cold material is not part of startup context. Open only the named record needed for a historical or evidence question.',
        '',
        "## Snapshot $snapshotId",
        '',
        "- Original SHA-256: $sourceHash",
        "- Original bytes: $($sourceBytes.Length)",
        "- Lossless bundle: $($control.archive_snapshot.bundle)",
        "- Manifest: $($control.archive_snapshot.manifest)",
        "- Claims: $archiveSnapshotReference/claims.json",
        '',
        '### Candidates',
        ''
    )) { $archiveIndexLines.Add($line) }
    foreach ($entry in $candidateArchiveIndex) {
        $archiveIndexLines.Add("- $($entry.id) ($($entry.status)): $archiveSnapshotReference/$($entry.file)")
    }
    Write-Utf8Text -Path (Join-Path $destinationStaging 'archive-index.md') -Content (($archiveIndexLines -join "`n") + "`n")

    $finalSnapshotRoot = Join-Path $archiveFullPath "snapshots\$snapshotId"
    if (Test-Path -LiteralPath $finalSnapshotRoot) {
        throw "Archive snapshot already exists: $finalSnapshotRoot"
    }
    $snapshotParent = Split-Path -Parent $finalSnapshotRoot
    if (-not (Test-Path -LiteralPath $snapshotParent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $snapshotParent -Force
    }
    $bundleHash = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($bundleStagingPath))
    $manifest.bundle_sha256 = $bundleHash
    Write-Utf8Json -Path (Join-Path $archiveStaging 'manifest.json') -Value $manifest

    $currentSourceHash = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($sourceFullPath))
    if ($currentSourceHash -cne $sourceHash) {
        throw "Source changed before commit. Expected $sourceHash; actual $currentSourceHash."
    }
    [System.IO.Directory]::Move($archiveStaging, $finalSnapshotRoot)
    $null = $stagingPaths.Remove($archiveStaging)
    $archiveCommitted = $true
    $bundleFinalPath = Join-Path $finalSnapshotRoot 'original-control-state.zip'
    $externalManifestPath = Join-Path $finalSnapshotRoot 'manifest.json'
    $stagingReconciliation = Invoke-StagedReconciliation -StatePath $destinationStaging -AuditArchive

    [System.IO.Directory]::Move($destinationStaging, $destinationFullPath)
    $null = $stagingPaths.Remove($destinationStaging)
    $destinationCommitted = $true

    if ($hasPointerReplacement) {
        $currentSourceHash = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($sourceFullPath))
        if ($currentSourceHash -cne $sourceHash) {
            throw "Source changed before pointer replacement. Expected $sourceHash; actual $currentSourceHash."
        }
        $currentPointerTargetHash = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($pointerTargetFullPath))
        if ($currentPointerTargetHash -cne $pointerTargetHash) {
            throw "Pointer target changed before replacement. Expected $pointerTargetHash; actual $currentPointerTargetHash."
        }
        $pointerManifestReference = [System.IO.Path]::GetRelativePath($pointerTargetParent, $externalManifestPath).Replace('\', '/')
        if ([System.IO.Path]::IsPathRooted($pointerManifestReference) -or $pointerManifestReference.StartsWith('../', [System.StringComparison]::Ordinal)) {
            throw 'archive_manifest must be a safe child reference from the pointer parent.'
        }
        $pointer = [ordered]@{
            schema_version = 3
            pointer_format = 'series-directory-pointer-v3'
            state_root = [System.IO.Path]::GetFileName($destinationFullPath)
            control = 'control.json'
            migrated_from_sha256 = $sourceHash
            archive_manifest = $pointerManifestReference
        }
        $pointerTempPath = "$pointerTargetFullPath.staging-$([Guid]::NewGuid().ToString('N'))"
        $stagingPaths.Add($pointerTempPath)
        Write-Utf8Json -Path $pointerTempPath -Value $pointer
        if ((Get-Item -LiteralPath $pointerTempPath).Length -gt 4096) {
            throw 'Generated pointer exceeds 4096 bytes.'
        }
        $backupName = if ($ReplaceSourceWithPointer) { 'source-backup.json' } else { 'previous-pointer.json' }
        $backupPath = Join-Path $finalSnapshotRoot $backupName
        [System.IO.File]::Replace($pointerTempPath, $pointerTargetFullPath, $backupPath)
        $pointerCommitted = $true
        $null = $stagingPaths.Remove($pointerTempPath)
        $backupHash = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($backupPath))
        if ($backupHash -cne $pointerTargetHash) {
            throw "Atomic replacement backup hash mismatch. Expected $pointerTargetHash; actual $backupHash."
        }
        $postCommitReconciliation = Invoke-StagedReconciliation -StatePath $pointerTargetFullPath -AuditArchive
    }
    else {
        $postCommitReconciliation = Invoke-StagedReconciliation -StatePath $destinationFullPath -AuditArchive
    }

    $receipt = [ordered]@{
        ok = $true
        source_path = $sourceFullPath
        original_sha256 = $sourceHash
        original_bytes = $sourceBytes.Length
        source_main_revision = $source.main_revision
        effective_main_revision = $effectiveMainRevision
        state_root = $destinationFullPath
        control_path = Join-Path $destinationFullPath 'control.json'
        hot_path = Join-Path $destinationFullPath 'HOT.md'
        archive_index_path = Join-Path $destinationFullPath 'archive-index.md'
        snapshot_id = $snapshotId
        archive_snapshot_path = $finalSnapshotRoot
        bundle_path = $bundleFinalPath
        bundle_sha256 = $bundleHash
        active_candidate_count = $activeCandidates.Count
        archived_candidate_count = @($source.candidates).Count
        active_claim_count = $activeClaims.Count
        archived_claim_count = @($source.claims).Count
        source_replaced_with_pointer = [bool]$ReplaceSourceWithPointer
        pointer_replaced = [bool]$hasPointerReplacement
        pointer_path = if ($hasPointerReplacement) { $pointerTargetFullPath } else { $null }
        staging_reconciliation_ok = [bool]$stagingReconciliation.ok
        post_commit_reconciliation_ok = [bool]$postCommitReconciliation.ok
    }
    [Console]::Out.WriteLine(($receipt | ConvertTo-Json -Depth 20))
}
catch {
    $primaryError = $_.Exception.Message
    $sourceRestored = -not $pointerCommitted
    if ($pointerCommitted) {
        try {
            $restoreTempPath = "$pointerTargetFullPath.staging-restore-$([Guid]::NewGuid().ToString('N'))"
            $stagingPaths.Add($restoreTempPath)
            [System.IO.File]::WriteAllBytes($restoreTempPath, $pointerTargetBytes)
            $failedPointerBackup = Join-Path $finalSnapshotRoot 'failed-pointer.json'
            [System.IO.File]::Replace($restoreTempPath, $pointerTargetFullPath, $failedPointerBackup)
            $null = $stagingPaths.Remove($restoreTempPath)
            $restoredHash = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($pointerTargetFullPath))
            if ($restoredHash -cne $pointerTargetHash) {
                throw "Restored pointer target hash mismatch. Expected $pointerTargetHash; actual $restoredHash."
            }
            $sourceRestored = $true
            $pointerCommitted = $false
        }
        catch {
            [Console]::Error.WriteLine("Automatic source restore failed: $($_.Exception.Message)")
            $sourceRestored = $false
        }
    }
    if ($sourceRestored) {
        try {
            if ($destinationCommitted) {
                Remove-ValidatedCommittedDirectory -Path $destinationFullPath -ExpectedParent $destinationParent -ExpectedName ([System.IO.Path]::GetFileName($destinationFullPath))
                $destinationCommitted = $false
            }
            if ($archiveCommitted) {
                Remove-ValidatedCommittedDirectory -Path $finalSnapshotRoot -ExpectedParent $snapshotParent -ExpectedName $snapshotId
                $archiveCommitted = $false
            }
        }
        catch {
            [Console]::Error.WriteLine("Committed-state cleanup failed: $($_.Exception.Message)")
        }
    }
    else {
        [Console]::Error.WriteLine("Committed archive retained for manual recovery: $finalSnapshotRoot")
    }
    [Console]::Error.WriteLine($primaryError)
    exit 1
}
finally {
    foreach ($stagingPath in @($stagingPaths)) {
        try {
            Remove-ValidatedStagingPath -Path $stagingPath
        }
        catch {
            [Console]::Error.WriteLine($_.Exception.Message)
        }
    }
}
