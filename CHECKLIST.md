# Comber Checklist

Status values: `planned`, `created`, `validated`, `fixed`.

| Stage | Status | Evidence | Notes |
|---|---|---|---|
| 1. Planning | created | `local-archive-agent-plan.md`, `README.md` | Confirm real archive roots before production use. |
| 2. Tool installation | created | `scripts/install/*` | Install scripts check first and print commands by default. |
| 3. Inventory | validated | `scripts/01-Inventory.ps1`, `make test` | Functional scan, hash, CSV, and error report. |
| 4. Metadata | validated | `scripts/02-Metadata.ps1`, `make test` | Uses inventory timestamps and optional ExifTool JSON. |
| 5. Dedupe | validated | `scripts/03-Dedupe.ps1`, `make test` | Exact duplicate report implemented; near-duplicate hooks documented. |
| 6. Text extraction | validated | `scripts/04-ExtractText.ps1`, `make test` | Plain text extraction implemented; external converters are optional. |
| 7. Transcription | validated | `scripts/05-TranscribeMedia.ps1`, `make test` | Disabled by default; writes skipped report unless enabled. |
| 8. Classification | validated | `scripts/06-ClassifyThemes.ps1`, `make test` | Heuristic tags implemented; optional model hook is conservative. |
| 9. Knowledge base | validated | `scripts/07-BuildKnowledgeBase.ps1`, `make test` | Builds Obsidian-style Markdown notes from prior outputs. |
| 10. Review and actions | validated | `scripts/08-ReviewReports.ps1`, `scripts/09-ApplyReviewedActions.ps1` | Action script refuses to run while actions are disabled. |
| Static validation | validated | `make lint` | PowerShell parser and destructive-command checks pass. |
| Fixture dry-run | validated | `tests/fixtures/source` | Covered by fixture pipeline source hash checks. |
| End-to-end sample | validated | `make test`, `outputs/` | Completed without modifying source fixtures. |

## Agent Work Rules

- Update this checklist after each implementation or validation pass.
- Do not mark a stage `validated` until its script has run against fixtures.
- If validation finds a problem, mark the stage `fixed` only after the repair has been rerun.
- Keep each script independent and reviewable.
- Do not add automatic deletion.
