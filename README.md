# didactic-enigma

## Running updates and viewing logs

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Upgrade-Everything.ps1
```

Each run creates a timestamped log in `%LOCALAPPDATA%\UpgradeEverything\Logs` and prints its path. To append to a specific log instead:

```powershell
.\Upgrade-Everything.ps1 -LogPath 'C:\Logs\upgrade.log'
```

Log entries include timestamps, severity, process IDs, task durations, command arguments and exit codes, skipped optional tools, and exception details. The log records command execution metadata; package-manager output remains in the console. The elevated machine-update process appends to the same log, with a separate per-process task summary.

Failed tasks are recorded and later tasks continue. Unexpected failures are logged before the final summary. The script exits with code `1` if an update, elevation, or logging operation fails, and `0` on success. An unwritable log destination stops the run before updates start; a later write failure produces a warning and switches to console-only reporting.

## Tests

The unit suite uses Windows PowerShell 5.1 and Pester 5.7.1. Install the test dependency once:

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
```

Run from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Run-UnitTests.ps1
```

The runner prints individual test results and exits with code `1` on failure. An existing Pester 5.7.1 module at another location can be selected with `-PesterPath <path-to-Pester.psd1>`.

Tests cover persistent logging, logging failures, task summaries, command exit codes, failure reporting, user/machine routing, UAC failure handling, Yarn compatibility, and module installation scopes. Updater functions and actions are loaded through PowerShell's parser; package managers, installation, and elevation are mocked. Tests do not run system upgrades.

The dependency-free regression checks also exercise harmless native exit codes:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Run-RegressionChecks.ps1
```

The unit suite follows [Pester 5's scoped mocking conventions](https://pester.dev/docs/v5/usage/mocking).
