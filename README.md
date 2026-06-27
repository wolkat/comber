# Comber

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Cross-platform local archive toolkit for mapping large personal file collections, detecting duplicate candidates, extracting text/transcripts, and building a Markdown knowledge base.

The toolkit is intentionally script-first. An AI agent may help maintain it, but the repeatable work is done by PowerShell 7 scripts with validation, logs, dry-runs, and review reports.

## Safety Model

- Source files are read-only during stages `01` through `08`.
- Generated files go under the configured output directory.
- Delete and move actions are isolated in `09-ApplyReviewedActions.ps1`.
- The action script refuses to run without an approved manifest.
- Deletion is disabled unless both config and command-line flags allow it.
- LLM output is never trusted for filesystem actions.

## Quick Start

Install PowerShell 7 first, then copy `config/pipeline.example.json` to a working config and edit archive roots.

```powershell
pwsh ./scripts/01-Inventory.ps1 -ConfigPath ./config/pipeline.example.json -DryRun
pwsh ./scripts/01-Inventory.ps1 -ConfigPath ./config/pipeline.example.json
pwsh ./scripts/02-Metadata.ps1 -ConfigPath ./config/pipeline.example.json
pwsh ./scripts/03-Dedupe.ps1 -ConfigPath ./config/pipeline.example.json
pwsh ./scripts/04-ExtractText.ps1 -ConfigPath ./config/pipeline.example.json
pwsh ./scripts/07-BuildKnowledgeBase.ps1 -ConfigPath ./config/pipeline.example.json
pwsh ./scripts/08-ReviewReports.ps1 -ConfigPath ./config/pipeline.example.json
```

Run against the included fixtures first:

```powershell
pwsh ./tests/Invoke-StaticChecks.ps1
pwsh ./scripts/01-Inventory.ps1 -RootPath ./tests/fixtures/source -OutputPath ./outputs -DryRun
pwsh ./scripts/01-Inventory.ps1 -RootPath ./tests/fixtures/source -OutputPath ./outputs
```

## Outputs

- `outputs/inventory/inventory.csv`
- `outputs/inventory/file-errors.csv`
- `outputs/metadata/metadata.csv`
- `outputs/reports/exact-duplicates.csv`
- `outputs/reports/near-duplicates.csv` (when near-duplicate detection is enabled)
- `outputs/reports/near-duplicate-status.csv`
- `outputs/extracted/*.md`
- `outputs/transcripts/*.md`
- `outputs/classification/classification.csv`
- `outputs/vault/*.md`
- `outputs/reports/review-summary.md`
- `outputs/logs/*.log`

### JSON Lines Format (for streaming ETL)

Generated alongside CSVs in the review stage:

- `outputs/inventory/inventory.jsonl`
- `outputs/metadata/metadata.jsonl`
- `outputs/reports/exact-duplicates.jsonl`
- `outputs/classification/classification.jsonl`

Each line is a self-contained JSON object, suitable for streaming ingestion into Elasticsearch, Splunk, or AWS Kinesis.

**Usage Example:**
```bash
# Stream to Elasticsearch
cat outputs/inventory/inventory.jsonl | curl -s -X POST "localhost:9200/_bulk" -H "Content-Type: application/x-ndjson" -d @-
```

### Excel Workbook (optional, requires ImportExcel)

- `outputs/reports/archive-summary.xlsx` — Multi-sheet workbook with Inventory, Metadata, Duplicates, and Classification data.

To enable, install the ImportExcel module: `Install-Module ImportExcel -Scope CurrentUser`

## External Tools

The scripts work in layers. Inventory, metadata fallback, exact duplicate detection, simple text extraction, and knowledge-base generation do not require AI.

Optional tools improve coverage:

- ExifTool for richer media/document metadata.
- FFmpeg/ffprobe for audio/video metadata and extraction.
- Czkawka CLI for near-duplicate image/video detection.
- ImageMagick for perceptual hash pre-filtering of similar images.
- Tesseract or PaddleOCR for image OCR.
- MarkItDown or Docling for document conversion.
- whisper.cpp or faster-whisper for transcripts.
- Ollama plus a local model for classification.

External command templates live in `config/pipeline.example.json` so tool flags can be adjusted without editing scripts.

## Recovery Notes

If a run fails, check:

1. `outputs/logs/`
2. Stage-specific error reports.
3. Whether previous-stage CSV files exist.
4. Whether output path is outside the source root.

The scripts are independent. Fix the issue and rerun the failed stage.

## Resume and Recovery (Future Feature)

The `-Resume` parameter is accepted by all pipeline stages but is not yet implemented.
Currently, if a stage fails:

1. Fix the underlying issue (missing tool, permission error, etc.)
2. Rerun the stage (it will reprocess all files)

Future versions will support checkpoint saving, incremental processing, and automatic recovery.

## Exit Codes

All pipeline scripts follow a consistent exit code contract:

| Code | Meaning | Action |
|------|---------|--------|
| `0` | Success | Proceed to next stage |
| `1` | Fatal error | Check logs, fix issue, rerun this stage |
| `3` | Partial success | Errors occurred but pipeline can continue; check error reports |

The test harness (`Invoke-FixturePipeline.ps1`) accepts both `0` and `3` as valid exit codes.

## License

This project is licensed under the [MIT License](LICENSE).

## Contributions

This project is primarily maintained by an AI agent for personal archive use. Contributions and suggestions are welcome.

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on commits, development setup, and the PR process. All contributors are expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

If you find a security vulnerability, see [SECURITY.md](SECURITY.md) for disclosure instructions.
