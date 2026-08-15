[CmdletBinding()]
param(
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }),
    # Retained for compatibility with 1.0.x installation commands. Hook-only
    # mode never registers or starts a resident watcher.
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
$LegacyRootScript = Join-Path $CodexHome "notify.ps1"
$HooksPath = Join-Path $CodexHome "hooks.json"
$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$LegacyStartupCommand = '"' + $PowerShellExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $InstallScript + '" watch'
$LegacyRootOwned = $false
if (Test-Path -LiteralPath $LegacyRootScript -PathType Leaf) {
    try {
        $legacyItem = Get-Item -LiteralPath $LegacyRootScript -Force
        if (($legacyItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
            $legacyText = [System.IO.File]::ReadAllText($LegacyRootScript)
            $LegacyRootOwned = $legacyText.Contains("Codex task status sounds") -and $legacyText.Contains("function Invoke-StatusSound")
        }
    }
    catch { $LegacyRootOwned = $false }
}

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

function Get-LegacyHookCommands {
    param([string]$Mode)
    $commands = @('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $InstallScript + '" ' + $Mode)
    if ($LegacyRootOwned) {
        $commands += 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $LegacyRootScript + '" ' + $Mode
    }
    return $commands
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
    $legacyCommands = @(Get-LegacyHookCommands $Mode)
    foreach ($name in @("command", "commandWindows")) {
        $command = [string](Get-PropertyValue $Hook $name)
        if ($command.Equals($expectedCommand, [StringComparison]::Ordinal)) { return $true }
        foreach ($legacyCommand in $legacyCommands) {
            if ($command.Equals($legacyCommand, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
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

function Invoke-InstalledBackgroundProcessStop {
    $processIds = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.Name -match '^(?i)(powershell|pwsh)\.exe$' -and
            ($_.CommandLine.IndexOf($InstallScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $_.CommandLine.IndexOf($LegacyRootScript, [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
            $_.CommandLine -match '(?i)\b(watch|monitor|wait-loop)\b'
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
        throw "Could not stop the existing task sound background process: $($remaining -join ', ')"
    }
}

function Get-RunValue {
    param([string]$RunKey, [string]$Name)
    $values = Get-ItemProperty -Path $RunKey -ErrorAction SilentlyContinue
    $property = if ($null -eq $values) { $null } else { $values.PSObject.Properties[$Name] }
    if ($null -eq $property) { return "" }
    return [string]$property.Value
}

function Remove-OwnedLegacyStartup {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $startupNames = @($StartupName)
    if ($StartupName -ne "CodexTaskSounds") { $startupNames += "CodexTaskSounds" }
    foreach ($name in $startupNames) {
        $value = Get-RunValue $runKey $name
        if ($value.Equals($LegacyStartupCommand, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
        }
    }
}

function Remove-OwnedLegacyScheduledWatcher {
    $tasks = @(Get-ScheduledTask -TaskName "CodexTaskStatusSounds" -ErrorAction SilentlyContinue)
    foreach ($task in $tasks) {
        $owned = $false
        foreach ($action in @($task.Actions)) {
            $text = [string]$action.Execute + " " + [string]$action.Arguments
            $usesOwnedScript = $text.IndexOf($InstallScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $text.IndexOf($LegacyRootScript, [StringComparison]::OrdinalIgnoreCase) -ge 0
            if ($usesOwnedScript -and $text -match '(?i)\bwatch\b') { $owned = $true; break }
        }
        if ($owned) {
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
        }
    }
}

[System.IO.Directory]::CreateDirectory($CodexHome) | Out-Null
$document = Read-HooksDocument
$hooksRoot = Get-PropertyValue $document "hooks"
Add-ManagedHook $hooksRoot "SessionStart" "session-start" 5 "Initialize task sound state"
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

Invoke-InstalledBackgroundProcessStop
Remove-OwnedLegacyStartup
Remove-OwnedLegacyScheduledWatcher
$null = $SkipStartup
$null = $NoStart

Write-Output "Installed Codex task sounds to: $InstallRoot"
Write-Output "Existing hooks were preserved; a timestamped backup was created when hooks.json already existed."
Write-Output "Hook-only mode is active; no login startup or resident watcher is installed."
