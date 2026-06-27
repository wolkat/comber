# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Empty CSV round-trip: `Export-ArchiveCsv` now exports headers-only CSV for empty lists when a schema is provided, preserving CSV structure for downstream stages.
- Tool output validation: added `Assert-ArchiveCommandSuccess` helper to validate tool exit codes and output before parsing.
- LLM config: `Get-ClassificationConfig` now reads from `classification.endpoint` (not `ollamaEndpoint`) and uses config values as primary source.

### Added
- Unit tests to CI/CD pipeline across Linux, macOS, and Windows.
- Pre-commit hook for local lint validation.
- JSON Lines export support (QUICK-4).
- Multi-sheet XLSX export support via ImportExcel (QUICK-5).
- `make setup` target for dependency checking (QUICK-6).

### Documentation
- Clarified that `-Resume` parameter is not yet implemented; checkpoint system planned for future release.

## [0.1.0] - 2026-06-04

### Added

- Initial release of Comber (formerly ArchiveAgentKit).
- Pipeline stages: inventory, metadata, deduplication, text extraction,
  media transcription, classification, knowledge-base generation,
  review reporting, and reviewed-action application.
- MIT license, contribution guidelines, code of conduct, and security policy.
