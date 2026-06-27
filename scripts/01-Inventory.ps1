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
    $run = New-ArchiveRun -ScriptName "01-Inventory" -ConfigPath $ConfigPath -RootPath $RootPath -OutputPath $OutputPath -VerboseLog:$VerboseLog
    Write-ArchiveLog -Run $run -Message "Root: $($run.RootPath)"
    Write-ArchiveLog -Run $run -Message "Output: $($run.OutputPath)"

    $scan = Get-ArchiveFiles -Run $run
    $algorithm = if ($run.Config.inventory.hashAlgorithm) { [string]$run.Config.inventory.hashAlgorithm } else { "SHA256" }
    $hashMaxBytes = if ($run.Config.inventory.hashMaxBytes -ne $null) { [int64]$run.Config.inventory.hashMaxBytes } else { 0 }
    $progressEvery = if ($run.Config.inventory.progressEvery) { [int]$run.Config.inventory.progressEvery } else { 250 }

    # Validate hash algorithm is available
    try {
        $null = Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes("test"))) -Algorithm $algorithm -ErrorAction Stop
    }
    catch {
        throw "Hash algorithm '$algorithm' is not available on this system. Check your config and installed algorithms."
    }

    $rows = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    foreach ($err in $scan.Errors) { $errors.Add($err) }

    $index = 0
    foreach ($file in $scan.Files) {
        $index += 1
        if (($index % $progressEvery) -eq 0) {
            Write-ArchiveLog -Run $run -Message "Scanned $index files"
        }

        $hash = ""
        $hashStatus = "not_requested"

        if ($DryRun) {
            $hashStatus = "dry_run"
        }
        elseif ($hashMaxBytes -gt 0 -and $file.Length -gt $hashMaxBytes) {
            $hashStatus = "skipped_size_limit"
        }
        else {
            try {
                $hash = Get-ArchiveHash -Path $file.FullName -Algorithm $algorithm
                $hashStatus = "ok"
            }
            catch {
                $hashStatus = "error"
                $errors.Add([pscustomobject]@{
                    stage = "01-Inventory"
                    path = $file.FullName
                    error = $_.Exception.Message
                })
            }
        }

        $rows.Add([pscustomobject]@{
            path = $file.FullName
            relative_path = [System.IO.Path]::GetRelativePath($run.RootPath, $file.FullName)
            parent = $file.DirectoryName
            name = $file.Name
            extension = $file.Extension.ToLowerInvariant()
            category = Get-ArchiveFileCategory -Extension $file.Extension
            length_bytes = $file.Length
            created_utc = $file.CreationTimeUtc.ToString("o")
            modified_utc = $file.LastWriteTimeUtc.ToString("o")
            accessed_utc = $file.LastAccessTimeUtc.ToString("o")
            hash_algorithm = $algorithm
            hash = $hash
            hash_status = $hashStatus
        })
    }

    $inventoryPath = Join-Path $run.OutputPath "inventory/inventory.csv"
    $errorsPath = Join-Path $run.OutputPath "inventory/file-errors.csv"

    if ($DryRun) {
        Write-ArchiveLog -Run $run -Message "Dry run: inventory would contain $($rows.Count) rows"
    }
    else {
        Export-ArchiveCsv -Rows $rows -Path $inventoryPath -Schema @('path','relative_path','parent','name','extension','category','length_bytes','created_utc','modified_utc','accessed_utc','hash_algorithm','hash','hash_status')
        Export-ArchiveCsv -Rows $errors -Path $errorsPath -Schema @('stage','path','error')
        Write-ArchiveLog -Run $run -Message "Wrote $inventoryPath"
        Write-ArchiveLog -Run $run -Message "Wrote $errorsPath"
    }

    if ($errors.Count -gt 0) { exit 3 }
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
