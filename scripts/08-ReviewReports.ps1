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

try {
    $run = New-ArchiveRun -ScriptName "08-ReviewReports" -ConfigPath $ConfigPath -RootPath $RootPath -OutputPath $OutputPath -VerboseLog:$VerboseLog
    $inventory = @(Import-ArchiveCsv -Path (Join-Path $run.OutputPath "inventory/inventory.csv"))

    $exactPath = Join-Path $run.OutputPath "reports/exact-duplicates.csv"
    $errorsPath = Join-Path $run.OutputPath "inventory/file-errors.csv"
    $extractPath = Join-Path $run.OutputPath "reports/extraction-status.csv"
    $transcriptPath = Join-Path $run.OutputPath "reports/transcription-status.csv"

    $duplicates = @(if (Test-Path -LiteralPath $exactPath) { Import-ArchiveCsv -Path $exactPath })
    $fileErrors = @(if (Test-Path -LiteralPath $errorsPath) { Import-ArchiveCsv -Path $errorsPath })
    $extractions = @(if (Test-Path -LiteralPath $extractPath) { Import-ArchiveCsv -Path $extractPath })
    $transcripts = @(if (Test-Path -LiteralPath $transcriptPath) { Import-ArchiveCsv -Path $transcriptPath })

    $actionRows = foreach ($dupe in $duplicates) {
        if ($dupe.recommended_action -ne "keep") {
            [pscustomobject]@{
                approved = "no"
                action = "quarantine"
                path = $dupe.path
                destination = ""
                reason = "duplicate_candidate:$($dupe.duplicate_group_id)"
            }
        }
    }

    $summary = @(
        "# Archive Review Summary"
        ""
        "- Generated: $(Get-Date -Format o)"
        "- Inventory rows: $($inventory.Count)"
        "- Exact duplicate report rows: $($duplicates.Count)"
        "- File errors: $($fileErrors.Count)"
        "- Extraction rows: $($extractions.Count)"
        "- Transcription rows: $($transcripts.Count)"
        ""
        "## Safety"
        ""
        "No files have been deleted or moved by reports. Review `actions-template.csv` before using `09-ApplyReviewedActions.ps1`."
    ) -join [Environment]::NewLine

    if (-not $DryRun) {
        $summary | Set-Content -LiteralPath (Join-Path $run.OutputPath "reports/review-summary.md") -Encoding UTF8
        Export-ArchiveCsv -Rows @($actionRows) -Path (Join-Path $run.OutputPath "reports/actions-template.csv")
    }

    Write-ArchiveLog -Run $run -Message "Review summary generated"
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
