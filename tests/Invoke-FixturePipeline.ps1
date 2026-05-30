param(
    [string]$ToolkitRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
    $ToolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
}

$root = Join-Path $ToolkitRoot "tests/fixtures/source"
$output = Join-Path $ToolkitRoot "outputs"
$config = Join-Path $ToolkitRoot "config/pipeline.example.json"

$sourceBefore = Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object {
    [pscustomobject]@{ path = $_.FullName; hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
}

$scripts = @(
    "01-Inventory.ps1",
    "02-Metadata.ps1",
    "03-Dedupe.ps1",
    "04-ExtractText.ps1",
    "05-TranscribeMedia.ps1",
    "06-ClassifyThemes.ps1",
    "07-BuildKnowledgeBase.ps1",
    "08-ReviewReports.ps1"
)

foreach ($script in $scripts) {
    $path = Join-Path $ToolkitRoot "scripts/$script"
    & $path -ConfigPath $config -RootPath $root -OutputPath $output
    if ($LASTEXITCODE -notin @(0, 3)) {
        throw "$script failed with exit code $LASTEXITCODE"
    }
}

$sourceAfter = Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object {
    [pscustomobject]@{ path = $_.FullName; hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
}

$beforeMap = @{}
foreach ($row in $sourceBefore) { $beforeMap[$row.path] = $row.hash }
foreach ($row in $sourceAfter) {
    if (-not $beforeMap.ContainsKey($row.path)) {
        throw "Unexpected source file appeared: $($row.path)"
    }
    if ($beforeMap[$row.path] -ne $row.hash) {
        throw "Source fixture changed: $($row.path)"
    }
}

foreach ($expected in @(
    "inventory/inventory.csv",
    "metadata/metadata.csv",
    "reports/exact-duplicates.csv",
    "reports/extraction-status.csv",
    "classification/classification.csv",
    "reports/review-summary.md"
)) {
    $path = Join-Path $output $expected
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Expected output missing: $path"
    }
}

Write-Host "Fixture pipeline completed without modifying source fixtures."
exit 0
