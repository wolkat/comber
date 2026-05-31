# SCRIPTS

## OVERVIEW

Nine-stage pipeline (01-09) plus shared module and platform installers. Each stage is self-contained, reads CSV/source inputs, validates, writes outputs, exits cleanly.

## PIPELINE MAP

```
01-Inventory.ps1             # Scan root, hash all files, emit inventory.csv
02-Metadata.ps1              # ExifTool/ffprobe enrichments, emit metadata.csv
03-Dedupe.ps1                # Exact-dupe detection via SHA256, Czkawka fuzzy
04-ExtractText.ps1           # Tesseract OCR, MarkItDown/Docling conversion
05-TranscribeMedia.ps1       # whisper.cpp/faster-whisper audio/video transcription
06-ClassifyThemes.ps1        # Ollama + local LLM classification
07-BuildKnowledgeBase.ps1    # Assemble Markdown vault from all prior stages
08-ReviewReports.ps1         # Summary + manifest for human review
09-ApplyReviewedActions.ps1  # ONLY script that moves/deletes files
```

## KEY FILES

| File | Role |
|------|------|
| `common/ArchiveAgent.Common.psm1` | Shared: config loading, CSV I/O, path safety, hashing, exclusion filtering, external-command runner |
| `install/Install-Linux.ps1` | Linux deploy: symlink helpers, dependency check |
| `install/Install-MacOS.ps1` | macOS deploy: Homebrew dep check, symlink |
| `install/Install-Windows.ps1` | Windows deploy: Path setup, winget deps |

## CONVENTIONS

- Every stage script starts with:
  ```powershell
  param([string]$ConfigPath, [string]$RootPath, [string]$OutputPath, [switch]$DryRun, [switch]$Resume, [switch]$VerboseLog)
  ```
- Stage scripts call `New-ArchiveRun` from the common module for bootstrap.
- Stage outputs are CSV files in `outputs/{stage}/`.
- Logging via `Write-ArchiveLog` from common module.
- External tool calls use `Invoke-ArchiveConfiguredCommand` with config templates.

## INVENTORY CSV SCHEMA (CROSS-STAGE CONTRACT)

The inventory CSV (`outputs/inventory/inventory.csv`) is the backbone data contract. All downstream stages depend on these columns:

| Column | Source | Used By | Required |
|--------|--------|---------|----------|
| `path` | `$file.FullName` | All stages | Yes |
| `relative_path` | `GetRelativePath(RootPath, FullName)` | Reports | Yes |
| `parent` | `$file.DirectoryName` | Reports | Yes |
| `name` | `$file.Name` | Metadata, Extraction, Transcription, Classification | Yes |
| `extension` | `$file.Extension.ToLowerInvariant()` | Classification, Extraction | Yes |
| `category` | `Get-ArchiveFileCategory` | All stages | Yes |
| `length_bytes` | `$file.Length` | Dedupe, Extraction | Yes |
| `created_utc` | `$file.CreationTimeUtc` | Metadata | Yes |
| `modified_utc` | `$file.LastWriteTimeUtc` | Metadata | Yes |
| `accessed_utc` | `$file.LastAccessTimeUtc` | Metadata | Yes |
| `hash_algorithm` | Config or "SHA256" | Reports | Yes |
| `hash` | `Get-FileHash` | Dedupe, KnowledgeBase | Yes (may be empty for large files) |
| `hash_status` | ok/dry_run/skipped_size_limit/error | Dedupe | Yes |

Each stage validates required columns on import via `Test-ArchiveCsvColumns`. If a column is missing or the CSV is empty, the stage fails with a clear error message before processing.

## ANTI-PATTERNS

- Do NOT add a new stage between existing numbered stages; append at the end.
- Do NOT modify outputs of other stages (read-only cross-stage access).
- Do NOT add hardcoded paths to third-party tools.
- Do NOT change the inventory CSV schema without updating all consuming stages.
