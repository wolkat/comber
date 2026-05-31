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

function Write-ExtractedMarkdown {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$Body,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$ToolName
    )

    $stem = Get-ArchiveSafeStem -Path $Item.path -PreferredName $Item.name
    $outPath = Join-Path $Run.OutputPath "extracted/$stem.md"
    $content = @(
        "---"
        "source_path: `"$($Item.path -replace '"', '\"')`""
        "category: `"$($Item.category)`""
        "extraction_status: `"$Status`""
        "tool: `"$ToolName`""
        "extracted_at: `"$(Get-Date -Format o)`""
        "---"
        ""
        "# $($Item.name)"
        ""
        $Body
    ) -join [Environment]::NewLine

    $content | Set-Content -LiteralPath $outPath -Encoding UTF8
    return $outPath
}

try {
    $run = New-ArchiveRun -ScriptName "04-ExtractText" -ConfigPath $ConfigPath -RootPath $RootPath -OutputPath $OutputPath -VerboseLog:$VerboseLog
    $inventoryPath = Join-Path $run.OutputPath "inventory/inventory.csv"
    $invCheck = Test-ArchiveCsvColumns -Path $inventoryPath -RequiredColumns @("path", "category", "name", "extension", "length_bytes")
    if (-not $invCheck.Valid) {
        throw "Inventory CSV is missing required columns for extraction stage: $($invCheck.Missing -join ', ')"
    }
    $inventory = @(Import-ArchiveCsv -Path $inventoryPath)
    $maxBytes = if ($run.Config.extraction.maxInlineTextBytes) { [int64]$run.Config.extraction.maxInlineTextBytes } else { 5242880 }
    $enableExternal = $run.Config.extraction -and [bool]$run.Config.extraction.enableExternalConverters
    $rows = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]

    foreach ($item in $inventory) {
        $status = "skipped"
        $tool = "none"
        $outPath = ""
        $message = ""

        try {
            if ($item.category -eq "text" -and [int64]$item.length_bytes -le $maxBytes) {
                if (-not $DryRun) {
                    $body = Get-Content -LiteralPath $item.path -Raw -ErrorAction Stop
                    $outPath = Write-ExtractedMarkdown -Run $run -Item $item -Body $body -Status "ok" -ToolName "powershell-read"
                }
                $status = "ok"
                $tool = "powershell-read"
            }
            elseif ($enableExternal -and $item.category -in @("document", "image")) {
                $template = $null
                if ($item.category -eq "document" -and $run.Config.extraction.converters.markitdown) {
                    $template = $run.Config.extraction.converters.markitdown
                    $tool = "markitdown"
                }
                elseif ($item.category -eq "image" -and $run.Config.extraction.converters.tesseract) {
                    $template = $run.Config.extraction.converters.tesseract
                    $tool = "tesseract"
                }

                if ($template) {
                    $languages = ($run.Config.ocrLanguages -join "+")
                    $result = Invoke-ArchiveConfiguredCommand -Template $template -Path $item.path -OcrLanguages $languages
                    if ($result.Available -and $result.ExitCode -eq 0) {
                        if (-not $DryRun) {
                            $outPath = Write-ExtractedMarkdown -Run $run -Item $item -Body $result.Output -Status "ok" -ToolName $tool
                        }
                        $status = "ok"
                    }
                    else {
                        $status = if ($result.Available) { "tool_error" } else { "tool_missing" }
                        $message = $result.Error + $result.Output
                    }
                }
            }
            else {
                $message = "No extraction path enabled for category '$($item.category)'."
            }
        }
        catch {
            $status = "error"
            $message = $_.Exception.Message
            $errors.Add([pscustomobject]@{ stage = "04-ExtractText"; path = $item.path; error = $message })
        }

        $rows.Add([pscustomobject]@{
            path = $item.path
            category = $item.category
            extraction_status = $status
            tool = $tool
            markdown_path = $outPath
            message = $message
        })
    }

    if (-not $DryRun) {
        Export-ArchiveCsv -Rows $rows -Path (Join-Path $run.OutputPath "reports/extraction-status.csv")
        Export-ArchiveCsv -Rows $errors -Path (Join-Path $run.OutputPath "reports/extraction-errors.csv")
    }

    Write-ArchiveLog -Run $run -Message "Extraction rows: $($rows.Count)"
    if ($errors.Count -gt 0) { exit 3 }
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
