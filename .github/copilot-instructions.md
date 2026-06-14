# Copilot Instructions for Comber

This document guides future Copilot CLI sessions working in the Comber repository.

## Build, Test, and Lint

All commands use `make` and require PowerShell 7:

```bash
make lint       # Parse-check all PS1 files + scan for destructive commands outside stage 09
make test       # Run fixture pipeline (all 8 stages against test fixtures)
make unit-test  # Run unit tests for common module functions
make build      # Validate expected files exist (no-op verification)
```

**Single stage testing:**
```powershell
# Test a single stage against fixtures without affecting source files
pwsh ./scripts/01-Inventory.ps1 -RootPath ./tests/fixtures/source -OutputPath ./outputs -DryRun
pwsh ./scripts/02-Metadata.ps1 -RootPath ./tests/fixtures/source -OutputPath ./outputs -DryRun
```

**After making code changes:**
1. Run `make lint` to validate syntax and check for safety violations
2. Run `make test` to ensure the fixture pipeline still passes
3. Verify output artifacts exist in `outputs/` directory

## High-Level Architecture

Comber is a **staged pipeline** where each stage reads previous outputs, validates, processes, and writes its own outputs independently. No stage depends on hidden orchestration—they are composable and replayable.

### Pipeline Flow

```
Source archive
    ↓
01-Inventory.ps1           → inventory.csv (all files, hashes, metadata)
    ↓ (parallel consuming stages)
├→ 02-Metadata.ps1         → metadata.csv (ExifTool/ffprobe enrichments)
├→ 03-Dedupe.ps1           → exact-duplicates.csv, near-duplicates.csv
├→ 04-ExtractText.ps1      → extracted/*.md (OCR via Tesseract/MarkItDown)
├→ 05-TranscribeMedia.ps1  → transcripts/*.md (whisper.cpp/faster-whisper)
├→ 06-ClassifyThemes.ps1   → classification.csv (Ollama LLM classification)
    ↓ (synthesis stage)
07-BuildKnowledgeBase.ps1  → vault/*.md (unified knowledge base)
    ↓
08-ReviewReports.ps1       → review-summary.md + manifest (human review)
    ↓
09-ApplyReviewedActions.ps1 (ONLY stage that moves/deletes)
    ↓
10-Cleanup.ps1             (remove temp files)
```

**Key invariant:** Stages 01–08 do NOT modify source files. Only stage 09 modifies the filesystem (and only with explicit approval).

### CSV as Contract

The **inventory.csv** is the backbone data contract passed between all stages. It contains:

```
path | relative_path | parent | name | extension | category | length_bytes | 
created_utc | modified_utc | accessed_utc | hash_algorithm | hash | hash_status
```

All downstream stages validate these columns on import via `Test-ArchiveCsvColumns`. If columns are missing or the CSV is empty, the stage fails immediately with a clear error before processing.

### External Tool Invocation

Third-party tools (ExifTool, FFmpeg, Tesseract, Czkawka, Ollama, etc.) are **not hardcoded** in stage scripts. Instead:

1. Command templates are stored in `config/pipeline.example.json` (see `tools` section)
2. Stages invoke tools via `Invoke-ArchiveConfiguredCommand` from the common module
3. Flags can be adjusted in the config without editing scripts

This keeps scripts maintainable and tool versions decoupled from code.

### Python Sidecars

ML/NLP features live in `scripts/python/`:

- **10_extract_entities.py** — GLiNER2 entity extraction, reads classification.csv, outputs entities.csv
- **11_semantic_search.py** — Sentence-transformers + ChromaDB vector search, indexes vault, supports natural-language queries

These scripts follow the same CLI patterns as the PowerShell pipeline: `--help`, argument parsing, read from outputs CSV/markdown.

## Key Conventions

### Safety Model

- **Read-only during stages 01–08** — Source files are never modified
- **Output isolation** — All output goes to `outputs/` (configurable, must be outside source root)
- **Deletion disabled by default** — Requires both config setting (`safety.allowDelete = true`) AND command-line opt-in
- **Manifest approval** — Stage 09 refuses to run without a human-reviewed manifest from stage 08
- **LLM outputs untrusted** — Classification/entity results are annotations only, never used for filesystem actions

### Parameter Contract

All stage scripts accept the same parameters:

```powershell
param(
    [string]$ConfigPath,      # Path to pipeline.example.json
    [string]$RootPath,        # Archive root directory (defaults from config)
    [string]$OutputPath,      # Output directory (defaults from config)
    [switch]$DryRun,          # Preview only, no file modifications
    [switch]$Resume,          # Skip already-processed files
    [switch]$VerboseLog       # Detailed logging to outputs/logs/
)
```

### Error Handling

Use the common module error functions:

- **`New-ArchiveError`** with `ArchiveErrorCategory` enum:
  - ConfigError, PathError, FileError, HashError, CsvError, ToolError, ValidationError, PermissionError, TransientError
- **`Invoke-ArchiveRetry`** for transient failures (file locks, access denied, network paths)
- **`Write-ArchiveLog`** for structured logging with Level (Info, Warning, Error) and Category

### Exit Codes

All scripts follow this contract:

| Code | Meaning | Action |
|------|---------|--------|
| `0` | Success | Proceed to next stage |
| `1` | Fatal error | Check logs, fix, rerun this stage |
| `3` | Partial success | Errors occurred but pipeline can continue; review error reports |

### Naming & Code Style

- **File categories** — Use `Get-ArchiveFileCategory` from common module (document, media, archive, image, video, audio, etc.)
- **CSV I/O** — Use `Import-ArchiveCsv` and `Export-ArchiveCsv` from common module
- **Hashing** — Use `Get-FileHash` with config algorithm (default SHA256)
- **Path safety** — Use `Resolve-ArchivePath` and `Test-ArchivePathSafety` to validate and normalize paths
- **Exclusions** — Use `Test-ArchiveExclusionMatch` to check if a path should be skipped

All scripts start with `Set-StrictMode -Version Latest`.

### Anti-Patterns (DO NOT DO THESE)

1. **Do NOT** create hidden dependencies between stages (they must be independently runnable)
2. **Do NOT** add automatic deletion (always require explicit opt-in)
3. **Do NOT** hardcode third-party CLI flags (use config templates instead)
4. **Do NOT** modify the inventory CSV schema without updating all consuming stages
5. **Do NOT** add stages between existing numbered stages (append at the end with the next number)
6. **Do NOT** place output path inside the source root (safety invariant)
7. **Do NOT** use LLM outputs for filesystem decisions (annotations only)

## Configuration

Config lives in `config/pipeline.example.json`:

```json
{
  "archive": {
    "roots": ["C:/archive/personal", "D:/archive/work"],
    "exclusions": {".git", "node_modules", "**/*.tmp"}
  },
  "output": {
    "rootPath": "C:/outputs"
  },
  "safety": {
    "allowOutputInsideRoot": false,
    "allowDelete": false,
    "hashAlgorithm": "SHA256"
  },
  "tools": {
    "exiftool": { "command": "exiftool {path}" },
    "ffprobe": { "command": "ffprobe -v quiet -print_format json {path}" },
    ...
  }
}
```

Always call `Test-ArchiveConfigSchema` before pipeline execution. Check for property existence using `$Config.PSObject.Properties.Name -contains "key"` before accessing nested values.

## Testing

### Before Committing

1. **Lint:** `make lint` → PowerShell syntax validation + destructive command detection
2. **Test:** `make test` → Full fixture pipeline, verifies source unchanged, checks outputs exist
3. **Unit tests:** `make unit-test` → 18 tests for common module functions

### Test Fixtures

- Located in `tests/fixtures/source/`
- Includes documents, media, photos, edge cases
- Test harness: `tests/Invoke-FixturePipeline.ps1`
- Static checks: `tests/Invoke-StaticChecks.ps1`
- Accepts exit codes `0` and `3` as valid

### Edge Cases

Fixtures include edge-case files in `tests/fixtures/source/edge-cases/`:

- Empty directories
- Very large files
- Symlinks
- Special characters in filenames
- Mixed file types

## File Layout

| Path | Purpose |
|------|---------|
| `scripts/01-09*.ps1` | Pipeline stages (01=inventory through 09=apply actions) |
| `scripts/common/ArchiveAgent.Common.psm1` | Shared module: config, CSV, hashing, path safety, error handling, logging |
| `scripts/install/Install-*.ps1` | Platform installers (Linux, macOS, Windows) |
| `scripts/python/` | ML/NLP sidecars (entity extraction, semantic search) |
| `config/pipeline.example.json` | Configuration template with tool command templates |
| `tests/` | Static checks, fixture pipeline, unit tests |
| `docs/` | Architecture, API reference, performance, release strategy |
| `outputs/` | Runtime artifacts (CSV, logs, markdown vault) — git-ignored |
| `CHECKLIST.md` | Stage validation checklist for maintainers |
| `AGENTS.md` | Knowledge base for AI agent development (this repository's agent instructions) |
| `CLAUDE.md` | Claude-specific guidance |

## Notes

- **PowerShell 7 only** — No Windows PowerShell compatibility
- **Independent stages** — Fix a failed stage and rerun; no need to restart the pipeline
- **Output cleanup** — `outputs/` is git-ignored; artifacts do not persist in version control
- **Logging** — Check `outputs/logs/` for detailed stage-specific logs when something fails
- **Dry-run first** — Always test with `-DryRun` before actual execution
