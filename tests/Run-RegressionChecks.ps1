# Dependency-free regression checks. Only extracted functions/branches are executed;
# package managers, module installation, and elevation are mocked.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Extracted updater branches read MachineOnly and isAdministrator from this scope.')]
param ()

$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'Upgrade-Everything.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

function Assert-True {
    param ([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

# Real, harmless native exit codes verify Windows PowerShell's error semantics.
Invoke-UpdateCommand cmd.exe @('/c', 'exit', '0')
Invoke-UpdateCommand cmd.exe @('/c', 'exit', '2') -SuccessExitCodes @(0, 2)
Invoke-UpdateCommand cmd.exe @('/c', 'exit', '3010') -SuccessExitCodes @(0, 3010)
$script:UpdateFailed = $false
$script:ReachedCleanup = $false
$output = Invoke-ManagedUpdate 'native failure' {
    Invoke-UpdateCommand cmd.exe @('/c', 'exit', '42')
    $script:ReachedCleanup = $true
} *>&1 | Out-String
Assert-True $script:UpdateFailed 'Native failure was not recorded.'
Assert-True (-not $script:ReachedCleanup) 'Execution continued after a failed command.'
Assert-True ($output -match '\[FAIL\]' -and $output -notmatch '\[OK\]') 'Failure was reported as success.'

$script:UpdateFailed = $false
$output = Invoke-ManagedUpdate 'cmdlet failure' { Write-Error 'test failure' } *>&1 | Out-String
Assert-True $script:UpdateFailed 'Nonterminating cmdlet error was not recorded.'
Assert-True ($output -notmatch '\[OK\]') 'Cmdlet error was reported as success.'
$output = Invoke-ManagedUpdate 'next task' { Invoke-UpdateCommand cmd.exe @('/c', 'exit', '0') } *>&1 | Out-String
Assert-True ($output -match '\[OK\]') 'A failed task prevented subsequent tasks.'
Assert-True $script:UpdateFailed 'A successful task erased an earlier failure.'

# A PowerShell shim must propagate native failures through the same wrapper.
function Test-CommandShim { cmd.exe /c exit 7 }
$caught = $false
try { Invoke-UpdateCommand Test-CommandShim } catch { $caught = $_.Exception.Message -match 'code 7' }
Assert-True $caught 'A command shim hid its native exit code.'

# Capture actions without executing any updater to test user/machine routing.
$script:Actions = @{}
function Invoke-ManagedUpdate {
    param ([string]$Name, [scriptblock]$Action)
    $script:Actions[$Name] = $Action
}
$userBranch = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '-not $MachineOnly'
    }, $true)
$machineBranch = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '-not $isAdministrator'
    }, $true)
$MachineOnly = $false
& ([scriptblock]::Create($userBranch.Extent.Text))
Assert-True ($script:Actions.ContainsKey('.NET Tools')) 'Normal invocation omitted user tools.'
Assert-True (-not $script:Actions.ContainsKey('Chocolatey')) 'User phase included machine updates.'
$nodeAction = $script:Actions['Node/NPM Ecosystem']
$moduleAction = $script:Actions['Current-user PowerShell Modules']
$script:Actions = @{}
$MachineOnly = $true
& ([scriptblock]::Create($userBranch.Extent.Text))
Assert-True ($script:Actions.Count -eq 0) 'Elevated child repeated user updates.'
$isAdministrator = $true
& ([scriptblock]::Create($machineBranch.Extent.Text))
Assert-True ($script:Actions.ContainsKey('Chocolatey') -and $script:Actions.ContainsKey('Windows OS')) 'Elevated phase omitted machine updates.'
Assert-True (-not $script:Actions.ContainsKey('.NET Tools')) 'Elevated phase included user tools.'

$isAdministrator = $false
$MachineOnly = $false
& ([scriptblock]::Create($machineBranch.Extent.Text))
function Start-Process {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'This test stub prevents real elevation.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This test stub only returns a simulated process result.')]
    param ($FilePath, $ArgumentList, $Verb, [switch]$Wait, [switch]$PassThru)
    Assert-True ($FilePath -eq 'powershell.exe') 'Elevation selected the wrong executable.'
    Assert-True ($ArgumentList -match '-MachineOnly' -and $Verb -eq 'RunAs' -and $Wait -and $PassThru) 'Elevation did not select and wait for machine-only updates.'
    [pscustomobject]@{ ExitCode = 1 }
}
$caught = $false
try { & $script:Actions['Machine-scoped updates'] } catch { $caught = $_.Exception.Message -match 'exited with code 1' }
Assert-True $caught 'Elevated child failure was ignored.'

# The detected Yarn version selects Classic upgrades or an explicit Modern skip.
function yarn { throw 'The real Yarn command must not run.' }
function Invoke-UpdateCommand {
    param ($Command, $Arguments)
    if ($Command -eq 'yarn') {
        if ($Arguments[0] -eq '--version') { return $script:YarnVersion }
        $script:YarnUpgraded = $true
    }
}
foreach ($version in @('1.22.22', '2.4.3', '4.6.0')) {
    $script:YarnVersion = $version
    $script:YarnUpgraded = $false
    $output = & $nodeAction *>&1 | Out-String
    Assert-True ($script:YarnUpgraded -eq $version.StartsWith('1.')) "Incorrect Yarn upgrade behavior for $version."
    if (-not $version.StartsWith('1.')) {
        Assert-True ($output -match '\[SKIP\]') 'Unsupported Yarn version was not explicitly skipped.'
    }
}

# Verify module updates keep the requested scope instead of following elevation.
function Update-PSResource {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This test stub only records the requested scope.')]
    param ($Scope, [switch]$AcceptLicense, [switch]$Force)
    Assert-True ($AcceptLicense -and $Force) 'Resource updates omitted noninteractive options.'
    $script:ModuleScope = $Scope
}
& $moduleAction
Assert-True ($script:ModuleScope -eq 'CurrentUser') 'User modules used the wrong installation scope.'
& $script:Actions['All-users PowerShell Modules']
Assert-True ($script:ModuleScope -eq 'AllUsers') 'Machine modules used the wrong installation scope.'

# Exercise the legacy fallback with the same module installed in both scopes.
function Get-Command {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'This test stub simulates a machine without PSResourceGet.')]
    param ($Name, $ErrorAction)
    Assert-True ($ErrorAction -eq 'SilentlyContinue') 'Optional command discovery should tolerate missing commands.'
    if ($Name -eq 'Update-PSResource') { return }
    throw "Unexpected command discovery: $Name"
}
function Get-InstalledModule {
    param ($Name, [switch]$AllVersions)
    # PowerShellGet rejects -AllVersions without a single wildcard-free -Name.
    Assert-True (-not ($AllVersions -and (-not $Name -or $Name -match '[*?]'))) 'Legacy discovery combined AllVersions with a missing or wildcard name.'
    $modules = foreach ($root in @([Environment]::GetFolderPath('MyDocuments'), $env:ProgramFiles)) {
        foreach ($version in @('1.0.0', '2.0.0')) {
            [pscustomobject]@{
                Name              = 'ExampleModule'
                Repository        = 'ExampleRepository'
                InstalledLocation = Join-Path $root "WindowsPowerShell\Modules\ExampleModule\$version"
            }
        }
    }
    if ($Name) { $modules = @($modules | Where-Object { $_.Name -eq $Name }) }
    if (-not $AllVersions) { $modules = @($modules | Sort-Object Name -Unique) }
    $modules
}
function Install-Module {
    param ($Name, $Repository, $Scope, [switch]$Force)
    Assert-True $Force 'Legacy module installation omitted Force.'
    $script:Installs += [pscustomobject]@{ Name = $Name; Repository = $Repository; Scope = $Scope }
}
foreach ($scope in @('CurrentUser', 'AllUsers')) {
    $script:Installs = @()
    Invoke-PowerShellModuleUpdate -Scope $scope
    Assert-True ($script:Installs.Count -eq 1) 'Legacy updates did not deduplicate installed versions.'
    Assert-True ($script:Installs[0].Scope -eq $scope) 'Legacy update targeted the wrong scope.'
    Assert-True ($script:Installs[0].Repository -eq 'ExampleRepository') 'Legacy update changed the source repository.'
}

Write-Output 'All update regression checks passed.'
