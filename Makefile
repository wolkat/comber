.PHONY: lint typecheck test unit-test build setup setup-linux setup-macos setup-windows

lint:
	pwsh ./tests/Invoke-StaticChecks.ps1

typecheck: lint

test:
	pwsh ./tests/Invoke-FixturePipeline.ps1

unit-test:
	pwsh ./tests/Invoke-UnitTests.ps1

build:
	test -f ./README.md
	test -f ./CHECKLIST.md
	test -f ./config/pipeline.example.json
	test -f ./scripts/common/ArchiveAgent.Common.psm1

setup:
	@echo "Comber Setup"
	@echo "============"
	@uname -s | grep -q Darwin && make setup-macos || (uname -s | grep -q Linux && make setup-linux || make setup-windows)

setup-linux:
	@echo "Checking required tools on Linux..."
	@command -v pwsh >/dev/null 2>&1 || (echo "ERROR: PowerShell 7 not found. Install: sudo apt install powershell" && exit 1)
	@echo "  [OK] pwsh"
	@command -v exiftool >/dev/null 2>&1 || echo "  [SKIP] exiftool (optional, sudo apt install libimage-exiftool-perl)"
	@command -v ffprobe >/dev/null 2>&1 || echo "  [SKIP] ffprobe (optional, sudo apt install ffmpeg)"
	@command -v tesseract >/dev/null 2>&1 || echo "  [SKIP] tesseract (optional, sudo apt install tesseract-ocr)"
	@echo "Setup complete. Run 'make lint' to verify."

setup-macos:
	@echo "Checking required tools on macOS..."
	@command -v pwsh >/dev/null 2>&1 || (echo "ERROR: PowerShell 7 not found. Install: brew install powershell" && exit 1)
	@echo "  [OK] pwsh"
	@command -v exiftool >/dev/null 2>&1 || echo "  [SKIP] exiftool (optional, brew install exiftool)"
	@command -v ffprobe >/dev/null 2>&1 || echo "  [SKIP] ffprobe (optional, brew install ffmpeg)"
	@command -v tesseract >/dev/null 2>&1 || echo "  [SKIP] tesseract (optional, brew install tesseract)"
	@echo "Setup complete. Run 'make lint' to verify."

setup-windows:
	@echo "Checking required tools on Windows..."
	@where pwsh >nul 2>&1 || (echo "ERROR: PowerShell 7 not found. Install: winget install Microsoft.PowerShell" && exit 1)
	@echo "  [OK] pwsh"
	@where exiftool >nul 2>&1 || echo "  [SKIP] exiftool (optional, winget install exiftool)"
	@where ffprobe >nul 2>&1 || echo "  [SKIP] ffprobe (optional, winget install ffmpeg)"
	@where tesseract >nul 2>&1 || echo "  [SKIP] tesseract (optional, winget install tesseract-ocr)"
	@echo "Setup complete. Run 'make lint' to verify."
