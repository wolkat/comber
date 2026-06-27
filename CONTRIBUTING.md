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

### Prerequisites

- PowerShell 7+
- Git
- ExifTool (optional, for richer metadata)
- FFmpeg (optional, for media)
- Tesseract (optional, for OCR)
- ImportExcel module (optional, for XLSX export): `Install-Module ImportExcel -Scope CurrentUser`

### Initial Setup

```powershell
# Clone the repository
git clone https://github.com/wolkat/comber.git
cd comber

# Check dependencies
make setup

# Enable pre-commit hooks (catches syntax errors before commit)
chmod +x .git/hooks/pre-commit

# Run static checks
make lint

# Run fixture pipeline
make test
```

### Development Workflow

1. **Create a feature branch:**
   ```powershell
   git checkout -b feat/my-feature
   ```

2. **Make your changes:**
   - Follow existing code conventions
   - Add comments for complex logic
   - Update documentation if needed

3. **Test your changes:**
   ```powershell
   # Static analysis
   make lint

   # Full fixture pipeline
   make test

   # Manual testing with dry run
   pwsh ./scripts/01-Inventory.ps1 -RootPath ./tests/fixtures/source -OutputPath ./outputs -DryRun
   ```

4. **Commit your changes:**
   ```powershell
   git add .
   git commit -m "feat: add my new feature"
   ```

5. **Push and create PR:**
   ```powershell
   git push origin feat/my-feature
   ```

## Testing Requirements

### Before Submitting a PR

All PRs must pass:

1. **Static checks:** `make lint`
   - PowerShell syntax validation
   - Destructive command detection (only allowed in stage 09)

2. **Fixture pipeline:** `make test`
   - Runs all 8 stages against test fixtures
   - Verifies source files are not modified
   - Checks expected outputs exist

3. **Manual verification** (if applicable):
   - Test with `-DryRun` flag
   - Test with `-VerboseLog` flag
   - Test edge cases (empty directories, large files, etc.)

### Adding New Tests

When adding new functionality:

1. **Add test fixtures** in `tests/fixtures/source/`:
   - Create appropriate subdirectories
   - Include representative file types
   - Keep fixtures small (< 1MB total)

2. **Update fixture pipeline** if needed:
   - Modify `tests/Invoke-FixturePipeline.ps1`
   - Add new expected outputs

3. **Add static checks** if needed:
   - Modify `tests/Invoke-StaticChecks.ps1`
   - Add new validation rules

## Code Review Process

### What We Look For

1. **Safety:**
   - No destructive operations outside stage 09
   - Proper error handling
   - Path safety checks

2. **Conventions:**
   - Follows existing code style
   - Uses common module functions
   - Proper parameter declarations

3. **Testing:**
   - Passes all automated tests
   - Includes appropriate test coverage
   - Handles edge cases

4. **Documentation:**
   - Updates README if needed
   - Adds comments for complex logic
   - Updates API reference if changing module functions

### Review Checklist

- [ ] `make lint` passes
- [ ] `make test` passes
- [ ] No destructive operations outside stage 09
- [ ] Uses `Set-StrictMode -Version Latest`
- [ ] Proper error handling with try/catch
- [ ] Uses common module functions
- [ ] Follows naming conventions
- [ ] Updates documentation if needed

## Release Process

### Versioning

Comber follows [Semantic Versioning](https://semver.org/):

- **Major:** Breaking changes to config format or CSV schema
- **Minor:** New features, new pipeline stages
- **Patch:** Bug fixes, documentation updates

### Creating a Release

1. **Update version** in relevant files
2. **Update CHANGELOG.md** with release notes
3. **Create a git tag:**
   ```powershell
   git tag -a v1.0.0 -m "Release v1.0.0"
   git push origin v1.0.0
   ```
4. **Create GitHub release** with release notes

## Code of Conduct

This project is governed by the [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold it.
