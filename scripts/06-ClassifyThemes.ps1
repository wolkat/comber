param(
    [string]$ConfigPath,
    [string]$RootPath,
    [string]$OutputPath,
    [switch]$DryRun,
    [switch]$Resume,
    [switch]$VerboseLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "common/ArchiveAgent.Common.psm1") -Force -DisableNameChecking

function Get-HeuristicTags {
    param($Item)

    $tags = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Item.category)) { $tags.Add($Item.category) }
    if (-not [string]::IsNullOrWhiteSpace($Item.extension)) { $tags.Add($Item.extension.TrimStart(".")) }

    $name = ([string]$Item.name).ToLowerInvariant()
    foreach ($word in @("invoice", "receipt", "screenshot", "photo", "scan", "contract", "recording", "backup")) {
        if ($name.Contains($word)) { $tags.Add($word) }
    }

    return (($tags | Select-Object -Unique) -join ";")
}

try {
    $run = New-ArchiveRun -ScriptName "06-ClassifyThemes" -ConfigPath $ConfigPath -RootPath $RootPath -OutputPath $OutputPath -VerboseLog:$VerboseLog
    $inventory = @(Import-ArchiveCsv -Path (Join-Path $run.OutputPath "inventory/inventory.csv"))
    $modelEnabled = $run.Config.classification -and [bool]$run.Config.classification.enabled
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($item in $inventory) {
        $tags = Get-HeuristicTags -Item $item
        $status = if ($modelEnabled) { "model_not_invoked_without_reviewed_template" } else { "heuristic_only" }
        $summary = "File categorized as $($item.category)."

        $rows.Add([pscustomobject]@{
            path = $item.path
            category = $item.category
            tags = $tags
            theme = $item.category
            summary = $summary
            confidence = "low"
            reason = "Heuristic tags from category, extension, and filename. LLM classification is optional and disabled unless reviewed."
            classification_status = $status
        })
    }

    if (-not $DryRun) {
        Export-ArchiveCsv -Rows $rows -Path (Join-Path $run.OutputPath "classification/classification.csv")
    }

    Write-ArchiveLog -Run $run -Message "Classification rows: $($rows.Count)"
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
