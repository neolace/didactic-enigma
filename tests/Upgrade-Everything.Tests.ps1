# Pester 5 setup and scoped mocks: https://pester.dev/docs/v5/usage/mocking
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester fixtures and extracted actions consume variables from parent scopes.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock signatures preserve command parameters, and test data is consumed by nested mock blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'These functions are throwing test stubs or reset in-memory fixtures, not real system operations.')]
param ()

BeforeAll {
    $sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Upgrade-Everything.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

    # Load definitions only: dot-sourcing the complete updater would perform upgrades.
    $ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

    $actions = @{}
    $ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Invoke-ManagedUpdate'
        }, $true) | ForEach-Object {
        $actions[$_.CommandElements[1].Value] = $_.CommandElements[2].ScriptBlock.GetScriptBlock()
    }
    $branches = @{}
    $ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst]
        }, $true) | ForEach-Object {
        $branches[$_.Clauses[0].Item1.Extent.Text] = [scriptblock]::Create($_.Extent.Text)
    }

    # Stubs make tests independent of installed package managers and module providers.
    # Unexpected unmocked calls fail instead of running a real updater.
    function Test-ExternalCommand { throw 'Unmocked external command' }
    function Update-PSResource { param($Scope, [switch]$AcceptLicense, [switch]$Force) throw 'Unmocked resource update' }
    function Get-InstalledModule { param($Name, [switch]$AllVersions) throw 'Unmocked module discovery' }
    function Install-Module { param($Name, $Repository, $Scope, [switch]$Force) throw 'Unmocked module installation' }
    # Emulates PowerShellGet: -AllVersions is valid only with a single wildcard-free -Name.
    function Select-InstalledModuleStub {
        param ($Modules, $Name, [switch]$AllVersions)
        if ($AllVersions -and (-not $Name -or $Name -match '[*?]')) {
            throw 'The RequiredVersion, MinimumVersion, MaximumVersion or AllVersions parameters are allowed only when you specify a single name as the value of the Name parameter, without any wildcard characters.'
        }
        $result = if ($Name) { @($Modules | Where-Object Name -eq $Name) } else { @($Modules) }
        if ($AllVersions) { $result } else { $result | Sort-Object Name -Unique }
    }
    function Reset-UpdateTestState {
        $script:ActiveLogPath = $null
        $script:LogFilePath = $null
        $script:UpdateFailed = $false
        $script:TaskResults = @()
    }
}

Describe 'Persistent logging' {
    BeforeEach {
        Reset-UpdateTestState
        Mock Write-Host {}
        Mock Write-Error {}
    }

    It 'creates parent directories and appends timestamped records without truncating an existing log' {
        $path = Join-Path $TestDrive 'nested logs\run.log'
        Initialize-UpdateLogging -Path $path
        Write-UpdateLog 'first event'
        Initialize-UpdateLogging -Path $path
        Write-UpdateLog 'second event' -Level WARN
        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match 'first event'
        $content | Should -Match '\d{4}-\d{2}-\d{2}T.+\[WARN\] \[PID:\d+\] second event'
        $script:LogFilePath | Should -Be $path
    }

    It 'chooses a per-run default path below LocalAppData' {
        Mock Add-Content {}
        Mock Test-Path { $true }
        Mock Write-UpdateLog {}
        Initialize-UpdateLogging
        $script:LogFilePath | Should -BeLike "$env:LOCALAPPDATA\UpgradeEverything\Logs\Upgrade-*-$PID.log"
    }

    It 'fails initialization when the destination cannot be written' {
        Mock Add-Content { throw 'access denied' }
        { Initialize-UpdateLogging -Path (Join-Path $TestDrive 'run.log') } | Should -Throw '*access denied*'
        $script:ActiveLogPath | Should -BeNullOrEmpty
    }

    It 'records exception details in the file and keeps each event on one line' {
        Initialize-UpdateLogging -Path (Join-Path $TestDrive 'error.log')
        try { throw 'download failed' } catch {
            Write-UpdateLog "task failed`nextra context" -Level ERROR -ErrorRecord $_
        }
        $entry = Get-Content -LiteralPath $script:ActiveLogPath | Select-Object -Last 1
        $entry | Should -Match 'task failed \| extra context'
        $entry | Should -Match 'download failed'
        $entry | Should -Match 'ErrorId:.*Position:.*Stack:'
    }

    It 'falls back to the console once when logging fails and marks the run unsuccessful' {
        Initialize-UpdateLogging -Path (Join-Path $TestDrive 'unavailable.log')
        $originalPath = $script:LogFilePath
        Mock Add-Content { throw 'disk full' }
        Mock Write-Warning {}
        { Write-UpdateLog 'first'; Write-UpdateLog 'second' } | Should -Not -Throw
        $script:UpdateFailed | Should -BeTrue
        $script:ActiveLogPath | Should -BeNullOrEmpty
        $script:LogFilePath | Should -Be $originalPath
        Should -Invoke Add-Content -Exactly -Times 1
        Should -Invoke Write-Warning -Exactly -Times 1 -ParameterFilter { $Message -like '*disk full*console logging only*' }
        Should -Invoke Write-Host -Exactly -Times 1 -ParameterFilter { "$Object" -like '*second' }
    }

    It 'does not contaminate command output with log messages' {
        Initialize-UpdateLogging -Path (Join-Path $TestDrive 'command.log')
        Mock Test-ExternalCommand { 'package-a'; 'package-b' }
        $output = @(Invoke-UpdateCommand Test-ExternalCommand @('list'))
        $output.Count | Should -Be 2
        $output[0] | Should -Be 'package-a'
        $output[1] | Should -Be 'package-b'
        $content = Get-Content -LiteralPath $script:ActiveLogPath -Raw
        $content | Should -Match '\[COMMAND\] Test-ExternalCommand list'
        $content | Should -Match 'exited with code 0 after'
    }

    It 'corrects the final result when the last log write fails' {
        Initialize-UpdateLogging -Path (Join-Path $TestDrive 'final-result.log')
        Mock Write-Warning {}
        Mock Add-Content { throw 'disk full' } -ParameterFilter { $Value -like '*Exit code: 0*' }
        Write-UpdateSummary
        $script:UpdateFailed | Should -BeTrue
        Should -Invoke Write-Error -Exactly -Times 1 -ParameterFilter {
            $Message -like '*Logging failed while writing the final result. Exit code: 1*'
        }
    }

    It 'logs a failing command and rethrows the original failure' {
        Initialize-UpdateLogging -Path (Join-Path $TestDrive 'command-error.log')
        Mock Test-ExternalCommand { throw 'network unavailable' }
        { Invoke-UpdateCommand Test-ExternalCommand } | Should -Throw '*network unavailable*'
        Get-Content -LiteralPath $script:ActiveLogPath -Raw | Should -Match '\[ERROR\].*Test-ExternalCommand failed.*network unavailable'
    }
}

Describe 'Task error records and summaries' {
    BeforeEach {
        Reset-UpdateTestState
        Mock Write-UpdateLog {}
    }

    It 'records success and failure with durations and a final failure summary' {
        Invoke-ManagedUpdate 'successful task' {}
        Invoke-ManagedUpdate 'failed task' { throw 'download failed' }
        $script:TaskResults.Count | Should -Be 2
        $script:TaskResults[0].Status | Should -Be 'Succeeded'
        $script:TaskResults[1].Error | Should -Be 'download failed'
        $script:TaskResults[1].DurationSeconds | Should -BeGreaterOrEqual 0
        Write-UpdateSummary
        Should -Invoke Write-UpdateLog -Exactly -Times 1 -ParameterFilter { $Message -like '*1 task(s) succeeded; 1 task(s) failed*' }
        Should -Invoke Write-UpdateLog -Exactly -Times 1 -ParameterFilter { $Message -like '*Failed: failed task - download failed*' }
        Should -Invoke Write-UpdateLog -Exactly -Times 1 -ParameterFilter { $Message -like '*Exit code: 1*' -and $Level -eq 'ERROR' }
    }

    It 'handles nonterminating cmdlet failures and continues later tasks' {
        Invoke-ManagedUpdate 'missing file' { Get-Item -LiteralPath (Join-Path $TestDrive 'does-not-exist') }
        Invoke-ManagedUpdate 'next task' { 'next output' } | Should -Be 'next output'
        $script:UpdateFailed | Should -BeTrue
        $script:TaskResults[0].Status | Should -Be 'Failed'
        $script:TaskResults[1].Status | Should -Be 'Succeeded'
    }

    It 'reports a logging failure even when all update tasks succeeded' {
        Invoke-ManagedUpdate 'successful task' {}
        $script:UpdateFailed = $true
        Write-UpdateSummary
        Should -Invoke Write-UpdateLog -Exactly -Times 1 -ParameterFilter { $Message -like '*Exit code: 1*' }
        Should -Invoke Write-UpdateLog -Times 0 -ParameterFilter { $Message -like '*Exit code: 0*' }
    }

    It 'reports a clean run as successful' {
        Invoke-ManagedUpdate 'successful task' {}
        Write-UpdateSummary
        Should -Invoke Write-UpdateLog -Exactly -Times 1 -ParameterFilter { $Message -like '*Exit code: 0*' -and $Level -eq 'SUCCESS' }
    }
}

Describe 'Optional command discovery' {
    BeforeEach {
        Reset-UpdateTestState
        Mock Write-UpdateLog {}
    }

    It 'logs an explicit skip for a missing optional tool' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'pipx' }
        Test-OptionalUpdateCommand pipx | Should -BeFalse
        Should -Invoke Write-UpdateLog -Exactly -Times 1 -ParameterFilter { $Message -like '*[[]SKIP] pipx*PATH*' -and $Level -eq 'WARN' }
    }

    It 'does not skip a tool that is available' {
        Mock Get-Command { [pscustomobject]@{ Name = 'pipx' } } -ParameterFilter { $Name -eq 'pipx' }
        Test-OptionalUpdateCommand pipx | Should -BeTrue
        Should -Invoke Write-UpdateLog -Times 0
    }
}

Describe 'Invoke-UpdateCommand' {
    BeforeEach {
        Reset-UpdateTestState
        $savedExitCode = $global:LASTEXITCODE
        Mock Test-ExternalCommand { 'command output' }
    }
    AfterEach { $global:LASTEXITCODE = $savedExitCode }

    It 'preserves output and arguments containing spaces and wildcards' {
        Invoke-UpdateCommand Test-ExternalCommand @('path with spaces', '*') | Should -Be 'command output'
        Should -Invoke Test-ExternalCommand -Exactly -Times 1 -ParameterFilter {
            $args.Count -eq 2 -and $args[0] -eq 'path with spaces' -and $args[1] -eq '*'
        }
    }

    It 'ignores a stale exit code from a previous command' {
        $global:LASTEXITCODE = 42
        { Invoke-UpdateCommand Test-ExternalCommand } | Should -Not -Throw
    }

    It 'accepts an explicitly supported exit code <Code>' -TestCases @(
        @{ Code = 0 }, @{ Code = 2 }, @{ Code = 1641 }, @{ Code = 3010 }, @{ Code = -1978335189 }
    ) {
        param($Code)
        Mock Test-ExternalCommand { $global:LASTEXITCODE = $Code }
        { Invoke-UpdateCommand Test-ExternalCommand -SuccessExitCodes @(0, $Code) } | Should -Not -Throw
    }

    It 'rejects an unsupported native exit code with command context' {
        Mock Test-ExternalCommand { $global:LASTEXITCODE = 42 }
        { Invoke-UpdateCommand Test-ExternalCommand } | Should -Throw '*Test-ExternalCommand exited with code 42*'
    }

    It 'turns nonterminating command errors into terminating failures' {
        Mock Test-ExternalCommand { Write-Error 'download failed' }
        { Invoke-UpdateCommand Test-ExternalCommand } | Should -Throw '*download failed*'
    }

    It 'reports missing executables as failures' {
        { Invoke-UpdateCommand (Join-Path $TestDrive 'missing-updater.exe') } | Should -Throw
    }
}

Describe 'Invoke-ManagedUpdate' {
    BeforeEach {
        Reset-UpdateTestState
        Mock Write-Host {}
        Mock Write-Error {}
    }

    It 'reports success only after the action completes' {
        Invoke-ManagedUpdate 'example' { 'result' } | Should -Be 'result'
        $script:UpdateFailed | Should -BeFalse
        Should -Invoke Write-Host -Exactly -Times 1 -ParameterFilter { "$Object" -like '*[[]OK]*' }
        Should -Invoke Write-Error -Times 0
    }

    It 'records a terminating error without reporting success' {
        Invoke-ManagedUpdate 'example' { throw 'failed download' }
        $script:UpdateFailed | Should -BeTrue
        Should -Invoke Write-Host -Times 0 -ParameterFilter { "$Object" -like '*[[]OK]*' }
        Should -Invoke Write-Error -Exactly -Times 1 -ParameterFilter { "$Message" -like '*example*failed download*' }
    }

    It 'stops a multi-command action at the first failed command' {
        Mock Test-OptionalUpdateCommand { $true }
        Mock Invoke-UpdateCommand { throw 'update failed' }
        Invoke-ManagedUpdate 'Scoop' $actions['Scoop']
        Should -Invoke Invoke-UpdateCommand -Exactly -Times 1
        Should -Invoke Invoke-UpdateCommand -Times 0 -ParameterFilter { $Arguments[0] -eq 'cleanup' }
    }

    It 'skips Scoop without failing when it is not installed' {
        Mock Test-OptionalUpdateCommand { $false }
        Mock Invoke-UpdateCommand {}
        Invoke-ManagedUpdate 'Scoop' $actions['Scoop']
        $script:UpdateFailed | Should -BeFalse
        Should -Invoke Invoke-UpdateCommand -Times 0
        Should -Invoke Write-Error -Times 0
    }

    It 'continues later tasks while retaining the earlier failure' {
        Invoke-ManagedUpdate 'failed task' { throw 'failure' }
        Invoke-ManagedUpdate 'next task' { 'next result' } | Should -Be 'next result'
        $script:UpdateFailed | Should -BeTrue
        Should -Invoke Write-Host -Exactly -Times 1 -ParameterFilter { "$Object" -like '*[[]OK] next task*' }
    }
}

Describe 'User and machine routing' {
    BeforeEach {
        Reset-UpdateTestState
        Mock Invoke-ManagedUpdate {}
    }

    It 'schedules user tools in the original invocation' {
        $MachineOnly = $false
        & $branches['-not $MachineOnly']
        Should -Invoke Invoke-ManagedUpdate -Exactly -Times 1 -ParameterFilter { $Name -eq '.NET Tools' }
        Should -Invoke Invoke-ManagedUpdate -Exactly -Times 1 -ParameterFilter { $Name -eq 'Python Tools' }
        Should -Invoke Invoke-ManagedUpdate -Times 0 -ParameterFilter { $Name -eq 'Chocolatey' -or $Name -eq 'Windows OS' }
    }

    It 'does not repeat user updates in the elevated child' {
        $MachineOnly = $true
        & $branches['-not $MachineOnly']
        Should -Invoke Invoke-ManagedUpdate -Times 0
    }

    It 'schedules only machine tasks in the administrator branch' {
        $isAdministrator = $true
        & $branches['-not $isAdministrator']
        Should -Invoke Invoke-ManagedUpdate -Exactly -Times 4
        Should -Invoke Invoke-ManagedUpdate -Exactly -Times 1 -ParameterFilter { $Name -eq 'Chocolatey' }
        Should -Invoke Invoke-ManagedUpdate -Exactly -Times 1 -ParameterFilter { $Name -eq 'Windows OS' }
        Should -Invoke Invoke-ManagedUpdate -Times 0 -ParameterFilter { $Name -eq '.NET Tools' -or $Name -eq 'Python Tools' }
    }
}

Describe 'Elevation' {
    BeforeEach {
        Reset-UpdateTestState
        $MachineOnly = $false
        $script:LogFilePath = Join-Path $TestDrive 'logs with spaces\run.log'
        Mock Write-UpdateLog {}
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }

    It 'waits for a machine-only child and requests its exit status' {
        & $actions['Machine-scoped updates']
        Should -Invoke Start-Process -Exactly -Times 1 -ParameterFilter {
            $FilePath -eq 'powershell.exe' -and $Verb -eq 'RunAs' -and $Wait -and $PassThru -and
            $ArgumentList -match '-File ".+" -MachineOnly -LogPath ".+"$' -and
            "$ArgumentList".Contains($script:LogFilePath) -and $ErrorAction -eq 'Stop'
        }
    }

    It 'propagates an elevated child failure' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1 } }
        { & $actions['Machine-scoped updates'] } | Should -Throw '*exited with code 1*'
    }

    It 'propagates a cancelled UAC prompt' {
        Mock Start-Process { throw 'The operation was canceled by the user' }
        { & $actions['Machine-scoped updates'] } | Should -Throw '*canceled*'
    }

    It 'rejects an unelevated machine-only invocation instead of relaunching recursively' {
        $MachineOnly = $true
        { & $actions['Machine-scoped updates'] } | Should -Throw '*require administrator privileges*'
        Should -Invoke Start-Process -Times 0
    }
}

Describe 'Yarn compatibility' {
    BeforeEach {
        Reset-UpdateTestState
        Mock Invoke-UpdateCommand {}
        Mock Write-Host {}
        Mock Get-Command { $null } -ParameterFilter { $Name -in @('yarn', 'pnpm', 'bun') }
        Mock Get-Command { [pscustomobject]@{ Name = 'yarn' } } -ParameterFilter { $Name -eq 'yarn' }
    }

    It 'upgrades Yarn Classic globals' {
        Mock Invoke-UpdateCommand { '1.22.22' } -ParameterFilter { $Command -eq 'yarn' -and $Arguments[0] -eq '--version' }
        & $actions['Node/NPM Ecosystem']
        Should -Invoke Invoke-UpdateCommand -Exactly -Times 1 -ParameterFilter {
            $Command -eq 'yarn' -and ($Arguments -join ' ') -eq 'global upgrade'
        }
    }

    It 'explicitly skips unsupported Yarn version <Version>' -TestCases @(
        @{ Version = '2.4.3' }, @{ Version = '4.6.0' }, @{ Version = 'unexpected output' }
    ) {
        param($Version)
        Mock Invoke-UpdateCommand { $Version } -ParameterFilter { $Command -eq 'yarn' -and $Arguments[0] -eq '--version' }
        & $actions['Node/NPM Ecosystem']
        Should -Invoke Invoke-UpdateCommand -Times 0 -ParameterFilter { $Command -eq 'yarn' -and $Arguments[0] -eq 'global' }
        Should -Invoke Write-Host -Exactly -Times 1 -ParameterFilter { "$Object" -like '*[[]SKIP]*Yarn*' }
    }

    It 'does not invoke Yarn when it is absent' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'yarn' }
        & $actions['Node/NPM Ecosystem']
        Should -Invoke Invoke-UpdateCommand -Times 0 -ParameterFilter { $Command -eq 'yarn' }
    }

    It 'does not attempt an upgrade when Yarn version detection fails' {
        Mock Invoke-UpdateCommand { throw 'version command failed' } -ParameterFilter { $Command -eq 'yarn' }
        { & $actions['Node/NPM Ecosystem'] } | Should -Throw '*version command failed*'
        Should -Invoke Invoke-UpdateCommand -Times 0 -ParameterFilter { $Command -eq 'yarn' -and $Arguments[0] -eq 'global' }
    }
}

Describe 'PowerShell module scopes' {
    BeforeEach {
        Reset-UpdateTestState
        Mock Update-PSResource {}
        Mock Install-Module {}
        Mock Get-InstalledModule { @() }
    }

    It 'passes <Scope> to PSResourceGet without using the legacy installer' -TestCases @(
        @{ Scope = 'CurrentUser' }, @{ Scope = 'AllUsers' }
    ) {
        param($Scope)
        Invoke-PowerShellModuleUpdate -Scope $Scope
        $expectedScope = $Scope
        Should -Invoke Update-PSResource -Exactly -Times 1 -ParameterFilter {
            $Scope -eq $expectedScope -and $AcceptLicense -and $Force
        }
        Should -Invoke Get-InstalledModule -Times 0
        Should -Invoke Install-Module -Times 0
    }

    Context 'Legacy PowerShellGet' {
        BeforeEach {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Update-PSResource' }
            $userRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
            $machineRoot = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'
        }

        It 'does nothing when no gallery-installed modules exist' {
            Invoke-PowerShellModuleUpdate -Scope CurrentUser
            Should -Invoke Install-Module -Times 0
        }

        It 'updates only <Scope> modules and deduplicates installed versions' -TestCases @(
            @{ Scope = 'CurrentUser'; ExpectedName = 'UserModule' },
            @{ Scope = 'AllUsers'; ExpectedName = 'MachineModule' }
        ) {
            param($Scope, $ExpectedName)
            Mock Get-InstalledModule {
                $installed = foreach ($version in @('1.0', '2.0')) {
                    [pscustomobject]@{ Name = 'UserModule'; Repository = 'UserRepo'; InstalledLocation = "$userRoot\UserModule\$version" }
                    [pscustomobject]@{ Name = 'MachineModule'; Repository = 'MachineRepo'; InstalledLocation = "$machineRoot\MachineModule\$version" }
                }
                Select-InstalledModuleStub -Modules $installed -Name $Name -AllVersions:$AllVersions
            }
            Invoke-PowerShellModuleUpdate -Scope $Scope
            Should -Invoke Get-InstalledModule -Exactly -Times 1 -ParameterFilter { -not $AllVersions }
            Should -Invoke Get-InstalledModule -Exactly -Times 2 -ParameterFilter { $AllVersions -and $Name -and $Name -notmatch '[*?]' }
            Should -Invoke Install-Module -Exactly -Times 1
            $expectedScope = $Scope
            Should -Invoke Install-Module -Exactly -Times 1 -ParameterFilter {
                $Name -eq $ExpectedName -and $Scope -eq $expectedScope -and $Force -and
                $Repository -eq ($ExpectedName -replace 'Module$', 'Repo')
            }
        }

        It 'excludes PSWindowsUpdate and paths outside the module directory' {
            Mock Get-InstalledModule {
                $installed = @(
                    [pscustomobject]@{ Name = 'PSWindowsUpdate'; Repository = 'PSGallery'; InstalledLocation = "$userRoot\PSWindowsUpdate\1.0" }
                    [pscustomobject]@{ Name = 'Outside'; Repository = 'PSGallery'; InstalledLocation = "${userRoot}Backup\Outside\1.0" }
                )
                Select-InstalledModuleStub -Modules $installed -Name $Name -AllVersions:$AllVersions
            }
            Invoke-PowerShellModuleUpdate -Scope CurrentUser
            Should -Invoke Install-Module -Times 0
        }
    }
}
