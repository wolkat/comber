param(
    [string]$ConfigPath,
    [string]$RootPath,
    [string]$OutputPath,
    [switch]$DryRun,
    [switch]$Resume,
    [switch]$VerboseLog,
    [switch]$AllowDelete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "common/ArchiveAgent.Common.psm1") -Force -DisableNameChecking

try {
    $run = New-ArchiveRun -ScriptName "10-Cleanup" -ConfigPath $ConfigPath -RootPath $RootPath -OutputPath $OutputPath -VerboseLog:$VerboseLog

    # Check if cleanup is enabled in config
    $cleanupEnabled = $run.Config.cleanup -and [bool]$run.Config.cleanup.enabled
    if (-not $cleanupEnabled) {
        Write-ArchiveLog -Run $run -Message "Cleanup is disabled in config. Skipping."
        exit 0
    }

    # Safety: require BOTH config.safety.allowDelete AND -AllowDelete flag
    $configAllowsDelete = $run.Config.safety -and [bool]$run.Config.safety.allowDelete
    if (-not ($AllowDelete -and $configAllowsDelete)) {
        Write-ArchiveLog -Run $run -Message "Cleanup requires both config.safety.allowDelete=true and -AllowDelete flag. Skipping."
        exit 0
    }

    # Determine targets from config
    $targets = @()
    if ($run.Config.cleanup.PSObject.Properties.Name -contains "targets" -and $run.Config.cleanup.targets) {
        $targets = @($run.Config.cleanup.targets)
    }
    if ($targets.Count -eq 0) {
        Write-ArchiveLog -Run $run -Message "No cleanup targets configured. Skipping."
        exit 0
    }

    # Validate targets against known values
    $validTargets = @("extracted", "transcripts", "sidecars")
    foreach ($t in $targets) {
        if ($t -notin $validTargets) {
            Write-ArchiveLog -Run $run -Message "Unknown cleanup target: '$t'. Valid targets: $($validTargets -join ', ')" -Level "WARN"
        }
    }

    $results = New-Object System.Collections.Generic.List[object]

    # Build lookup of successful extraction entries
    $extractionOk = @()
    $extractionStatusPath = Join-Path $run.OutputPath "reports/extraction-status.csv"
    if ($targets -contains "extracted" -and (Test-Path -LiteralPath $extractionStatusPath -PathType Leaf)) {
        $extractionStatus = @(Import-ArchiveCsv -Path $extractionStatusPath)
        foreach ($row in $extractionStatus) {
            if ($row.extraction_status -eq "ok" -and $row.markdown_path) {
                $extractionOk += [pscustomobject]@{
                    source_path = $row.path
                    artifact_path = $row.markdown_path
                }
            }
        }
        Write-ArchiveLog -Run $run -Message "Extraction 'ok' entries found: $($extractionOk.Count)"
    }

    # Build lookup of successful transcription entries
    $transcriptionOk = @()
    $transcriptionStatusPath = Join-Path $run.OutputPath "reports/transcription-status.csv"
    if ($targets -contains "transcripts" -and (Test-Path -LiteralPath $transcriptionStatusPath -PathType Leaf)) {
        $transcriptionStatus = @(Import-ArchiveCsv -Path $transcriptionStatusPath)
        foreach ($row in $transcriptionStatus) {
            if ($row.transcription_status -eq "ok" -and $row.transcript_path) {
                $transcriptionOk += [pscustomobject]@{
                    source_path = $row.path
                    artifact_path = $row.transcript_path
                }
            }
        }
        Write-ArchiveLog -Run $run -Message "Transcription 'ok' entries found: $($transcriptionOk.Count)"
    }

    # Build set of processed source paths for sidecar matching
    $processedPaths = New-Object System.Collections.Generic.List[string]
    if ($targets -contains "sidecars") {
        foreach ($entry in $extractionOk) { if ($entry.source_path -and $entry.source_path -notin $processedPaths) { $processedPaths.Add($entry.source_path) } }
        foreach ($entry in $transcriptionOk) { if ($entry.source_path -and $entry.source_path -notin $processedPaths) { $processedPaths.Add($entry.source_path) } }
    }

    # --- Process extracted markdown files ---
    foreach ($entry in $extractionOk) {
        $targetPath = Resolve-ArchivePath -PathValue $entry.artifact_path -BasePath $run.ToolkitRoot

        if ($DryRun) {
            $results.Add([pscustomobject]@{ path = $targetPath; action = "delete_extracted_md"; status = "dry_run"; message = "Would delete extracted markdown." })
        }
        else {
            try {
                Remove-Item -LiteralPath $targetPath -ErrorAction Stop
                $results.Add([pscustomobject]@{ path = $targetPath; action = "delete_extracted_md"; status = "deleted"; message = "" })
            }
            catch [System.IO.FileNotFoundException] {
                $results.Add([pscustomobject]@{ path = $targetPath; action = "delete_extracted_md"; status = "missing"; message = "Extracted markdown not found." })
            }
            catch {
                $results.Add([pscustomobject]@{ path = $targetPath; action = "delete_extracted_md"; status = "error"; message = $_.Exception.Message })
            }
        }
    }

    # --- Process transcript markdown files ---
    foreach ($entry in $transcriptionOk) {
        $targetPath = Resolve-ArchivePath -PathValue $entry.artifact_path -BasePath $run.ToolkitRoot

        if ($DryRun) {
            $results.Add([pscustomobject]@{ path = $targetPath; action = "delete_transcript_md"; status = "dry_run"; message = "Would delete transcript." })
        }
        else {
            try {
                Remove-Item -LiteralPath $targetPath -ErrorAction Stop
                $results.Add([pscustomobject]@{ path = $targetPath; action = "delete_transcript_md"; status = "deleted"; message = "" })
            }
            catch [System.IO.FileNotFoundException] {
                $results.Add([pscustomobject]@{ path = $targetPath; action = "delete_transcript_md"; status = "missing"; message = "Transcript not found." })
            }
            catch {
                $results.Add([pscustomobject]@{ path = $targetPath; action = "delete_transcript_md"; status = "error"; message = $_.Exception.Message })
            }
        }
    }

    # --- Process sidecar JSON files ---
    if ($targets -contains "sidecars") {
        $sidecarDir = Join-Path $run.OutputPath "sidecars"
        if (-not (Test-Path -LiteralPath $sidecarDir -PathType Container)) {
            Write-ArchiveLog -Run $run -Message "Sidecar directory does not exist: $sidecarDir" -Level "WARN"
        }
        else {
            # Build set of stems for processed source paths
            $processedStems = New-Object System.Collections.Generic.List[string]
            foreach ($srcPath in $processedPaths) {
                $stem = Get-ArchiveSafeStem -Path $srcPath
                if ($stem -notin $processedStems) { $processedStems.Add($stem) }
            }

            $sidecarFiles = Get-ChildItem -LiteralPath $sidecarDir -Filter "*.json" -File
            foreach ($sf in $sidecarFiles) {
                $sidecarStem = [System.IO.Path]::GetFileNameWithoutExtension($sf.Name)
                # Strip suffix from stage-specific sidecar naming (e.g. ".metadata.json")
                $baseStem = $sidecarStem
                foreach ($suffix in @(".metadata")) {
                    if ($baseStem.EndsWith($suffix)) {
                        $baseStem = $baseStem.Substring(0, $baseStem.Length - $suffix.Length)
                    }
                }

                if ($baseStem -in $processedStems) {
                    if ($DryRun) {
                        $results.Add([pscustomobject]@{ path = $sf.FullName; action = "delete_sidecar"; status = "dry_run"; message = "Would delete sidecar JSON." })
                    }
                    else {
                        try {
                            Remove-Item -LiteralPath $sf.FullName -ErrorAction Stop
                            $results.Add([pscustomobject]@{ path = $sf.FullName; action = "delete_sidecar"; status = "deleted"; message = "" })
                        }
                        catch {
                            $results.Add([pscustomobject]@{ path = $sf.FullName; action = "delete_sidecar"; status = "error"; message = $_.Exception.Message })
                        }
                    }
                }
            }
        }
    }

    Export-ArchiveCsv -Rows $results -Path (Join-Path $run.OutputPath "reports/cleanup-actions.csv") -Schema @('path','action','status','message')
    Write-ArchiveLog -Run $run -Message "Cleanup actions processed: $($results.Count)"

    $errors = @($results | Where-Object { $_.status -eq "error" })
    if ($errors.Count -gt 0) {
        Write-ArchiveLog -Run $run -Message "Cleanup completed with $($errors.Count) error(s)." -Level "WARN"
        exit 3
    }

    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
