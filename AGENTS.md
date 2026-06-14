# PROJECT KNOWLEDGE BASE

**Generated:** 2026-05-31
**Branch:** main

## OVERVIEW

Comber is a standalone PowerShell 7 toolkit for local archive inventory, metadata extraction, duplicate reporting, text extraction, classification, and Markdown knowledge-base generation. Script-first, safety-gated, LLM-optional.

## STRUCTURE

```
./
├── config/             # JSON configs (pipeline.example.json, tools.json)
├── docs/               # Architecture, tool decisions, troubleshooting
├── scripts/            # 10 pipeline stages + common module + installers
│   └── python/         # Python sidecars for ML/NLP features
├── tests/              # Fixture pipeline + static checks
├── outputs/            # Runtime artifacts (logs, CSVs, reports, vault)
├── CHECKLIST.md        # Stage validation checklist
└── Makefile            # lint, test, build
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Pipeline stage | `scripts/NN-*.ps1` | 01=inventory through 10=cleanup |
| Python sidecars | `scripts/python/` | 10=entity extraction, 11=semantic search |
| Shared functions | `scripts/common/ArchiveAgent.Common.psm1` | Config, CSV, hashing, path safety, LLM JSON parsing |
| Install scripts | `scripts/install/Install-*.ps1` | Linux/Mac/Windows |
| Config schema | `config/pipeline.example.json` | Archive roots, exclusions, tool templates |
| Test harness | `tests/Invoke-FixturePipeline.ps1` | Runs full pipeline on fixtures |
| Static checks | `tests/Invoke-StaticChecks.ps1` | Lint: parse-check all PS1 |
| Doc site | `docs/` | Architecture, tool decisions, troubleshooting |
| Fixture data | `tests/fixtures/source/` | Documents, media, photos for testing |
| Change log | `CHANGELOG.md` | Keep a Changelog + SemVer |
| PR template | `.github/PULL_REQUEST_TEMPLATE.md` | For contributions |

## CONVENTIONS

- PowerShell 7 only (no Windows PowerShell compat assumed).
- `Set-StrictMode -Version Latest` in all .ps1 and .psm1 files.
- All processing scripts accept: `-ConfigPath`, `-RootPath`, `-OutputPath`, `-DryRun`, `-Resume`, `-VerboseLog`.
- External tool invocation uses config-driven command templates (`config/pipeline.example.json`), not hardcoded flags.
- CSV for tabular data, JSON sidecars for nested metadata, Markdown for knowledge base.
- Destructive filesystem operations only in `09-ApplyReviewedActions.ps1`.
- No automatic deletion; deletion requires both config and command-line opt-in.
- Source files read-only during stages 01-08.
- LLM outputs are untrusted annotations; never used for filesystem actions.

## ANTI-PATTERNS (THIS PROJECT)

- Do NOT create hidden orchestration dependencies between scripts.
- Do NOT add automatic deletion.
- Do NOT hardcode third-party CLI flags; use config templates.
- Do NOT place output path inside source root (safety guard).

## COMMANDS

```bash
make lint       # Parse-check all PS1 + scan for destructive commands outside 09/10
make test       # Run fixture pipeline
make typecheck  # Alias for lint
make build      # No-op: validate expected files exist
```

## PYTHON SIDECARS

Python sidecars in `scripts/python/` extend Comber with ML/NLP capabilities. All support `--help`:

```bash
# Entity extraction (requires: pip install gliner2 pyyaml)
python scripts/python/10_extract_entities.py \
    --classification-csv outputs/classification/classification.csv \
    --output-dir outputs

# Semantic search (requires: pip install sentence-transformers chromadb pyyaml)
python scripts/python/11_semantic_search.py --mode index \
    --vault-dir outputs/vault/archive-vault --output-dir outputs
python scripts/python/11_semantic_search.py --mode query --query "find documents about X"
```

Requirements files: `scripts/python/requirements-entities.txt`, `scripts/python/requirements-search.txt`

## NOTES

- Output artifacts (CSV, logs, reports, vault) live under `outputs/` and are git-ignored.
- Pipeline stages are independent; rerun a failed stage after fixing the issue.
- `make lint` and `make test` require PowerShell 7 installed.
- Exit codes: 0 = success, 1 = fatal error, 3 = partial success (errors occurred but pipeline can continue).
