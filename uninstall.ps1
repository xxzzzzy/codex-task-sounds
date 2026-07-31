[CmdletBinding()]
param(
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }),
    [switch]$SkipStartup,
    [switch]$KeepFiles
)

$ErrorActionPreference = "Stop"
$InstallRoot = Join-Path $CodexHome "codex-task-sounds"
$InstallScript = Join-Path $InstallRoot "notify.ps1"
$HooksPath = Join-Path $CodexHome "hooks.json"
$StartupName = "CodexTaskSounds"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-PropertyValue {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
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

function Stop-InstalledWatchers {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine.IndexOf($InstallScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $_.CommandLine -match '(?i)\bwatch\b'
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

Stop-InstalledWatchers

if (-not $SkipStartup) {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    Remove-ItemProperty -Path $runKey -Name $StartupName -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $HooksPath) {
    $document = [System.IO.File]::ReadAllText($HooksPath, $Utf8NoBom) | ConvertFrom-Json
    $hooksRoot = Get-PropertyValue $document "hooks"
    if ($null -ne $hooksRoot) {
        foreach ($eventName in @("SessionStart", "PermissionRequest", "Stop", "SessionEnd")) {
            $groups = @((Get-PropertyValue $hooksRoot $eventName))
            if ($groups.Count -eq 0) { continue }
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
            $hooksRoot | Add-Member -NotePropertyName $eventName -NotePropertyValue $cleanGroups -Force
        }
    }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Copy-Item -LiteralPath $HooksPath -Destination ($HooksPath + ".backup-" + $stamp) -Force
    $hooksJson = $document | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($HooksPath, $hooksJson + [Environment]::NewLine, $Utf8NoBom)
}

if (-not $KeepFiles -and (Test-Path -LiteralPath $InstallRoot)) {
    $resolvedHome = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
    $resolvedInstall = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $expectedPrefix = $resolvedHome + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedInstall.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($resolvedInstall) -ne "codex-task-sounds") {
        throw "Refusing to remove unexpected path: $resolvedInstall"
    }
    Remove-Item -LiteralPath $resolvedInstall -Recurse -Force
}

Write-Output "Removed Codex task sound hooks and stopped the watcher."
if ($SkipStartup) { Write-Output "Login startup cleanup was skipped." }
if ($KeepFiles) { Write-Output "Installed files were kept at: $InstallRoot" }
