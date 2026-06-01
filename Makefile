.PHONY: lint typecheck test unit-test build

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
