Set-StrictMode -Version Latest

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
        throw "Config file not found: $resolved"
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
        throw "Config file is not valid JSON: $resolved. $($_.Exception.Message)"
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

function New-ArchiveRun {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [string]$ConfigPath,
        [string]$RootPath,
        [string]$OutputPath,
        [switch]$VerboseLog,
        [switch]$AllowMissingRoot
    )

    $toolkitRoot = Get-ArchiveToolkitRoot
    $configInfo = Read-ArchiveConfig -ConfigPath $ConfigPath
    $config = $configInfo.Data

    $rootCandidate = $RootPath
    if ([string]::IsNullOrWhiteSpace($rootCandidate)) {
        if ($config.archiveRoots -and $config.archiveRoots.Count -gt 0) {
            $rootCandidate = [string]$config.archiveRoots[0]
        }
    }

    if ([string]::IsNullOrWhiteSpace($rootCandidate) -and -not $AllowMissingRoot) {
        throw "Root path was not supplied and config.archiveRoots is empty."
    }

    $resolvedRoot = $null
    if (-not [string]::IsNullOrWhiteSpace($rootCandidate)) {
        $resolvedRoot = Resolve-ArchivePath -PathValue $rootCandidate -BasePath $toolkitRoot
        if ((-not $AllowMissingRoot) -and (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container))) {
            throw "Root path does not exist: $resolvedRoot"
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
            throw "Output path is inside root path. Refusing by default. Root: $resolvedRoot Output: $resolvedOutput"
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
        [Parameter(Mandatory = $true)][string]$Message
    )

    $line = "[$(Get-Date -Format o)] $Message"
    Add-Content -LiteralPath $Run.LogPath -Value $line -Encoding UTF8
    if ($Run.VerboseLog) {
        Write-Host $line
    }
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
        throw "Required CSV not found: $Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($content)) {
        return @()
    }

    return Import-Csv -LiteralPath $Path
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

    if ($Config.exclusions -and $Config.exclusions.extensions) {
        foreach ($excludedExt in $Config.exclusions.extensions) {
            if ($extension -eq ([string]$excludedExt).ToLowerInvariant()) {
                return $true
            }
        }
    }

    if ($Config.exclusions -and $Config.exclusions.pathGlobs) {
        foreach ($glob in $Config.exclusions.pathGlobs) {
            $pattern = ([string]$glob).Replace("\", "/")
            if ($relative -like $pattern) {
                return $true
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
        throw "Hash failed: $($_.Exception.Message)"
    }
}

function Invoke-ArchiveConfiguredCommand {
    param(
        [Parameter(Mandatory = $true)]$Template,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$OcrLanguages = "eng"
    )

    if (-not $Template.command) {
        throw "Configured command template is missing 'command'."
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

Export-ModuleMember -Function *
