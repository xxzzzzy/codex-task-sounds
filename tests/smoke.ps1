[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$TestHome = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-task-sounds-test-" + [Guid]::NewGuid().ToString("N"))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Get-ManagedHookCount {
    param([object]$Document, [string]$EventName)
    $property = $Document.hooks.PSObject.Properties[$EventName]
    if ($null -eq $property) { return 0 }
    $count = 0
    foreach ($group in @($property.Value)) {
        foreach ($hook in @($group.hooks)) {
            if ([string]$hook.command -like "*codex-task-sounds*notify.ps1*") { $count++ }
        }
    }
    return $count
}

try {
    [System.IO.Directory]::CreateDirectory($TestHome) | Out-Null
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

    $installedScript = Join-Path $TestHome "codex-task-sounds\notify.ps1"
    $tokens = $null
    $syntaxErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($installedScript, [ref]$tokens, [ref]$syntaxErrors) | Out-Null
    Assert-True ($syntaxErrors.Count -eq 0) "installed script parses in PowerShell"
    $scriptText = [System.IO.File]::ReadAllText($installedScript)
    Assert-True (-not $scriptText.Contains("ToastNotification")) "custom Windows Toast code is absent"

    $hooks = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $TestHome "hooks.json") | ConvertFrom-Json
    foreach ($eventName in @("SessionStart", "PermissionRequest", "Stop", "SessionEnd")) {
        Assert-True ((Get-ManagedHookCount $hooks $eventName) -eq 1) "$eventName has one managed hook"
    }
    $existingCount = @($hooks.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { $_.command -eq "existing-tool --keep" }).Count
    Assert-True ($existingCount -eq 1) "existing hooks were preserved"

    & (Join-Path $ProjectRoot "install.ps1") -CodexHome $TestHome -SkipStartup -NoStart
    $hooks = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $TestHome "hooks.json") | ConvertFrom-Json
    foreach ($eventName in @("SessionStart", "PermissionRequest", "Stop", "SessionEnd")) {
        Assert-True ((Get-ManagedHookCount $hooks $eventName) -eq 1) "reinstall remains idempotent for $EventName"
    }

    & (Join-Path $ProjectRoot "uninstall.ps1") -CodexHome $TestHome -SkipStartup
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $TestHome "codex-task-sounds"))) "install directory was removed"
    $hooks = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $TestHome "hooks.json") | ConvertFrom-Json
    foreach ($eventName in @("SessionStart", "PermissionRequest", "Stop", "SessionEnd")) {
        Assert-True ((Get-ManagedHookCount $hooks $eventName) -eq 0) "$eventName managed hook was removed"
    }
    $existingCount = @($hooks.hooks.Stop | ForEach-Object { $_.hooks } | Where-Object { $_.command -eq "existing-tool --keep" }).Count
    Assert-True ($existingCount -eq 1) "uninstall preserved the existing hook"

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
