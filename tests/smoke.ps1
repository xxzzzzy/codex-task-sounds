[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$TestHome = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-task-sounds-test-" + [Guid]::NewGuid().ToString("N"))
$ExpectedInstallScript = Join-Path $TestHome "codex-task-sounds\notify.ps1"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$EventModes = [ordered]@{
    SessionStart = "session-start"
    PermissionRequest = "permission"
    Stop = "stop"
    SessionEnd = "session-end"
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Get-ExpectedHookCommand {
    param([string]$InstallScript, [string]$Mode)
    $escapedScript = $InstallScript.Replace("'", "''")
    $escapedMode = $Mode.Replace("'", "''")
    $source = "`$ProgressPreference='SilentlyContinue'; & '$escapedScript' '$escapedMode' | Out-Null"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($source))
    return "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $encoded"
}

function Get-ExpectedHookSource {
    param([string]$InstallScript, [string]$Mode)
    $escapedScript = $InstallScript.Replace("'", "''")
    $escapedMode = $Mode.Replace("'", "''")
    return "`$ProgressPreference='SilentlyContinue'; & '$escapedScript' '$escapedMode' | Out-Null"
}

function Get-ManagedHookCount {
    param([object]$Document, [string]$EventName)
    $property = $Document.hooks.PSObject.Properties[$EventName]
    if ($null -eq $property) { return 0 }
    $expectedCommand = Get-ExpectedHookCommand $ExpectedInstallScript $EventModes[$EventName]
    $count = 0
    foreach ($group in @($property.Value)) {
        foreach ($hook in @($group.hooks)) {
            if ([string]$hook.command -ceq $expectedCommand) { $count++ }
        }
    }
    return $count
}

try {
    [System.IO.Directory]::CreateDirectory($TestHome) | Out-Null
    $legacyRootScript = Join-Path $TestHome "notify.ps1"
    [System.IO.File]::WriteAllText($legacyRootScript, "# Codex task status sounds`r`nfunction Invoke-StatusSound {}`r`n", $Utf8NoBom)
    $existingHooks = [pscustomobject][ordered]@{
        hooks = [pscustomobject][ordered]@{
            Stop = @(
                [pscustomobject][ordered]@{
                    hooks = @(
                        [pscustomobject][ordered]@{
                            type = "command"
                            command = "existing-tool --keep"
                            commandWindows = "existing-tool --keep"
                            timeout = 2
                        },
                        [pscustomobject][ordered]@{
                            type = "command"
                            command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $legacyRootScript + '" stop'
                            commandWindows = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $legacyRootScript + '" stop'
                            timeout = 5
                        },
                        [pscustomobject][ordered]@{
                            type = "command"
                            command = 'powershell.exe -File "C:\other\codex-task-sounds\notify.ps1" stop'
                            commandWindows = 'powershell.exe -File "C:\other\codex-task-sounds\notify.ps1" stop'
                            timeout = 2
                        },
                        [pscustomobject][ordered]@{
                            type = "command"
                            command = 'some-tool.exe "' + $ExpectedInstallScript + '" stop'
                            commandWindows = 'some-tool.exe "' + $ExpectedInstallScript + '" stop'
                            timeout = 2
                        },
                        [pscustomobject][ordered]@{
                            type = "command"
                            command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ExpectedInstallScript + '" stop'
                            commandWindows = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ExpectedInstallScript + '" stop'
                            timeout = 5
                        }
                    )
                }
            )
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $TestHome "hooks.json"), ($existingHooks | ConvertTo-Json -Depth 20), $Utf8NoBom)

    & (Join-Path $ProjectRoot "install.ps1") -CodexHome $TestHome -SkipStartup -NoStart
    Assert-True (Test-Path -LiteralPath (Join-Path $TestHome "codex-task-sounds\notify.ps1")) "notify.ps1 was installed"
    Assert-True (Test-Path -LiteralPath (Join-Path $TestHome "codex-task-sounds\sounds\success.wav")) "default sounds were generated"
    Assert-True (@(Get-ChildItem -LiteralPath $TestHome -Filter ".codex-task-sounds-stage-*" -Directory -Force).Count -eq 0) "successful installation removes its staging directory"
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $TestHome "codex-task-sounds") -Recurse -Force -File | Where-Object { $_.Name -like ".*.install-*" -or $_.Name -like ".*.sound-backup-*" }).Count -eq 0) "successful installation leaves no atomic-deployment temporary files"

    $exampleSettings = [System.IO.File]::ReadAllText((Join-Path $ProjectRoot "src\config.example.json"), $Utf8NoBom) | ConvertFrom-Json
    Assert-True ($exampleSettings -is [System.Management.Automation.PSCustomObject]) "the example configuration is valid JSON object"
    Assert-True ([Math]::Abs([double]$exampleSettings.waiting_volume - 0.65) -lt 0.0001) "the example configuration includes the audible action-required volume"
    Assert-True ($null -eq $exampleSettings.PSObject.Properties["waiting_repeat"]) "the example configuration has no background waiting loop"
    Assert-True ($null -eq $exampleSettings.PSObject.Properties["error_on_tool_failure"]) "the example configuration has no watcher-only tool failure setting"

    $installedScript = Join-Path $TestHome "codex-task-sounds\notify.ps1"
    $tokens = $null
    $syntaxErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($installedScript, [ref]$tokens, [ref]$syntaxErrors) | Out-Null
    Assert-True ($syntaxErrors.Count -eq 0) "installed script parses in PowerShell"
    $scriptText = [System.IO.File]::ReadAllText($installedScript)
    Assert-True (-not $scriptText.Contains("ToastNotification")) "custom Windows Toast code is absent"
    Assert-True ($scriptText.Contains("action-custom.mp3")) "custom action-required sounds are supported"
    Assert-True (-not $scriptText.Contains('"watch" {')) "watch mode is not exposed"
    Assert-True (-not $scriptText.Contains('"monitor" {')) "per-session monitor mode is not exposed"
    Assert-True (-not $scriptText.Contains('"wait-loop" {')) "repeating waiting loop mode is not exposed"
    $helpText = & $installedScript help
    Assert-True (($helpText -join [Environment]::NewLine) -notmatch '(?im)^\s*\.\\notify\.ps1\s+watch\s*$') "help does not advertise a resident watcher"

    $backgroundProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine.IndexOf($installedScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $_.CommandLine -match '(?i)\b(watch|monitor|wait-loop)\b'
    })
    Assert-True ($backgroundProcesses.Count -eq 0) "installation creates no resident background process"
    $runValues = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
    $ownedStartupValues = @()
    if ($null -ne $runValues) {
        $ownedStartupValues = @($runValues.PSObject.Properties | Where-Object {
            $_.Name -notmatch '^PS' -and [string]$_.Value -like "*$ExpectedInstallScript*"
        })
    }
    Assert-True ($ownedStartupValues.Count -eq 0) "installation creates no login startup entry"

    $hooks = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $TestHome "hooks.json") | ConvertFrom-Json
    foreach ($eventName in $EventModes.Keys) {
        Assert-True ((Get-ManagedHookCount $hooks $eventName) -eq 1) "$eventName has one managed hook"
        $expectedCommand = Get-ExpectedHookCommand $ExpectedInstallScript $EventModes[$eventName]
        $managed = @($hooks.hooks.PSObject.Properties[$eventName].Value | ForEach-Object { $_.hooks } | Where-Object { [string]$_.command -ceq $expectedCommand })
        Assert-True ($managed.Count -eq 1 -and $managed[0].commandWindows -ceq $expectedCommand) "$eventName uses the exact hidden encoded command"
        $encoded = ([string]$managed[0].command -split '\s+')[-1]
        $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        Assert-True ($decoded -ceq (Get-ExpectedHookSource $ExpectedInstallScript $EventModes[$eventName])) "$eventName encoded command decodes to the expected script and mode"
    }
    $existingCount = @($hooks.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { $_.command -eq "existing-tool --keep" }).Count
    Assert-True ($existingCount -eq 1) "existing hooks were preserved"
    $decoyCount = @($hooks.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { $_.command -like "*C:\other\codex-task-sounds\notify.ps1*" }).Count
    Assert-True ($decoyCount -eq 1) "a similarly named Hook owned by another installation was preserved"
    $samePathDecoyCount = @($hooks.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { $_.command -like "some-tool.exe*" }).Count
    Assert-True ($samePathDecoyCount -eq 1) "an unrelated Hook mentioning the installed script was preserved"
    $legacyRootCount = @($hooks.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { $_.command -like "*$legacyRootScript*" }).Count
    Assert-True ($legacyRootCount -eq 0) "an owned pre-1.0 root Hook was migrated"

    & (Join-Path $ProjectRoot "install.ps1") -CodexHome $TestHome -SkipStartup -NoStart
    $hooks = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $TestHome "hooks.json") | ConvertFrom-Json
    foreach ($eventName in @("SessionStart", "PermissionRequest", "Stop", "SessionEnd")) {
        Assert-True ((Get-ManagedHookCount $hooks $eventName) -eq 1) "reinstall remains idempotent for $EventName"
    }
    $backups = @(Get-ChildItem -LiteralPath $TestHome -Filter "hooks.json.backup-*" -File)
    Assert-True ($backups.Count -ge 2) "each replacement creates a unique hooks backup"
    Assert-True (@(Get-ChildItem -LiteralPath $TestHome -Filter ".hooks.json.tmp-*" -File).Count -eq 0) "atomic write temporary files were cleaned up"

    & (Join-Path $ProjectRoot "uninstall.ps1") -CodexHome $TestHome
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $TestHome "codex-task-sounds"))) "install directory was removed"
    $hooks = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $TestHome "hooks.json") | ConvertFrom-Json
    foreach ($eventName in @("SessionStart", "PermissionRequest", "Stop", "SessionEnd")) {
        Assert-True ((Get-ManagedHookCount $hooks $eventName) -eq 0) "$eventName managed hook was removed"
    }
    $existingCount = @($hooks.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { $_.command -eq "existing-tool --keep" }).Count
    Assert-True ($existingCount -eq 1) "uninstall preserved the existing hook"
    $decoyCount = @($hooks.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { $_.command -like "*C:\other\codex-task-sounds\notify.ps1*" }).Count
    Assert-True ($decoyCount -eq 1) "uninstall preserved another installation's similarly named Hook"
    $samePathDecoyCount = @($hooks.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { $_.command -like "some-tool.exe*" }).Count
    Assert-True ($samePathDecoyCount -eq 1) "uninstall preserved an unrelated Hook mentioning the installed script"
    Assert-True (@(Get-ChildItem -LiteralPath $TestHome -Filter ".hooks.json.tmp-*" -File).Count -eq 0) "uninstall cleaned up atomic write temporary files"

    $invalidHome = Join-Path $TestHome "invalid-hooks-home"
    [System.IO.Directory]::CreateDirectory($invalidHome) | Out-Null
    $invalidHooksPath = Join-Path $invalidHome "hooks.json"
    [System.IO.File]::WriteAllText($invalidHooksPath, '{invalid-json', $Utf8NoBom)
    $invalidInstallFailed = $false
    try { & (Join-Path $ProjectRoot "install.ps1") -CodexHome $invalidHome -SkipStartup -NoStart }
    catch { $invalidInstallFailed = $true }
    Assert-True $invalidInstallFailed "invalid hooks.json stops installation"
    Assert-True ([System.IO.File]::ReadAllText($invalidHooksPath, $Utf8NoBom) -eq '{invalid-json') "invalid hooks.json is left unchanged"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $invalidHome "codex-task-sounds"))) "invalid hooks.json causes no partial runtime installation"
    Assert-True (@(Get-ChildItem -LiteralPath $invalidHome -Filter ".hooks.json.tmp-*" -File).Count -eq 0) "failed Hook validation leaves no temporary file"

    foreach ($invalidDocument in @(
        '[]',
        '{"hooks":[]}',
        '{"hooks":{"Stop":null}}',
        '{"hooks":{"Stop":"bad"}}',
        '{"hooks":{"Stop":[{"hooks":null}]}}',
        '{"hooks":{"Stop":[{"hooks":"bad"}]}}',
        '{"hooks":{"Stop":[null]}}',
        '{"hooks":{"Stop":[{"hooks":[null]}]}}'
    )) {
        $invalidStructureHome = Join-Path $TestHome ("invalid-structure-" + [Guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::CreateDirectory($invalidStructureHome) | Out-Null
        $invalidStructurePath = Join-Path $invalidStructureHome "hooks.json"
        [System.IO.File]::WriteAllText($invalidStructurePath, $invalidDocument, $Utf8NoBom)
        $structureInstallFailed = $false
        try { & (Join-Path $ProjectRoot "install.ps1") -CodexHome $invalidStructureHome -SkipStartup -NoStart }
        catch { $structureInstallFailed = $true }
        Assert-True $structureInstallFailed "invalid Hook document structure stops installation"
        Assert-True ([System.IO.File]::ReadAllText($invalidStructurePath, $Utf8NoBom) -eq $invalidDocument) "invalid Hook document structure is unchanged"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $invalidStructureHome "codex-task-sounds"))) "invalid Hook structure causes no partial runtime installation"
    }

    $invalidUninstallHome = Join-Path $TestHome ("invalid-uninstall-" + [Guid]::NewGuid().ToString("N"))
    $invalidUninstallRoot = Join-Path $invalidUninstallHome "codex-task-sounds"
    [System.IO.Directory]::CreateDirectory($invalidUninstallRoot) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $invalidUninstallRoot "keep.txt"), "keep", $Utf8NoBom)
    $invalidUninstallHooks = Join-Path $invalidUninstallHome "hooks.json"
    $invalidUninstallJson = '{"hooks":{"Stop":[{"hooks":"bad"}]}}'
    [System.IO.File]::WriteAllText($invalidUninstallHooks, $invalidUninstallJson, $Utf8NoBom)
    $invalidUninstallFailed = $false
    try { & (Join-Path $ProjectRoot "uninstall.ps1") -CodexHome $invalidUninstallHome -SkipStartup }
    catch { $invalidUninstallFailed = $true }
    Assert-True $invalidUninstallFailed "invalid Hook structure stops uninstall"
    Assert-True (Test-Path -LiteralPath (Join-Path $invalidUninstallRoot "keep.txt")) "failed uninstall leaves installed files untouched"
    Assert-True ([System.IO.File]::ReadAllText($invalidUninstallHooks, $Utf8NoBom) -eq $invalidUninstallJson) "failed uninstall leaves hooks.json untouched"

    $invalidConfigHome = Join-Path $TestHome ("invalid-config-" + [Guid]::NewGuid().ToString("N"))
    $invalidConfigRoot = Join-Path $invalidConfigHome "codex-task-sounds"
    [System.IO.Directory]::CreateDirectory($invalidConfigRoot) | Out-Null
    $existingRuntimePath = Join-Path $invalidConfigRoot "notify.ps1"
    [System.IO.File]::WriteAllText($existingRuntimePath, "existing-runtime", $Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $invalidConfigRoot "config.json"), '{invalid-json', $Utf8NoBom)
    $invalidConfigFailed = $false
    try { & (Join-Path $ProjectRoot "install.ps1") -CodexHome $invalidConfigHome -SkipStartup -NoStart }
    catch { $invalidConfigFailed = $true }
    Assert-True $invalidConfigFailed "an invalid existing config stops installation"
    Assert-True ([System.IO.File]::ReadAllText($existingRuntimePath, $Utf8NoBom) -eq "existing-runtime") "failed config validation does not overwrite the existing runtime"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $invalidConfigHome "hooks.json"))) "failed config validation does not create Hooks"
    Assert-True (@(Get-ChildItem -LiteralPath $invalidConfigHome -Filter ".codex-task-sounds-stage-*" -Directory).Count -eq 0) "failed installation leaves no staging directory"

    $emptyHomeFailed = $false
    try { & (Join-Path $ProjectRoot "install.ps1") -CodexHome "" -SkipStartup -NoStart }
    catch { $emptyHomeFailed = $true }
    Assert-True $emptyHomeFailed "an empty CodexHome is rejected"

    $fileInstallHome = Join-Path $TestHome ("file-install-root-" + [Guid]::NewGuid().ToString("N"))
    [System.IO.Directory]::CreateDirectory($fileInstallHome) | Out-Null
    $fileInstallRoot = Join-Path $fileInstallHome "codex-task-sounds"
    [System.IO.File]::WriteAllText($fileInstallRoot, "not-an-install-directory", $Utf8NoBom)
    $fileRootUninstallFailed = $false
    try { & (Join-Path $ProjectRoot "uninstall.ps1") -CodexHome $fileInstallHome -SkipStartup }
    catch { $fileRootUninstallFailed = $true }
    Assert-True $fileRootUninstallFailed "uninstall rejects a file where the installation directory should be"
    Assert-True ([System.IO.File]::ReadAllText($fileInstallRoot, $Utf8NoBom) -eq "not-an-install-directory") "failed uninstall does not delete an unexpected file"

    $hooksAfterUninstall = [System.IO.File]::ReadAllText((Join-Path $TestHome "hooks.json"), $Utf8NoBom)
    $backupCountAfterUninstall = @(Get-ChildItem -LiteralPath $TestHome -Filter "hooks.json.backup-*" -File).Count
    & (Join-Path $ProjectRoot "uninstall.ps1") -CodexHome $TestHome
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $TestHome "hooks.json"), $Utf8NoBom) -eq $hooksAfterUninstall) "repeated uninstall does not rewrite an already clean hooks.json"
    Assert-True (@(Get-ChildItem -LiteralPath $TestHome -Filter "hooks.json.backup-*" -File).Count -eq $backupCountAfterUninstall) "repeated uninstall does not create a redundant backup"

    Write-Output "Smoke test passed."
}
finally {
    if (Test-Path -LiteralPath $TestHome) {
        $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedTest = [System.IO.Path]::GetFullPath($TestHome)
        if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
            [System.IO.Path]::GetFileName($resolvedTest) -like "codex-task-sounds-test-*") {
            Remove-Item -LiteralPath $resolvedTest -Recurse -Force
        }
    }
}
