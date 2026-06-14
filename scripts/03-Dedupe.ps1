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
    $inventoryPath = Join-Path $run.OutputPath "inventory/inventory.csv"
    $invCheck = Test-ArchiveCsvColumns -Path $inventoryPath -RequiredColumns @("path", "hash", "hash_status", "length_bytes")
    if (-not $invCheck.Valid) {
        throw "Inventory CSV is missing required columns for dedupe stage: $($invCheck.Missing -join ', ')"
    }
    $inventory = @(Import-ArchiveCsv -Path $inventoryPath)
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

    $dedupeConfig = $run.Config.dedupe
    $enableNearDup = $false
    if ($dedupeConfig -and $dedupeConfig.PSObject.Properties.Name -contains "enableNearDuplicate") {
        $enableNearDup = [bool]$dedupeConfig.enableNearDuplicate
    }

    $nearDuplicateRows = New-Object System.Collections.Generic.List[object]
    $nearDuplicateStatus = @()

    if ($enableNearDup) {
        $imageExtensions = @(".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".tif", ".tiff", ".bmp")
        $imageFiles = @($inventory | Where-Object {
            $ext = [System.IO.Path]::GetExtension($_.path).ToLowerInvariant()
            $ext -in $imageExtensions
        })

        Write-ArchiveLog -Run $run -Message "Near-duplicate detection enabled. $($imageFiles.Count) image candidates found."

        $usePerceptualHash = $false
        $phashTemplate = $null
        if ($dedupeConfig.PSObject.Properties.Name -contains "perceptualHash" -and $dedupeConfig.perceptualHash) {
            $phashTemplate = $dedupeConfig.perceptualHash
            if (Test-ArchiveCommand -Command $phashTemplate.command) {
                $usePerceptualHash = $true
                Write-ArchiveLog -Run $run -Message "Perceptual hash tool available: $($phashTemplate.command)"
            } else {
                Write-ArchiveLog -Run $run -Message "Perceptual hash tool not found: $($phashTemplate.command)" -Level "WARN"
            }
        }

        $useCzkawka = $false
        $czkawkaTemplate = $null
        if ($dedupeConfig.PSObject.Properties.Name -contains "czkawka" -and $dedupeConfig.czkawka) {
            $czkawkaTemplate = $dedupeConfig.czkawka
            if (Test-ArchiveCommand -Command $czkawkaTemplate.command) {
                $useCzkawka = $true
                Write-ArchiveLog -Run $run -Message "Czkawka tool available: $($czkawkaTemplate.command)"
            } else {
                Write-ArchiveLog -Run $run -Message "Czkawka tool not found: $($czkawkaTemplate.command)" -Level "WARN"
            }
        }

        if ($usePerceptualHash -and $imageFiles.Count -gt 0) {
            Write-ArchiveLog -Run $run -Message "Running perceptual hash comparison on $($imageFiles.Count) images."
            $phashResults = @{}
            $phashErrors = 0

            foreach ($file in $imageFiles) {
                if (-not (Test-Path -LiteralPath $file.path -PathType Leaf)) { continue }
                $result = Get-ArchivePerceptualHash -Path $file.path -Template $phashTemplate
                if ($result.Available -and -not [string]::IsNullOrWhiteSpace($result.Hash)) {
                    $compressed = Compress-ArchivePerceptualHash -HexHash $result.Hash
                    $phashResults[$file.path] = $compressed
                } else {
                    $phashErrors += 1
                }
            }

            Write-ArchiveLog -Run $run -Message "Perceptual hashes computed: $($phashResults.Count), errors: $phashErrors"

            $threshold = 0.15
            if ($dedupeConfig.PSObject.Properties.Name -contains "similarityThreshold") {
                $threshold = [double]$dedupeConfig.similarityThreshold
            }

            $pHashPaths = @($phashResults.Keys)
            $nearGroupId = $groupId
            for ($i = 0; $i -lt $pHashPaths.Count; $i++) {
                for ($j = $i + 1; $j -lt $pHashPaths.Count; $j++) {
                    $distance = Compare-ArchivePerceptualHash -HashA $phashResults[$pHashPaths[$i]] -HashB $phashResults[$pHashPaths[$j]]
                    if ($distance -le $threshold) {
                        $nearGroupId += 1
                        $nearDuplicateRows.Add([pscustomobject]@{
                            duplicate_group_id = "near-$nearGroupId"
                            path = $pHashPaths[$i]
                            compared_path = $pHashPaths[$j]
                            method = "perceptual_hash"
                            distance = [math]::Round($distance, 4)
                            confidence = if ($distance -le 0.05) { "high" } elseif ($distance -le 0.10) { "medium" } else { "low" }
                            recommended_action = "review_near_duplicate_candidate"
                        })
                    }
                }
            }

            $nearDuplicateStatus += [pscustomobject]@{
                method = "perceptual_hash"
                tool = $phashTemplate.command
                images_compared = $pHashPaths.Count
                near_duplicate_pairs = $nearDuplicateRows.Count
                threshold = $threshold
            }
        }

        if ($useCzkawka) {
            Write-ArchiveLog -Run $run -Message "Running Czkawka near-duplicate detection."
            $similarity = "80"
            if ($dedupeConfig.PSObject.Properties.Name -contains "similarityThreshold") {
                $similarity = [string][int]([double]$dedupeConfig.similarityThreshold * 100)
            }

            $escapedRoots = New-Object System.Collections.Generic.List[string]
            foreach ($root in $run.Config.archiveRoots) {
                $escapedRoots.Add(([string]$root).Replace(",", "\,"))
            }
            $rootDirs = $escapedRoots -join ","

            $czkawkaArgs = New-Object System.Collections.Generic.List[string]
            foreach ($arg in $czkawkaTemplate.arguments) {
                $value = [string]$arg
                $value = $value.Replace("{directories}", $rootDirs)
                $value = $value.Replace("{similarityThreshold}", $similarity)
                $czkawkaArgs.Add($value)
            }

            try {
                $czkawkaOutput = & $czkawkaTemplate.command @czkawkaArgs 2>&1
                $czkawkaExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
                $czkawkaText = ($czkawkaOutput -join [Environment]::NewLine)

                if ($czkawkaExit -eq 0) {
                    Write-ArchiveLog -Run $run -Message "Czkawka completed successfully."
                    $czkawkaLines = $czkawkaText -split [Environment]::NewLine | Where-Object {
                        $_ -match '\.(jpg|jpeg|png|gif|webp|heic|tif|tiff|bmp|mp4|mov|mkv)' -and $_ -match '-->'
                    }
                    $czkawkaGroupId = $groupId + $nearDuplicateRows.Count
                    foreach ($line in $czkawkaLines) {
                        $parts = $line -split '-->' | ForEach-Object { $_.Trim() }
                        if ($parts.Count -ge 2) {
                            $czkawkaGroupId += 1
                            $nearDuplicateRows.Add([pscustomobject]@{
                                duplicate_group_id = "czkawka-$czkawkaGroupId"
                                path = $parts[0]
                                compared_path = $parts[$parts.Count - 1]
                                method = "czkawka_image_similarity"
                                distance = ""
                                confidence = "medium"
                                recommended_action = "review_near_duplicate_candidate"
                            })
                        }
                    }
                } else {
                    Write-ArchiveLog -Run $run -Message "Czkawka exited with code $czkawkaExit" -Level "WARN"
                }

                $nearDuplicateStatus += [pscustomobject]@{
                    method = "czkawka_image_similarity"
                    tool = $czkawkaTemplate.command
                    near_duplicate_pairs = $czkawkaLines.Count
                    exit_code = $czkawkaExit
                }
            }
            catch {
                Write-ArchiveLog -Run $run -Message "Czkawka invocation failed: $($_.Exception.Message)" -Level "WARN"
                $nearDuplicateStatus += [pscustomobject]@{
                    method = "czkawka_image_similarity"
                    tool = $czkawkaTemplate.command
                    error = $_.Exception.Message
                }
            }
        }

        if (-not $usePerceptualHash -and -not $useCzkawka) {
            Write-ArchiveLog -Run $run -Message "Near-duplicate detection enabled but no tools available." -Level "WARN"
            $nearDuplicateStatus += [pscustomobject]@{
                method = "none"
                tool = "none"
                note = "Near-duplicate detection enabled but neither perceptual_hash nor czkawka tools are available."
            }
        }
    } else {
        $nearDuplicateStatus += [pscustomobject]@{
            stage = "03-Dedupe"
            status = if (Test-ArchiveCommand -Command "czkawka_cli") { "czkawka_cli_available_not_enabled" } else { "czkawka_cli_missing" }
            note = "Near-duplicate detection is disabled. Set dedupe.enableNearDuplicate to true in config to enable."
        }
    }

    if (-not $DryRun) {
        Export-ArchiveCsv -Rows $duplicateRows -Path (Join-Path $run.OutputPath "reports/exact-duplicates.csv")
        if ($nearDuplicateRows.Count -gt 0) {
            Export-ArchiveCsv -Rows $nearDuplicateRows -Path (Join-Path $run.OutputPath "reports/near-duplicates.csv")
        }
        Export-ArchiveCsv -Rows $nearDuplicateStatus -Path (Join-Path $run.OutputPath "reports/near-duplicate-status.csv")
    }

    Write-ArchiveLog -Run $run -Message "Exact duplicate rows: $($duplicateRows.Count)"
    Write-ArchiveLog -Run $run -Message "Near-duplicate rows: $($nearDuplicateRows.Count)"
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}