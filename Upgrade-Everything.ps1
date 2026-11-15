param (
    [switch]$MachineOnly,
    [string]$LogPath
)

$script:UpdateFailed = $false
$script:ActiveLogPath = $null
$script:LogFilePath = $null
$script:TaskResults = @()

function Initialize-UpdateLogging {
    param ([string]$Path)
    if (-not $Path) {
        $name = 'Upgrade-{0}-{1}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $PID
        $Path = Join-Path (Join-Path $env:LOCALAPPDATA 'UpgradeEverything\Logs') $name
    }
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $directory = Split-Path -Parent $resolvedPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    }
    # Probe the destination before starting any updates. Existing logs are appended.
    Add-Content -LiteralPath $resolvedPath -Value '' -Encoding UTF8 -ErrorAction Stop
    $script:ActiveLogPath = $resolvedPath
    $script:LogFilePath = $resolvedPath
    Write-UpdateLog "Log file: $resolvedPath"
}

function Write-UpdateLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console status must stay out of command output pipelines; Windows PowerShell 5.1 supports capturing Write-Host.')]
    param (
        [string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [switch]$FileOnly
    )
    $prefix = '{0} [{1}] [PID:{2}]' -f (Get-Date -Format 'o'), $Level, $PID
    $line = "$prefix $Message"
    if ($script:ActiveLogPath) {
        try {
            $details = if ($ErrorRecord) {
                ' | {0} | ErrorId: {1} | Position: {2} | Stack: {3}' -f
                $ErrorRecord.Exception, $ErrorRecord.FullyQualifiedErrorId,
                $ErrorRecord.InvocationInfo.PositionMessage, $ErrorRecord.ScriptStackTrace
            }
            else { '' }
            Add-Content -LiteralPath $script:ActiveLogPath -Value (($line + $details) -replace '\r?\n', ' | ') -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            # Avoid recursive logging errors; continue console reporting and fail the run.
            $script:UpdateFailed = $true
            $failedPath = $script:ActiveLogPath
            $script:ActiveLogPath = $null
            Write-Warning "Cannot write log '$failedPath': $($_.Exception.Message). Continuing with console logging only." -WarningAction Continue
        }
    }
    if (-not $FileOnly) {
        if ($Level -eq 'ERROR') {
            Write-Error $line -ErrorAction Continue
        }
        else {
            $color = switch ($Level) { 'SUCCESS' { 'Green' } 'WARN' { 'Yellow' } default { 'Cyan' } }
            Write-Host $line -ForegroundColor $color
        }
    }
}

function Test-OptionalUpdateCommand {
    param ([string]$Command)
    if (Get-Command $Command -ErrorAction SilentlyContinue) { return $true }
    Write-UpdateLog "[SKIP] $Command is not installed or is unavailable on PATH." -Level WARN
    return $false
}

function Write-UpdateSummary {
    $failed = @($script:TaskResults | Where-Object { $_.Status -eq 'Failed' })
    $succeeded = @($script:TaskResults | Where-Object { $_.Status -eq 'Succeeded' })
    Write-UpdateLog "[SUMMARY] $($succeeded.Count) task(s) succeeded; $($failed.Count) task(s) failed in this process."
    foreach ($task in $failed) {
        Write-UpdateLog "[SUMMARY] Failed: $($task.Name) - $($task.Error)" -Level ERROR
    }
    if ($script:UpdateFailed) {
        Write-UpdateLog '[COMPLETE] Run finished with errors. Exit code: 1.' -Level ERROR
    }
    else {
        Write-UpdateLog '[COMPLETE] All tasks finished. Exit code: 0.' -Level SUCCESS
        if ($script:UpdateFailed) {
            Write-UpdateLog '[COMPLETE] Logging failed while writing the final result. Exit code: 1.' -Level ERROR
        }
    }
}

# Check every invocation separately, including PowerShell-based command shims.
function Invoke-UpdateCommand {
    param (
        [string]$Command,
        [string[]]$Arguments,
        [long[]]$SuccessExitCodes = @(0)
    )
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Write-UpdateLog "[COMMAND] $Command $($Arguments -join ' ')" -FileOnly
    try {
        $global:LASTEXITCODE = 0
        & $Command @Arguments
        $exitCode = $global:LASTEXITCODE
        if ($exitCode -notin $SuccessExitCodes) {
            throw "$Command exited with code $exitCode."
        }
        Write-UpdateLog "[COMMAND] $Command exited with code $exitCode after $($timer.Elapsed.TotalSeconds.ToString('F2'))s." -FileOnly
    }
    catch {
        Write-UpdateLog "[COMMAND] $Command failed after $($timer.Elapsed.TotalSeconds.ToString('F2'))s: $($_.Exception.Message)" -Level ERROR -ErrorRecord $_ -FileOnly
        throw
    }
    finally {
        $timer.Stop()
    }
}

# Helper: Standardized Logging and Execution
function Invoke-ManagedUpdate {
    param ([string]$Name, [scriptblock]$Action)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $status = 'Failed'
    $failure = $null
    Write-UpdateLog "[>>>] Updating $Name..."
    try {
        $ErrorActionPreference = 'Stop'
        & $Action
        $status = 'Succeeded'
        Write-UpdateLog "[OK] $Name update completed in $($timer.Elapsed.TotalSeconds.ToString('F2'))s." -Level SUCCESS
    }
    catch {
        $script:UpdateFailed = $true
        $failure = $_.Exception.Message
        Write-UpdateLog "[FAIL] $Name update failed: $failure" -Level ERROR -ErrorRecord $_
    }
    finally {
        $timer.Stop()
        $script:TaskResults += @([pscustomobject]@{
                Name            = $Name
                Status          = $status
                DurationSeconds = $timer.Elapsed.TotalSeconds
                Error           = $failure
            })
    }
}

function Invoke-PowerShellModuleUpdate {
    param ([ValidateSet('CurrentUser', 'AllUsers')][string]$Scope)
    if (Get-Command Update-PSResource -ErrorAction SilentlyContinue) {
        Update-PSResource -Scope $Scope -AcceptLicense -Force
    }
    else {
        $basePath = if ($Scope -eq 'CurrentUser') {
            [Environment]::GetFolderPath('MyDocuments')
        }
        else {
            $env:ProgramFiles
        }
        $modulePaths = @(
            (Join-Path $basePath 'WindowsPowerShell\Modules\'),
            (Join-Path $basePath 'PowerShell\Modules\')
        )
        # Update-Module in older PowerShellGet versions cannot select an install scope.
        # Install the latest version explicitly into the existing module's scope instead.
        # Get-InstalledModule accepts -AllVersions only with a single wildcard-free -Name,
        # so enumerate installed names first and query each name's versions separately.
        Get-InstalledModule | ForEach-Object {
            Get-InstalledModule -Name $_.Name -AllVersions
        } | Where-Object {
            $_.Name -ne 'PSWindowsUpdate' -and (
                $_.InstalledLocation.StartsWith($modulePaths[0], [StringComparison]::OrdinalIgnoreCase) -or
                $_.InstalledLocation.StartsWith($modulePaths[1], [StringComparison]::OrdinalIgnoreCase)
            )
        } | Sort-Object Name -Unique | ForEach-Object {
            Install-Module -Name $_.Name -Repository $_.Repository -Scope $Scope -Force
        }
    }
}

try {
    Initialize-UpdateLogging -Path $LogPath
}
catch {
    Write-Error "Cannot initialize update logging: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}

try {
    Write-UpdateLog "[START] Account: $([Security.Principal.WindowsIdentity]::GetCurrent().Name); MachineOnly: $MachineOnly; PowerShell: $($PSVersionTable.PSVersion)."

    # User-scoped tools must run under the initiating account, before UAC elevation.
    if (-not $MachineOnly) {
        Invoke-ManagedUpdate "WinGet" {
            # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE means there is nothing to upgrade.
            Invoke-UpdateCommand winget @('upgrade', '--all', '--silent', '--accept-package-agreements', '--accept-source-agreements') -SuccessExitCodes @(0, -1978335189)
        }
        Invoke-ManagedUpdate "Scoop" {
            if (Test-OptionalUpdateCommand scoop) {
                Invoke-UpdateCommand scoop @('update')
                Invoke-UpdateCommand scoop @('update', '*')
                Invoke-UpdateCommand scoop @('cleanup', '*')
            }
        }
        Invoke-ManagedUpdate "Current-user PowerShell Modules" { Invoke-PowerShellModuleUpdate -Scope CurrentUser }

        # Developer Runtimes
        Invoke-ManagedUpdate ".NET Tools" {
            $tools = Invoke-UpdateCommand dotnet @('tool', 'list', '-g') | Select-Object -Skip 2
            foreach ($line in $tools) {
                $name = ($line -split '\s+')[0]
                if ($name) { Invoke-UpdateCommand dotnet @('tool', 'update', '-g', $name) }
            }
        }

        Invoke-ManagedUpdate "Node/NPM Ecosystem" {
            Invoke-UpdateCommand npm @('update', '-g')
            if (Test-OptionalUpdateCommand pnpm) { Invoke-UpdateCommand pnpm @('update', '-g') }
            if (Test-OptionalUpdateCommand yarn) {
                $yarnVersion = (Invoke-UpdateCommand yarn @('--version') | Out-String).Trim()
                if ($yarnVersion -match '^1\.') {
                    Invoke-UpdateCommand yarn @('global', 'upgrade')
                }
                else {
                    Write-UpdateLog "[SKIP] Yarn $yarnVersion does not support Yarn Classic global upgrades." -Level WARN
                }
            }
            if (Test-OptionalUpdateCommand bun) { Invoke-UpdateCommand bun @('upgrade') }
        }

        Invoke-ManagedUpdate "Python Tools" {
            if (Test-OptionalUpdateCommand pipx) { Invoke-UpdateCommand pipx @('upgrade-all') }
            if (Test-OptionalUpdateCommand uv) { Invoke-UpdateCommand uv @('tool', 'upgrade', '--all') }
        }

        Invoke-ManagedUpdate "Rust/Cargo" {
            if (Test-OptionalUpdateCommand rustup) { Invoke-UpdateCommand rustup @('update') }
            if (Test-OptionalUpdateCommand cargo-install-update) { Invoke-UpdateCommand cargo @('install-update', '-a') }
        }
    }

    # Only machine-scoped operations run in the elevated process.
    $isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdministrator) {
        Invoke-ManagedUpdate "Machine-scoped updates" {
            if ($MachineOnly) { throw 'Machine-scoped updates require administrator privileges.' }
            Write-UpdateLog '[ELEVATE] Requesting administrator privileges for machine-scoped updates.'
            $process = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -MachineOnly -LogPath `"$script:LogFilePath`"" -Verb RunAs -Wait -PassThru -ErrorAction Stop
            Write-UpdateLog "[ELEVATE] Machine-scoped process exited with code $($process.ExitCode)."
            if ($process.ExitCode -ne 0) { throw "Elevated updates exited with code $($process.ExitCode)." }
        }
    }
    else {
        Invoke-ManagedUpdate "Chocolatey" {
            # Accept no-op and successful reboot-required results as well as ordinary success.
            Invoke-UpdateCommand choco @('upgrade', 'all', '-y', '--no-progress') -SuccessExitCodes @(0, 2, 1641, 3010)
        }
        Invoke-ManagedUpdate "All-users PowerShell Modules" { Invoke-PowerShellModuleUpdate -Scope AllUsers }
        Invoke-ManagedUpdate "WSL" { Invoke-UpdateCommand wsl @('--update') }

        Invoke-ManagedUpdate "Windows OS" {
            if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
                Install-PackageProvider -Name NuGet -Force -Scope AllUsers
                Install-Module -Name PSWindowsUpdate -Force -SkipPublisherCheck -Scope AllUsers
            }
            Import-Module PSWindowsUpdate -ErrorAction Stop
            # Use -Confirm:$false to bypass interactive prompts
            Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Confirm:$false
        }
    }
}
catch {
    $script:UpdateFailed = $true
    Write-UpdateLog "[FATAL] Unexpected failure: $($_.Exception.Message)" -Level ERROR -ErrorRecord $_
}
finally {
    Write-UpdateSummary
}

if ($script:UpdateFailed) { exit 1 }
exit 0
