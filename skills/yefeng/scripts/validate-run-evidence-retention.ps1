[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ControlRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$issues = [System.Collections.Generic.List[string]]::new()

function Normalize-Path([string]$Value) {
  $full = [System.IO.Path]::GetFullPath($Value)
  $root = [System.IO.Path]::GetPathRoot($full)
  if ($full.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $root }
  return $full.TrimEnd('\', '/')
}

function Test-PathWithin([string]$Child, [string]$Parent) {
  $childPath = (Normalize-Path $Child) + [System.IO.Path]::DirectorySeparatorChar
  $parentPath = (Normalize-Path $Parent) + [System.IO.Path]::DirectorySeparatorChar
  return $childPath.StartsWith($parentPath, [System.StringComparison]::OrdinalIgnoreCase)
}

function Find-ReparsePointInExistingPathChain([string]$PathValue) {
  $fullPath = Normalize-Path $PathValue
  $pathRoot = Normalize-Path ([System.IO.Path]::GetPathRoot($fullPath))
  $probe = $fullPath
  while (-not (Test-Path -LiteralPath $probe)) {
    if ($probe.Equals($pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $fullPath }
    $parent = Split-Path -Parent $probe
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { return $fullPath }
    $probe = Normalize-Path $parent
  }
  while ($true) {
    $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $probe }
    if ($probe.Equals($pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) { break }
    $probe = Normalize-Path (Split-Path -Parent $probe)
  }
  return $null
}

function Get-NormalizedManifestCarrierHash([string]$PathValue) {
  $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
  $text = [System.IO.File]::ReadAllText($PathValue, $strictUtf8)
  $startMarker = '# RETENTION_TRUST_MANIFEST_START'
  $endMarker = '# RETENTION_TRUST_MANIFEST_END'
  $startMatch = [Text.RegularExpressions.Regex]::Match($text, "(?m)^$startMarker`r?$")
  $endMatch = [Text.RegularExpressions.Regex]::Match($text, "(?m)^$endMarker`r?$")
  if (-not $startMatch.Success -or -not $endMatch.Success -or $endMatch.Index -le $startMatch.Index) {
    throw "Retention manifest carrier markers are missing or out of order: $PathValue"
  }
  $startIndex = $startMatch.Index
  $blockLength = ($endMatch.Index + $endMatch.Length) - $startIndex
  $block = $text.Substring($startIndex, $blockLength)
  $hashPattern = "(?i)'[0-9a-f]{64}'"
  $matches = [Text.RegularExpressions.Regex]::Matches($block, $hashPattern)
  if ($matches.Count -ne 5) {
    throw "Retention manifest carrier must contain exactly five fixed hash slots: $PathValue"
  }
  $normalizedBlock = [Text.RegularExpressions.Regex]::Replace($block, $hashPattern, ("'" + ('0' * 64) + "'"))
  $normalizedText = $text.Substring(0, $startIndex) + $normalizedBlock + $text.Substring($startIndex + $blockLength)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($strictUtf8.GetBytes($normalizedText)))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-RetentionArtifactHash([string]$PathValue, [string]$FileName) {
  if ($FileName -in @('install-governed-runner.ps1', 'validate-run-evidence-retention.ps1')) {
    return Get-NormalizedManifestCarrierHash $PathValue
  }
  return (Get-FileHash -LiteralPath $PathValue -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-RetentionManifestCarrierMatches(
  [string]$PathValue,
  [System.Collections.IDictionary]$ExpectedManifest
) {
  $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
  $text = [System.IO.File]::ReadAllText($PathValue, $strictUtf8)
  $startMatches = [Text.RegularExpressions.Regex]::Matches($text, '(?m)^# RETENTION_TRUST_MANIFEST_START\r?$')
  $endMatches = [Text.RegularExpressions.Regex]::Matches($text, '(?m)^# RETENTION_TRUST_MANIFEST_END\r?$')
  if ($startMatches.Count -ne 1 -or $endMatches.Count -ne 1) {
    throw "Retention manifest carrier must contain one unique marker pair: $PathValue"
  }
  $startMatch = $startMatches[0]
  $endMatch = $endMatches[0]
  if ($endMatch.Index -le $startMatch.Index) {
    throw "Retention manifest carrier markers are out of order: $PathValue"
  }
  $block = $text.Substring(
    $startMatch.Index,
    ($endMatch.Index + $endMatch.Length) - $startMatch.Index
  )
  $matches = [Text.RegularExpressions.Regex]::Matches(
    $block,
    "(?m)^\s*'([^']+)'\s*=\s*'([0-9a-f]{64})'\s*$"
  )
  if ($matches.Count -ne 5) {
    throw "Retention manifest carrier must contain exactly five named hash entries: $PathValue"
  }
  $actualManifest = @{}
  foreach ($match in $matches) {
    $name = [string]$match.Groups[1].Value
    if ($actualManifest.ContainsKey($name)) {
      throw "Retention manifest carrier contains a duplicate entry: $name"
    }
    $actualManifest[$name] = [string]$match.Groups[2].Value
  }
  foreach ($entry in $ExpectedManifest.GetEnumerator()) {
    if (
      -not $actualManifest.ContainsKey([string]$entry.Key) -or
      [string]$actualManifest[[string]$entry.Key] -cne [string]$entry.Value
    ) {
      throw "Retention manifest carrier values disagree: $PathValue / $($entry.Key)"
    }
  }
}

# RETENTION TRUST INVARIANT (keep this comment identical in both carriers):
# The marked block must contain exactly five single-quoted 64-hex value slots.
# Adding a sixth slot or moving a trusted hash outside the block must fail tests.
# RETENTION_TRUST_MANIFEST_START
$retentionManifest = [ordered]@{
  'compact-run-evidence.ps1' = 'ebf15689e53e9d482c2f0b38c9f02e5edd47469633694afb2e5c438dc080e41d'
  'run-retention-policy.json' = '295df97cd07341663fe1716f310c372fccaaed7a553c560c2e364c91d93dcb4b'
  'test-run-evidence-retention.ps1' = '43d28c6fdded85579518b8035bbfdd65d48faf1ff4b1a789b88d47c67a570b0b'
  'install-governed-runner.ps1' = '6893bee6c2703671551880ac404b9ff36cbe66146e7346680b90cdfd7c6e8cd0'
  'validate-run-evidence-retention.ps1' = 'a536cc130ff796a2b96e285cddf4763dd7245202519827afe2459d0df6440eef'
}
# RETENTION_TRUST_MANIFEST_END

$controlRootPath = ''
try {
  $controlRootPath = Normalize-Path $ControlRoot
  if (-not (Test-Path -LiteralPath $controlRootPath -PathType Container)) {
    $issues.Add("Control root does not exist: $controlRootPath")
  } elseif (Find-ReparsePointInExistingPathChain $controlRootPath) {
    $issues.Add("Control root traverses a reparse point: $controlRootPath")
  } else {
    $gitOutput = @(& git -C $controlRootPath rev-parse --show-toplevel 2>&1)
    if ($LASTEXITCODE -ne 0) {
      $issues.Add("Control root is not a Git repository: $controlRootPath / $($gitOutput -join ' ')")
    } else {
      $gitTop = Normalize-Path (($gitOutput -join [Environment]::NewLine).Trim())
      if (-not $gitTop.Equals($controlRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $issues.Add("Control root is not an exact Git top level: $controlRootPath")
      }
    }
  }
} catch {
  $issues.Add("Invalid control root: $($_.Exception.Message)")
}

$scriptsRoot = if ($controlRootPath) { Normalize-Path (Join-Path $controlRootPath 'scripts\yefeng') } else { '' }
if ($scriptsRoot -and -not (Test-PathWithin $scriptsRoot $controlRootPath)) {
  $issues.Add('Retention scripts root escaped the control repository.')
}

foreach ($entry in $retentionManifest.GetEnumerator()) {
  $artifactPath = Join-Path $scriptsRoot ([string]$entry.Key)
  if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
    $issues.Add("Partial retention helper installation is missing: $($entry.Key)")
    continue
  }
  try {
    if (Find-ReparsePointInExistingPathChain $artifactPath) {
      $issues.Add("Retention helper traverses a reparse point: $($entry.Key)")
      continue
    }
    if ((Get-RetentionArtifactHash $artifactPath ([string]$entry.Key)) -cne [string]$entry.Value) {
      $issues.Add("Retention helper hash mismatch: $($entry.Key)")
    }
  } catch {
    $issues.Add("Retention helper validation failed: $($entry.Key) / $($_.Exception.Message)")
  }
}
foreach ($carrierName in @('install-governed-runner.ps1', 'validate-run-evidence-retention.ps1')) {
  $carrierPath = Join-Path $scriptsRoot $carrierName
  if (Test-Path -LiteralPath $carrierPath -PathType Leaf) {
    try {
      Assert-RetentionManifestCarrierMatches $carrierPath $retentionManifest
    } catch {
      $issues.Add("Retention carrier manifest mismatch: $carrierName / $($_.Exception.Message)")
    }
  }
}

$policyPath = Join-Path $scriptsRoot 'run-retention-policy.json'
if (Test-Path -LiteralPath $policyPath -PathType Leaf) {
  try {
    $policy = Get-Content -LiteralPath $policyPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $expectedFields = @(
      'version', 'dry_run_default', 'terminal_age_hours', 'superseded_retention_days',
      'long_log_threshold_bytes', 'scope_soft_cap_bytes', 'overall_cap_bytes',
      'receipt_max_bytes', 'keep_last_failures_per_group', 'keep_final_passes_per_group',
      'apply_window_minutes', 'max_candidates_per_plan', 'allowed_leaf_logs'
    )
    $actualFields = @($policy.PSObject.Properties | ForEach-Object { [string]$_.Name })
    foreach ($field in $expectedFields) {
      if ($actualFields -notcontains $field) { $issues.Add("Retention policy field is missing: $field") }
    }
    foreach ($field in $actualFields) {
      if ($expectedFields -notcontains $field) { $issues.Add("Retention policy field is unknown: $field") }
    }
    if ([int]$policy.version -ne 1) { $issues.Add('Retention policy version must be 1.') }
    if ($policy.dry_run_default -isnot [bool] -or -not $policy.dry_run_default) {
      $issues.Add('Retention policy must default to dry-run.')
    }
    $expectedDefaults = [ordered]@{
      terminal_age_hours = 24
      superseded_retention_days = 7
      long_log_threshold_bytes = 1048576
      scope_soft_cap_bytes = 536870912
      overall_cap_bytes = 1073741824
      receipt_max_bytes = 65536
      keep_last_failures_per_group = 1
      keep_final_passes_per_group = 1
      apply_window_minutes = 60
      max_candidates_per_plan = 64
    }
    foreach ($entry in $expectedDefaults.GetEnumerator()) {
      if ([int64]$policy.($entry.Key) -ne [int64]$entry.Value) {
        $issues.Add("Retention policy default mismatch: $($entry.Key)")
      }
    }
    $exactLeaves = @('stdout.jsonl', 'stderr.log', 'worker-stdout.log', 'worker-stderr.log')
    if (@($policy.allowed_leaf_logs).Count -ne $exactLeaves.Count) {
      $issues.Add('Retention policy allowed leaf set is not exact.')
    } else {
      foreach ($leaf in $exactLeaves) {
        if (@($policy.allowed_leaf_logs) -notcontains $leaf) {
          $issues.Add("Retention policy is missing allowed leaf: $leaf")
        }
      }
    }
  } catch {
    $issues.Add("Invalid retention policy JSON: $($_.Exception.Message)")
  }
}

$result = [ordered]@{
  valid = ($issues.Count -eq 0)
  control_root = $controlRootPath
  validator_scope = 'run-evidence-retention-only'
  retention_manifest = $retentionManifest
  issues = @($issues)
}
$result | ConvertTo-Json -Depth 10
if (-not $result.valid) { exit 1 }
