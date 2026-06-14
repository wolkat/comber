Set-StrictMode -Version Latest

# Error categories for structured error handling
enum ArchiveErrorCategory {
    ConfigError
    PathError
    FileError
    HashError
    CsvError
    ToolError
    ValidationError
    PermissionError
    TransientError
}

function New-ArchiveError {
    param(
        [Parameter(Mandatory = $true)][ArchiveErrorCategory]$Category,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Path = "",
        [string]$Stage = "",
        [object]$OriginalError = $null,
        [bool]$Recoverable = $false
    )

    return [pscustomobject]@{
        Category = $Category.ToString()
        Message = $Message
        Path = $Path
        Stage = $Stage
        Timestamp = Get-Date -Format "o"
        Recoverable = $Recoverable
        OriginalError = if ($OriginalError) { $OriginalError.ToString() } else { "" }
    }
}

function Invoke-ArchiveRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$DelayMs = 100,
        [string]$OperationName = "operation"
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return & $ScriptBlock
        }
        catch {
            $isTransient = $_.Exception.Message -match "being used by another process" -or
                           $_.Exception.Message -match "access denied" -or
                           $_.Exception.Message -match "sharing violation" -or
                           $_.Exception.Message -match "network path"

            if ($attempt -ge $MaxRetries -or -not $isTransient) {
                throw (New-ArchiveError -Category ([ArchiveErrorCategory]::TransientError) -Message "Failed after $attempt attempts: $OperationName. $($_.Exception.Message)" -OriginalError $_.Exception -Recoverable $isTransient)
            }

            Start-Sleep -Milliseconds ($DelayMs * $attempt)
            Write-Warning "Retry $attempt/$MaxRetries for $OperationName after transient error"
        }
    }
}

function Get-ArchiveToolkitRoot {
    $root = Join-Path $PSScriptRoot "../.."
    return (Resolve-Path -LiteralPath $root).Path
}

function Resolve-ArchivePath {
    param(
        [Parameter(Mandatory = $true)][string]$PathValue,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $expanded))
}

function Read-ArchiveConfig {
    param([string]$ConfigPath)

    $toolkitRoot = Get-ArchiveToolkitRoot
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $toolkitRoot "config/pipeline.example.json"
    }

    $resolved = Resolve-ArchivePath -PathValue $ConfigPath -BasePath $toolkitRoot
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw (New-ArchiveError -Category ([ArchiveErrorCategory]::ConfigError) -Message "Config file not found: $resolved" -Path $resolved)
    }

    try {
        $json = Get-Content -LiteralPath $resolved -Raw -ErrorAction Stop
        $config = $json | ConvertFrom-Json -Depth 50 -ErrorAction Stop
        return [pscustomobject]@{
            Path = $resolved
            Data = $config
        }
    }
    catch {
        throw (New-ArchiveError -Category ([ArchiveErrorCategory]::ConfigError) -Message "Config file is not valid JSON: $resolved. $($_.Exception.Message)" -Path $resolved -OriginalError $_.Exception)
    }
}

function Test-ArchiveConfigSchema {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$ConfigPath = ""
    )

    $errors = @()
    $warnings = @()

    # Required top-level sections
    $requiredSections = @("archiveRoots", "outputPath", "inventory", "dedupe", "metadata", "extraction", "transcription", "classification", "knowledgeBase", "actions", "safety")
    foreach ($section in $requiredSections) {
        if (-not ($Config.PSObject.Properties.Name -contains $section)) {
            $errors += "Missing required section: $section"
        }
    }

    # Validate archiveRoots
    if ($Config.PSObject.Properties.Name -contains "archiveRoots" -and $Config.archiveRoots) {
        if (-not ($Config.archiveRoots -is [array])) {
            $errors += "archiveRoots must be an array"
        }
        elseif ($Config.archiveRoots.Count -eq 0) {
            $warnings += "archiveRoots is empty"
        }
    }

    # Validate outputPath
    if ($Config.PSObject.Properties.Name -contains "outputPath" -and $Config.outputPath -and -not ($Config.outputPath -is [string])) {
        $errors += "outputPath must be a string"
    }

    # Validate inventory section
    if ($Config.PSObject.Properties.Name -contains "inventory" -and $Config.inventory) {
        if ($Config.inventory.PSObject.Properties.Name -contains "hashAlgorithm" -and $Config.inventory.hashAlgorithm -and $Config.inventory.hashAlgorithm -notin @("SHA1", "SHA256", "SHA384", "SHA512", "MD5")) {
            $errors += "inventory.hashAlgorithm must be one of: SHA1, SHA256, SHA384, SHA512, MD5"
        }
        if ($Config.inventory.PSObject.Properties.Name -contains "hashMaxBytes" -and $Config.inventory.hashMaxBytes -lt 0) {
            $errors += "inventory.hashMaxBytes must be non-negative"
        }
        if ($Config.inventory.PSObject.Properties.Name -contains "progressEvery" -and $Config.inventory.progressEvery -lt 1) {
            $errors += "inventory.progressEvery must be positive"
        }
    }

    # Validate dedupe section
    if ($Config.PSObject.Properties.Name -contains "dedupe" -and $Config.dedupe) {
        if ($Config.dedupe.PSObject.Properties.Name -contains "enableNearDuplicate" -and $Config.dedupe.enableNearDuplicate -and -not ($Config.dedupe.enableNearDuplicate -is [bool])) {
            $errors += "dedupe.enableNearDuplicate must be a boolean"
        }
        if ($Config.dedupe.PSObject.Properties.Name -contains "enableNearDuplicate" -and $Config.dedupe.enableNearDuplicate) {
            if (-not ($Config.dedupe.PSObject.Properties.Name -contains "czkawka" -and $Config.dedupe.czkawka)) {
                $errors += "dedupe.czkawka is required when near-duplicate detection is enabled"
            }
        }
        if ($Config.dedupe.PSObject.Properties.Name -contains "similarityThreshold") {
            $threshold = $Config.dedupe.similarityThreshold
            if ($null -ne $threshold -and ($threshold -lt 0 -or $threshold -gt 1)) {
                $errors += "dedupe.similarityThreshold must be between 0 and 1"
            }
        }
    }

    # Validate metadata section
    if ($Config.PSObject.Properties.Name -contains "metadata" -and $Config.metadata) {
        if ($Config.metadata.PSObject.Properties.Name -contains "enableExifTool" -and $Config.metadata.enableExifTool -and -not ($Config.metadata.enableExifTool -is [bool])) {
            $errors += "metadata.enableExifTool must be a boolean"
        }
        if ($Config.metadata.PSObject.Properties.Name -contains "enableMediaProbe" -and $Config.metadata.enableMediaProbe -and -not ($Config.metadata.enableMediaProbe -is [bool])) {
            $errors += "metadata.enableMediaProbe must be a boolean"
        }
        if ($Config.metadata.PSObject.Properties.Name -contains "enableMediaProbe" -and $Config.metadata.enableMediaProbe -and -not ($Config.metadata.PSObject.Properties.Name -contains "ffprobe" -and $Config.metadata.ffprobe)) {
            $errors += "metadata.ffprobe is required when enableMediaProbe is true"
        }
    }

    # Validate extraction section
    if ($Config.PSObject.Properties.Name -contains "extraction" -and $Config.extraction) {
        if ($Config.extraction.PSObject.Properties.Name -contains "maxInlineTextBytes" -and $Config.extraction.maxInlineTextBytes -lt 0) {
            $errors += "extraction.maxInlineTextBytes must be non-negative"
        }
        if ($Config.extraction.PSObject.Properties.Name -contains "enableExternalConverters" -and $Config.extraction.enableExternalConverters -and -not ($Config.extraction.enableExternalConverters -is [bool])) {
            $errors += "extraction.enableExternalConverters must be a boolean"
        }
    }

    # Validate transcription section
    if ($Config.PSObject.Properties.Name -contains "transcription" -and $Config.transcription) {
        if ($Config.transcription.PSObject.Properties.Name -contains "enabled" -and $Config.transcription.enabled -and -not ($Config.transcription.enabled -is [bool])) {
            $errors += "transcription.enabled must be a boolean"
        }
        if ($Config.transcription.PSObject.Properties.Name -contains "enabled" -and $Config.transcription.enabled -and -not ($Config.transcription.PSObject.Properties.Name -contains "commandTemplate" -and $Config.transcription.commandTemplate)) {
            $errors += "transcription.commandTemplate is required when transcription is enabled"
        }
    }

    # Validate classification section
    if ($Config.PSObject.Properties.Name -contains "classification" -and $Config.classification) {
        if ($Config.classification.PSObject.Properties.Name -contains "enabled" -and $Config.classification.enabled -and -not ($Config.classification.enabled -is [bool])) {
            $errors += "classification.enabled must be a boolean"
        }
        if ($Config.classification.PSObject.Properties.Name -contains "maxChars" -and $Config.classification.maxChars -lt 1) {
            $errors += "classification.maxChars must be positive"
        }
        if ($Config.classification.PSObject.Properties.Name -contains "ollamaEndpoint" -and $Config.classification.ollamaEndpoint -and -not ($Config.classification.ollamaEndpoint -is [string])) {
            $errors += "classification.ollamaEndpoint must be a string"
        }
        if ($Config.classification.PSObject.Properties.Name -contains "systemPrompt" -and $Config.classification.systemPrompt -and -not ($Config.classification.systemPrompt -is [string])) {
            $errors += "classification.systemPrompt must be a string"
        }
    }

    # Validate knowledgeBase section
    if ($Config.PSObject.Properties.Name -contains "knowledgeBase" -and $Config.knowledgeBase) {
        if ($Config.knowledgeBase.PSObject.Properties.Name -contains "vaultName" -and $Config.knowledgeBase.vaultName -and -not ($Config.knowledgeBase.vaultName -is [string])) {
            $errors += "knowledgeBase.vaultName must be a string"
        }
        if ($Config.knowledgeBase.PSObject.Properties.Name -contains "copyOriginals" -and $Config.knowledgeBase.copyOriginals -and -not ($Config.knowledgeBase.copyOriginals -is [bool])) {
            $errors += "knowledgeBase.copyOriginals must be a boolean"
        }
    }

    # Validate entities section
    if ($Config.PSObject.Properties.Name -contains "entities" -and $Config.entities) {
        if ($Config.entities.PSObject.Properties.Name -contains "enabled" -and $Config.entities.enabled -and -not ($Config.entities.enabled -is [bool])) {
            $errors += "entities.enabled must be a boolean"
        }
        if ($Config.entities.PSObject.Properties.Name -contains "threshold" -and $Config.entities.threshold -and ($Config.entities.threshold -lt 0 -or $Config.entities.threshold -gt 1)) {
            $errors += "entities.threshold must be between 0 and 1"
        }
        if ($Config.entities.PSObject.Properties.Name -contains "labels" -and $Config.entities.labels -and -not ($Config.entities.labels -is [array])) {
            $errors += "entities.labels must be an array"
        }
    }

    # Validate search section
    if ($Config.PSObject.Properties.Name -contains "search" -and $Config.search) {
        if ($Config.search.PSObject.Properties.Name -contains "enabled" -and $Config.search.enabled -and -not ($Config.search.enabled -is [bool])) {
            $errors += "search.enabled must be a boolean"
        }
    }

    # Validate cleanup section
    if ($Config.PSObject.Properties.Name -contains "cleanup" -and $Config.cleanup) {
        if ($Config.cleanup.PSObject.Properties.Name -contains "enabled" -and $Config.cleanup.enabled -and -not ($Config.cleanup.enabled -is [bool])) {
            $errors += "cleanup.enabled must be a boolean"
        }
        if ($Config.cleanup.PSObject.Properties.Name -contains "targets" -and $Config.cleanup.targets -and -not ($Config.cleanup.targets -is [array])) {
            $errors += "cleanup.targets must be an array"
        }
    }

    # Validate actions section
    if ($Config.PSObject.Properties.Name -contains "actions" -and $Config.actions) {
        if ($Config.actions.PSObject.Properties.Name -contains "enableApplyReviewedActions" -and $Config.actions.enableApplyReviewedActions -and -not ($Config.actions.enableApplyReviewedActions -is [bool])) {
            $errors += "actions.enableApplyReviewedActions must be a boolean"
        }
    }

    # Validate safety section
    if ($Config.PSObject.Properties.Name -contains "safety" -and $Config.safety) {
        if ($Config.safety.PSObject.Properties.Name -contains "allowOutputInsideRoot" -and $Config.safety.allowOutputInsideRoot -and -not ($Config.safety.allowOutputInsideRoot -is [bool])) {
            $errors += "safety.allowOutputInsideRoot must be a boolean"
        }
        if ($Config.safety.PSObject.Properties.Name -contains "allowDelete" -and $Config.safety.allowDelete -and -not ($Config.safety.allowDelete -is [bool])) {
            $errors += "safety.allowDelete must be a boolean"
        }
        if ($Config.safety.PSObject.Properties.Name -contains "requireApprovedManifest" -and $Config.safety.requireApprovedManifest -and -not ($Config.safety.requireApprovedManifest -is [bool])) {
            $errors += "safety.requireApprovedManifest must be a boolean"
        }
    }

    # Validate exclusions section
    if ($Config.PSObject.Properties.Name -contains "exclusions" -and $Config.exclusions) {
        if ($Config.exclusions.PSObject.Properties.Name -contains "pathGlobs" -and $Config.exclusions.pathGlobs -and -not ($Config.exclusions.pathGlobs -is [array])) {
            $errors += "exclusions.pathGlobs must be an array"
        }
        if ($Config.exclusions.PSObject.Properties.Name -contains "extensions" -and $Config.exclusions.extensions -and -not ($Config.exclusions.extensions -is [array])) {
            $errors += "exclusions.extensions must be an array"
        }
    }

    return [pscustomobject]@{
        Valid = $errors.Count -eq 0
        Errors = $errors
        Warnings = $warnings
        ConfigPath = $ConfigPath
    }
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$ChildPath,
        [Parameter(Mandatory = $true)][string]$ParentPath
    )

    $child = [System.IO.Path]::GetFullPath($ChildPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

    return ($child -eq $parent) -or $child.StartsWith($parent + [System.IO.Path]::DirectorySeparatorChar, $comparison) -or $child.StartsWith($parent + [System.IO.Path]::AltDirectorySeparatorChar, $comparison)
}

function Ensure-ArchiveDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Test-ArchiveSystemPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $systemDirs = @(
        # Linux/Unix
        "/etc", "/var", "/usr", "/bin", "/sbin", "/proc", "/sys", "/boot", "/dev", "/run", "/tmp",
        # macOS
        "/System", "/Library", "/Applications",
        # Windows (common roots)
        "C:\Windows", "C:\Program Files", "C:\Program Files (x86)"
    )

    $normalized = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

    foreach ($dir in $systemDirs) {
        if ($normalized -eq $dir -or $normalized.StartsWith($dir + [System.IO.Path]::DirectorySeparatorChar)) {
            return $true
        }
    }
    return $false
}

function New-ArchiveRun {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [string]$ConfigPath,
        [string]$RootPath,
        [string]$OutputPath,
        [switch]$VerboseLog,
        [switch]$AllowMissingRoot,
        [switch]$AllowSystemRoot
    )

    $toolkitRoot = Get-ArchiveToolkitRoot
    $configInfo = Read-ArchiveConfig -ConfigPath $ConfigPath
    $config = $configInfo.Data

    # Ensure config sections exist with safe defaults
    $requiredSections = @("inventory", "dedupe", "metadata", "extraction", "transcription", "classification", "knowledgeBase", "actions", "safety")
    foreach ($section in $requiredSections) {
        if (-not ($config.PSObject.Properties.Name -contains $section) -or $null -eq $config.$section) {
            $config | Add-Member -NotePropertyName $section -NotePropertyValue ([pscustomobject]@{}) -Force
        }
    }

    $rootCandidate = $RootPath
    if ([string]::IsNullOrWhiteSpace($rootCandidate)) {
        if ($config.archiveRoots -and $config.archiveRoots.Count -gt 0) {
            $rootCandidate = [string]$config.archiveRoots[0]
        }
    }

    if ([string]::IsNullOrWhiteSpace($rootCandidate) -and -not $AllowMissingRoot) {
        throw (New-ArchiveError -Category ([ArchiveErrorCategory]::PathError) -Message "Root path was not supplied and config.archiveRoots is empty." -Stage $ScriptName)
    }

    $resolvedRoot = $null
    if (-not [string]::IsNullOrWhiteSpace($rootCandidate)) {
        $resolvedRoot = Resolve-ArchivePath -PathValue $rootCandidate -BasePath $toolkitRoot
        if ((-not $AllowMissingRoot) -and (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container))) {
            throw (New-ArchiveError -Category ([ArchiveErrorCategory]::PathError) -Message "Root path does not exist: $resolvedRoot" -Path $resolvedRoot -Stage $ScriptName)
        }
        if ((-not $AllowSystemRoot) -and (Test-ArchiveSystemPath -Path $resolvedRoot)) {
            throw (New-ArchiveError -Category ([ArchiveErrorCategory]::PathError) -Message "Root path appears to be a system directory: $resolvedRoot. Use -AllowSystemRoot to override." -Path $resolvedRoot -Stage $ScriptName)
        }
    }

    $outputCandidate = if ([string]::IsNullOrWhiteSpace($OutputPath)) { [string]$config.outputPath } else { $OutputPath }
    if ([string]::IsNullOrWhiteSpace($outputCandidate)) {
        $outputCandidate = "./outputs"
    }

    $resolvedOutput = Resolve-ArchivePath -PathValue $outputCandidate -BasePath $toolkitRoot
    Ensure-ArchiveDirectory -Path $resolvedOutput

    if ($resolvedRoot -and (Test-PathInside -ChildPath $resolvedOutput -ParentPath $resolvedRoot)) {
        $allowInside = $false
        if ($config.safety -and $config.safety.PSObject.Properties.Name -contains "allowOutputInsideRoot") {
            $allowInside = [bool]$config.safety.allowOutputInsideRoot
        }
        if (-not $allowInside) {
            throw (New-ArchiveError -Category ([ArchiveErrorCategory]::PathError) -Message "Output path is inside root path. Refusing by default. Root: $resolvedRoot Output: $resolvedOutput" -Path $resolvedOutput -Stage $ScriptName)
        }
    }

    foreach ($dir in @("logs", "inventory", "metadata", "reports", "extracted", "transcripts", "classification", "vault", "sidecars")) {
        Ensure-ArchiveDirectory -Path (Join-Path $resolvedOutput $dir)
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $logPath = Join-Path $resolvedOutput "logs/$ScriptName-$timestamp.log"
    "[$(Get-Date -Format o)] Starting $ScriptName" | Set-Content -LiteralPath $logPath -Encoding UTF8

    return [pscustomobject]@{
        ScriptName = $ScriptName
        ToolkitRoot = $toolkitRoot
        ConfigPath = $configInfo.Path
        Config = $config
        RootPath = $resolvedRoot
        OutputPath = $resolvedOutput
        LogPath = $logPath
        VerboseLog = [bool]$VerboseLog
    }
}

function Write-ArchiveLog {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Level = "INFO",
        [string]$Category = "general",
        [object]$Data = $null
    )

    $timestamp = Get-Date -Format "o"
    
    # Plain text log entry
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -LiteralPath $Run.LogPath -Value $line -Encoding UTF8
    
    # Structured JSON log entry
    $jsonLogPath = $Run.LogPath -replace '\.log$', '.json'
    $jsonEntry = [pscustomobject]@{
        timestamp = $timestamp
        level = $Level
        category = $Category
        message = $Message
        stage = $Run.ScriptName
        data = $Data
    } | ConvertTo-Json -Compress
    
    Add-Content -LiteralPath $jsonLogPath -Value $jsonEntry -Encoding UTF8
    
    if ($Run.VerboseLog) {
        Write-Host $line
    }
}

function Write-ArchiveMetrics {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$MetricName,
        [Parameter(Mandatory = $true)][double]$Value,
        [string]$Unit = "count",
        [object]$Tags = $null
    )

    $timestamp = Get-Date -Format "o"
    $metricsPath = Join-Path $Run.OutputPath "logs/metrics.json"
    
    $metricEntry = [pscustomobject]@{
        timestamp = $timestamp
        stage = $Run.ScriptName
        metric = $MetricName
        value = $Value
        unit = $Unit
        tags = $Tags
    } | ConvertTo-Json -Compress
    
    Add-Content -LiteralPath $metricsPath -Value $metricEntry -Encoding UTF8
}

function Start-ArchiveTimer {
    param(
        [Parameter(Mandatory = $true)][string]$OperationName
    )

    return [pscustomobject]@{
        Operation = $OperationName
        StartTime = Get-Date
        EndTime = $null
        Duration = $null
    }
}

function Stop-ArchiveTimer {
    param(
        [Parameter(Mandatory = $true)]$Timer
    )

    $Timer.EndTime = Get-Date
    $Timer.Duration = ($Timer.EndTime - $Timer.StartTime).TotalSeconds
    return $Timer
}

function Export-ArchiveCsv {
    param(
        [Parameter(Mandatory = $true)]$Rows,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $parent = Split-Path -Parent $Path
    Ensure-ArchiveDirectory -Path $parent

    $items = New-Object System.Collections.Generic.List[object]
    if ($null -ne $Rows) {
        foreach ($row in $Rows) {
            $items.Add($row)
        }
    }

    if ($items.Count -eq 0) {
        "" | Set-Content -LiteralPath $Path -Encoding UTF8
        return
    }

    $items | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Import-ArchiveCsv {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (New-ArchiveError -Category ([ArchiveErrorCategory]::CsvError) -Message "Required CSV not found: $Path" -Path $Path)
    }

    $content = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($content)) {
        return @()
    }

    return Import-Csv -LiteralPath $Path
}

function Test-ArchiveCsvColumns {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$RequiredColumns
    )

    $rows = @(Import-ArchiveCsv -Path $Path)
    if ($rows.Count -eq 0) {
        return [pscustomobject]@{
            Valid = $RequiredColumns.Count -eq 0
            Missing = if ($RequiredColumns.Count -gt 0) { @("no_rows") } else { @() }
            RowCount = 0
            Note = if ($RequiredColumns.Count -gt 0) { "CSV is empty - cannot verify required columns: $($RequiredColumns -join ', ')" } else { "" }
        }
    }

    $actualColumns = @($rows[0].PSObject.Properties.Name)
    $missing = @($RequiredColumns | Where-Object { $_ -notin $actualColumns })

    return [pscustomobject]@{
        Valid = $missing.Count -eq 0
        Missing = $missing
        RowCount = $rows.Count
    }
}

function Test-ArchiveCommand {
    param([Parameter(Mandatory = $true)][string]$Command)

    return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-ArchiveToolVersion {
    param([Parameter(Mandatory = $true)][string]$Command)

    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return [pscustomobject]@{
            command = $Command
            available = $false
            path = ""
            version = ""
        }
    }

    $versionText = ""
    try {
        $versionText = (& $Command --version 2>&1 | Select-Object -First 1) -join " "
    }
    catch {
        $versionText = "available; version check failed"
    }

    return [pscustomobject]@{
        command = $Command
        available = $true
        path = $cmd.Source
        version = $versionText
    }
}

function Get-ArchiveFileCategory {
    param([string]$Extension)

    $ext = $Extension.ToLowerInvariant()
    if ($ext -in @(".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".tif", ".tiff", ".bmp")) { return "image" }
    if ($ext -in @(".mp4", ".mov", ".mkv", ".avi", ".m4v", ".wmv", ".webm")) { return "video" }
    if ($ext -in @(".mp3", ".wav", ".m4a", ".flac", ".aac", ".ogg", ".opus")) { return "audio" }
    if ($ext -in @(".pdf", ".doc", ".docx", ".odt", ".rtf")) { return "document" }
    if ($ext -in @(".txt", ".md", ".csv", ".json", ".xml", ".log", ".ps1", ".yml", ".yaml")) { return "text" }
    return "unknown"
}

function Get-ArchiveSafeStem {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$PreferredName
    )

    if ([string]::IsNullOrWhiteSpace($PreferredName)) {
        $PreferredName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    }

    $safe = $PreferredName -replace '[^\p{L}\p{Nd}\._-]+', '_'
    if ($safe.Length -gt 80) {
        $safe = $safe.Substring(0, 80)
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
    }
    finally {
        $sha.Dispose()
    }

    return "$safe-$($hash.Substring(0, 12))"
}

function Test-ArchiveExcluded {
    param(
        [Parameter(Mandatory = $true)][string]$FullName,
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)]$Config
    )

    $relative = [System.IO.Path]::GetRelativePath($RootPath, $FullName)
    $relative = $relative.Replace([string][System.IO.Path]::DirectorySeparatorChar, "/")
    $relative = $relative.Replace([string][System.IO.Path]::AltDirectorySeparatorChar, "/")
    $extension = [System.IO.Path]::GetExtension($FullName).ToLowerInvariant()

    if ($Config.PSObject.Properties.Name -contains "exclusions" -and $Config.exclusions) {
        if ($Config.exclusions.PSObject.Properties.Name -contains "extensions" -and $Config.exclusions.extensions) {
            foreach ($excludedExt in $Config.exclusions.extensions) {
                if ($extension -eq ([string]$excludedExt).ToLowerInvariant()) {
                    return $true
                }
            }
        }

        if ($Config.exclusions.PSObject.Properties.Name -contains "pathGlobs" -and $Config.exclusions.pathGlobs) {
            foreach ($glob in $Config.exclusions.pathGlobs) {
                $pattern = ([string]$glob).Replace("\", "/")
                if ($relative -like $pattern) {
                    return $true
                }
            }
        }
    }

    return $false
}

function Get-ArchiveFiles {
    param(
        [Parameter(Mandatory = $true)]$Run
    )

    $scanErrors = @()
    $files = Get-ChildItem -LiteralPath $Run.RootPath -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable scanErrors
    $included = foreach ($file in $files) {
        if (-not (Test-ArchiveExcluded -FullName $file.FullName -RootPath $Run.RootPath -Config $Run.Config)) {
            $file
        }
    }

    $errors = foreach ($err in $scanErrors) {
        [pscustomobject]@{
            stage = $Run.ScriptName
            path = ""
            error = $err.Exception.Message
        }
    }

    return [pscustomobject]@{
        Files = @($included)
        Errors = @($errors)
    }
}

function Get-ArchiveHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Algorithm = "SHA256"
    )

    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm -ErrorAction Stop).Hash
    }
    catch {
        throw (New-ArchiveError -Category ([ArchiveErrorCategory]::HashError) -Message "Hash failed: $($_.Exception.Message)" -Path $Path -OriginalError $_.Exception)
    }
}

function Invoke-ArchiveConfiguredCommand {
    param(
        [Parameter(Mandatory = $true)]$Template,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$OcrLanguages = "eng"
    )

    if (-not $Template.command) {
        throw (New-ArchiveError -Category ([ArchiveErrorCategory]::ConfigError) -Message "Configured command template is missing 'command'." -Path $Path)
    }

    $command = [string]$Template.command
    if (-not (Test-ArchiveCommand -Command $command)) {
        return [pscustomobject]@{
            Available = $false
            ExitCode = 2
            Output = ""
            Error = "Command not found: $command"
        }
    }

    $args = @()
    foreach ($arg in $Template.arguments) {
        $value = [string]$arg
        $value = $value.Replace("{path}", $Path)
        $value = $value.Replace("{ocrLanguages}", $OcrLanguages)
        $args += $value
    }

    try {
        $output = & $command @args 2>&1
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        return [pscustomobject]@{
            Available = $true
            ExitCode = $exitCode
            Output = ($output -join [Environment]::NewLine)
            Error = ""
        }
    }
    catch {
        return [pscustomobject]@{
            Available = $true
            ExitCode = 4
            Output = ""
            Error = $_.Exception.Message
        }
    }
}

function ConvertTo-ArchiveMarkdownValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return "" }
    return ([string]$Value).Replace("\", "\\").Replace("`"", "\`"")
}

function Get-ArchivePerceptualHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Template
    )

    $result = Invoke-ArchiveConfiguredCommand -Template $Template -Path $Path
    if (-not $result.Available -or $result.ExitCode -ne 0) {
        return [pscustomobject]@{
            Path = $Path
            Hash = ""
            Available = $false
            Error = if ($result.Error) { $result.Error } else { "Exit code $($result.ExitCode)" }
        }
    }

    $hashValue = $result.Output.Trim()
    return [pscustomobject]@{
        Path = $Path
        Hash = $hashValue
        Available = $true
        Error = ""
    }
}

function Compress-ArchivePerceptualHash {
    param(
        [Parameter(Mandatory = $true)][string]$HexHash
    )

    $bytes = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $HexHash.Length; $i += 2) {
        if ($i + 1 -lt $HexHash.Length) {
            $byteVal = [Convert]::ToByte($HexHash.Substring($i, 2), 16)
            $bytes.Add($byteVal)
        }
    }

    $bits = New-Object System.Collections.Generic.List[bool]
    foreach ($b in $bytes) {
        for ($bit = 7; $bit -ge 0; $bit--) {
            $bits.Add(([bool](($b -shr $bit) -band 1)))
        }
    }

    $dhashBits = New-Object System.Collections.Generic.List[bool]
    $cols = 8
    for ($row = 0; $row -lt ($bits.Count - $cols); $row++) {
        if ($bits[$row] -ne $bits[$row + $cols]) {
            $dhashBits.Add($true)
        }
    }

    $dhash = 0
    foreach ($bit in $dhashBits) {
        $dhash = ($dhash -shl 1) -bor ([int]$bit)
    }

    return $dhash
}

function ConvertFrom-ArchiveLlmJson {
    param([AllowEmptyString()][string]$RawText)

    if ([string]::IsNullOrWhiteSpace($RawText)) { return $null }

    $start = $RawText.IndexOf('{')
    if ($start -lt 0) { return $null }

    $depth = 0
    for ($i = $start; $i -lt $RawText.Length; $i++) {
        $c = $RawText[$i]
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') { $depth-- }
        if ($depth -eq 0) {
            try {
                return $RawText.Substring($start, $i - $start + 1) | ConvertFrom-Json -Depth 10 -ErrorAction Stop
            }
            catch {
                return $null
            }
        }
    }
    return $null
}

function Invoke-ArchiveLlm {
    param(
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$SystemPrompt,
        [Parameter(Mandatory = $true)][string]$UserPrompt,
        [int]$TimeoutSeconds = 120
    )

    $body = @{
        model = $Model
        messages = @(
            @{ role = "system"; content = $SystemPrompt }
            @{ role = "user"; content = $UserPrompt }
        )
        stream = $false
        options = @{ timeout = $TimeoutSeconds * 1000 }
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri "$Endpoint/api/chat" -Method Post -Body $body -ContentType "application/json" -TimeoutSec $TimeoutSeconds
        if ($response -and $response.message -and $response.message.content) {
            $json = ConvertFrom-ArchiveLlmJson -RawText $response.message.content
            return [pscustomobject]@{
                Success = $true
                RawText = $response.message.content
                Json = $json
                Error = ""
            }
        }
        return [pscustomobject]@{
            Success = $false
            RawText = ""
            Json = $null
            Error = "No content in response"
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            RawText = ""
            Json = $null
            Error = $_.Exception.Message
        }
    }
}

function Compare-ArchivePerceptualHash {
    param(
        [Parameter(Mandatory = $true)][long]$HashA,
        [Parameter(Mandatory = $true)][long]$HashB
    )

    $xor = $HashA -bxor $HashB
    $diffBits = 0
    while ($xor -gt 0) {
        $diffBits += ($xor -band 1)
        $xor = $xor -shr 1
    }
    return [double]($diffBits) / 64
}

Export-ModuleMember -Function @(
    'New-ArchiveError', 'Invoke-ArchiveRetry', 'Write-ArchiveMetrics',
    'Start-ArchiveTimer', 'Stop-ArchiveTimer', 'Test-ArchiveConfigSchema',
    'ConvertFrom-ArchiveLlmJson', 'Invoke-ArchiveLlm',
    'New-ArchiveRun', 'Write-ArchiveLog',
    'Get-ArchiveToolkitRoot', 'Resolve-ArchivePath', 'Read-ArchiveConfig',
    'Test-ArchiveCsvColumns', 'Import-ArchiveCsv', 'Export-ArchiveCsv',
    'Ensure-ArchiveDirectory', 'Get-ArchiveFileCategory', 'Get-ArchiveFiles',
    'Get-ArchiveHash', 'Get-ArchiveSafeStem', 'Test-ArchiveExcluded',
    'Test-ArchiveCommand', 'Get-ArchiveToolVersion',
    'Invoke-ArchiveConfiguredCommand', 'ConvertTo-ArchiveMarkdownValue',
    'Get-ArchivePerceptualHash', 'Compress-ArchivePerceptualHash', 'Compare-ArchivePerceptualHash',
    'Test-ArchiveSystemPath', 'Test-PathInside'
)
