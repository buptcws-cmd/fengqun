[CmdletBinding()]
param(
  [string]$ValidatedSourceRoot = 'D:\fengchao-control',
  [Parameter(Mandatory = $true)]
  [string]$DestinationControlRoot,
  [string]$ExpectedCandidate = 'b282e83f746b6aa042e0e724166cb49c05da21e9'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-Path([string]$Value) {
  [System.IO.Path]::GetFullPath($Value).TrimEnd('\', '/')
}

$sourceRoot = Normalize-Path $ValidatedSourceRoot
$destinationRoot = Normalize-Path $DestinationControlRoot
foreach ($root in @($sourceRoot, $destinationRoot)) {
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Control root does not exist: $root"
  }
  $gitTop = Normalize-Path ((& git -C $root rev-parse --show-toplevel).Trim())
  if ($LASTEXITCODE -ne 0 -or
      -not $gitTop.Equals(
        $root,
        [System.StringComparison]::OrdinalIgnoreCase
      )) {
    throw "Control root is not an exact Git top level: $root"
  }
}

& git -C $sourceRoot cat-file -e "$ExpectedCandidate^{commit}"
if ($LASTEXITCODE -ne 0) {
  throw "Validated candidate does not exist: $ExpectedCandidate"
}

$files = [ordered]@{
  'scripts/yefeng/lib/runner-common.ps1' = '6de0eb2e4c7c8f0b46757a8e33eab66f5ca1608dc53ddc0f3242ded4b805be30'
  'scripts/yefeng/role-runner.ps1' = '3b763560b02a47bbd92cde20d5f07b05563ac75958707b5f65b9899feaa96d7b'
  'scripts/yefeng/run-backend-worker.ps1' = '9ed435941b5a9ce1212e1be4ce199be8b1a12250a87ac04feeda377be64f27b0'
  'scripts/yefeng/runner-policy.json' = '0b69a1754299e5b9b8e14d5866552e95cac002b6c3c04ecb2812ed833dc8c5c4'
  'scripts/yefeng/test-runner-contract.ps1' = '52efc0d51126cc8960839777728a7926e1e8fb76e8d2b47a87c9307707a9e9b8'
  'scripts/yefeng/test-runner-governance.ps1' = 'f7650e813d428672fb5c37393dae834cd7b61fc5310efd5168c3c86773698af1'
  'scripts/yefeng/test-runner-process-cleanup.ps1' = '60f7c5f02effb7f8515b17998def361d49bf8fe9153936d1ea003756e9b96604'
}

foreach ($entry in $files.GetEnumerator()) {
  $sourcePath = Join-Path $sourceRoot $entry.Key
  if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Validated runner file is missing: $($entry.Key)"
  }
  $actualHash = (
    Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256
  ).Hash.ToLowerInvariant()
  if ($actualHash -cne $entry.Value) {
    throw "Validated runner hash changed: $($entry.Key)"
  }
}

foreach ($entry in $files.GetEnumerator()) {
  $sourcePath = Join-Path $sourceRoot $entry.Key
  $destinationPath = Join-Path $destinationRoot $entry.Key
  $destinationParent = Split-Path -Parent $destinationPath
  if (-not (Test-Path -LiteralPath $destinationParent)) {
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
  }
  [System.IO.File]::Copy($sourcePath, $destinationPath, $true)
}

[pscustomobject]@{
  installed = $true
  source_root = $sourceRoot
  source_candidate = $ExpectedCandidate
  destination_root = $destinationRoot
  files = @($files.Keys)
} | ConvertTo-Json -Depth 5
