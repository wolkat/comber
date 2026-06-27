param(
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ToolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$config = Join-Path $ToolkitRoot "config/test-pics.json"
$root = "/Users/katops/git/test_pics"
$output = Join-Path $ToolkitRoot "outputs/test-pics"

# Pre-flight: verify config exists
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
    throw "Config not found: $config"
}

# Pre-flight: verify source exists
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Source directory not found: $root"
}

# Pre-flight: tool availability
Write-Host "`n=== Tool Availability ===" -ForegroundColor Cyan
foreach ($tool in @("exiftool", "ffprobe", "tesseract", "czkawka_cli")) {
    $found = Get-Command $tool -ErrorAction SilentlyContinue
    if ($found) {
        Write-Host "  [OK] $tool" -ForegroundColor Green
    } else {
        Write-Host "  [--] $tool (not found, features requiring it will be skipped)" -ForegroundColor Yellow
    }
}
Write-Host ""

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

$dryRunArgs = @{}
if ($DryRun) {
    $dryRunArgs["DryRun"] = $true
    Write-Host "=== DRY RUN MODE ===" -ForegroundColor Yellow
}

Write-Host "Source: $root"
Write-Host "Output: $output"
Write-Host ""

foreach ($script in $scripts) {
    $path = Join-Path $ToolkitRoot "scripts/$script"
    Write-Host "--- Running $script ---" -ForegroundColor Cyan
    & $path -ConfigPath $config -RootPath $root -OutputPath $output @dryRunArgs
    if ($LASTEXITCODE -notin @(0, 3)) {
        throw "$script failed with exit code $LASTEXITCODE"
    }
    if ($LASTEXITCODE -eq 3) {
        Write-Host "  (partial success, continuing)" -ForegroundColor Yellow
    }
}

# Summary: check which outputs exist
Write-Host "`n=== Output Summary ===" -ForegroundColor Cyan
foreach ($expected in @(
    "inventory/inventory.csv",
    "metadata/metadata.csv",
    "reports/exact-duplicates.csv",
    "reports/near-duplicate-status.csv",
    "reports/extraction-status.csv",
    "classification/classification.csv",
    "reports/review-summary.md"
)) {
    $outPath = Join-Path $output $expected
    if (Test-Path -LiteralPath $outPath -PathType Leaf) {
        $size = (Get-Item -LiteralPath $outPath).Length
        Write-Host "  [OK] $expected ($size bytes)" -ForegroundColor Green
    } else {
        Write-Host "  [--] $expected (not generated)" -ForegroundColor Yellow
    }
}

Write-Host "`nDone." -ForegroundColor Green
exit 0
