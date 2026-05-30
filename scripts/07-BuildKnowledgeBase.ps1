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

function Get-RowByPath {
    param($Rows)

    $map = @{}
    foreach ($row in $Rows) {
        if ($row.path) { $map[$row.path] = $row }
    }
    return $map
}

try {
    $run = New-ArchiveRun -ScriptName "07-BuildKnowledgeBase" -ConfigPath $ConfigPath -RootPath $RootPath -OutputPath $OutputPath -VerboseLog:$VerboseLog
    $inventory = @(Import-ArchiveCsv -Path (Join-Path $run.OutputPath "inventory/inventory.csv"))
    $metadataPath = Join-Path $run.OutputPath "metadata/metadata.csv"
    $extractPath = Join-Path $run.OutputPath "reports/extraction-status.csv"
    $classPath = Join-Path $run.OutputPath "classification/classification.csv"
    $dedupePath = Join-Path $run.OutputPath "reports/exact-duplicates.csv"

    $metadata = if (Test-Path -LiteralPath $metadataPath) { @(Import-ArchiveCsv -Path $metadataPath) } else { @() }
    $extract = if (Test-Path -LiteralPath $extractPath) { @(Import-ArchiveCsv -Path $extractPath) } else { @() }
    $classification = if (Test-Path -LiteralPath $classPath) { @(Import-ArchiveCsv -Path $classPath) } else { @() }
    $dedupe = if (Test-Path -LiteralPath $dedupePath) { @(Import-ArchiveCsv -Path $dedupePath) } else { @() }

    $metadataMap = Get-RowByPath -Rows $metadata
    $extractMap = Get-RowByPath -Rows $extract
    $classMap = Get-RowByPath -Rows $classification
    $dupeMap = @{}
    foreach ($row in $dedupe) {
        if ($row.path) { $dupeMap[$row.path] = $row }
    }

    $vaultName = if ($run.Config.knowledgeBase.vaultName) { [string]$run.Config.knowledgeBase.vaultName } else { "archive-vault" }
    $vaultPath = Join-Path $run.OutputPath "vault/$vaultName"
    if (-not $DryRun) { Ensure-ArchiveDirectory -Path $vaultPath }

    foreach ($item in $inventory) {
        $stem = Get-ArchiveSafeStem -Path $item.path -PreferredName $item.name
        $notePath = Join-Path $vaultPath "$stem.md"
        $m = if ($metadataMap.ContainsKey($item.path)) { $metadataMap[$item.path] } else { $null }
        $e = if ($extractMap.ContainsKey($item.path)) { $extractMap[$item.path] } else { $null }
        $c = if ($classMap.ContainsKey($item.path)) { $classMap[$item.path] } else { $null }
        $d = if ($dupeMap.ContainsKey($item.path)) { $dupeMap[$item.path] } else { $null }
        $bestDatetime = if ($m) { $m.best_datetime } else { "" }
        $bestDatetimeSource = if ($m) { $m.best_datetime_source } else { "" }
        $tags = if ($c) { $c.tags } else { "" }
        $theme = if ($c) { $c.theme } else { "" }
        $summary = if ($c) { $c.summary } else { "" }
        $duplicateGroupId = if ($d) { $d.duplicate_group_id } else { "" }
        $recommendedAction = if ($d) { $d.recommended_action } else { "" }
        $sourcePath = ConvertTo-ArchiveMarkdownValue -Value $item.path

        $body = ""
        if ($e -and $e.markdown_path -and (Test-Path -LiteralPath $e.markdown_path)) {
            $body = Get-Content -LiteralPath $e.markdown_path -Raw
        }

        $frontmatter = @(
            "---"
            "source_path: `"$sourcePath`""
            "category: `"$($item.category)`""
            "extension: `"$($item.extension)`""
            "length_bytes: $($item.length_bytes)"
            "hash: `"$($item.hash)`""
            "best_datetime: `"$bestDatetime`""
            "best_datetime_source: `"$bestDatetimeSource`""
            "tags: `"$tags`""
            "duplicate_group_id: `"$duplicateGroupId`""
            "recommended_action: `"$recommendedAction`""
            "generated_at: `"$(Get-Date -Format o)`""
            "---"
            ""
            "# $($item.name)"
            ""
            "- Source: $($item.path)"
            "- Category: $($item.category)"
            "- Theme: $theme"
            "- Summary: $summary"
            ""
        ) -join [Environment]::NewLine

        if (-not $DryRun) {
            ($frontmatter + [Environment]::NewLine + $body) | Set-Content -LiteralPath $notePath -Encoding UTF8
        }
    }

    Write-ArchiveLog -Run $run -Message "Knowledge base notes: $($inventory.Count)"
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
