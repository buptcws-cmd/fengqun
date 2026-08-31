[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StatePath,

    [switch]$AuditArchive
)

$ErrorActionPreference = 'Stop'
try {
    # Non-ASCII repository paths: decode native (git) output as UTF-8 regardless of console codepage.
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}
catch {
    # Hosts with a locked console encoding still work for ASCII-only repositories.
}
$issues = [System.Collections.Generic.List[object]]::new()
$resultContext = [ordered]@{
    state_path = $null
    state_root = $null
    archive_audited = [bool]$AuditArchive
    repository_git_common_dir = $null
    main_revision = $null
    declared_candidate_count = 0
    active_candidate_count = 0
    pending_review_count = 0
    wip_budget = [ordered]@{
        active_repairs = 2
        pending_reviews = 2
        integration_batches = 1
    }
    wip_usage = [ordered]@{
        active_repairs = 0
        pending_reviews = 0
        integration_batches = 0
    }
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
        state_root = $script:resultContext.state_root
        archive_audited = $script:resultContext.archive_audited
        repository_git_common_dir = $script:resultContext.repository_git_common_dir
        main_revision = $script:resultContext.main_revision
        declared_candidate_count = $script:resultContext.declared_candidate_count
        active_candidate_count = $script:resultContext.active_candidate_count
        pending_review_count = $script:resultContext.pending_review_count
        wip_budget = $script:resultContext.wip_budget
        wip_usage = $script:resultContext.wip_usage
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

function Get-SafeRelativeChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0 -or
        $RelativePath -match '[*?]' -or
        @($RelativePath -split '[\\/]' | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        return $null
    }

    try {
        $rootFullPath = [System.IO.Path]::GetFullPath($RootPath).TrimEnd([char[]]@('\', '/'))
        $childFullPath = [System.IO.Path]::GetFullPath((Join-Path $rootFullPath $RelativePath))
        $prefix = $rootFullPath + [System.IO.Path]::DirectorySeparatorChar
        if (-not $childFullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        return $childFullPath
    }
    catch {
        return $null
    }
}

function Test-PathContainsReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $rootFullPath = [System.IO.Path]::GetFullPath($RootPath).TrimEnd([char[]]@('\', '/'))
    $targetFullPath = [System.IO.Path]::GetFullPath($TargetPath)
    $prefix = $rootFullPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $targetFullPath.Equals($rootFullPath, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $targetFullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $relative = [System.IO.Path]::GetRelativePath($rootFullPath, $targetFullPath)
    $current = $rootFullPath
    $segments = if ($relative -eq '.') { @() } else { @($relative -split '[\\/]') }
    foreach ($segment in $segments) {
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

function Get-StateArchiveRootPath {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ArchiveRootReference
    )

    $normalized = $ArchiveRootReference.Replace('\', '/')
    if (-not $normalized.StartsWith('../', [System.StringComparison]::Ordinal) -or
        $normalized.Substring(3) -match '(^|/)(\.|\.\.)($|/)' -or
        [string]::IsNullOrWhiteSpace($normalized.Substring(3))) {
        return $null
    }
    $stateParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($StateRoot))
    return Get-SafeRelativeChildPath -RootPath $stateParent -RelativePath $normalized.Substring(3)
}

function Get-StateArchiveReferencePath {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][string]$Reference
    )

    $pathPart = $Reference.Split([char]'#', 2)[0]
    if ([string]::IsNullOrWhiteSpace($pathPart) -or [System.IO.Path]::IsPathRooted($pathPart) -or
        $pathPart.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0 -or $pathPart -match '[*?]') {
        return $null
    }
    try {
        $resolved = [System.IO.Path]::GetFullPath((Join-Path $StateRoot $pathPart))
        $archiveFullPath = [System.IO.Path]::GetFullPath($ArchiveRoot).TrimEnd([char[]]@('\', '/'))
        $prefix = $archiveFullPath + [System.IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        return $resolved
    }
    catch {
        return $null
    }
}

function Read-SeriesJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $raw = [System.IO.File]::ReadAllText($Path, $utf8)
    $jsonArguments = @{}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $jsonArguments.DateKind = 'String'
    }
    return $raw | ConvertFrom-Json @jsonArguments
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    # core.quotepath=false keeps non-ASCII paths as raw UTF-8 instead of C-style octal quoting.
    $output = @(& git -C $WorkingDirectory -c core.quotepath=false @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Invoke-GitBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($argument in @('-C', $WorkingDirectory, '-c', 'core.quotepath=false') + $Arguments) {
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

function ConvertFrom-StrictUtf8 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    return $encoding.GetString($Bytes)
}

function Test-RepositoryPath {
    param([AllowNull()][object]$PathValue)

    $pathText = [string]$PathValue
    if ([string]::IsNullOrWhiteSpace($pathText) -or
        [System.IO.Path]::IsPathRooted($pathText) -or
        $pathText.Contains('\') -or
        $pathText -match '[\x00-\x1f\x7f]' -or
        $pathText -match '[*?\[\]]') {
        return $false
    }

    $segments = @($pathText.Split('/'))
    return $segments.Count -gt 0 -and @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -eq 0
}

function Get-GitChangedPaths {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$SourceRevision,
        [Parameter(Mandatory = $true)][string]$TargetRevision
    )

    $bytes = Invoke-GitBytes -WorkingDirectory $WorkingDirectory -Arguments @(
        'diff-tree', '--no-commit-id', '--name-only', '-r', '-z', $SourceRevision, $TargetRevision, '--'
    )
    $text = ConvertFrom-StrictUtf8 -Bytes $bytes
    return @($text.Split([char[]]@([char]0), [System.StringSplitOptions]::RemoveEmptyEntries))
}

function Get-GitRawDiffSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$SourceRevision,
        [Parameter(Mandatory = $true)][string]$TargetRevision
    )

    $bytes = Invoke-GitBytes -WorkingDirectory $WorkingDirectory -Arguments @(
        'diff-tree', '--no-commit-id', '--raw', '-r', '-z', $SourceRevision, $TargetRevision, '--'
    )
    return Get-Sha256Hex -Bytes $bytes
}

function Get-GitScopedSurfaceSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$Revision,
        [Parameter(Mandatory = $true)][string[]]$ExcludedPaths
    )

    $excluded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in $ExcludedPaths) {
        $null = $excluded.Add($path)
    }

    $treeBytes = Invoke-GitBytes -WorkingDirectory $WorkingDirectory -Arguments @('ls-tree', '-r', '-z', '--full-tree', $Revision)
    $treeText = ConvertFrom-StrictUtf8 -Bytes $treeBytes
    $records = @($treeText.Split([char[]]@([char]0), [System.StringSplitOptions]::RemoveEmptyEntries))
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    $surface = [System.IO.MemoryStream]::new()
    try {
        foreach ($record in $records) {
            $tabIndex = $record.IndexOf("`t")
            if ($tabIndex -le 0) {
                throw "Invalid git ls-tree record at revision '$Revision'."
            }
            $path = $record.Substring($tabIndex + 1)
            if ($excluded.Contains($path)) {
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

function Test-ExactStringSet {
    param(
        [Parameter(Mandatory = $true)][object[]]$Expected,
        [Parameter(Mandatory = $true)][object[]]$Actual
    )

    $expectedValues = @($Expected | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive -Unique)
    $actualValues = @($Actual | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive -Unique)
    if ($expectedValues.Count -ne $actualValues.Count) {
        return $false
    }
    return @(Compare-Object -ReferenceObject $expectedValues -DifferenceObject $actualValues -CaseSensitive).Count -eq 0
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

$stateInputFullPath = Get-AbsolutePath -PathValue $StatePath -BasePath (Get-Location).Path
$stateFullPath = $stateInputFullPath
$stateRoot = $null
$directoryMode = $false
$state = $null
$pointerState = $null
$pointerParent = $null
$pointerArchiveManifestPath = $null

if (Test-Path -LiteralPath $stateInputFullPath -PathType Container) {
    $directoryMode = $true
    $stateRoot = $stateInputFullPath
    $stateFullPath = Join-Path $stateRoot 'control.json'
}
elseif (Test-Path -LiteralPath $stateInputFullPath -PathType Leaf) {
    try {
        $state = Read-SeriesJsonFile -Path $stateInputFullPath
    }
    catch {
        Add-Issue -Code 'state_json_invalid' -Subject 'state' -Message 'State file is not valid strict UTF-8 JSON.' -Expected 'valid JSON' -Actual $_.Exception.Message
        Complete-Reconciliation -ExitCode 2
    }

    $isV3Pointer =
        (Test-Property -InputObject $state -Name 'schema_version') -and [string]$state.schema_version -eq '3' -and
        (Test-Property -InputObject $state -Name 'pointer_format')
    if ($isV3Pointer) {
        if ((Get-Item -LiteralPath $stateInputFullPath).Length -gt 4096) {
            Add-Issue -Code 'state_pointer_too_large' -Subject 'state' -Message 'A v3 pointer file must remain at or below 4096 bytes.' -Expected 4096 -Actual (Get-Item -LiteralPath $stateInputFullPath).Length
            Complete-Reconciliation -ExitCode 2
        }
        if ([string]$state.pointer_format -cne 'series-directory-pointer-v3' -or
            -not (Test-Property -InputObject $state -Name 'state_root') -or
            -not (Test-Property -InputObject $state -Name 'control') -or
            -not (Test-Property -InputObject $state -Name 'migrated_from_sha256') -or
            -not (Test-Property -InputObject $state -Name 'archive_manifest') -or
            [string]$state.control -cne 'control.json') {
            Add-Issue -Code 'state_pointer_invalid' -Subject 'state' -Message 'A v3 pointer requires pointer_format, safe state_root, control, migrated_from_sha256, and archive_manifest fields.'
            Complete-Reconciliation -ExitCode 2
        }
        $pointerState = $state
        $pointerParent = Split-Path -Parent $stateInputFullPath
        $resolvedRoot = Get-SafeRelativeChildPath -RootPath $pointerParent -RelativePath ([string]$state.state_root)
        if ($null -eq $resolvedRoot -or -not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
            Add-Issue -Code 'state_pointer_invalid' -Subject 'state' -Message 'The v3 pointer state_root must resolve to an existing child directory.' -Expected 'existing relative child directory' -Actual $state.state_root
            Complete-Reconciliation -ExitCode 2
        }
        if (Test-PathContainsReparsePoint -RootPath $pointerParent -TargetPath $resolvedRoot) {
            Add-Issue -Code 'state_reparse_point_forbidden' -Subject 'state:pointer-root' -Message 'The v3 pointer state_root path must not traverse a reparse point.' -Actual $resolvedRoot
            Complete-Reconciliation -ExitCode 2
        }
        $pointerArchiveManifestPath = Get-SafeRelativeChildPath -RootPath $pointerParent -RelativePath ([string]$state.archive_manifest)
        if ($null -eq $pointerArchiveManifestPath -or -not (Test-Path -LiteralPath $pointerArchiveManifestPath -PathType Leaf)) {
            Add-Issue -Code 'state_archive_ref_missing' -Subject 'state:pointer-manifest' -Message 'The pointer archive_manifest must resolve to an existing child file.' -Actual $state.archive_manifest
        }
        elseif (Test-PathContainsReparsePoint -RootPath $pointerParent -TargetPath $pointerArchiveManifestPath) {
            Add-Issue -Code 'state_reparse_point_forbidden' -Subject 'state:pointer-manifest' -Message 'The pointer archive_manifest must not traverse a reparse point.' -Actual $pointerArchiveManifestPath
        }
        $directoryMode = $true
        $stateRoot = $resolvedRoot
        $stateFullPath = Join-Path $stateRoot 'control.json'
        $state = $null
    }
    elseif ((Test-Property -InputObject $state -Name 'state_format') -and [string]$state.state_format -ceq 'series-directory-v3') {
        $directoryMode = $true
        $stateRoot = Split-Path -Parent $stateInputFullPath
    }
}
else {
    Add-Issue -Code 'state_path_not_found' -Subject 'state' -Message 'State path does not exist.' -Expected $stateInputFullPath -Actual $null
    Complete-Reconciliation -ExitCode 2
}

$resultContext.state_path = Normalize-PathValue $stateFullPath

if ($directoryMode) {
    $resultContext.state_root = Normalize-PathValue $stateRoot
    $stateParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($stateRoot))
    if (Test-PathContainsReparsePoint -RootPath $stateParent -TargetPath $stateRoot) {
        Add-Issue -Code 'state_reparse_point_forbidden' -Subject 'state:root' -Message 'The v3 state root must not be a reparse point.' -Actual $stateRoot
    }
    $hotPath = Join-Path $stateRoot 'HOT.md'
    if (-not (Test-Path -LiteralPath $hotPath -PathType Leaf)) {
        Add-Issue -Code 'state_hot_entry_missing' -Subject 'state' -Message 'Directory state requires HOT.md.' -Expected $hotPath -Actual $null
    }
    else {
        $hotLength = (Get-Item -LiteralPath $hotPath).Length
        if ($hotLength -gt 16384) {
            Add-Issue -Code 'state_hot_entry_too_large' -Subject 'state' -Message 'HOT.md exceeds the 16384-byte hot-context budget.' -Expected 16384 -Actual $hotLength
        }
        $hotLineCount = [System.IO.File]::ReadAllLines($hotPath).Count
        if ($hotLineCount -gt 120) {
            Add-Issue -Code 'state_hot_entry_too_large' -Subject 'state' -Message 'HOT.md exceeds the 120-line hot-context budget.' -Expected 120 -Actual $hotLineCount
        }
    }

    if (-not (Test-Path -LiteralPath $stateFullPath -PathType Leaf)) {
        Add-Issue -Code 'state_control_missing' -Subject 'state' -Message 'Directory state requires control.json.' -Expected $stateFullPath -Actual $null
        Complete-Reconciliation -ExitCode 2
    }
    $controlLength = (Get-Item -LiteralPath $stateFullPath).Length
    if ($controlLength -gt 32768) {
        Add-Issue -Code 'state_control_too_large' -Subject 'state' -Message 'control.json exceeds the 32768-byte hot-state budget.' -Expected 32768 -Actual $controlLength
        Complete-Reconciliation -ExitCode 2
    }
    if ($null -eq $state) {
        try {
            $state = Read-SeriesJsonFile -Path $stateFullPath
        }
        catch {
            Add-Issue -Code 'state_json_invalid' -Subject 'state' -Message 'control.json is not valid strict UTF-8 JSON.' -Expected 'valid JSON' -Actual $_.Exception.Message
            Complete-Reconciliation -ExitCode 2
        }
    }

    if (-not (Test-Property -InputObject $state -Name 'schema_version') -or [string]$state.schema_version -ne '3' -or
        -not (Test-Property -InputObject $state -Name 'state_format') -or [string]$state.state_format -cne 'series-directory-v3') {
        Add-Issue -Code 'state_directory_schema_invalid' -Subject 'state' -Message 'Directory control must declare schema_version=3 and state_format=series-directory-v3.'
    }
    foreach ($field in @('candidates', 'closed_candidate_history', 'yefeng_parallelization', 'phase0_snapshot', 'context_checkpoint', 'backlog_summary')) {
        if (Test-Property -InputObject $state -Name $field) {
            Add-Issue -Code 'state_hot_history_forbidden' -Subject "state:$field" -Message "Hot v3 control must not embed cold or historical field '$field'; store it below the archive root and keep only a pointer."
        }
    }
    foreach ($field in @('candidate_refs', 'archive_index', 'next_safe_action')) {
        if (-not (Test-Property -InputObject $state -Name $field)) {
            Add-Issue -Code 'state_schema_invalid' -Subject 'state' -Message "Directory control field '$field' is required."
        }
    }

    if (Test-Property -InputObject $state -Name 'archive_index') {
        $archiveIndexPath = Get-SafeRelativeChildPath -RootPath $stateRoot -RelativePath ([string]$state.archive_index)
        if ($null -eq $archiveIndexPath -or -not (Test-Path -LiteralPath $archiveIndexPath -PathType Leaf)) {
            Add-Issue -Code 'state_archive_index_invalid' -Subject 'state' -Message 'archive_index must resolve to an existing child file.' -Actual $state.archive_index
        }
        elseif (Test-PathContainsReparsePoint -RootPath $stateRoot -TargetPath $archiveIndexPath) {
            Add-Issue -Code 'state_reparse_point_forbidden' -Subject 'state:archive-index' -Message 'archive_index must not traverse a reparse point.' -Actual $archiveIndexPath
        }
    }

    $materializedCandidates = [System.Collections.Generic.List[object]]::new()
    $candidateRefs = if (Test-Property -InputObject $state -Name 'candidate_refs') { @($state.candidate_refs) } else { @() }
    if ($candidateRefs.Count -gt 3) {
        Add-Issue -Code 'state_candidate_ref_budget_exceeded' -Subject 'state' -Message 'Directory control may reference at most three active candidates.' -Expected 3 -Actual $candidateRefs.Count
    }
    $refIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($candidateRef in $candidateRefs) {
        if (-not (Test-Property -InputObject $candidateRef -Name 'id') -or
            -not (Test-Property -InputObject $candidateRef -Name 'path') -or
            -not (Test-Property -InputObject $candidateRef -Name 'sha256')) {
            Add-Issue -Code 'candidate_ref_invalid' -Subject 'candidate-ref' -Message 'Each candidate ref requires id, path, and sha256.'
            continue
        }
        $refId = [string]$candidateRef.id
        $refSubject = "candidate-ref:$refId"
        if ($refId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or -not $refIds.Add($refId)) {
            Add-Issue -Code 'candidate_ref_invalid' -Subject $refSubject -Message 'Candidate ref id must be a unique safe identifier.' -Actual $refId
            continue
        }
        $candidatePath = Get-SafeRelativeChildPath -RootPath $stateRoot -RelativePath ([string]$candidateRef.path)
        $expectedRelativePath = "active/$refId/state.json"
        if ($null -eq $candidatePath -or ([string]$candidateRef.path).Replace('\', '/') -cne $expectedRelativePath -or
            -not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            Add-Issue -Code 'candidate_ref_path_invalid' -Subject $refSubject -Message 'Candidate ref path must be the existing exact active/<id>/state.json child.' -Expected $expectedRelativePath -Actual $candidateRef.path
            continue
        }
        if (Test-PathContainsReparsePoint -RootPath $stateRoot -TargetPath $candidatePath) {
            Add-Issue -Code 'state_reparse_point_forbidden' -Subject $refSubject -Message 'Candidate ref path must not traverse a reparse point.' -Actual $candidatePath
            continue
        }
        $candidateLength = (Get-Item -LiteralPath $candidatePath).Length
        if ($candidateLength -gt 65536) {
            Add-Issue -Code 'candidate_state_too_large' -Subject $refSubject -Message 'Active candidate state exceeds the 65536-byte warm-state budget.' -Expected 65536 -Actual $candidateLength
            continue
        }
        $expectedHash = ([string]$candidateRef.sha256).ToLowerInvariant()
        $actualHash = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($candidatePath))
        if ($expectedHash -notmatch '^[0-9a-f]{64}$' -or $expectedHash -cne $actualHash) {
            Add-Issue -Code 'candidate_ref_hash_mismatch' -Subject $refSubject -Message 'Candidate ref sha256 does not match the exact active state bytes.' -Expected $expectedHash -Actual $actualHash
            continue
        }
        try {
            $candidate = Read-SeriesJsonFile -Path $candidatePath
        }
        catch {
            Add-Issue -Code 'candidate_state_json_invalid' -Subject $refSubject -Message 'Active candidate state is not valid strict UTF-8 JSON.' -Actual $_.Exception.Message
            continue
        }
        if (-not (Test-Property -InputObject $candidate -Name 'id') -or [string]$candidate.id -cne $refId) {
            Add-Issue -Code 'candidate_ref_id_mismatch' -Subject $refSubject -Message 'Candidate state id must exactly match its ref id.' -Expected $refId -Actual $candidate.id
        }
        if ((Test-Property -InputObject $candidate -Name 'status') -and [string]$candidate.status -in @('done', 'merged', 'cancelled', 'expired', 'abandoned', 'closed')) {
            Add-Issue -Code 'candidate_ref_terminal_forbidden' -Subject $refSubject -Message 'Terminal candidates belong in the archive, not the active directory.' -Actual $candidate.status
        }
        if ((Test-Property -InputObject $candidate -Name 'validations') -and @($candidate.validations).Count -gt 5) {
            Add-Issue -Code 'candidate_validation_budget_exceeded' -Subject $refSubject -Message 'Active candidate state may retain at most five current validation records.' -Expected 5 -Actual @($candidate.validations).Count
        }
        if ((Test-Property -InputObject $candidate -Name 'reviews') -and @($candidate.reviews).Count -gt 1) {
            Add-Issue -Code 'candidate_review_budget_exceeded' -Subject $refSubject -Message 'Active candidate state may retain only the current review record.' -Expected 1 -Actual @($candidate.reviews).Count
        }
        $materializedCandidates.Add($candidate)
    }
    $state | Add-Member -NotePropertyName candidates -NotePropertyValue @($materializedCandidates) -Force

    if (Test-Property -InputObject $state -Name 'claims') {
        $hotClaimStatuses = @('claimed', 'running', 'reviewing', 'blocked')
        $coldClaims = @($state.claims | Where-Object { $_.status -notin $hotClaimStatuses })
        if ($coldClaims.Count -gt 0) {
            Add-Issue -Code 'state_hot_claim_history_forbidden' -Subject 'state:claims' -Message 'Hot v3 control may contain only current active claims.' -Expected 0 -Actual $coldClaims.Count
        }
        if (@($state.claims).Count -gt 3) {
            Add-Issue -Code 'state_claim_budget_exceeded' -Subject 'state:claims' -Message 'Hot v3 control may contain at most three active claims.' -Expected 3 -Actual @($state.claims).Count
        }
    }

    $archiveRootPath = $null
    $archiveManifestPath = $null
    $archiveBundlePath = $null
    foreach ($field in @('archive_root', 'archive_snapshot')) {
        if (-not (Test-Property -InputObject $state -Name $field)) {
            Add-Issue -Code 'state_schema_invalid' -Subject 'state' -Message "Directory control field '$field' is required."
        }
    }
    if (Test-Property -InputObject $state -Name 'archive_root') {
        $archiveRootPath = Get-StateArchiveRootPath -StateRoot $stateRoot -ArchiveRootReference ([string]$state.archive_root)
        if ($null -eq $archiveRootPath -or -not (Test-Path -LiteralPath $archiveRootPath -PathType Container)) {
            Add-Issue -Code 'state_archive_root_invalid' -Subject 'state:archive-root' -Message 'archive_root must be an existing non-reparse descendant of the state-root parent, expressed as ../<child>.' -Actual $state.archive_root
            $archiveRootPath = $null
        }
        elseif (Test-PathContainsReparsePoint -RootPath $stateParent -TargetPath $archiveRootPath) {
            Add-Issue -Code 'state_reparse_point_forbidden' -Subject 'state:archive-root' -Message 'archive_root must not traverse a reparse point.' -Actual $archiveRootPath
            $archiveRootPath = $null
        }
    }

    if ((Test-Property -InputObject $state -Name 'archive_snapshot') -and $null -ne $archiveRootPath) {
        $snapshot = $state.archive_snapshot
        foreach ($field in @('reference_base', 'id', 'original_sha256', 'manifest', 'bundle')) {
            if (-not (Test-Property -InputObject $snapshot -Name $field)) {
                Add-Issue -Code 'state_archive_snapshot_invalid' -Subject 'state:archive-snapshot' -Message "archive_snapshot field '$field' is required."
            }
        }
        if ((Test-Property -InputObject $snapshot -Name 'reference_base') -and [string]$snapshot.reference_base -cne 'state_root') {
            Add-Issue -Code 'state_archive_snapshot_invalid' -Subject 'state:archive-snapshot' -Message 'archive_snapshot.reference_base must be state_root.' -Expected 'state_root' -Actual $snapshot.reference_base
        }
        if ((Test-Property -InputObject $snapshot -Name 'original_sha256') -and [string]$snapshot.original_sha256 -notmatch '^[0-9a-f]{64}$') {
            Add-Issue -Code 'state_archive_snapshot_invalid' -Subject 'state:archive-snapshot' -Message 'archive_snapshot.original_sha256 must be lowercase SHA-256.' -Actual $snapshot.original_sha256
        }
        if (Test-Property -InputObject $snapshot -Name 'manifest') {
            $archiveManifestPath = Get-StateArchiveReferencePath -StateRoot $stateRoot -ArchiveRoot $archiveRootPath -Reference ([string]$snapshot.manifest)
            if ($null -eq $archiveManifestPath -or -not (Test-Path -LiteralPath $archiveManifestPath -PathType Leaf)) {
                Add-Issue -Code 'state_archive_ref_missing' -Subject 'state:archive-manifest' -Message 'archive_snapshot.manifest must resolve inside archive_root to an existing file.' -Actual $snapshot.manifest
                $archiveManifestPath = $null
            }
            elseif (Test-PathContainsReparsePoint -RootPath $archiveRootPath -TargetPath $archiveManifestPath) {
                Add-Issue -Code 'state_reparse_point_forbidden' -Subject 'state:archive-manifest' -Message 'archive_snapshot.manifest must not traverse a reparse point.' -Actual $archiveManifestPath
                $archiveManifestPath = $null
            }
        }
        if (Test-Property -InputObject $snapshot -Name 'bundle') {
            $archiveBundlePath = Get-StateArchiveReferencePath -StateRoot $stateRoot -ArchiveRoot $archiveRootPath -Reference ([string]$snapshot.bundle)
            if ($null -eq $archiveBundlePath -or -not (Test-Path -LiteralPath $archiveBundlePath -PathType Leaf)) {
                Add-Issue -Code 'state_archive_ref_missing' -Subject 'state:archive-bundle' -Message 'archive_snapshot.bundle must resolve inside archive_root to an existing file.' -Actual $snapshot.bundle
                $archiveBundlePath = $null
            }
            elseif (Test-PathContainsReparsePoint -RootPath $archiveRootPath -TargetPath $archiveBundlePath) {
                Add-Issue -Code 'state_reparse_point_forbidden' -Subject 'state:archive-bundle' -Message 'archive_snapshot.bundle must not traverse a reparse point.' -Actual $archiveBundlePath
                $archiveBundlePath = $null
            }
        }

        if ($null -ne $pointerState) {
            if ([string]$pointerState.migrated_from_sha256 -notmatch '^[0-9a-f]{64}$' -or
                [string]$pointerState.migrated_from_sha256 -cne [string]$snapshot.original_sha256) {
                Add-Issue -Code 'state_archive_identity_mismatch' -Subject 'state:pointer' -Message 'Pointer migrated_from_sha256 must exactly match archive_snapshot.original_sha256.' -Expected $snapshot.original_sha256 -Actual $pointerState.migrated_from_sha256
            }
            if ($null -ne $pointerArchiveManifestPath -and $null -ne $archiveManifestPath -and
                (Normalize-PathValue $pointerArchiveManifestPath) -cne (Normalize-PathValue $archiveManifestPath)) {
                Add-Issue -Code 'state_archive_identity_mismatch' -Subject 'state:pointer' -Message 'Pointer archive_manifest must resolve to the same exact file as archive_snapshot.manifest.' -Expected $archiveManifestPath -Actual $pointerArchiveManifestPath
            }
        }
    }

    if ($null -ne $archiveRootPath) {
        foreach ($candidate in @($materializedCandidates)) {
            $subject = "candidate:$($candidate.id)"
            if (-not (Test-Property -InputObject $candidate -Name 'archive_ref_base') -or [string]$candidate.archive_ref_base -cne 'state_root' -or
                -not (Test-Property -InputObject $candidate -Name 'archive_ref')) {
                Add-Issue -Code 'state_archive_ref_invalid' -Subject $subject -Message 'Each active candidate requires archive_ref_base=state_root and archive_ref.'
                continue
            }
            $candidateArchivePath = Get-StateArchiveReferencePath -StateRoot $stateRoot -ArchiveRoot $archiveRootPath -Reference ([string]$candidate.archive_ref)
            if ($null -eq $candidateArchivePath -or -not (Test-Path -LiteralPath $candidateArchivePath -PathType Leaf)) {
                Add-Issue -Code 'state_archive_ref_missing' -Subject $subject -Message 'Candidate archive_ref must resolve inside archive_root to an existing file.' -Actual $candidate.archive_ref
            }
            elseif (Test-PathContainsReparsePoint -RootPath $archiveRootPath -TargetPath $candidateArchivePath) {
                Add-Issue -Code 'state_reparse_point_forbidden' -Subject $subject -Message 'Candidate archive_ref must not traverse a reparse point.' -Actual $candidateArchivePath
            }
        }
        foreach ($claim in @($state.claims)) {
            $subject = "claim:$($claim.id)"
            if (-not (Test-Property -InputObject $claim -Name 'archive_ref_base') -or [string]$claim.archive_ref_base -cne 'state_root' -or
                -not (Test-Property -InputObject $claim -Name 'archive_ref')) {
                Add-Issue -Code 'state_archive_ref_invalid' -Subject $subject -Message 'Each active claim requires archive_ref_base=state_root and archive_ref.'
                continue
            }
            $claimArchivePath = Get-StateArchiveReferencePath -StateRoot $stateRoot -ArchiveRoot $archiveRootPath -Reference ([string]$claim.archive_ref)
            if ($null -eq $claimArchivePath -or -not (Test-Path -LiteralPath $claimArchivePath -PathType Leaf)) {
                Add-Issue -Code 'state_archive_ref_missing' -Subject $subject -Message 'Claim archive_ref must resolve inside archive_root to an existing file.' -Actual $claim.archive_ref
            }
            elseif (Test-PathContainsReparsePoint -RootPath $archiveRootPath -TargetPath $claimArchivePath) {
                Add-Issue -Code 'state_reparse_point_forbidden' -Subject $subject -Message 'Claim archive_ref must not traverse a reparse point.' -Actual $claimArchivePath
            }
        }
        if (Test-Property -InputObject $state -Name 'shelves_ref') {
            if (-not (Test-Property -InputObject $state -Name 'shelves_ref_base') -or [string]$state.shelves_ref_base -cne 'state_root') {
                Add-Issue -Code 'state_archive_ref_invalid' -Subject 'state:shelves' -Message 'shelves_ref requires shelves_ref_base=state_root.'
            }
            $shelvesPath = Get-StateArchiveReferencePath -StateRoot $stateRoot -ArchiveRoot $archiveRootPath -Reference ([string]$state.shelves_ref)
            if ($null -eq $shelvesPath -or -not (Test-Path -LiteralPath $shelvesPath -PathType Leaf)) {
                Add-Issue -Code 'state_archive_ref_missing' -Subject 'state:shelves' -Message 'shelves_ref must resolve inside archive_root to an existing file.' -Actual $state.shelves_ref
            }
            elseif (Test-PathContainsReparsePoint -RootPath $archiveRootPath -TargetPath $shelvesPath) {
                Add-Issue -Code 'state_reparse_point_forbidden' -Subject 'state:shelves' -Message 'shelves_ref must not traverse a reparse point.' -Actual $shelvesPath
            }
        }
    }

    if ($AuditArchive -and $null -ne $archiveManifestPath -and $null -ne $archiveBundlePath -and
        (Test-Property -InputObject $state.archive_snapshot -Name 'original_sha256')) {
        try {
            $manifest = Read-SeriesJsonFile -Path $archiveManifestPath
            $expectedOriginalHash = [string]$state.archive_snapshot.original_sha256
            if (-not (Test-Property -InputObject $manifest -Name 'source_sha256') -or [string]$manifest.source_sha256 -cne $expectedOriginalHash) {
                Add-Issue -Code 'state_archive_integrity_mismatch' -Subject 'state:archive-manifest' -Message 'Manifest source_sha256 must match archive_snapshot.original_sha256.' -Expected $expectedOriginalHash -Actual $manifest.source_sha256
            }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($archiveBundlePath)
            try {
                $entry = $zip.GetEntry('original-control-state.json')
                if ($null -eq $entry) {
                    Add-Issue -Code 'state_archive_integrity_mismatch' -Subject 'state:archive-bundle' -Message 'Archive bundle is missing original-control-state.json.'
                }
                else {
                    $memory = [System.IO.MemoryStream]::new()
                    try {
                        $stream = $entry.Open()
                        try { $stream.CopyTo($memory) } finally { $stream.Dispose() }
                        $entryBytes = $memory.ToArray()
                        $entryHash = Get-Sha256Hex -Bytes $entryBytes
                    }
                    finally { $memory.Dispose() }
                    if ($entryHash -cne $expectedOriginalHash) {
                        Add-Issue -Code 'state_archive_integrity_mismatch' -Subject 'state:archive-bundle' -Message 'Bundled original SHA-256 does not match archive_snapshot.original_sha256.' -Expected $expectedOriginalHash -Actual $entryHash
                    }
                    if ((Test-Property -InputObject $manifest -Name 'source_bytes') -and [long]$manifest.source_bytes -ne $entryBytes.Length) {
                        Add-Issue -Code 'state_archive_integrity_mismatch' -Subject 'state:archive-bundle' -Message 'Bundled original byte count does not match the manifest.' -Expected $manifest.source_bytes -Actual $entryBytes.Length
                    }
                }
            }
            finally { $zip.Dispose() }
            if (Test-Property -InputObject $manifest -Name 'bundle_sha256') {
                $actualBundleHash = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($archiveBundlePath))
                if ([string]$manifest.bundle_sha256 -cne $actualBundleHash) {
                    Add-Issue -Code 'state_archive_integrity_mismatch' -Subject 'state:archive-bundle' -Message 'Bundle SHA-256 does not match the manifest.' -Expected $manifest.bundle_sha256 -Actual $actualBundleHash
                }
            }
        }
        catch {
            Add-Issue -Code 'state_archive_integrity_mismatch' -Subject 'state:archive-audit' -Message 'Explicit archive audit could not parse or verify the declared cold snapshot.' -Actual $_.Exception.Message
        }
    }
}
else {
    $resultContext.state_root = $null
}

$requiredStateFields = @('run_epoch', 'status', 'main_revision', 'cycle_budget', 'claims', 'candidates')
foreach ($field in $requiredStateFields) {
    if (-not (Test-Property -InputObject $state -Name $field)) {
        Add-Issue -Code 'state_schema_invalid' -Subject 'state' -Message "State field '$field' is required."
    }
}

$schemaVersion = 1
if (Test-Property -InputObject $state -Name 'schema_version') {
    $parsedSchemaVersion = 0
    if (-not [int]::TryParse([string]$state.schema_version, [ref]$parsedSchemaVersion) -or $parsedSchemaVersion -notin @(1, 2, 3)) {
        Add-Issue -Code 'state_schema_version_unsupported' -Subject 'state' -Message 'schema_version must be 1, 2, or 3.' -Expected '1,2,3' -Actual $state.schema_version
    }
    else {
        $schemaVersion = $parsedSchemaVersion
    }
}

$allowedControlStatuses = @('active', 'paused', 'handed-off', 'cancelled', 'closed')
if (Test-Property -InputObject $state -Name 'status') {
    if ([string]::IsNullOrWhiteSpace([string]$state.status) -or $state.status -notin $allowedControlStatuses) {
        Add-Issue -Code 'state_schema_invalid' -Subject 'state' -Message 'State status is invalid.' -Expected ($allowedControlStatuses -join ',') -Actual $state.status
    }
}

$soloMode = $false
if (Test-Property -InputObject $state -Name 'execution_mode') {
    $allowedExecutionModes = @('solo', 'multi')
    if ([string]$state.execution_mode -notin $allowedExecutionModes) {
        Add-Issue -Code 'state_schema_invalid' -Subject 'state' -Message 'execution_mode must be solo or multi when present.' -Expected ($allowedExecutionModes -join ',') -Actual $state.execution_mode
    }
    else {
        $soloMode = ([string]$state.execution_mode -eq 'solo')
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
$hotCandidateStatuses = @('claimed', 'implementation', 'running', 'validation', 'review', 'implementation-review', 'blocked')
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
    if ($schemaVersion -ge 2 -and [string]$candidate.status -in $hotCandidateStatuses -and -not (Test-Property -InputObject $candidate -Name 'review_gate')) {
        Add-Issue -Code 'candidate_schema_invalid' -Subject $subject -Message "schema_version 2 requires an explicit review_gate field; use null before a gate exists."
    }
    if ($schemaVersion -eq 1 -and (Test-Property -InputObject $candidate -Name 'review_gate') -and $null -ne $candidate.review_gate) {
        Add-Issue -Code 'review_gate_requires_schema_v2' -Subject $subject -Message 'schema_version 1 uses exact-only fallback and cannot declare review_gate.' -Expected 'schema_version 2' -Actual 1
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

$budgetValues = [ordered]@{
    active_repairs = 2
    pending_reviews = 2
    integration_batches = 1
}
if (Test-Property -InputObject $state -Name 'wip_budget') {
    foreach ($field in @('active_repairs', 'pending_reviews', 'integration_batches')) {
        if (-not (Test-Property -InputObject $state.wip_budget -Name $field)) {
            Add-Issue -Code 'state_schema_invalid' -Subject 'wip' -Message "Explicit wip_budget limit '$field' is required."
            continue
        }
        $parsedBudget = 0
        $budgetParsed = [int]::TryParse([string]$state.wip_budget.$field, [ref]$parsedBudget)
        if (-not $budgetParsed -or $parsedBudget -lt 0) {
            Add-Issue -Code 'state_schema_invalid' -Subject 'wip' -Message "WIP limit '$field' must be a non-negative integer." -Actual $state.wip_budget.$field
        }
        else {
            $budgetValues[$field] = $parsedBudget
        }
    }
}
$resultContext.wip_budget = $budgetValues

$integrationUsageKnown = $true
$integrationBatchIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$activeIntegrationStatuses = @('pending', 'running', 'committing', 'reconciling')
$allowedIntegrationStatuses = $activeIntegrationStatuses + @('completed', 'cancelled', 'expired')
if (Test-Property -InputObject $state -Name 'integration_intents') {
    $integrationIntents = @($state.integration_intents)
    $declaredIntegrationIds = @{}
    for ($index = 0; $index -lt $integrationIntents.Count; $index++) {
        $intent = $integrationIntents[$index]
        $intentId = if (Test-Property -InputObject $intent -Name 'id') { [string]$intent.id } else { "index:$index" }
        $subject = "integration_intent:$intentId"
        $intentIsValid = $true
        foreach ($field in @('id', 'status', 'run_epoch')) {
            if (-not (Test-Property -InputObject $intent -Name $field) -or [string]::IsNullOrWhiteSpace([string]$intent.$field)) {
                Add-Issue -Code 'integration_intent_schema_invalid' -Subject $subject -Message "Integration intent field '$field' is required."
                $intentIsValid = $false
            }
        }
        if ($intentIsValid -and $declaredIntegrationIds.ContainsKey($intentId)) {
            Add-Issue -Code 'integration_intent_schema_invalid' -Subject $subject -Message 'Integration intent id must be unique.' -Actual $intentId
            $intentIsValid = $false
        }
        elseif ($intentIsValid) {
            $declaredIntegrationIds[$intentId] = $true
        }
        if ($intentIsValid -and [string]$intent.status -notin $allowedIntegrationStatuses) {
            Add-Issue -Code 'integration_intent_schema_invalid' -Subject $subject -Message 'Integration intent status is invalid.' -Expected ($allowedIntegrationStatuses -join ',') -Actual $intent.status
            $intentIsValid = $false
        }

        $intentEpoch = 0L
        if ($intentIsValid -and (-not [long]::TryParse([string]$intent.run_epoch, [ref]$intentEpoch) -or $intentEpoch -lt 0)) {
            Add-Issue -Code 'integration_intent_schema_invalid' -Subject $subject -Message 'Integration intent run_epoch must be a non-negative integer.' -Actual $intent.run_epoch
            $intentIsValid = $false
        }
        if ($intentIsValid -and [string]$intent.status -in $activeIntegrationStatuses) {
            if ($intentEpoch -ne $epochValue) {
                Add-Issue -Code 'integration_intent_epoch_mismatch' -Subject $subject -Message 'An active integration intent from another epoch is ambiguous and cannot be counted as current usage.' -Expected $epochValue -Actual $intentEpoch
                $intentIsValid = $false
            }
            else {
                $null = $integrationBatchIds.Add($intentId)
            }
        }
        if (-not $intentIsValid) {
            $integrationUsageKnown = $false
        }
    }
}
$resultContext.wip_usage.integration_batches = if ($integrationUsageKnown) { $integrationBatchIds.Count } else { $null }

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

$activeCandidateStatuses = $hotCandidateStatuses
$activeCandidatePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$activeCandidates = [System.Collections.Generic.List[object]]::new()
$pendingReviewCount = 0
$pendingReviewUsageKnown = $true
$reviewIdOwners = @{}

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
            if ($validationIsCurrent) {
                $hasPassedValidation = $true
            }
        }
    }

    $candidateReviews = @($candidate.reviews)
    $candidateReviewIds = @{}
    for ($reviewIndex = 0; $reviewIndex -lt $candidateReviews.Count; $reviewIndex++) {
        $review = $candidateReviews[$reviewIndex]
        if (Test-Property -InputObject $review -Name 'review_id') {
            $reviewId = [string]$review.review_id
            if ([string]::IsNullOrWhiteSpace($reviewId)) {
                Add-Issue -Code 'review_id_invalid' -Subject $subject -Message "Review at index $reviewIndex has an empty review_id. Omit it for unmigrated history or provide a unique id."
            }
            elseif ($candidateReviewIds.ContainsKey($reviewId)) {
                Add-Issue -Code 'review_id_duplicate' -Subject $subject -Message 'review_id must be unique.' -Actual $reviewId
            }
            else {
                $candidateReviewIds[$reviewId] = $review
                if ($reviewIdOwners.ContainsKey($reviewId)) {
                    Add-Issue -Code 'review_id_duplicate' -Subject $subject -Message 'review_id must be unique across current control state.' -Expected $reviewIdOwners[$reviewId] -Actual $reviewId
                }
                else {
                    $reviewIdOwners[$reviewId] = "$candidateId#$reviewIndex"
                }
            }
        }
    }

    $currentReview = $null
    $reviewGateBindingValid = $false
    $currentReviewConsumesPendingWip = $false
    $reviewGateRequiredStatuses = @('review', 'implementation-review', 'done', 'merged', 'closed')
    if ($schemaVersion -eq 1) {
        # v1 migration fallback is deliberately exact-only: choose the last record for this exact revision.
        foreach ($review in $candidateReviews) {
            if ([string]$review.reviewed_revision -ceq [string]$candidate.revision) {
                $currentReview = $review
            }
        }
        if ($null -ne $currentReview) {
            $reviewGateBindingValid = $true
            $currentReviewConsumesPendingWip = [string]$candidate.status -in $hotCandidateStatuses
        }
        elseif ([string]$candidate.status -in $reviewGateRequiredStatuses) {
            Add-Issue -Code 'current_review_binding_missing' -Subject $subject -Message 'schema_version 1 exact-only fallback found no review record for the current candidate revision.' -Expected $candidate.revision -Actual $null
            $pendingReviewUsageKnown = $false
        }
    }
    else {
        $hasReviewGate = (Test-Property -InputObject $candidate -Name 'review_gate') -and $null -ne $candidate.review_gate
        if (-not $hasReviewGate) {
            if ([string]$candidate.status -in @('review', 'implementation-review')) {
                Add-Issue -Code 'review_gate_missing' -Subject $subject -Message "Candidate status '$($candidate.status)' requires a non-null explicit review_gate."
                $pendingReviewUsageKnown = $false
            }
            elseif ([string]$candidate.status -notin $hotCandidateStatuses) {
                # Schema-v2 migration fallback for read-only historical candidates is exact-only.
                foreach ($review in $candidateReviews) {
                    if ([string]$review.reviewed_revision -ceq [string]$candidate.revision) {
                        $currentReview = $review
                    }
                }
                if ($null -ne $currentReview) {
                    $reviewGateBindingValid = $true
                }
                elseif ([string]$candidate.status -in @('done', 'merged', 'closed')) {
                    Add-Issue -Code 'legacy_current_review_binding_missing' -Subject $subject -Message "Historical schema-v2 candidate status '$($candidate.status)' has no explicit gate and no exact passed-review fallback for its revision." -Expected $candidate.revision -Actual $null
                }
            }
        }
        else {
            $reviewGate = $candidate.review_gate
            $gateShapeValid = $true
            foreach ($field in @('review_id', 'candidate_revision', 'binding', 'proof')) {
                if (-not (Test-Property -InputObject $reviewGate -Name $field) -or
                    ($field -ne 'proof' -and [string]::IsNullOrWhiteSpace([string]$reviewGate.$field)) -or
                    ($field -eq 'proof' -and $null -eq $reviewGate.proof)) {
                    Add-Issue -Code 'review_gate_schema_invalid' -Subject $subject -Message "review_gate field '$field' is required."
                    $gateShapeValid = $false
                }
            }

            if ($gateShapeValid -and [string]$reviewGate.candidate_revision -cne [string]$candidate.revision) {
                Add-Issue -Code 'review_gate_candidate_revision_mismatch' -Subject $subject -Message 'review_gate.candidate_revision must bind the current candidate revision.' -Expected $candidate.revision -Actual $reviewGate.candidate_revision
                $gateShapeValid = $false
            }

            $allowedReviewBindings = @('exact', 'administrative-descendant', 'repository-verifier')
            if ($gateShapeValid -and [string]$reviewGate.binding -notin $allowedReviewBindings) {
                Add-Issue -Code 'review_gate_binding_invalid' -Subject $subject -Message 'review_gate.binding is invalid.' -Expected ($allowedReviewBindings -join ',') -Actual $reviewGate.binding
                $gateShapeValid = $false
            }

            if ($gateShapeValid) {
                $matchingReviews = @($candidateReviews | Where-Object {
                    (Test-Property -InputObject $_ -Name 'review_id') -and [string]$_.review_id -ceq [string]$reviewGate.review_id
                })
                if ($matchingReviews.Count -ne 1) {
                    Add-Issue -Code 'review_gate_review_id_unresolved' -Subject $subject -Message 'review_gate.review_id must identify exactly one review record.' -Expected 1 -Actual $matchingReviews.Count
                    $gateShapeValid = $false
                    $pendingReviewUsageKnown = $false
                }
                else {
                    $currentReview = $matchingReviews[0]
                    $currentReviewConsumesPendingWip = $true
                }
            }

            if ($gateShapeValid) {
                $proof = $reviewGate.proof
                if (-not (Test-Property -InputObject $proof -Name 'reviewed_revision') -or [string]::IsNullOrWhiteSpace([string]$proof.reviewed_revision)) {
                    Add-Issue -Code 'review_gate_proof_invalid' -Subject $subject -Message 'review_gate.proof.reviewed_revision is required.'
                    $gateShapeValid = $false
                }
                elseif ([string]$proof.reviewed_revision -cne [string]$currentReview.reviewed_revision) {
                    Add-Issue -Code 'review_gate_proof_revision_mismatch' -Subject $subject -Message 'Proof source revision must equal the bound review reviewed_revision.' -Expected $currentReview.reviewed_revision -Actual $proof.reviewed_revision
                    $gateShapeValid = $false
                }
            }

            if ($gateShapeValid) {
                $proof = $reviewGate.proof
                $sourceRevision = [string]$proof.reviewed_revision
                $targetRevision = [string]$candidate.revision
                $binding = [string]$reviewGate.binding
                $bindingValid = $true

                if ($binding -eq 'exact') {
                    if ($sourceRevision -cne $targetRevision) {
                        Add-Issue -Code 'review_gate_exact_revision_mismatch' -Subject $subject -Message 'An exact review gate requires reviewed_revision to equal candidate_revision.' -Expected $targetRevision -Actual $sourceRevision
                        $bindingValid = $false
                    }
                }
                else {
                    if ($currentReview.status -ne 'passed' -or $currentReview.verdict -ne 'review passed') {
                        Add-Issue -Code 'review_gate_inheritance_requires_pass' -Subject $subject -Message "Binding '$binding' can inherit only a literal review passed record." -Expected 'passed / review passed' -Actual "$($currentReview.status) / $($currentReview.verdict)"
                        $bindingValid = $false
                    }
                    if ($sourceRevision -ceq $targetRevision) {
                        Add-Issue -Code 'review_gate_inheritance_not_descendant' -Subject $subject -Message "Binding '$binding' requires a distinct descendant candidate; use exact for the reviewed revision."
                        $bindingValid = $false
                    }
                }

                if ($bindingValid -and $binding -eq 'administrative-descendant') {
                    foreach ($field in @('scoped_surface_digest', 'raw_diff_sha256')) {
                        if (-not (Test-Property -InputObject $proof -Name $field) -or $null -eq $proof.$field) {
                            Add-Issue -Code 'review_gate_administrative_proof_invalid' -Subject $subject -Message "Administrative descendant proof field '$field' is required."
                            $bindingValid = $false
                        }
                    }
                    if (-not (Test-Property -InputObject $currentReview -Name 'independent') -or $currentReview.independent -ne $true) {
                        Add-Issue -Code 'review_gate_administrative_review_not_independent' -Subject $subject -Message 'administrative-descendant requires the referenced passed review record to declare independent=true.' -Expected $true -Actual $currentReview.independent
                        $bindingValid = $false
                    }
                    if (-not (Test-Property -InputObject $currentReview -Name 'review_surface') -or $null -eq $currentReview.review_surface) {
                        Add-Issue -Code 'review_gate_administrative_surface_missing' -Subject $subject -Message 'administrative-descendant requires review_surface on the referenced passed review record.'
                        $bindingValid = $false
                    }
                    elseif (-not (Test-Property -InputObject $currentReview.review_surface -Name 'path_semantics') -or
                        [string]$currentReview.review_surface.path_semantics -cne 'whole-file-administrative') {
                        Add-Issue -Code 'review_gate_administrative_scope_invalid' -Subject $subject -Message 'The independent review must classify its exact path list as whole-file-administrative. Mixed-semantic files require a fresh exact review.' -Expected 'whole-file-administrative' -Actual $currentReview.review_surface.path_semantics
                        $bindingValid = $false
                    }
                    elseif (-not (Test-Property -InputObject $currentReview.review_surface -Name 'administrative_paths')) {
                        Add-Issue -Code 'review_gate_administrative_surface_missing' -Subject $subject -Message 'The independent review_surface must contain administrative_paths.'
                        $bindingValid = $false
                    }

                    $administrativePaths = if ((Test-Property -InputObject $currentReview -Name 'review_surface') -and
                        (Test-Property -InputObject $currentReview.review_surface -Name 'administrative_paths')) {
                        @($currentReview.review_surface.administrative_paths)
                    }
                    else {
                        @()
                    }
                    if ($administrativePaths.Count -eq 0) {
                        Add-Issue -Code 'review_gate_administrative_paths_invalid' -Subject $subject -Message 'The referenced review administrative_paths must contain at least one exact repository-relative whole-file path.'
                        $bindingValid = $false
                    }
                    $uniqueAdministrativePaths = @($administrativePaths | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive -Unique)
                    if ($uniqueAdministrativePaths.Count -ne $administrativePaths.Count) {
                        Add-Issue -Code 'review_gate_administrative_paths_invalid' -Subject $subject -Message 'administrative_paths must not contain duplicates.'
                        $bindingValid = $false
                    }
                    foreach ($path in $uniqueAdministrativePaths) {
                        if (-not (Test-RepositoryPath -PathValue $path)) {
                            Add-Issue -Code 'review_gate_administrative_paths_invalid' -Subject $subject -Message 'administrative_paths contains an unsafe or non-normalized repository path.' -Actual $path
                            $bindingValid = $false
                        }
                    }

                    if ($bindingValid) {
                        try {
                            $parentLine = @(Invoke-Git -WorkingDirectory $workingDirectory -Arguments @('rev-list', '--parents', '-n', '1', $targetRevision))[0]
                            $parentParts = @($parentLine.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries))
                            if ($parentParts.Count -ne 2 -or $parentParts[1] -cne $sourceRevision) {
                                Add-Issue -Code 'review_gate_administrative_parent_invalid' -Subject $subject -Message 'administrative-descendant requires a direct, single-parent child of the reviewed revision.' -Expected $sourceRevision -Actual ($parentParts -join ',')
                                $bindingValid = $false
                            }

                            $changedPaths = @(Get-GitChangedPaths -WorkingDirectory $workingDirectory -SourceRevision $sourceRevision -TargetRevision $targetRevision)
                            if (@($changedPaths | Where-Object { -not (Test-RepositoryPath -PathValue $_) }).Count -gt 0 -or
                                -not (Test-ExactStringSet -Expected $uniqueAdministrativePaths -Actual $changedPaths)) {
                                Add-Issue -Code 'review_gate_administrative_diff_scope_mismatch' -Subject $subject -Message 'Git changed paths must equal the referenced independent review administrative_paths exactly.' -Expected $uniqueAdministrativePaths -Actual $changedPaths
                                $bindingValid = $false
                            }

                            if (-not (Test-Property -InputObject $proof.scoped_surface_digest -Name 'source_sha256') -or
                                -not (Test-Property -InputObject $proof.scoped_surface_digest -Name 'target_sha256')) {
                                Add-Issue -Code 'review_gate_administrative_digest_invalid' -Subject $subject -Message 'scoped_surface_digest requires source_sha256 and target_sha256.'
                                $bindingValid = $false
                            }
                            else {
                                $actualSourceDigest = Get-GitScopedSurfaceSha256 -WorkingDirectory $workingDirectory -Revision $sourceRevision -ExcludedPaths $uniqueAdministrativePaths
                                $actualTargetDigest = Get-GitScopedSurfaceSha256 -WorkingDirectory $workingDirectory -Revision $targetRevision -ExcludedPaths $uniqueAdministrativePaths
                                if ($actualSourceDigest -cne $actualTargetDigest) {
                                    Add-Issue -Code 'review_gate_administrative_surface_changed' -Subject $subject -Message 'The complete non-administrative Git-object surface changed; administrative review inheritance is unsafe.' -Expected $actualSourceDigest -Actual $actualTargetDigest
                                    $bindingValid = $false
                                }
                                if ([string]$proof.scoped_surface_digest.source_sha256 -cne [string]$proof.scoped_surface_digest.target_sha256) {
                                    Add-Issue -Code 'review_gate_administrative_digest_mismatch' -Subject $subject -Message 'Proof source and target scoped-surface digests must be identical.' -Expected $proof.scoped_surface_digest.source_sha256 -Actual $proof.scoped_surface_digest.target_sha256
                                    $bindingValid = $false
                                }
                                if ([string]$proof.scoped_surface_digest.source_sha256 -cne $actualSourceDigest) {
                                    Add-Issue -Code 'review_gate_administrative_digest_mismatch' -Subject $subject -Message 'Source scoped-surface digest does not match Git objects.' -Expected $actualSourceDigest -Actual $proof.scoped_surface_digest.source_sha256
                                    $bindingValid = $false
                                }
                                if ([string]$proof.scoped_surface_digest.target_sha256 -cne $actualTargetDigest) {
                                    Add-Issue -Code 'review_gate_administrative_digest_mismatch' -Subject $subject -Message 'Target scoped-surface digest does not match Git objects.' -Expected $actualTargetDigest -Actual $proof.scoped_surface_digest.target_sha256
                                    $bindingValid = $false
                                }
                            }

                            $actualRawDiffDigest = Get-GitRawDiffSha256 -WorkingDirectory $workingDirectory -SourceRevision $sourceRevision -TargetRevision $targetRevision
                            if ([string]$proof.raw_diff_sha256 -cne $actualRawDiffDigest) {
                                Add-Issue -Code 'review_gate_administrative_raw_diff_mismatch' -Subject $subject -Message 'raw_diff_sha256 does not match the exact Git raw diff.' -Expected $actualRawDiffDigest -Actual $proof.raw_diff_sha256
                                $bindingValid = $false
                            }
                        }
                        catch {
                            Add-Issue -Code 'review_gate_administrative_proof_unverifiable' -Subject $subject -Message 'Administrative descendant proof could not be verified from Git.' -Actual $_.Exception.Message
                            $bindingValid = $false
                        }
                    }
                }

                if ($binding -eq 'repository-verifier') {
                    Add-Issue -Code 'review_gate_verifier_unsupported' -Subject $subject -Message 'repository-verifier is reserved until a repository-owned executable contract can recompute field selectors from Git. Mixed-semantic changes require a fresh exact review.' -Expected 'exact or administrative-descendant' -Actual $binding
                    $bindingValid = $false
                }

                $reviewGateBindingValid = $bindingValid
            }
        }
    }

    if ($null -ne $currentReview) {
        if ($currentReview.status -eq 'passed' -and $currentReview.verdict -ne 'review passed') {
            Add-Issue -Code 'review_verdict_invalid' -Subject $subject -Message 'A current passed review requires the literal verdict review passed.' -Expected 'review passed' -Actual $currentReview.verdict
        }
        if ($currentReview.verdict -eq 'review passed' -and $currentReview.status -ne 'passed') {
            Add-Issue -Code 'review_status_invalid' -Subject $subject -Message 'The current verdict review passed requires review status passed.' -Expected 'passed' -Actual $currentReview.status
        }
        if ($currentReview.status -eq 'failed' -and $currentReview.verdict -ne 'review failed') {
            Add-Issue -Code 'review_verdict_invalid' -Subject $subject -Message 'A current failed review requires the literal verdict review failed.' -Expected 'review failed' -Actual $currentReview.verdict
        }
        if ($currentReview.verdict -eq 'review failed' -and $currentReview.status -ne 'failed') {
            Add-Issue -Code 'review_status_invalid' -Subject $subject -Message 'The current verdict review failed requires review status failed.' -Expected 'failed' -Actual $currentReview.status
        }
    }
    if ($currentReviewConsumesPendingWip -and $null -ne $currentReview -and $currentReview.status -in @('pending', 'reviewing')) {
        $pendingReviewCount++
    }
    $hasPassedReview = $reviewGateBindingValid -and
        $null -ne $currentReview -and
        $currentReview.status -eq 'passed' -and
        $currentReview.verdict -eq 'review passed'

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
$resultContext.pending_review_count = if ($pendingReviewUsageKnown) { $pendingReviewCount } else { $null }
$resultContext.wip_usage.active_repairs = $activeCandidatePaths.Count
$resultContext.wip_usage.pending_reviews = if ($pendingReviewUsageKnown) { $pendingReviewCount } else { $null }

$activeRepairLimit = $budgetValues.active_repairs
$pendingReviewLimit = $budgetValues.pending_reviews
$integrationBatchLimit = $budgetValues.integration_batches

if ($activeCandidatePaths.Count -gt $activeRepairLimit) {
    Add-Issue -Code 'wip_active_repairs_exceeded' -Subject 'wip' -Message 'Active candidate count exceeds the recorded WIP budget.' -Expected $activeRepairLimit -Actual $activeCandidatePaths.Count
}
if ($pendingReviewUsageKnown -and $pendingReviewCount -gt $pendingReviewLimit) {
    Add-Issue -Code 'wip_pending_reviews_exceeded' -Subject 'wip' -Message 'Pending review count exceeds the recorded WIP budget.' -Expected $pendingReviewLimit -Actual $pendingReviewCount
}
if ($integrationUsageKnown -and $integrationBatchIds.Count -gt $integrationBatchLimit) {
    Add-Issue -Code 'wip_integration_batches_exceeded' -Subject 'wip' -Message 'Active current-epoch integration intent count exceeds the recorded WIP budget.' -Expected $integrationBatchLimit -Actual $integrationBatchIds.Count
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

    if ($soloMode) {
        # Solo execution mode: startup reconciliation replaces lease expiry as the staleness guard.
        continue
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
