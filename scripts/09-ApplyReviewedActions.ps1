param(
    [string]$ConfigPath,
    [string]$RootPath,
    [string]$OutputPath,
    [switch]$DryRun,
    [switch]$Resume,
    [switch]$VerboseLog,
    [string]$ApprovedManifest,
    [switch]$AllowDelete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "common/ArchiveAgent.Common.psm1") -Force -DisableNameChecking

try {
    $run = New-ArchiveRun -ScriptName "09-ApplyReviewedActions" -ConfigPath $ConfigPath -RootPath $RootPath -OutputPath $OutputPath -VerboseLog:$VerboseLog

    if (-not $run.Config.actions.enableApplyReviewedActions) {
        throw "Reviewed actions are disabled in config. Set actions.enableApplyReviewedActions to true after review."
    }

    if ([string]::IsNullOrWhiteSpace($ApprovedManifest)) {
        throw "Approved manifest is required. Refusing to act without -ApprovedManifest."
    }

    $manifestPath = Resolve-ArchivePath -PathValue $ApprovedManifest -BasePath $run.ToolkitRoot

    # Validate manifest has required columns before processing
    $manifestCheck = Test-ArchiveCsvColumns -Path $manifestPath -RequiredColumns @("approved", "action", "path")
    if (-not $manifestCheck.Valid) {
        throw "Approved manifest is missing required columns: $($manifestCheck.Missing -join ', '). File: $manifestPath"
    }

    $actions = @(Import-ArchiveCsv -Path $manifestPath)
    $quarantinePath = Resolve-ArchivePath -PathValue ([string]$run.Config.actions.quarantinePath) -BasePath $run.ToolkitRoot
    Ensure-ArchiveDirectory -Path $quarantinePath

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($row in $actions) {
        if ($row.approved -ne "yes") {
            $results.Add([pscustomobject]@{ path = $row.path; action = $row.action; status = "skipped_not_approved"; message = "" })
            continue
        }

        if (-not (Test-Path -LiteralPath $row.path -PathType Leaf)) {
            $results.Add([pscustomobject]@{ path = $row.path; action = $row.action; status = "missing"; message = "Source file not found." })
            continue
        }

        if ($row.action -eq "quarantine" -or $row.action -eq "move") {
            $destinationRoot = if (-not [string]::IsNullOrWhiteSpace($row.destination)) { $row.destination } else { $quarantinePath }
            $destinationRoot = Resolve-ArchivePath -PathValue $destinationRoot -BasePath $run.ToolkitRoot
            Ensure-ArchiveDirectory -Path $destinationRoot
            $destination = Join-Path $destinationRoot ([System.IO.Path]::GetFileName($row.path))

            if ($DryRun) {
                $results.Add([pscustomobject]@{ path = $row.path; action = $row.action; status = "dry_run"; message = "Would move to $destination" })
            }
            else {
                Move-Item -LiteralPath $row.path -Destination $destination -ErrorAction Stop
                $results.Add([pscustomobject]@{ path = $row.path; action = $row.action; status = "moved"; message = $destination })
            }
        }
        elseif ($row.action -eq "delete") {
            $configAllowsDelete = $run.Config.safety -and [bool]$run.Config.safety.allowDelete
            if (-not ($AllowDelete -and $configAllowsDelete)) {
                $results.Add([pscustomobject]@{ path = $row.path; action = $row.action; status = "refused_delete_disabled"; message = "Requires -AllowDelete and safety.allowDelete=true." })
                continue
            }

            if ($DryRun) {
                $results.Add([pscustomobject]@{ path = $row.path; action = $row.action; status = "dry_run"; message = "Would delete." })
            }
            else {
                Remove-Item -LiteralPath $row.path -ErrorAction Stop
                $results.Add([pscustomobject]@{ path = $row.path; action = $row.action; status = "deleted"; message = "" })
            }
        }
        else {
            $results.Add([pscustomobject]@{ path = $row.path; action = $row.action; status = "unknown_action"; message = "Allowed actions: quarantine, move, delete." })
        }
    }

    Export-ArchiveCsv -Rows $results -Path (Join-Path $run.OutputPath "reports/applied-actions.csv")
    Write-ArchiveLog -Run $run -Message "Reviewed actions processed: $($results.Count)"
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
