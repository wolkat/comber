# Comber

PowerShell 7 toolkit for local archive inventory, metadata extraction, duplicate reporting, text extraction, classification, and Markdown knowledge-base generation.

## Quick Reference

```bash
make lint       # Parse-check all PS1 + scan for destructive commands outside 09
make test       # Run fixture pipeline (8 stages against test fixtures)
make unit-test  # Run unit tests for common module functions
make build      # Validate expected files exist
```

## Project Structure

- `scripts/01-09*.ps1` — Pipeline stages (inventory through apply actions)
- `scripts/common/ArchiveAgent.Common.psm1` — Shared module (config, CSV, hashing, path safety, errors, logging)
- `config/pipeline.example.json` — Config template with tool command templates
- `tests/` — Static checks, fixture pipeline, unit tests
- `docs/` — Architecture, API reference, performance, release strategy

## Key Conventions

- PowerShell 7 only; `Set-StrictMode -Version Latest` in all scripts
- All stage scripts accept: `-ConfigPath`, `-RootPath`, `-OutputPath`, `-DryRun`, `-Resume`, `-VerboseLog`
- External tools invoked via config templates, not hardcoded flags
- Source files read-only during stages 01-08; destructive ops only in stage 09
- LLM outputs are untrusted annotations, never used for filesystem actions

## Safety Model

- Output path must be outside source root (configurable via `safety.allowOutputInsideRoot`)
- Deletion disabled by default; requires `safety.allowDelete` + command-line opt-in
- `09-ApplyReviewedActions.ps1` refuses to run without approved manifest

## Error Handling

- Use `New-ArchiveError` with `ArchiveErrorCategory` enum for structured errors
- Use `Invoke-ArchiveRetry` for transient failures (file locks, access denied)
- Use `Write-ArchiveLog` with Level and Category for structured logging

## Config Validation

- Use `Test-ArchiveConfigSchema` to validate config before pipeline execution
- Check property existence with `$Config.PSObject.Properties.Name -contains "key"` before access

## Testing

- Static checks: PowerShell parser + destructive command detection
- Fixture pipeline: runs all 8 stages, verifies source files unchanged
- Unit tests: 18 tests covering common module functions
- Edge case fixtures in `tests/fixtures/source/edge-cases/`

## Preferred CLI Tools

Prefer these tools over legacy alternatives for better performance and output quality:

| Task | Prefer | Over | Fallback |
|------|--------|------|----------|
| File search | `fd` | `find` | `find` (if fd unavailable) |
| JSON processing | `jq` | `grep/sed` | Python `json.tool` |
| YAML processing | `yq` | manual parsing | Python `yaml` module |
| Directory listing | `eza` | `ls` | `ls` (if eza unavailable) |
| File viewing | `bat` | `cat` | `cat` (if bat unavailable) |
| Directory tree | `tree` | manual `find` | `find` + formatting |
| Smart navigation | `zoxide` (`z`) | `cd` + history | `cd` |
| Fuzzy search | `fzf` | manual grep | `grep` + manual selection |
| Git diffs | `delta` (auto) | default pager | default pager |
| Markdown preview | `glow` | `cat` | `cat` |
| HTTP requests | `http` (httpie) | `curl` | `curl` |
| Code statistics | `tokei` | `cloc`, `scc` | `wc -l` |
| Simplified man | `tldr` | `man` | `man` |

**When writing scripts:** Check tool availability with `command -v <tool>` before using. Provide fallbacks for portability.

**Full documentation:** `docs/cli-tools-2026-06-20.md` (install script, examples, troubleshooting)
