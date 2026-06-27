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

function Get-FileContentForLlm {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [string]$ContentDir,
        [string]$TranscriptDir,
        [int]$MaxChars
    )

    $stem = Get-ArchiveSafeStem -Path $Item.path -PreferredName $Item.name

    $contentPaths = @(
        (Join-Path $ContentDir "$stem.md"),
        (Join-Path $TranscriptDir "$stem.md")
    )

    foreach ($path in $contentPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
                $body = ($raw -replace '^---.*?---\s*', '').Trim()
                if ($body.Length -gt $MaxChars) {
                    return $body.Substring(0, $MaxChars)
                }
                return $body
            }
            catch {
                return $null
            }
        }
    }
    return $null
}

function Get-ClassificationConfig {
    param($Config)

    $classification = $Config.classification
    $enabled = if ($classification) { [bool]$classification.enabled } else { $false }

    if ($enabled) {
        if (-not $classification.model) { throw "classification.model is required when classification is enabled" }
        if (-not $classification.endpoint) { throw "classification.endpoint is required when classification is enabled" }
    }

    return [pscustomobject]@{
        Enabled = $enabled
        Model = if ($classification -and $classification.PSObject.Properties.Name -contains "model") { [string]$classification.model } else { "" }
        MaxChars = if ($classification -and $classification.PSObject.Properties.Name -contains "maxChars") { [int]$classification.maxChars } else { 6000 }
        Endpoint = if ($classification -and $classification.PSObject.Properties.Name -contains "endpoint") { [string]$classification.endpoint } else { "" }
        SystemPrompt = if ($classification -and $classification.PSObject.Properties.Name -contains "systemPrompt") { [string]$classification.systemPrompt } else { "You are an archive analyst. Categorize file content into themes and extract keywords." }
    }
}

try {
    $run = New-ArchiveRun -ScriptName "06-ClassifyThemes" -ConfigPath $ConfigPath -RootPath $RootPath -OutputPath $OutputPath -VerboseLog:$VerboseLog
    $inventoryPath = Join-Path $run.OutputPath "inventory/inventory.csv"
    $invCheck = Test-ArchiveCsvColumns -Path $inventoryPath -RequiredColumns @("path", "category", "name", "extension")
    if (-not $invCheck.Valid) {
        throw "Inventory CSV is missing required columns for classification stage: $($invCheck.Missing -join ', ')"
    }
    $inventory = @(Import-ArchiveCsv -Path $inventoryPath)
    $classCfg = Get-ClassificationConfig -Config $run.Config
    $contentDir = Join-Path $run.OutputPath "extracted"
    $transcriptDir = Join-Path $run.OutputPath "transcripts"
    $rows = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]

    foreach ($item in $inventory) {
        $tags = Get-HeuristicTags -Item $item
        $vibe = ""
        $summary = "File categorized as $($item.category)."
        $confidence = "low"
        $reason = "Heuristic tags from category, extension, and filename. LLM classification is optional and disabled unless reviewed."
        $status = "heuristic_only"

        if ($classCfg.Enabled) {
            $content = Get-FileContentForLlm -Item $item -ContentDir $contentDir -TranscriptDir $transcriptDir -MaxChars $classCfg.MaxChars
            $userPrompt = if ($content) {
                "File name: $($item.name)`nCategory: $($item.category)`nExtension: $($item.extension)`n`nCONTENT:`n$content`n`nReturn ONLY a JSON object with fields: summary (one sentence), tags (array of 2-5 keywords), vibe (one-word mood)."
            } else {
                "File name: $($item.name)`nCategory: $($item.category)`nExtension: $($item.extension)`n`nReturn ONLY a JSON object with fields: summary (one sentence), tags (array of 2-5 keywords), vibe (one-word mood)."
            }

            $result = Invoke-ArchiveLlm -Endpoint $classCfg.Endpoint -Model $classCfg.Model -SystemPrompt $classCfg.SystemPrompt -UserPrompt $userPrompt
            if ($result.Success -and $result.Json) {
                $parsed = $result.Json
                if (-not ($parsed.PSObject.Properties.Name -contains "summary")) {
                    $status = "llm_invalid_schema"
                    $reason = "LLM response missing required 'summary' field."
                    $errors.Add([pscustomobject]@{ stage = "06-ClassifyThemes"; path = $item.path; error = $reason })
                }
                else {
                    $summary = if ($parsed.summary) { [string]$parsed.summary } else { $summary }
                    $vibe = if ($parsed.vibe) { [string]$parsed.vibe } else { "" }
                    if ($parsed.tags -and @($parsed.tags).Count -gt 0) {
                        $tags = ($parsed.tags | ForEach-Object { [string]$_ } | Select-Object -Unique) -join ";"
                    }
                    $confidence = "medium"
                    $status = "llm_structured"
                    $reason = "LLM classification with structured JSON response."
                }
            }
            else {
                $status = "llm_failed"
                $reason = "LLM call failed: $($result.Error). Using heuristic fallback."
                $errors.Add([pscustomobject]@{ stage = "06-ClassifyThemes"; path = $item.path; error = $result.Error })
            }
        }

        $rows.Add([pscustomobject]@{
            path = $item.path
            category = $item.category
            tags = $tags
            vibe = $vibe
            theme = $item.category
            summary = $summary
            confidence = $confidence
            reason = $reason
            classification_status = $status
        })
    }

    if (-not $DryRun) {
        Export-ArchiveCsv -Rows $rows -Path (Join-Path $run.OutputPath "classification/classification.csv") -Schema @('path','category','tags','vibe','theme','summary','confidence','status','reason')
        Export-ArchiveCsv -Rows $errors -Path (Join-Path $run.OutputPath "classification/classification-errors.csv") -Schema @('stage','path','error')
    }

    Write-ArchiveLog -Run $run -Message "Classification rows: $($rows.Count)"
    if ($errors.Count -gt 0) { exit 3 }
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
