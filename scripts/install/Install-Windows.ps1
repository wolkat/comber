param(
    [string]$ConfigPath,
    [string]$RootPath,
    [string]$OutputPath,
    [switch]$DryRun,
    [switch]$Resume,
    [switch]$VerboseLog,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "../common/ArchiveAgent.Common.psm1") -Force -DisableNameChecking

try {
    $run = New-ArchiveRun -ScriptName "Install-Windows" -ConfigPath $ConfigPath -RootPath $RootPath -OutputPath $OutputPath -VerboseLog:$VerboseLog -AllowMissingRoot
    $toolsPath = Join-Path $run.ToolkitRoot "config/tools.json"
    $tools = Get-Content -LiteralPath $toolsPath -Raw | ConvertFrom-Json -Depth 20
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($tool in @($tools.required + $tools.recommended)) {
        $version = Get-ArchiveToolVersion -Command $tool.command
        $rows.Add([pscustomobject]@{
            name = $tool.name
            command = $tool.command
            available = $version.available
            path = $version.path
            version = $version.version
            install_hint = $tool.windows
        })
    }

    Export-ArchiveCsv -Rows $rows -Path (Join-Path $run.OutputPath "reports/tool-versions-windows.csv")

    if ($Apply) {
        Write-ArchiveLog -Run $run -Message "Apply mode is intentionally conservative. Review tool-versions-windows.csv and install missing tools manually or with trusted commands."
    }
    else {
        Write-ArchiveLog -Run $run -Message "Dry check complete. Install hints written; no packages installed."
    }

    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
