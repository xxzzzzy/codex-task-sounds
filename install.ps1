[CmdletBinding()]
param(
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }),
    [switch]$SkipStartup,
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceRoot = Join-Path $ProjectRoot "src"
$InstallRoot = Join-Path $CodexHome "codex-task-sounds"
$InstallScript = Join-Path $InstallRoot "notify.ps1"
$HooksPath = Join-Path $CodexHome "hooks.json"
$StartupName = "CodexTaskSounds"
$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-PropertyValue {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Read-HooksDocument {
    if (-not (Test-Path -LiteralPath $HooksPath)) {
        return [pscustomobject][ordered]@{ hooks = [pscustomobject]@{} }
    }
    $document = [System.IO.File]::ReadAllText($HooksPath, $Utf8NoBom) | ConvertFrom-Json
    if ($null -eq (Get-PropertyValue $document "hooks")) {
        $document | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    return $document
}

function Test-ManagedHook {
    param([object]$Hook)
    foreach ($name in @("command", "commandWindows")) {
        $command = [string](Get-PropertyValue $Hook $name)
        if ($command -like "*codex-task-sounds*notify.ps1*") { return $true }
        if (-not [string]::IsNullOrWhiteSpace($command) -and $command.IndexOf($InstallScript, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Add-ManagedHook {
    param(
        [object]$HooksRoot,
        [string]$EventName,
        [string]$Mode,
        [int]$Timeout,
        [string]$StatusMessage
    )
    $groups = @((Get-PropertyValue $HooksRoot $EventName))
    $cleanGroups = @()
    foreach ($group in $groups) {
        if ($null -eq $group) { continue }
        $hookItems = @((Get-PropertyValue $group "hooks"))
        if ($hookItems.Count -eq 0) {
            $cleanGroups += $group
            continue
        }
        $filtered = @($hookItems | Where-Object { -not (Test-ManagedHook $_) })
        if ($filtered.Count -gt 0) {
            $group | Add-Member -NotePropertyName hooks -NotePropertyValue $filtered -Force
            $cleanGroups += $group
        }
    }

    $command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $InstallScript + '" ' + $Mode
    $managedHook = [pscustomobject][ordered]@{
        type = "command"
        command = $command
        commandWindows = $command
        timeout = $Timeout
    }
    if (-not [string]::IsNullOrWhiteSpace($StatusMessage)) {
        $managedHook | Add-Member -NotePropertyName statusMessage -NotePropertyValue $StatusMessage
    }
    $cleanGroups += [pscustomobject][ordered]@{ hooks = @($managedHook) }
    $HooksRoot | Add-Member -NotePropertyName $EventName -NotePropertyValue $cleanGroups -Force
}

function Stop-InstalledWatchers {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine.IndexOf($InstallScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $_.CommandLine -match '(?i)\bwatch\b'
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

[System.IO.Directory]::CreateDirectory($CodexHome) | Out-Null
[System.IO.Directory]::CreateDirectory($InstallRoot) | Out-Null
Copy-Item -LiteralPath (Join-Path $SourceRoot "notify.ps1") -Destination $InstallScript -Force

$settingsPath = Join-Path $InstallRoot "config.json"
if (-not (Test-Path -LiteralPath $settingsPath)) {
    Copy-Item -LiteralPath (Join-Path $SourceRoot "config.example.json") -Destination $settingsPath
}

$document = Read-HooksDocument
$hooksRoot = Get-PropertyValue $document "hooks"
Add-ManagedHook $hooksRoot "SessionStart" "session-start" 5 "Start task sound monitor"
Add-ManagedHook $hooksRoot "PermissionRequest" "permission" 5 "Waiting for user action"
Add-ManagedHook $hooksRoot "Stop" "stop" 5 "Play task status sound"
Add-ManagedHook $hooksRoot "SessionEnd" "session-end" 3 ""

if (Test-Path -LiteralPath $HooksPath) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Copy-Item -LiteralPath $HooksPath -Destination ($HooksPath + ".backup-" + $stamp) -Force
}
$hooksJson = $document | ConvertTo-Json -Depth 30
[System.IO.File]::WriteAllText($HooksPath, $hooksJson + [Environment]::NewLine, $Utf8NoBom)

& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $InstallScript generate

if (-not $SkipStartup) {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $runCommand = '"' + $PowerShellExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $InstallScript + '" watch'
    New-Item -Path $runKey -Force | Out-Null
    Set-ItemProperty -Path $runKey -Name $StartupName -Value $runCommand
}

if (-not $NoStart) {
    Stop-InstalledWatchers
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $InstallScript + '" watch'
    Start-Process -FilePath $PowerShellExe -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

Write-Output "Installed Codex task sounds to: $InstallRoot"
Write-Output "Existing hooks were preserved; a timestamped backup was created when hooks.json already existed."
if ($SkipStartup) { Write-Output "Login startup was skipped." }
elseif ($NoStart) { Write-Output "Login startup was registered; the watcher was not started in this session." }
else { Write-Output "The watcher is running and will start again when the current user signs in." }
