param(
    [string]$ToolkitRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
    $ToolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
}

$scriptRoot = Join-Path $ToolkitRoot "scripts"
$scriptFiles = Get-ChildItem -LiteralPath $scriptRoot -Filter "*.ps1" -Recurse
$testFiles = Get-ChildItem -LiteralPath (Join-Path $ToolkitRoot "tests") -Filter "*.ps1" -Recurse
$moduleFiles = Get-ChildItem -LiteralPath $ToolkitRoot -Filter "*.psm1" -Recurse
$files = @($scriptFiles + $testFiles + $moduleFiles)
$failures = New-Object System.Collections.Generic.List[object]

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($err in $errors) {
        $failures.Add([pscustomobject]@{
            path = $file.FullName
            line = $err.Extent.StartLineNumber
            message = $err.Message
        })
    }
}

$actionScripts = @(
    (Join-Path $ToolkitRoot "scripts/09-ApplyReviewedActions.ps1"),
    (Join-Path $ToolkitRoot "scripts/10-Cleanup.ps1")
)
$nonActionDestructive = $scriptFiles | Where-Object { $_.FullName -notin $actionScripts } | ForEach-Object {
    $content = Get-Content -LiteralPath $_.FullName -Raw
    if ($content -match '\bRemove-Item\b' -or $content -match '\bMove-Item\b') {
        $_.FullName
    }
}

foreach ($path in $nonActionDestructive) {
    $failures.Add([pscustomobject]@{
        path = $path
        line = 0
        message = "Remove-Item or Move-Item appears outside reviewed action script."
    })
}

if ($failures.Count -gt 0) {
    $failures | Format-Table -AutoSize
    exit 1
}

Write-Host "Static checks passed for $($files.Count) PowerShell files."
exit 0
