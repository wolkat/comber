# AGENTS.md

## Scope

Comber is a standalone PowerShell 7 toolkit for local archive inventory, metadata extraction, duplicate reporting, text extraction, classification, and Markdown knowledge-base generation.

## Rules

- Read existing scripts before editing them.
- Keep scripts independent; do not create a hidden orchestration dependency.
- Do not add automatic deletion.
- Keep destructive operations isolated to `scripts/09-ApplyReviewedActions.ps1`.
- Maintain `-ConfigPath`, `-RootPath`, `-OutputPath`, `-DryRun`, `-Resume`, and `-VerboseLog` on processing scripts.
- Update `CHECKLIST.md` when adding or validating stages.
- Prefer config-driven external command templates over hardcoded third-party CLI flags.
- Run `make lint` and `make test` when PowerShell 7 is available.

## Commands

- `make lint`: parse-check all PowerShell scripts and scan for destructive commands outside the action script.
- `make test`: run the fixture pipeline.
- `make typecheck`: alias for `make lint`; PowerShell scripts do not have a separate type checker.
- `make build`: no-op validation that checks expected files exist.
