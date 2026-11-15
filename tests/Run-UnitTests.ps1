param ([string]$PesterPath)

$ErrorActionPreference = 'Stop'
if ($PesterPath) {
    Import-Module $PesterPath -RequiredVersion 5.7.1 -Force
}
else {
    Import-Module Pester -RequiredVersion 5.7.1 -Force
}

$result = Invoke-Pester -Path (Join-Path $PSScriptRoot 'Upgrade-Everything.Tests.ps1') -Output Detailed -PassThru
if ($result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0 -or $result.TotalCount -eq 0) {
    exit 1
}
exit 0
