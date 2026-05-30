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
    $run = New-ArchiveRun -ScriptName "03-Dedupe" -ConfigPath $ConfigPath -RootPath $RootPath -OutputPath $OutputPath -VerboseLog:$VerboseLog
    $inventory = @(Import-ArchiveCsv -Path (Join-Path $run.OutputPath "inventory/inventory.csv"))
    $hashed = @($inventory | Where-Object { $_.hash_status -eq "ok" -and -not [string]::IsNullOrWhiteSpace($_.hash) })

    $duplicateRows = New-Object System.Collections.Generic.List[object]
    $groupId = 0

    foreach ($group in ($hashed | Group-Object -Property hash | Where-Object { $_.Count -gt 1 })) {
        $groupId += 1
        $members = @($group.Group | Sort-Object @{ Expression = { [int64]$_.length_bytes }; Descending = $true }, path)
        $keep = $members[0]

        foreach ($member in $members) {
            $duplicateRows.Add([pscustomobject]@{
                duplicate_group_id = "exact-$groupId"
                path = $member.path
                hash = $member.hash
                length_bytes = $member.length_bytes
                recommended_action = if ($member.path -eq $keep.path) { "keep" } else { "review_duplicate_candidate" }
                recommended_keep_path = $keep.path
                reason = "same_size_and_hash"
                confidence = "high"
            })
        }
    }

    $nearDuplicateNote = [pscustomobject]@{
        stage = "03-Dedupe"
        status = if (Test-ArchiveCommand -Command "czkawka_cli") { "czkawka_cli_available_not_invoked_by_default" } else { "czkawka_cli_missing" }
        note = "Near-duplicate image/video detection is intentionally not invoked until command templates are reviewed for the installed Czkawka version."
    }

    if (-not $DryRun) {
        Export-ArchiveCsv -Rows $duplicateRows -Path (Join-Path $run.OutputPath "reports/exact-duplicates.csv")
        Export-ArchiveCsv -Rows @($nearDuplicateNote) -Path (Join-Path $run.OutputPath "reports/near-duplicate-status.csv")
    }

    Write-ArchiveLog -Run $run -Message "Exact duplicate rows: $($duplicateRows.Count)"
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
