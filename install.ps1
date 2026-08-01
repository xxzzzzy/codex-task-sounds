[CmdletBinding()]
param(
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }),
    [switch]$SkipStartup,
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($CodexHome)) { throw "CodexHome cannot be empty." }
$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceRoot = Join-Path $ProjectRoot "src"
$InstallRoot = Join-Path $CodexHome "codex-task-sounds"
$InstallScript = Join-Path $InstallRoot "notify.ps1"
$HooksPath = Join-Path $CodexHome "hooks.json"
$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$StartupCommand = '"' + $PowerShellExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $InstallScript + '" watch'

function Get-PathKey {
    param([string]$Path)
    $normalized = [System.IO.Path]::GetFullPath($Path).TrimEnd('\').ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Utf8NoBom.GetBytes($normalized)))).Replace("-", "").Substring(0, 12).ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

$defaultCodexHome = [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE ".codex")).TrimEnd('\')
$normalizedCodexHome = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
$StartupName = if ($normalizedCodexHome.Equals($defaultCodexHome, [StringComparison]::OrdinalIgnoreCase)) {
    "CodexTaskSounds"
}
else {
    "CodexTaskSounds-" + (Get-PathKey $normalizedCodexHome)
}

function Get-PropertyValue {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-HookCommand {
    param([string]$Mode)
    $escapedScript = $InstallScript.Replace("'", "''")
    $escapedMode = $Mode.Replace("'", "''")
    $source = "`$ProgressPreference='SilentlyContinue'; & '$escapedScript' '$escapedMode' | Out-Null"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($source))
    return "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $encoded"
}

function Get-LegacyHookCommand {
    param([string]$Mode)
    return 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $InstallScript + '" ' + $Mode
}

function Read-HooksDocument {
    if (-not (Test-Path -LiteralPath $HooksPath)) {
        return [pscustomobject][ordered]@{ hooks = [pscustomobject]@{} }
    }
    try {
        $document = [System.IO.File]::ReadAllText($HooksPath, $Utf8NoBom) | ConvertFrom-Json
    }
    catch {
        throw "hooks.json is not valid JSON; no Hook changes were made: $HooksPath"
    }
    if ($document -isnot [System.Management.Automation.PSCustomObject]) {
        throw "hooks.json must contain a JSON object at the top level; no Hook changes were made: $HooksPath"
    }
    $hooksProperty = $document.PSObject.Properties["hooks"]
    if ($null -eq $hooksProperty) {
        $document | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    elseif ($hooksProperty.Value -isnot [System.Management.Automation.PSCustomObject]) {
        throw "The hooks property in hooks.json must be a JSON object; no Hook changes were made: $HooksPath"
    }
    return $document
}

function Write-HooksDocument {
    param([object]$Document)
    $hooksJson = $Document | ConvertTo-Json -Depth 100
    $directory = Split-Path -Parent $HooksPath
    $temporaryPath = Join-Path $directory (".hooks.json.tmp-{0}-{1}" -f $PID, [Guid]::NewGuid().ToString("N"))
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $hooksJson + [Environment]::NewLine, $Utf8NoBom)
        [void]([System.IO.File]::ReadAllText($temporaryPath, $Utf8NoBom) | ConvertFrom-Json)
        if (Test-Path -LiteralPath $HooksPath) {
            $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
            $backupPath = "{0}.backup-{1}-{2}" -f $HooksPath, $stamp, [Guid]::NewGuid().ToString("N").Substring(0, 8)
            [System.IO.File]::Replace($temporaryPath, $HooksPath, $backupPath, $true)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $HooksPath)
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-ManagedHook {
    param([object]$Hook, [string]$Mode)
    $expectedCommand = Get-HookCommand $Mode
    $legacyCommand = Get-LegacyHookCommand $Mode
    foreach ($name in @("command", "commandWindows")) {
        $command = [string](Get-PropertyValue $Hook $name)
        if ($command.Equals($expectedCommand, [StringComparison]::Ordinal)) { return $true }
        if ($command.Equals($legacyCommand, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Copy-FileAtomically {
    param([string]$Source, [string]$Destination)
    $directory = Split-Path -Parent $Destination
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory (".{0}.install-{1}-{2}" -f [System.IO.Path]::GetFileName($Destination), $PID, [Guid]::NewGuid().ToString("N"))
    $replacementBackup = Join-Path $directory (".{0}.install-backup-{1}-{2}" -f [System.IO.Path]::GetFileName($Destination), $PID, [Guid]::NewGuid().ToString("N"))
    try {
        [System.IO.File]::Copy($Source, $temporaryPath, $false)
        if (Test-Path -LiteralPath $Destination) {
            [System.IO.File]::Replace($temporaryPath, $Destination, $replacementBackup, $true)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Destination)
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $replacementBackup -Force -ErrorAction SilentlyContinue
    }
}

function Add-ManagedHook {
    param(
        [object]$HooksRoot,
        [string]$EventName,
        [string]$Mode,
        [int]$Timeout,
        [string]$StatusMessage
    )
    $eventProperty = $HooksRoot.PSObject.Properties[$EventName]
    if ($null -ne $eventProperty -and $null -eq $eventProperty.Value) {
        throw "The $EventName Hook value cannot be null; no Hook changes were made."
    }
    if ($null -ne $eventProperty -and $eventProperty.Value -is [System.Array]) {
        for ($index = 0; $index -lt $eventProperty.Value.Count; $index++) {
            if ($null -eq $eventProperty.Value[$index]) {
                throw "The $EventName Hook groups cannot contain null; no Hook changes were made."
            }
        }
    }
    $groups = if ($null -eq $eventProperty) { @() } else { @($eventProperty.Value) }
    $cleanGroups = @()
    foreach ($group in $groups) {
        if ($null -eq $group) {
            throw "The $EventName Hook groups cannot contain null; no Hook changes were made."
        }
        if ($group -isnot [System.Management.Automation.PSCustomObject]) {
            throw "The $EventName Hook groups must be JSON objects; no Hook changes were made."
        }
        $hookProperty = $group.PSObject.Properties["hooks"]
        if ($null -eq $hookProperty -or $null -eq $hookProperty.Value) {
            throw "A $EventName Hook group is missing its hooks array; no Hook changes were made."
        }
        $hookItems = @($hookProperty.Value)
        foreach ($hookItem in $hookItems) {
            if ($null -eq $hookItem) {
                throw "The hooks entries under $EventName cannot contain null; no Hook changes were made."
            }
            if ($hookItem -isnot [System.Management.Automation.PSCustomObject]) {
                throw "The hooks entries under $EventName must be JSON objects; no Hook changes were made."
            }
        }
        if ($hookItems.Count -eq 0) {
            $cleanGroups += $group
            continue
        }
        $filtered = @($hookItems | Where-Object { -not (Test-ManagedHook $_ $Mode) })
        if ($filtered.Count -gt 0) {
            $group | Add-Member -NotePropertyName hooks -NotePropertyValue $filtered -Force
            $cleanGroups += $group
        }
    }

    $command = Get-HookCommand $Mode
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

function Invoke-InstalledWatcherStop {
    $watchArgument = '-File "' + $InstallScript + '" watch'
    $processIds = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.Name -match '^(?i)(powershell|pwsh)\.exe$' -and
            $_.CommandLine.IndexOf($watchArgument, [StringComparison]::OrdinalIgnoreCase) -ge 0
        } |
        Select-Object -ExpandProperty ProcessId)
    foreach ($processId in $processIds) { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue }
    $stopDeadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $stopDeadline -and
        @($processIds | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) }).Count -gt 0) {
        Start-Sleep -Milliseconds 100
    }
    $remaining = @($processIds | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
    if ($remaining.Count -gt 0) {
        throw "Could not stop the existing task sound watcher process: $($remaining -join ', ')"
    }
}

function Get-RunValue {
    param([string]$RunKey, [string]$Name)
    $values = Get-ItemProperty -Path $RunKey -ErrorAction SilentlyContinue
    $property = if ($null -eq $values) { $null } else { $values.PSObject.Properties[$Name] }
    if ($null -eq $property) { return "" }
    return [string]$property.Value
}

function Test-WatcherReady {
    param([System.Diagnostics.Process]$Process, [string]$ReadyToken, [int]$TimeoutSeconds = 5)
    $watchLogPath = Join-Path $InstallRoot "notify.log"
    $readyText = "pid={0} watch ready token={1}" -f $Process.Id, $ReadyToken
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited) { return $false }
        if (Test-Path -LiteralPath $watchLogPath) {
            try {
                if ([System.IO.File]::ReadAllText($watchLogPath, $Utf8NoBom).Contains($readyText)) { return $true }
            }
            catch { [System.Diagnostics.Debug]::WriteLine($_.Exception.Message) }
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

[System.IO.Directory]::CreateDirectory($CodexHome) | Out-Null
$document = Read-HooksDocument
$hooksRoot = Get-PropertyValue $document "hooks"
Add-ManagedHook $hooksRoot "SessionStart" "session-start" 5 "Start task sound monitor"
Add-ManagedHook $hooksRoot "PermissionRequest" "permission" 5 "Waiting for user action"
Add-ManagedHook $hooksRoot "Stop" "stop" 5 "Play task status sound"
Add-ManagedHook $hooksRoot "SessionEnd" "session-end" 3 ""

if (Test-Path -LiteralPath $InstallRoot) {
    $installItem = Get-Item -LiteralPath $InstallRoot -Force
    if (-not $installItem.PSIsContainer) {
        throw "The installation path exists but is not a directory: $InstallRoot"
    }
    if (($installItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to install through a reparse point: $InstallRoot"
    }
}
$settingsPath = Join-Path $InstallRoot "config.json"
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $existingSettings = [System.IO.File]::ReadAllText($settingsPath, $Utf8NoBom) | ConvertFrom-Json
        if ($existingSettings -isnot [System.Management.Automation.PSCustomObject]) {
            throw "The settings root must be a JSON object."
        }
    }
    catch {
        throw "Existing config.json is invalid; installation files, Hooks, and startup settings were not changed: $settingsPath"
    }
}

$stagingRoot = Join-Path $CodexHome (".codex-task-sounds-stage-{0}-{1}" -f $PID, [Guid]::NewGuid().ToString("N"))
try {
    [System.IO.Directory]::CreateDirectory($stagingRoot) | Out-Null
    $stagingScript = Join-Path $stagingRoot "notify.ps1"
    $stagingSettings = Join-Path $stagingRoot "config.json"
    Copy-Item -LiteralPath (Join-Path $SourceRoot "notify.ps1") -Destination $stagingScript
    if (Test-Path -LiteralPath $settingsPath) {
        Copy-Item -LiteralPath $settingsPath -Destination $stagingSettings
    }
    else {
        Copy-Item -LiteralPath (Join-Path $SourceRoot "config.example.json") -Destination $stagingSettings
    }

    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $stagingScript generate
    if ($LASTEXITCODE -ne 0) {
        throw "Default sound generation failed with exit code $LASTEXITCODE. Installation files, Hooks, and startup settings were not changed."
    }
    $stagingSounds = Join-Path $stagingRoot "sounds"
    foreach ($name in @("success.wav", "error.wav", "action.wav", ".generated-volume")) {
        $generatedPath = Join-Path $stagingSounds $name
        if (-not (Test-Path -LiteralPath $generatedPath) -or (Get-Item -LiteralPath $generatedPath).Length -eq 0) {
            throw "Default sound generation did not produce a valid $name file. Installation files, Hooks, and startup settings were not changed."
        }
    }

    $soundsPath = Join-Path $InstallRoot "sounds"
    foreach ($path in @($InstallScript, $soundsPath)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to update an installation target that is a reparse point: $path"
        }
    }
    if ((Test-Path -LiteralPath $soundsPath) -and -not (Get-Item -LiteralPath $soundsPath -Force).PSIsContainer) {
        throw "The sounds path exists but is not a directory: $soundsPath"
    }
    foreach ($name in @("success.wav", "error.wav", "action.wav", ".generated-volume")) {
        $target = Join-Path $soundsPath $name
        if ((Test-Path -LiteralPath $target) -and
            (((Get-Item -LiteralPath $target -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Refusing to replace a sound target that is a reparse point: $target"
        }
    }

    [System.IO.Directory]::CreateDirectory($InstallRoot) | Out-Null
    Copy-FileAtomically $stagingScript $InstallScript
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        Copy-FileAtomically $stagingSettings $settingsPath
    }
    [System.IO.Directory]::CreateDirectory($soundsPath) | Out-Null
    foreach ($name in @("success.wav", "error.wav", "action.wav", ".generated-volume")) {
        Copy-FileAtomically (Join-Path $stagingSounds $name) (Join-Path $soundsPath $name)
    }
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-HooksDocument $document

if (-not $NoStart) {
    Invoke-InstalledWatcherStop
    $readyToken = [Guid]::NewGuid().ToString("N")
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $InstallScript + '" watch -ReadyToken ' + $readyToken
    $watcherProcess = Start-Process -FilePath $PowerShellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if (-not (Test-WatcherReady $watcherProcess $readyToken 5)) {
        $exitDescription = if ($watcherProcess.HasExited) { "exit code $($watcherProcess.ExitCode)" } else { "no readiness signal" }
        if (-not $watcherProcess.HasExited) {
            Stop-Process -Id $watcherProcess.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $watcherProcess.Id -Timeout 5 -ErrorAction SilentlyContinue
        }
        throw "The background watcher failed startup validation: $exitDescription."
    }
}

if (-not $SkipStartup) {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    New-Item -Path $runKey -Force | Out-Null
    if ($StartupName -ne "CodexTaskSounds") {
        $legacyValue = Get-RunValue $runKey "CodexTaskSounds"
        if ($legacyValue.Equals($StartupCommand, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-ItemProperty -Path $runKey -Name "CodexTaskSounds" -ErrorAction SilentlyContinue
        }
    }
    Set-ItemProperty -Path $runKey -Name $StartupName -Value $StartupCommand
}

Write-Output "Installed Codex task sounds to: $InstallRoot"
Write-Output "Existing hooks were preserved; a timestamped backup was created when hooks.json already existed."
if ($SkipStartup) { Write-Output "Login startup was skipped." }
elseif ($NoStart) { Write-Output "Login startup was registered; the watcher was not started in this session." }
else { Write-Output "The watcher is running and will start again when the current user signs in." }
