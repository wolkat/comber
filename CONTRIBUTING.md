# Contributing to Comber

First off, thanks for taking the time to contribute.

## How Can I Contribute?

### Reporting Bugs

Before creating a bug report, check existing issues to avoid duplicates. When you create one, include:

- A clear, descriptive title
- Steps to reproduce
- Expected vs actual behavior
- Comber version / commit hash
- Environment: OS version, PowerShell version (`$PSVersionTable`)

### Suggesting Features

Open an issue describing the problem you're trying to solve and your proposed solution. Feature requests are always welcome.

### Submitting Code

1. Fork the repo or create a branch.
2. Run `make lint` before committing.
3. Run `make test` to verify the fixture pipeline still passes.
4. Open a pull request with a clear description of what changed and why.

## Commit Guidelines

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add fuzzy deduplication by filename similarity
fix: handle paths with spaces in inventory stage
docs: clarify recovery notes in README
```

Keep the subject under 50 characters, imperative mood, no period.

All commits must carry a `Signed-off-by` trailer (yours) and `Co-authored-by` trailers for any AI tools used.

## Development Setup

Prerequisites:

- PowerShell 7+
- ExifTool (optional, for richer metadata)
- FFmpeg (optional, for media)

To run the fixture pipeline:

```powershell
pwsh ./tests/Invoke-StaticChecks.ps1
pwsh ./scripts/01-Inventory.ps1 -RootPath ./tests/fixtures/source -OutputPath ./outputs
```

## Code of Conduct

This project is governed by the [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold it.
