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
    $run = New-ArchiveRun -ScriptName "05-TranscribeMedia" -ConfigPath $ConfigPath -RootPath $RootPath -OutputPath $OutputPath -VerboseLog:$VerboseLog
    $inventory = @(Import-ArchiveCsv -Path (Join-Path $run.OutputPath "inventory/inventory.csv"))
    $media = @($inventory | Where-Object { $_.category -in @("audio", "video") })
    $enabled = $run.Config.transcription -and [bool]$run.Config.transcription.enabled
    $rows = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]

    foreach ($item in $media) {
        $status = "disabled"
        $outPath = ""
        $message = "Transcription is disabled in config."

        if ($enabled -and $run.Config.transcription.commandTemplate) {
            $result = Invoke-ArchiveConfiguredCommand -Template $run.Config.transcription.commandTemplate -Path $item.path
            if ($result.Available -and $result.ExitCode -eq 0) {
                $status = "ok"
                if (-not $DryRun) {
                    $stem = Get-ArchiveSafeStem -Path $item.path -PreferredName $item.name
                    $outPath = Join-Path $run.OutputPath "transcripts/$stem.md"
                    @(
                        "---"
                        "source_path: `"$($item.path -replace '"', '\"')`""
                        "transcription_status: `"ok`""
                        "tool: `"$($run.Config.transcription.engine)`""
                        "transcribed_at: `"$(Get-Date -Format o)`""
                        "---"
                        ""
                        "# Transcript: $($item.name)"
                        ""
                        $result.Output
                    ) -join [Environment]::NewLine | Set-Content -LiteralPath $outPath -Encoding UTF8
                }
                $message = ""
            }
            else {
                $status = if ($result.Available) { "tool_error" } else { "tool_missing" }
                $message = $result.Error + $result.Output
                $errors.Add([pscustomobject]@{ stage = "05-TranscribeMedia"; path = $item.path; error = $message })
            }
        }

        $rows.Add([pscustomobject]@{
            path = $item.path
            category = $item.category
            transcription_status = $status
            transcript_path = $outPath
            message = $message
        })
    }

    if (-not $DryRun) {
        Export-ArchiveCsv -Rows $rows -Path (Join-Path $run.OutputPath "reports/transcription-status.csv")
        Export-ArchiveCsv -Rows $errors -Path (Join-Path $run.OutputPath "reports/transcription-errors.csv")
    }

    Write-ArchiveLog -Run $run -Message "Media rows: $($media.Count)"
    if ($errors.Count -gt 0) { exit 3 }
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
