[CmdletBinding()]
param(
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }),
    [switch]$SkipStartup,
    [switch]$KeepFiles
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($CodexHome)) { throw "CodexHome cannot be empty." }
$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
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

function Write-HooksDocument {
    param([object]$Document)
    $hooksJson = $Document | ConvertTo-Json -Depth 100
    $directory = Split-Path -Parent $HooksPath
    $temporaryPath = Join-Path $directory (".hooks.json.tmp-{0}-{1}" -f $PID, [Guid]::NewGuid().ToString("N"))
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $hooksJson + [Environment]::NewLine, $Utf8NoBom)
        [void]([System.IO.File]::ReadAllText($temporaryPath, $Utf8NoBom) | ConvertFrom-Json)
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
        $backupPath = "{0}.backup-{1}-{2}" -f $HooksPath, $stamp, [Guid]::NewGuid().ToString("N").Substring(0, 8)
        [System.IO.File]::Replace($temporaryPath, $HooksPath, $backupPath, $true)
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-CleanedHooksDocument {
    if (-not (Test-Path -LiteralPath $HooksPath)) { return $null }
    try {
        $document = [System.IO.File]::ReadAllText($HooksPath, $Utf8NoBom) | ConvertFrom-Json
    }
    catch {
        throw "hooks.json is not valid JSON; no uninstall changes were made: $HooksPath"
    }
    if ($document -isnot [System.Management.Automation.PSCustomObject]) {
        throw "hooks.json must contain a JSON object at the top level; no uninstall changes were made: $HooksPath"
    }
    $hooksProperty = $document.PSObject.Properties["hooks"]
    $hooksRoot = if ($null -eq $hooksProperty) { $null } else { $hooksProperty.Value }
    if ($null -ne $hooksProperty -and $hooksRoot -isnot [System.Management.Automation.PSCustomObject]) {
        throw "The hooks property in hooks.json must be a JSON object; no uninstall changes were made: $HooksPath"
    }
    $changed = $false
    if ($null -ne $hooksRoot) {
        $eventModes = [ordered]@{
            SessionStart = "session-start"
            PermissionRequest = "permission"
            Stop = "stop"
            SessionEnd = "session-end"
        }
        foreach ($eventName in $eventModes.Keys) {
            $mode = $eventModes[$eventName]
            $eventProperty = $hooksRoot.PSObject.Properties[$eventName]
            if ($null -ne $eventProperty -and $null -eq $eventProperty.Value) {
                throw "The $eventName Hook value cannot be null; no uninstall changes were made."
            }
            if ($null -ne $eventProperty -and $eventProperty.Value -is [System.Array]) {
                for ($index = 0; $index -lt $eventProperty.Value.Count; $index++) {
                    if ($null -eq $eventProperty.Value[$index]) {
                        throw "The $eventName Hook groups cannot contain null; no uninstall changes were made."
                    }
                }
            }
            $groups = if ($null -eq $eventProperty) { @() } else { @($eventProperty.Value) }
            if ($groups.Count -eq 0) { continue }
            $cleanGroups = @()
            foreach ($group in $groups) {
                if ($null -eq $group) {
                    throw "The $eventName Hook groups cannot contain null; no uninstall changes were made."
                }
                if ($group -isnot [System.Management.Automation.PSCustomObject]) {
                    throw "The $eventName Hook groups must be JSON objects; no uninstall changes were made."
                }
                $hookProperty = $group.PSObject.Properties["hooks"]
                if ($null -eq $hookProperty -or $null -eq $hookProperty.Value) {
                    throw "A $eventName Hook group is missing its hooks array; no uninstall changes were made."
                }
                $hookItems = @($hookProperty.Value)
                foreach ($hookItem in $hookItems) {
                    if ($null -eq $hookItem) {
                        throw "The hooks entries under $eventName cannot contain null; no uninstall changes were made."
                    }
                    if ($hookItem -isnot [System.Management.Automation.PSCustomObject]) {
                        throw "The hooks entries under $eventName must be JSON objects; no uninstall changes were made."
                    }
                }
                if ($hookItems.Count -eq 0) {
                    $cleanGroups += $group
                    continue
                }
                $filtered = @($hookItems | Where-Object { -not (Test-ManagedHook $_ $mode) })
                if ($filtered.Count -ne $hookItems.Count) { $changed = $true }
                if ($filtered.Count -gt 0) {
                    $group | Add-Member -NotePropertyName hooks -NotePropertyValue $filtered -Force
                    $cleanGroups += $group
                }
            }
            $hooksRoot | Add-Member -NotePropertyName $eventName -NotePropertyValue $cleanGroups -Force
        }
    }
    return [pscustomobject]@{ Document = $document; Changed = $changed }
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

$hooksCleanup = Get-CleanedHooksDocument

$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runKeyValues = Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue
$startupNames = @($StartupName)
if ($StartupName -ne "CodexTaskSounds") { $startupNames += "CodexTaskSounds" }
$matchingStartupNames = @()
foreach ($name in $startupNames) {
    $property = if ($null -eq $runKeyValues) { $null } else { $runKeyValues.PSObject.Properties[$name] }
    $value = if ($null -eq $property) { "" } else { [string]$property.Value }
    if ($value.Equals($StartupCommand, [StringComparison]::OrdinalIgnoreCase)) {
        $matchingStartupNames += $name
    }
}
if ($SkipStartup -and -not $KeepFiles -and $matchingStartupNames.Count -gt 0) {
    throw "Refusing to delete installed files while a matching login startup entry is kept. Remove -SkipStartup or add -KeepFiles."
}

$resolvedInstall = $null
if (-not $KeepFiles -and (Test-Path -LiteralPath $InstallRoot)) {
    $resolvedHome = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
    $resolvedInstall = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $expectedPrefix = $resolvedHome + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedInstall.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($resolvedInstall) -ne "codex-task-sounds") {
        throw "Refusing to remove unexpected path: $resolvedInstall"
    }
    $installItem = Get-Item -LiteralPath $resolvedInstall -Force
    if (-not $installItem.PSIsContainer) {
        throw "Refusing to remove an installation path that is not a directory: $resolvedInstall"
    }
    if (($installItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to recursively remove a reparse point: $resolvedInstall"
    }
    $directoriesToInspect = New-Object System.Collections.Generic.Stack[string]
    $directoriesToInspect.Push($resolvedInstall)
    while ($directoriesToInspect.Count -gt 0) {
        $directoryToInspect = $directoriesToInspect.Pop()
        foreach ($child in ([System.IO.DirectoryInfo]$directoryToInspect).EnumerateFileSystemInfos()) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to recursively remove an installation containing a reparse point: $($child.FullName)"
            }
            if (($child.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $directoriesToInspect.Push($child.FullName)
            }
        }
    }
}

Invoke-InstalledWatcherStop

if (-not $SkipStartup) {
    foreach ($name in $matchingStartupNames) {
        Remove-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
    }
}

if ($null -ne $hooksCleanup -and $hooksCleanup.Changed) { Write-HooksDocument $hooksCleanup.Document }

if ($null -ne $resolvedInstall) {
    Remove-Item -LiteralPath $resolvedInstall -Recurse -Force
}

Write-Output "Removed Codex task sound hooks and stopped the watcher."
if ($SkipStartup) { Write-Output "Login startup cleanup was skipped." }
if ($KeepFiles) { Write-Output "Installed files were kept at: $InstallRoot" }
