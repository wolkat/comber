# API Reference: ArchiveAgent.Common Module

This document provides API documentation for all exported functions in the `ArchiveAgent.Common.psm1` module.

## Table of Contents

- [Path Utilities](#path-utilities)
- [Configuration](#configuration)
- [Run Management](#run-management)
- [Logging](#logging)
- [CSV Operations](#csv-operations)
- [File Operations](#file-operations)
- [External Tools](#external-tools)
- [String Utilities](#string-utilities)

---

## Path Utilities

### Get-ArchiveToolkitRoot

Returns the absolute path to the Comber toolkit root directory.

**Syntax:**
```powershell
Get-ArchiveToolkitRoot
```

**Parameters:** None

**Returns:** `[string]` - Absolute path to the toolkit root

**Example:**
```powershell
$root = Get-ArchiveToolkitRoot
# Returns: /Users/user/projects/Comber
```

---

### Resolve-ArchivePath

Resolves a path value relative to a base path, expanding environment variables.

**Syntax:**
```powershell
Resolve-ArchivePath -PathValue <string> -BasePath <string>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `PathValue` | string | Yes | Path to resolve (may be relative or contain env vars) |
| `BasePath` | string | Yes | Base path for relative resolution |

**Returns:** `[string]` - Absolute resolved path

**Example:**
```powershell
# Relative path
$resolved = Resolve-ArchivePath -PathValue "./outputs" -BasePath "/Users/user/Comber"
# Returns: /Users/user/Comber/outputs

# Environment variable
$resolved = Resolve-ArchivePath -PathValue "$HOME/archives" -BasePath "/tmp"
# Returns: /Users/user/archives
```

---

### Test-PathInside

Tests whether a child path is inside a parent path.

**Syntax:**
```powershell
Test-PathInside -ChildPath <string> -ParentPath <string>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `ChildPath` | string | Yes | Path to test |
| `ParentPath` | string | Yes | Potential parent path |

**Returns:** `[bool]` - `$true` if child is inside parent

**Example:**
```powershell
Test-PathInside -ChildPath "/Users/user/archives/photos" -ParentPath "/Users/user/archives"
# Returns: $true

Test-PathInside -ChildPath "/tmp/other" -ParentPath "/Users/user/archives"
# Returns: $false
```

---

### Ensure-ArchiveDirectory

Creates a directory if it doesn't exist.

**Syntax:**
```powershell
Ensure-ArchiveDirectory -Path <string>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Path` | string | Yes | Directory path to ensure |

**Returns:** None

**Example:**
```powershell
Ensure-ArchiveDirectory -Path "/Users/user/Comber/outputs/logs"
# Creates directory if it doesn't exist
```

---

### Test-ArchiveSystemPath

Tests whether a path is a system directory that should not be used as archive root.

**Syntax:**
```powershell
Test-ArchiveSystemPath -Path <string>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Path` | string | Yes | Path to test |

**Returns:** `[bool]` - `$true` if path is a system directory

**Example:**
```powershell
Test-ArchiveSystemPath -Path "/etc"
# Returns: $true

Test-ArchiveSystemPath -Path "/Users/user/archives"
# Returns: $false
```

---

## Configuration

### Read-ArchiveConfig

Reads and parses a JSON configuration file.

**Syntax:**
```powershell
Read-ArchiveConfig -ConfigPath <string>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `ConfigPath` | string | No | Path to config file (defaults to `config/pipeline.example.json`) |

**Returns:** `[pscustomobject]` with properties:
- `Path` - Absolute path to the config file
- `Data` - Parsed JSON configuration object

**Throws:**
- Config file not found
- Config file is not valid JSON

**Example:**
```powershell
$configInfo = Read-ArchiveConfig -ConfigPath "./config/pipeline.example.json"
$config = $configInfo.Data
```

---

## Run Management

### New-ArchiveRun

Initializes a new pipeline run with configuration, paths, and logging.

**Syntax:**
```powershell
New-ArchiveRun -ScriptName <string> [-ConfigPath <string>] [-RootPath <string>] 
               [-OutputPath <string>] [-VerboseLog] [-AllowMissingRoot] [-AllowSystemRoot]
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `ScriptName` | string | Yes | Name of the script (e.g., "01-Inventory") |
| `ConfigPath` | string | No | Path to config file |
| `RootPath` | string | No | Root path to scan (overrides config) |
| `OutputPath` | string | No | Output path (overrides config) |
| `VerboseLog` | switch | No | Enable verbose console logging |
| `AllowMissingRoot` | switch | No | Allow run without root path |
| `AllowSystemRoot` | switch | No | Allow system directories as root |

**Returns:** `[pscustomobject]` with properties:
- `ScriptName` - Name of the script
- `ToolkitRoot` - Absolute path to toolkit root
- `ConfigPath` - Absolute path to config file
- `Config` - Parsed configuration object
- `RootPath` - Resolved root path
- `OutputPath` - Resolved output path
- `LogPath` - Path to log file
- `VerboseLog` - Whether verbose logging is enabled

**Throws:**
- Root path was not supplied and config.archiveRoots is empty
- Root path does not exist
- Root path appears to be a system directory
- Output path is inside root path (unless allowed)

**Example:**
```powershell
$run = New-ArchiveRun -ScriptName "01-Inventory" -ConfigPath "./config/pipeline.json" -VerboseLog
Write-ArchiveLog -Run $run -Message "Starting inventory scan"
```

---

## Logging

### Write-ArchiveLog

Writes a timestamped log message to the run's log file.

**Syntax:**
```powershell
Write-ArchiveLog -Run <pscustomobject> -Message <string>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Run` | pscustomobject | Yes | Run object from `New-ArchiveRun` |
| `Message` | string | Yes | Log message |

**Returns:** None

**Example:**
```powershell
Write-ArchiveLog -Run $run -Message "Processed 100 files"
# Writes: [2026-06-01T12:00:00.0000000+00:00] Processed 100 files
```

---

## CSV Operations

### Export-ArchiveCsv

Exports rows to a CSV file, creating parent directories if needed.

**Syntax:**
```powershell
Export-ArchiveCsv -Rows <object[]> -Path <string>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Rows` | object[] | Yes | Array of objects to export |
| `Path` | string | Yes | Output CSV file path |

**Returns:** None

**Example:**
```powershell
$rows = @(
    [pscustomobject]@{ Name = "file1.txt"; Size = 1024 },
    [pscustomobject]@{ Name = "file2.txt"; Size = 2048 }
)
Export-ArchiveCsv -Rows $rows -Path "./outputs/inventory.csv"
```

---

### Import-ArchiveCsv

Imports a CSV file and returns the rows as objects.

**Syntax:**
```powershell
Import-ArchiveCsv -Path <string>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Path` | string | Yes | CSV file path |

**Returns:** `[object[]]` - Array of CSV rows (empty array if file is empty)

**Throws:**
- Required CSV not found

**Example:**
```powershell
$rows = Import-ArchiveCsv -Path "./outputs/inventory.csv"
foreach ($row in $rows) {
    Write-Host $row.Name
}
```

---

### Test-ArchiveCsvColumns

Validates that a CSV file contains required columns.

**Syntax:**
```powershell
Test-ArchiveCsvColumns -Path <string> -RequiredColumns <string[]>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Path` | string | Yes | CSV file path |
| `RequiredColumns` | string[] | Yes | Array of required column names |

**Returns:** `[pscustomobject]` with properties:
- `Valid` - `$true` if all required columns exist
- `Missing` - Array of missing column names
- `RowCount` - Number of rows in CSV
- `Note` - Additional information (e.g., for empty CSVs)

**Example:**
```powershell
$result = Test-ArchiveCsvColumns -Path "./outputs/inventory.csv" -RequiredColumns @("path", "hash", "size")
if (-not $result.Valid) {
    Write-Error "Missing columns: $($result.Missing -join ', ')"
}
```

---

## File Operations

### Get-ArchiveFiles

Scans a directory for files, excluding configured patterns.

**Syntax:**
```powershell
Get-ArchiveFiles -Run <pscustomobject>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Run` | pscustomobject | Yes | Run object from `New-ArchiveRun` |

**Returns:** `[pscustomobject]` with properties:
- `Files` - Array of included file objects
- `Errors` - Array of scan errors

**Example:**
```powershell
$scan = Get-ArchiveFiles -Run $run
Write-Host "Found $($scan.Files.Count) files"
Write-Host "Encountered $($scan.Errors.Count) errors"
```

---

### Get-ArchiveHash

Computes the hash of a file.

**Syntax:**
```powershell
Get-ArchiveHash -Path <string> [-Algorithm <string>]
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Path` | string | Yes | File path to hash |
| `Algorithm` | string | No | Hash algorithm (default: "SHA256") |

**Returns:** `[string]` - Hash value in uppercase hex

**Throws:**
- Hash failed

**Example:**
```powershell
$hash = Get-ArchiveHash -Path "./photo.jpg" -Algorithm "SHA256"
```

---

### Test-ArchiveExcluded

Tests whether a file should be excluded based on configuration.

**Syntax:**
```powershell
Test-ArchiveExcluded -FullName <string> -RootPath <string> -Config <pscustomobject>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `FullName` | string | Yes | Full path to file |
| `RootPath` | string | Yes | Root path for relative matching |
| `Config` | pscustomobject | Yes | Configuration object |

**Returns:** `[bool]` - `$true` if file should be excluded

**Example:**
```powershell
$excluded = Test-ArchiveExcluded -FullName $file.FullName -RootPath $run.RootPath -Config $run.Config
if (-not $excluded) {
    # Process file
}
```

---

### Get-ArchiveFileCategory

Returns the category for a file extension.

**Syntax:**
```powershell
Get-ArchiveFileCategory -Extension <string>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Extension` | string | Yes | File extension (e.g., ".jpg") |

**Returns:** `[string]` - Category name: "image", "video", "audio", "document", "text", or "unknown"

**Example:**
```powershell
$category = Get-ArchiveFileCategory -Extension ".mp4"
# Returns: "video"
```

---

### Get-ArchiveSafeStem

Generates a safe filename stem from a path.

**Syntax:**
```powershell
Get-ArchiveSafeStem -Path <string> [-PreferredName <string>]
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Path` | string | Yes | Original file path |
| `PreferredName` | string | No | Preferred name (defaults to filename without extension) |

**Returns:** `[string]` - Safe filename stem with hash suffix

**Example:**
```powershell
$stem = Get-ArchiveSafeStem -Path "/Users/user/photos/My Photo (2024).jpg"
# Returns: "My_Photo_2024_-a1b2c3d4e5f6"
```

---

## External Tools

### Test-ArchiveCommand

Tests whether a command is available on the system.

**Syntax:**
```powershell
Test-ArchiveCommand -Command <string>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Command` | string | Yes | Command name to test |

**Returns:** `[bool]` - `$true` if command is available

**Example:**
```powershell
if (Test-ArchiveCommand -Command "exiftool") {
    # Use ExifTool
}
```

---

### Get-ArchiveToolVersion

Gets version information for a command.

**Syntax:**
```powershell
Get-ArchiveToolVersion -Command <string>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Command` | string | Yes | Command name |

**Returns:** `[pscustomobject]` with properties:
- `command` - Command name
- `available` - `$true` if command exists
- `path` - Full path to command
- `version` - Version string

**Example:**
```powershell
$info = Get-ArchiveToolVersion -Command "ffmpeg"
if ($info.available) {
    Write-Host "FFmpeg version: $($info.version)"
}
```

---

### Invoke-ArchiveConfiguredCommand

Executes a command using a configuration template.

**Syntax:**
```powershell
Invoke-ArchiveConfiguredCommand -Template <pscustomobject> -Path <string> [-OcrLanguages <string>]
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Template` | pscustomobject | Yes | Command template from config |
| `Path` | string | Yes | File path to process |
| `OcrLanguages` | string | No | OCR languages (default: "eng") |

**Returns:** `[pscustomobject]` with properties:
- `Available` - `$true` if command was found
- `ExitCode` - Command exit code
- `Output` - Standard output
- `Error` - Error message (if any)

**Example:**
```powershell
$template = $run.Config.extraction.converters.tesseract
$result = Invoke-ArchiveConfiguredCommand -Template $template -Path $file.FullName -OcrLanguages "eng+fra"
if ($result.ExitCode -eq 0) {
    Write-Host $result.Output
}
```

---

## String Utilities

### ConvertTo-ArchiveMarkdownValue

Escapes a value for safe inclusion in Markdown.

**Syntax:**
```powershell
ConvertTo-ArchiveMarkdownValue -Value <object>
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Value` | object | Yes | Value to escape (can be null) |

**Returns:** `[string]` - Escaped string value

**Example:**
```powershell
$safe = ConvertTo-ArchiveMarkdownValue -Value 'File "My Doc".txt'
# Returns: File \"My Doc\".txt
```
