param(
    [string]$ToolkitRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
    $ToolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
}

$modulePath = Join-Path $ToolkitRoot "scripts/common/ArchiveAgent.Common.psm1"
Import-Module $modulePath -Force -DisableNameChecking

$failures = New-Object System.Collections.Generic.List[object]
$tests = New-Object System.Collections.Generic.List[object]

function Add-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = ""
    )

    $tests.Add([pscustomobject]@{
        Test = $TestName
        Passed = $Passed
        Message = $Message
    })

    if (-not $Passed) {
        $failures.Add([pscustomobject]@{
            Test = $TestName
            Message = $Message
        })
    }
}

# Test Get-ArchiveToolkitRoot
try {
    $root = Get-ArchiveToolkitRoot
    $passed = (Test-Path -LiteralPath $root -PathType Container) -and ($root -eq $ToolkitRoot)
    Add-TestResult -TestName "Get-ArchiveToolkitRoot" -Passed $passed -Message "Root: $root"
}
catch {
    Add-TestResult -TestName "Get-ArchiveToolkitRoot" -Passed $false -Message $_.Exception.Message
}

# Test Resolve-ArchivePath
try {
    # Test relative path
    $resolved = Resolve-ArchivePath -PathValue "./test" -BasePath "/tmp"
    $expected = [System.IO.Path]::GetFullPath((Join-Path "/tmp" "./test"))
    $passed = $resolved -eq $expected
    Add-TestResult -TestName "Resolve-ArchivePath (relative)" -Passed $passed -Message "Resolved: $resolved"

    # Test absolute path
    $resolved = Resolve-ArchivePath -PathValue "/absolute/path" -BasePath "/tmp"
    $passed = $resolved -eq "/absolute/path"
    Add-TestResult -TestName "Resolve-ArchivePath (absolute)" -Passed $passed -Message "Resolved: $resolved"
}
catch {
    Add-TestResult -TestName "Resolve-ArchivePath" -Passed $false -Message $_.Exception.Message
}

# Test Test-PathInside
try {
    $passed = Test-PathInside -ChildPath "/tmp/test" -ParentPath "/tmp"
    Add-TestResult -TestName "Test-PathInside (inside)" -Passed $passed

    $passed = -not (Test-PathInside -ChildPath "/other" -ParentPath "/tmp")
    Add-TestResult -TestName "Test-PathInside (outside)" -Passed $passed

    $passed = Test-PathInside -ChildPath "/tmp" -ParentPath "/tmp"
    Add-TestResult -TestName "Test-PathInside (same)" -Passed $passed
}
catch {
    Add-TestResult -TestName "Test-PathInside" -Passed $false -Message $_.Exception.Message
}

# Test Ensure-ArchiveDirectory
try {
    $testDir = Join-Path "/tmp" "comber-test-$(Get-Random)"
    Ensure-ArchiveDirectory -Path $testDir
    $passed = Test-Path -LiteralPath $testDir -PathType Container
    Add-TestResult -TestName "Ensure-ArchiveDirectory" -Passed $passed
    Remove-Item -LiteralPath $testDir -Force -ErrorAction SilentlyContinue
}
catch {
    Add-TestResult -TestName "Ensure-ArchiveDirectory" -Passed $false -Message $_.Exception.Message
}

# Test Test-ArchiveSystemPath
try {
    $passed = Test-ArchiveSystemPath -Path "/etc"
    Add-TestResult -TestName "Test-ArchiveSystemPath (system)" -Passed $passed

    $passed = -not (Test-ArchiveSystemPath -Path "/Users/test/archives")
    Add-TestResult -TestName "Test-ArchiveSystemPath (non-system)" -Passed $passed
}
catch {
    Add-TestResult -TestName "Test-ArchiveSystemPath" -Passed $false -Message $_.Exception.Message
}

# Test Test-ArchiveCommand
try {
    $passed = Test-ArchiveCommand -Command "pwsh"
    Add-TestResult -TestName "Test-ArchiveCommand (exists)" -Passed $passed

    $passed = -not (Test-ArchiveCommand -Command "nonexistent-command-12345")
    Add-TestResult -TestName "Test-ArchiveCommand (not exists)" -Passed $passed
}
catch {
    Add-TestResult -TestName "Test-ArchiveCommand" -Passed $false -Message $_.Exception.Message
}

# Test Get-ArchiveFileCategory
try {
    $passed = (Get-ArchiveFileCategory -Extension ".jpg") -eq "image"
    Add-TestResult -TestName "Get-ArchiveFileCategory (image)" -Passed $passed

    $passed = (Get-ArchiveFileCategory -Extension ".mp4") -eq "video"
    Add-TestResult -TestName "Get-ArchiveFileCategory (video)" -Passed $passed

    $passed = (Get-ArchiveFileCategory -Extension ".txt") -eq "text"
    Add-TestResult -TestName "Get-ArchiveFileCategory (text)" -Passed $passed

    $passed = (Get-ArchiveFileCategory -Extension ".unknown") -eq "unknown"
    Add-TestResult -TestName "Get-ArchiveFileCategory (unknown)" -Passed $passed
}
catch {
    Add-TestResult -TestName "Get-ArchiveFileCategory" -Passed $false -Message $_.Exception.Message
}

# Test Get-ArchiveSafeStem
try {
    $stem = Get-ArchiveSafeStem -Path "/tmp/test file.txt"
    $passed = $stem -match "^test_file-[a-f0-9]{12}$"
    Add-TestResult -TestName "Get-ArchiveSafeStem" -Passed $passed -Message "Stem: $stem"
}
catch {
    Add-TestResult -TestName "Get-ArchiveSafeStem" -Passed $false -Message $_.Exception.Message
}

# Test New-ArchiveError
try {
    $archiveError = New-ArchiveError -Category "ConfigError" -Message "Test error" -Path "/test" -Stage "Test"
    $passed = $archiveError.Category -eq "ConfigError" -and $archiveError.Message -eq "Test error" -and $archiveError.Path -eq "/test" -and $archiveError.Stage -eq "Test"
    Add-TestResult -TestName "New-ArchiveError" -Passed $passed
}
catch {
    Add-TestResult -TestName "New-ArchiveError" -Passed $false -Message $_.Exception.Message
}

# Test Test-ArchiveConfigSchema
try {
    $validConfig = [pscustomobject]@{
        archiveRoots = @("/tmp")
        outputPath = "./outputs"
        inventory = [pscustomobject]@{
            hashAlgorithm = "SHA256"
            hashMaxBytes = 0
            progressEvery = 250
        }
        metadata = [pscustomobject]@{
            enableExifTool = $true
        }
        dedupe = [pscustomobject]@{
            enableNearDuplicate = $false
            similarityThreshold = 0.8
        }
        cleanup = [pscustomobject]@{
            enabled = $false
            targets = @("extracted", "transcripts")
        }
        entities = [pscustomobject]@{
            enabled = $false
        }
        search = [pscustomobject]@{
            enabled = $false
        }
        extraction = [pscustomobject]@{
            maxInlineTextBytes = 5242880
            enableExternalConverters = $false
        }
        transcription = [pscustomobject]@{
            enabled = $false
        }
        classification = [pscustomobject]@{
            enabled = $false
        }
        knowledgeBase = [pscustomobject]@{
            vaultName = "test"
            copyOriginals = $false
        }
        actions = [pscustomobject]@{
            enableApplyReviewedActions = $false
        }
        safety = [pscustomobject]@{
            allowOutputInsideRoot = $false
            allowDelete = $false
            requireApprovedManifest = $true
        }
    }

    $result = Test-ArchiveConfigSchema -Config $validConfig
    $passed = $result.Valid -eq $true
    Add-TestResult -TestName "Test-ArchiveConfigSchema (valid)" -Passed $passed

    # Test invalid config
    $invalidConfig = [pscustomobject]@{
        archiveRoots = "not-an-array"
        outputPath = "./outputs"
        inventory = [pscustomobject]@{
            hashAlgorithm = "INVALID"
            hashMaxBytes = 0
            progressEvery = 250
        }
        metadata = [pscustomobject]@{ enableExifTool = $true }
        extraction = [pscustomobject]@{ enableExternalConverters = $false }
        transcription = [pscustomobject]@{ enabled = $false }
        classification = [pscustomobject]@{ enabled = $false; maxChars = 0 }
        knowledgeBase = [pscustomobject]@{ vaultName = "test" }
        actions = [pscustomobject]@{ enableApplyReviewedActions = $false }
        safety = [pscustomobject]@{ allowDelete = $false }
        cleanup = [pscustomobject]@{ enabled = $false }
    }

    try {
        $result = Test-ArchiveConfigSchema -Config $invalidConfig
        $passed = $result.Valid -eq $false -and $result.Errors.Count -gt 0
        Add-TestResult -TestName "Test-ArchiveConfigSchema (invalid)" -Passed $passed -Message "Errors: $($result.Errors -join '; ')"
    }
    catch {
        Add-TestResult -TestName "Test-ArchiveConfigSchema (invalid)" -Passed $false -Message $_.Exception.Message
    }
}
catch {
    Add-TestResult -TestName "Test-ArchiveConfigSchema" -Passed $false -Message $_.Exception.Message
}

# Test ConvertFrom-ArchiveLlmJson
try {
    $result = ConvertFrom-ArchiveLlmJson -RawText '{"summary":"test","tags":["a","b"],"vibe":"cool"}'
    $passed = $result -and $result.summary -eq "test" -and $result.vibe -eq "cool"
    Add-TestResult -TestName "ConvertFrom-ArchiveLlmJson (clean JSON)" -Passed $passed

    $result = ConvertFrom-ArchiveLlmJson -RawText "prefix`n`n{`"summary`":`"my summary`",`"tags`":[`"tag1`"],`"vibe`":`"happy`"}`n`nsuffix"
    $passed = $result -and $result.summary -eq "my summary" -and $result.vibe -eq "happy"
    Add-TestResult -TestName "ConvertFrom-ArchiveLlmJson (text with JSON)" -Passed $passed

    $result = ConvertFrom-ArchiveLlmJson -RawText "No JSON here at all"
    $passed = $null -eq $result
    Add-TestResult -TestName "ConvertFrom-ArchiveLlmJson (no JSON)" -Passed $passed

    $result = ConvertFrom-ArchiveLlmJson -RawText ([string]::Empty)
    $passed = $null -eq $result
    Add-TestResult -TestName "ConvertFrom-ArchiveLlmJson (empty)" -Passed $passed

    $result = ConvertFrom-ArchiveLlmJson -RawText '{"data":{"inner":"value","list":[1,2,3]},"ok":true}'
    $passed = $result -and $result.data.inner -eq "value" -and $result.ok -eq $true
    Add-TestResult -TestName "ConvertFrom-ArchiveLlmJson (nested)" -Passed $passed
}
catch {
    Add-TestResult -TestName "ConvertFrom-ArchiveLlmJson" -Passed $false -Message $_.Exception.Message
}

# Print results
Write-Host "`nUnit Test Results:"
Write-Host "=================="
foreach ($test in $tests) {
    $status = if ($test.Passed) { "PASS" } else { "FAIL" }
    Write-Host "[$status] $($test.Test)"
    if (-not $test.Passed -and $test.Message) {
        Write-Host "       $($test.Message)"
    }
}

Write-Host "`nSummary:"
Write-Host "  Total: $($tests.Count)"
Write-Host "  Passed: $(@($tests | Where-Object { $_.Passed }).Count)"
Write-Host "  Failed: $(@($tests | Where-Object { -not $_.Passed }).Count)"

if ($failures.Count -gt 0) {
    Write-Host "`nFailed Tests:"
    foreach ($failure in $failures) {
        Write-Host "  - $($failure.Test): $($failure.Message)"
    }
    exit 1
}

exit 0
