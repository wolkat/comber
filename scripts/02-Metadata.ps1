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

function Get-MediaSubType {
    param($Path, $Template)

    $result = Invoke-ArchiveConfiguredCommand -Template $Template -Path $Path

    if (-not $result.Available) {
        return [pscustomobject]@{
            path = $Path
            media_subtype = ""
            codec = ""
            width = 0
            height = 0
            duration = ""
            probe_status = "ffprobe_missing"
        }
    }

    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) {
        return [pscustomobject]@{
            path = $Path
            media_subtype = ""
            codec = ""
            width = 0
            height = 0
            duration = ""
            probe_status = "ffprobe_error"
        }
    }

    try {
        $json = $result.Output | ConvertFrom-Json -Depth 10

        $videoStream = $null
        $hasAudio = $false

        if ($json.streams) {
            foreach ($stream in $json.streams) {
                if ($stream.codec_type -eq "video") {
                    $videoStream = $stream
                }
                elseif ($stream.codec_type -eq "audio") {
                    $hasAudio = $true
                }
            }
        }

        $codec = ""
        $width = 0
        $height = 0
        $duration = ""
        $subtype = "unknown"

        if ($null -ne $videoStream) {
            $codec = if ($videoStream.codec_name) { [string]$videoStream.codec_name } else { "" }
            $width = if ($null -ne $videoStream.width) { [int]$videoStream.width } else { 0 }
            $height = if ($null -ne $videoStream.height) { [int]$videoStream.height } else { 0 }

            if ([string]::IsNullOrWhiteSpace($codec) -or $codec -eq "none" -or $width -eq 0 -or $height -eq 0) {
                $subtype = "slideshow"
            }
            else {
                $subtype = "video"
            }
        }
        elseif ($hasAudio) {
            $subtype = "audio_only"
        }

        if ($json.format -and $json.format.duration) {
            $duration = [string]$json.format.duration
        }

        return [pscustomobject]@{
            path = $Path
            media_subtype = $subtype
            codec = $codec
            width = $width
            height = $height
            duration = $duration
            probe_status = "ffprobe_ok"
        }
    }
    catch {
        return [pscustomobject]@{
            path = $Path
            media_subtype = ""
            codec = ""
            width = 0
            height = 0
            duration = ""
            probe_status = "ffprobe_parse_error"
        }
    }
}

try {
    $run = New-ArchiveRun -ScriptName "02-Metadata" -ConfigPath $ConfigPath -RootPath $RootPath -OutputPath $OutputPath -VerboseLog:$VerboseLog
    $inventoryPath = Join-Path $run.OutputPath "inventory/inventory.csv"
    $invCheck = Test-ArchiveCsvColumns -Path $inventoryPath -RequiredColumns @("path", "category", "name", "modified_utc", "created_utc")
    if (-not $invCheck.Valid) {
        throw "Inventory CSV is missing required columns for metadata stage: $($invCheck.Missing -join ', ')"
    }
    $inventory = @(Import-ArchiveCsv -Path $inventoryPath)
    $rows = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    $enableExifTool = $run.Config.metadata -and [bool]$run.Config.metadata.enableExifTool
    $enableMediaProbe = $run.Config.metadata -and [bool]$run.Config.metadata.enableMediaProbe

    foreach ($item in $inventory) {
        $exifData = $null
        $metadataStatus = "filesystem_only"

        if ($enableExifTool -and $run.Config.metadata.exifToolJson) {
            $result = Invoke-ArchiveConfiguredCommand -Template $run.Config.metadata.exifToolJson -Path $item.path
            try {
                Assert-ArchiveCommandSuccess -Result $result -ToolName "exiftool" -Stage "02-Metadata"
                $parsed = $result.Output | ConvertFrom-Json -Depth 50
                if (@($parsed).Count -gt 0) {
                    $exifData = @($parsed)[0]
                    $metadataStatus = "exiftool_ok"
                }
            }
            catch {
                $metadataStatus = if (-not $result.Available) { "exiftool_missing" } elseif ($result.ExitCode -ne 0) { "exiftool_error" } else { "exiftool_parse_error" }
                $errors.Add([pscustomobject]@{ stage = "02-Metadata"; path = $item.path; error = $_.Exception.Message })
            }
        }

        $mediaProbeData = $null
        $mediaSubtype = ""

        if ($enableMediaProbe -and ($item.category -eq "video" -or $item.category -eq "audio") -and $run.Config.metadata.ffprobe) {
            $probeResult = Get-MediaSubType -Path $item.path -Template $run.Config.metadata.ffprobe
            $mediaProbeData = $probeResult
            $mediaSubtype = $probeResult.media_subtype

            if ($probeResult.probe_status -ne "ffprobe_ok") {
                $errors.Add([pscustomobject]@{
                    stage = "02-Metadata"
                    path = $item.path
                    error = "ffprobe probe_status=$($probeResult.probe_status)"
                })
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
                ffprobe = $mediaProbeData
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
            media_subtype = $mediaSubtype
            sidecar_path = $sidecarPath
        })
    }

    if (-not $DryRun) {
        Export-ArchiveCsv -Rows $rows -Path (Join-Path $run.OutputPath "metadata/metadata.csv") -Schema @('path','metadata_status','media_subtype','sidecar_path')
        Export-ArchiveCsv -Rows $errors -Path (Join-Path $run.OutputPath "metadata/metadata-errors.csv") -Schema @('stage','path','error')
    }

    Write-ArchiveLog -Run $run -Message "Processed metadata rows: $($rows.Count)"
    if ($errors.Count -gt 0) { exit 3 }
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
