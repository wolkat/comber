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

function Select-BestDate {
    param($InventoryRow, $ExifData)

    if ($ExifData) {
        foreach ($field in @("DateTimeOriginal", "CreateDate", "MediaCreateDate", "ModifyDate")) {
            if ($ExifData.PSObject.Properties.Name -contains $field) {
                $value = [string]$ExifData.$field
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    return [pscustomobject]@{ value = $value; source = "exiftool:$field" }
                }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($InventoryRow.modified_utc)) {
        return [pscustomobject]@{ value = $InventoryRow.modified_utc; source = "filesystem:modified_utc" }
    }

    return [pscustomobject]@{ value = $InventoryRow.created_utc; source = "filesystem:created_utc" }
}

try {
    $run = New-ArchiveRun -ScriptName "02-Metadata" -ConfigPath $ConfigPath -RootPath $RootPath -OutputPath $OutputPath -VerboseLog:$VerboseLog
    $inventoryPath = Join-Path $run.OutputPath "inventory/inventory.csv"
    $inventory = @(Import-ArchiveCsv -Path $inventoryPath)
    $rows = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    $enableExifTool = $run.Config.metadata -and [bool]$run.Config.metadata.enableExifTool

    foreach ($item in $inventory) {
        $exifData = $null
        $metadataStatus = "filesystem_only"

        if ($enableExifTool -and $run.Config.metadata.exifToolJson) {
            $result = Invoke-ArchiveConfiguredCommand -Template $run.Config.metadata.exifToolJson -Path $item.path
            if ($result.Available -and $result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.Output)) {
                try {
                    $parsed = $result.Output | ConvertFrom-Json -Depth 50
                    if (@($parsed).Count -gt 0) {
                        $exifData = @($parsed)[0]
                        $metadataStatus = "exiftool_ok"
                    }
                }
                catch {
                    $metadataStatus = "exiftool_parse_error"
                    $errors.Add([pscustomobject]@{ stage = "02-Metadata"; path = $item.path; error = $_.Exception.Message })
                }
            }
            elseif (-not $result.Available) {
                $metadataStatus = "exiftool_missing"
            }
            elseif ($result.ExitCode -ne 0) {
                $metadataStatus = "exiftool_error"
                $errors.Add([pscustomobject]@{ stage = "02-Metadata"; path = $item.path; error = $result.Output + $result.Error })
            }
        }

        $best = Select-BestDate -InventoryRow $item -ExifData $exifData
        $sidecarName = (Get-ArchiveSafeStem -Path $item.path -PreferredName $item.name) + ".metadata.json"
        $sidecarPath = Join-Path $run.OutputPath "sidecars/$sidecarName"

        if (-not $DryRun) {
            $sidecar = [pscustomobject]@{
                source_path = $item.path
                inventory = $item
                exiftool = $exifData
                metadata_status = $metadataStatus
                best_datetime = $best.value
                best_datetime_source = $best.source
            }
            $sidecar | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $sidecarPath -Encoding UTF8
        }

        $rows.Add([pscustomobject]@{
            path = $item.path
            category = $item.category
            best_datetime = $best.value
            best_datetime_source = $best.source
            metadata_status = $metadataStatus
            sidecar_path = $sidecarPath
        })
    }

    if (-not $DryRun) {
        Export-ArchiveCsv -Rows $rows -Path (Join-Path $run.OutputPath "metadata/metadata.csv")
        Export-ArchiveCsv -Rows $errors -Path (Join-Path $run.OutputPath "metadata/metadata-errors.csv")
    }

    Write-ArchiveLog -Run $run -Message "Processed metadata rows: $($rows.Count)"
    if ($errors.Count -gt 0) { exit 3 }
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
