[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Mode = "help",
    [string]$SessionId,
    [string]$TurnId,
    [string]$TranscriptPath,
    [string]$Status,
    [string]$DedupeKey,
    [string]$ReadyToken,
    [int]$ParentProcessId = 0,
    [Alias("version")]
    [switch]$ShowVersion,
    [switch]$Silent,
    [switch]$Unsilent
)

$ErrorActionPreference = "Stop"

$InstallRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$CodexHome = Split-Path -Parent $InstallRoot
$ScriptPath = $MyInvocation.MyCommand.Path
$SettingsPath = Join-Path $InstallRoot "config.json"
$SoundsDirectory = Join-Path $InstallRoot "sounds"
$StateDirectory = Join-Path $InstallRoot "notify-state"
$SessionsDirectory = Join-Path $CodexHome "sessions"
$LogPath = Join-Path $InstallRoot "notify.log"
$PowerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Version = "1.0.2"
$MaxLogBytes = 2MB
$MaxLogArchives = 3
$SettingsWarningLogged = $false

function Get-TextHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Utf8NoBom.GetBytes($Text)))).Replace("-", "").ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

$NormalizedCodexHome = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
$InstanceKey = (Get-TextHash $NormalizedCodexHome).Substring(0, 16)

function Initialize-Directory {
    [System.IO.Directory]::CreateDirectory($SoundsDirectory) | Out-Null
    [System.IO.Directory]::CreateDirectory($StateDirectory) | Out-Null
}

function Enter-NotifyMutex {
    param([System.Threading.Mutex]$Mutex, [int]$TimeoutMilliseconds)
    try { return $Mutex.WaitOne($TimeoutMilliseconds) }
    catch [System.Threading.AbandonedMutexException] { return $true }
}

function Write-NotifyLog {
    param([string]$Message)
    $mutex = New-Object System.Threading.Mutex($false, ("Local\CodexNotifyLog-{0}" -f $InstanceKey))
    $acquired = $false
    try {
        $acquired = Enter-NotifyMutex $mutex 3000
        if (-not $acquired) { return }
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -ge $MaxLogBytes) {
            for ($index = $MaxLogArchives; $index -ge 1; $index--) {
                $archive = $LogPath + "." + $index
                if ($index -eq $MaxLogArchives -and (Test-Path -LiteralPath $archive)) {
                    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
                }
                elseif (Test-Path -LiteralPath $archive) {
                    Move-Item -LiteralPath $archive -Destination ($LogPath + "." + ($index + 1)) -Force
                }
            }
            Move-Item -LiteralPath $LogPath -Destination ($LogPath + ".1") -Force
        }
        $line = "{0} pid={1} {2}{3}" -f [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss.fff"), $PID, $Message, [Environment]::NewLine
        [System.IO.File]::AppendAllText($LogPath, $line, $Utf8NoBom)
    }
    catch { [System.Diagnostics.Debug]::WriteLine($_.Exception.Message) }
    finally {
        if ($acquired) {
            try { $mutex.ReleaseMutex() }
            catch { [System.Diagnostics.Debug]::WriteLine($_.Exception.Message) }
        }
        $mutex.Dispose()
    }
}

function Get-DefaultConfiguration {
    [pscustomobject][ordered]@{
        volume = 0.3
        waiting_volume = 0.65
        success = $true
        error = $true
        waiting = $true
        waiting_interval = 10
        waiting_repeat = $false
        waiting_max_seconds = 120
        detect_question_waiting = $true
        error_on_tool_failure = $true
        silent = $false
        quiet_hours = [pscustomobject][ordered]@{
            enabled = $false
            start = "23:00"
            end = "08:00"
        }
    }
}

function Read-Configuration {
    param([switch]$Strict)
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return Get-DefaultConfiguration
    }
    try {
        $settings = [System.IO.File]::ReadAllText($SettingsPath, $Utf8NoBom) | ConvertFrom-Json
        if ($settings -isnot [System.Management.Automation.PSCustomObject]) {
            throw "The settings root must be a JSON object."
        }
        return $settings
    }
    catch {
        if ($Strict) { throw "config.json is invalid and was not changed: $SettingsPath" }
        if (-not $script:SettingsWarningLogged) {
            Write-NotifyLog ("settings fallback path={0} error={1}" -f $SettingsPath, $_.Exception.Message)
            $script:SettingsWarningLogged = $true
        }
        return Get-DefaultConfiguration
    }
}

function Get-Setting {
    param([object]$Object, [string]$Name, [object]$Default)
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) {
            return $property.Value
        }
    }
    return $Default
}

function Get-BooleanSetting {
    param([object]$Object, [string]$Name, [bool]$Default)
    $value = Get-Setting $Object $Name $Default
    if ($value -is [bool]) { return $value }
    $parsed = $false
    if ([bool]::TryParse([string]$value, [ref]$parsed)) { return $parsed }
    return $Default
}

function Get-IntegerSetting {
    param([object]$Object, [string]$Name, [int]$Default, [int]$Minimum, [int]$Maximum)
    $parsed = 0
    if (-not [int]::TryParse([string](Get-Setting $Object $Name $Default), [ref]$parsed)) { $parsed = $Default }
    return [Math]::Max($Minimum, [Math]::Min($Maximum, $parsed))
}

function Write-JsonAtomically {
    param([string]$Path, [object]$Value, [int]$Depth = 20)
    $directory = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory (".{0}.tmp-{1}-{2}" -f [System.IO.Path]::GetFileName($Path), $PID, [Guid]::NewGuid().ToString("N"))
    $replacementBackup = Join-Path $directory (".{0}.replace-backup-{1}-{2}" -f [System.IO.Path]::GetFileName($Path), $PID, [Guid]::NewGuid().ToString("N"))
    try {
        $json = $Value | ConvertTo-Json -Depth $Depth
        [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $Utf8NoBom)
        [void]([System.IO.File]::ReadAllText($temporaryPath, $Utf8NoBom) | ConvertFrom-Json)
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($temporaryPath, $Path, $replacementBackup, $true)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $replacementBackup -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SilentModeUpdate {
    param([bool]$Value)
    $mutex = New-Object System.Threading.Mutex($false, ("Local\CodexNotifySettings-{0}" -f $InstanceKey))
    $acquired = $false
    try {
        $acquired = Enter-NotifyMutex $mutex 3000
        if (-not $acquired) { throw "Timed out while waiting to update config.json." }
        $settings = Read-Configuration -Strict
        $settings | Add-Member -NotePropertyName silent -NotePropertyValue $Value -Force
        Write-JsonAtomically $SettingsPath $settings 20
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-NotifyVolume {
    $volume = 0.3
    try { $volume = [double](Get-Setting (Read-Configuration) "volume" 0.3) }
    catch { Write-NotifyLog ("invalid volume; using default error={0}" -f $_.Exception.Message) }
    return [Math]::Max(0.0, [Math]::Min(1.0, $volume))
}

function Get-WaitingVolume {
    $volume = 0.65
    try { $volume = [double](Get-Setting (Read-Configuration) "waiting_volume" 0.65) }
    catch { Write-NotifyLog ("invalid waiting volume; using default error={0}" -f $_.Exception.Message) }
    return [Math]::Max(0.0, [Math]::Min(1.0, $volume))
}

function Test-QuietHour {
    param([object]$Settings)
    $quiet = Get-Setting $Settings "quiet_hours" $null
    if (-not (Get-BooleanSetting $quiet "enabled" $false)) {
        return $false
    }
    $start = [TimeSpan]::Zero
    $end = [TimeSpan]::Zero
    if (-not [TimeSpan]::TryParse([string](Get-Setting $quiet "start" "23:00"), [ref]$start)) {
        return $false
    }
    if (-not [TimeSpan]::TryParse([string](Get-Setting $quiet "end" "08:00"), [ref]$end)) {
        return $false
    }
    $now = (Get-Date).TimeOfDay
    if ($start -le $end) {
        return $now -ge $start -and $now -lt $end
    }
    return $now -ge $start -or $now -lt $end
}

function Test-StatusEnabled {
    param([ValidateSet("success", "error", "action")][string]$Status)
    $settings = Read-Configuration
    if ((Get-BooleanSetting $settings "silent" $false) -or (Test-QuietHour $settings)) {
        return $false
    }
    switch ($Status) {
        "success" { return Get-BooleanSetting $settings "success" $true }
        "error" { return Get-BooleanSetting $settings "error" $true }
        "action" { return Get-BooleanSetting $settings "waiting" $true }
    }
}

function Invoke-AudioFile {
    param([string]$Path, [double]$Volume)
    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -eq ".wav") {
        $player = New-Object System.Media.SoundPlayer($Path)
        try { $player.PlaySync() }
        finally { $player.Dispose() }
        return
    }

    Add-Type -AssemblyName PresentationCore
    $mediaPlayer = New-Object System.Windows.Media.MediaPlayer
    try {
        $mediaPlayer.Volume = [Math]::Max(0.0, [Math]::Min(1.0, $Volume))
        $mediaPlayer.Open([Uri]$Path)
        $openDeadline = (Get-Date).AddSeconds(5)
        while (-not $mediaPlayer.NaturalDuration.HasTimeSpan -and (Get-Date) -lt $openDeadline) {
            Start-Sleep -Milliseconds 25
        }
        if (-not $mediaPlayer.NaturalDuration.HasTimeSpan) {
            throw "The audio file could not be opened by Windows Media Foundation: $Path"
        }
        $duration = $mediaPlayer.NaturalDuration.TimeSpan
        $mediaPlayer.Play()
        Start-Sleep -Milliseconds ([Math]::Ceiling($duration.TotalMilliseconds + 100))
    }
    finally { $mediaPlayer.Close() }
}

function Write-WaveSequence {
    param([string]$Path, [object[]]$Notes, [double]$Amplitude)
    $sampleRate = 44100
    $sampleCount = 0
    $duration = 0.0
    foreach ($note in $Notes) {
        $duration += [double]$note.Duration + [double]$note.Gap
    }
    $sampleCount = [int][Math]::Ceiling($duration * $sampleRate)
    $dataSize = $sampleCount * 2
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $writer = New-Object System.IO.BinaryWriter($stream)
    try {
        $ascii = [System.Text.Encoding]::ASCII
        $writer.Write($ascii.GetBytes("RIFF"))
        $writer.Write([int](36 + $dataSize))
        $writer.Write($ascii.GetBytes("WAVE"))
        $writer.Write($ascii.GetBytes("fmt "))
        $writer.Write([int]16)
        $writer.Write([int16]1)
        $writer.Write([int16]1)
        $writer.Write([int]$sampleRate)
        $writer.Write([int]($sampleRate * 2))
        $writer.Write([int16]2)
        $writer.Write([int16]16)
        $writer.Write($ascii.GetBytes("data"))
        $writer.Write([int]$dataSize)
        for ($index = 0; $index -lt $sampleCount; $index++) {
            $time = $index / [double]$sampleRate
            $cursor = 0.0
            $sample = 0.0
            foreach ($note in $Notes) {
                $noteDuration = [double]$note.Duration
                if ($time -ge $cursor -and $time -lt ($cursor + $noteDuration)) {
                    $localTime = $time - $cursor
                    $attack = [Math]::Min(1.0, $localTime / 0.008)
                    $release = [Math]::Min(1.0, ($noteDuration - $localTime) / 0.045)
                    $decay = [Math]::Exp(-1.8 * $localTime / $noteDuration)
                    $frequency = [double]$note.Frequency
                    $wave = 0.75 * [Math]::Sin(2 * [Math]::PI * $frequency * $localTime)
                    $wave += 0.18 * [Math]::Sin(2 * [Math]::PI * $frequency * 2.0 * $localTime)
                    $wave += 0.07 * [Math]::Sin(2 * [Math]::PI * $frequency * 3.0 * $localTime)
                    $sample = $Amplitude * $attack * $release * $decay * $wave
                    break
                }
                $cursor += $noteDuration + [double]$note.Gap
            }
            $sample = [Math]::Max(-1.0, [Math]::Min(1.0, $sample))
            $writer.Write([int16][Math]::Round($sample * 32767))
        }
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Move-FileAtomically {
    param([string]$Source, [string]$Destination)
    $directory = Split-Path -Parent $Destination
    $replacementBackup = Join-Path $directory (".{0}.sound-backup-{1}-{2}" -f [System.IO.Path]::GetFileName($Destination), $PID, [Guid]::NewGuid().ToString("N"))
    try {
        if (Test-Path -LiteralPath $Destination) {
            [System.IO.File]::Replace($Source, $Destination, $replacementBackup, $true)
        }
        else {
            [System.IO.File]::Move($Source, $Destination)
        }
    }
    finally {
        Remove-Item -LiteralPath $replacementBackup -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-Sound {
    param([switch]$Force)
    Initialize-Directory
    $volume = Get-NotifyVolume
    $waitingVolume = Get-WaitingVolume
    $volumeText = "{0}|{1}" -f
        $volume.ToString("0.0000", [Globalization.CultureInfo]::InvariantCulture),
        $waitingVolume.ToString("0.0000", [Globalization.CultureInfo]::InvariantCulture)
    $volumeMarker = Join-Path $SoundsDirectory ".generated-volume"
    $successPath = Join-Path $SoundsDirectory "success.wav"
    $errorPath = Join-Path $SoundsDirectory "error.wav"
    $actionPath = Join-Path $SoundsDirectory "action.wav"
    $needsBuild = $Force -or -not (Test-Path -LiteralPath $successPath) -or -not (Test-Path -LiteralPath $errorPath) -or -not (Test-Path -LiteralPath $actionPath)
    if (-not $needsBuild -and (Test-Path -LiteralPath $volumeMarker)) {
        $needsBuild = ([System.IO.File]::ReadAllText($volumeMarker).Trim() -ne $volumeText)
    }
    elseif (-not (Test-Path -LiteralPath $volumeMarker)) {
        $needsBuild = $true
    }
    if (-not $needsBuild) {
        return
    }
    $created = $false
    $mutex = New-Object System.Threading.Mutex($false, ("Local\CodexNotifySoundBuilder-{0}" -f $InstanceKey), [ref]$created)
    $acquired = $false
    try {
        $acquired = Enter-NotifyMutex $mutex 5000
        if (-not $acquired) { throw "Timed out while waiting to generate the default sounds." }
        $token = "{0}-{1}" -f $PID, [Guid]::NewGuid().ToString("N")
        $temporarySuccess = Join-Path $SoundsDirectory (".success-{0}.wav" -f $token)
        $temporaryError = Join-Path $SoundsDirectory (".error-{0}.wav" -f $token)
        $temporaryAction = Join-Path $SoundsDirectory (".action-{0}.wav" -f $token)
        $temporaryMarker = Join-Path $SoundsDirectory (".volume-{0}.tmp" -f $token)
        try {
            Write-WaveSequence $temporarySuccess @(
                [pscustomobject]@{ Frequency = 523.25; Duration = 0.120; Gap = 0.040 },
                [pscustomobject]@{ Frequency = 659.25; Duration = 0.120; Gap = 0.000 }
            ) ($volume * 0.78)
            Write-WaveSequence $temporaryError @(
                [pscustomobject]@{ Frequency = 329.63; Duration = 0.150; Gap = 0.040 },
                [pscustomobject]@{ Frequency = 261.63; Duration = 0.150; Gap = 0.000 }
            ) ($volume * 0.68)
            Write-WaveSequence $temporaryAction @(
                [pscustomobject]@{ Frequency = 659.25; Duration = 0.160; Gap = 0.070 },
                [pscustomobject]@{ Frequency = 880.00; Duration = 0.160; Gap = 0.070 },
                [pscustomobject]@{ Frequency = 659.25; Duration = 0.200; Gap = 0.000 }
            ) ($waitingVolume * 0.82)
            [System.IO.File]::WriteAllText($temporaryMarker, $volumeText, $Utf8NoBom)
            Remove-Item -LiteralPath $volumeMarker -Force -ErrorAction SilentlyContinue
            Move-FileAtomically $temporarySuccess $successPath
            Move-FileAtomically $temporaryError $errorPath
            Move-FileAtomically $temporaryAction $actionPath
            [System.IO.File]::Move($temporaryMarker, $volumeMarker)
        }
        finally {
            foreach ($temporaryPath in @($temporarySuccess, $temporaryError, $temporaryAction, $temporaryMarker)) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Test-AndMarkEvent {
    param([string]$Key, [int]$WindowSeconds = 3)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $true }
    Initialize-Directory
    $path = Join-Path $StateDirectory ("event-" + (Get-TextHash $Key) + ".stamp")
    $created = $false
    $mutex = New-Object System.Threading.Mutex($false, ("Local\CodexNotifyEventState-{0}" -f $InstanceKey), [ref]$created)
    try {
        if (-not (Enter-NotifyMutex $mutex 3000)) { return $false }
        try {
            if (Test-Path -LiteralPath $path) {
                $age = (Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime
                if ($age.TotalSeconds -lt $WindowSeconds) { return $false }
            }
            [System.IO.File]::WriteAllText($path, [DateTime]::UtcNow.ToString("o"), $Utf8NoBom)
            Get-ChildItem -LiteralPath $StateDirectory -Filter "event-*.stamp" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            return $true
        }
        finally { $mutex.ReleaseMutex() }
    }
    finally { $mutex.Dispose() }
}

function Invoke-StatusSound {
    param(
        [ValidateSet("success", "error", "action")][string]$Status,
        [string]$DedupeKey
    )
    if (-not (Test-StatusEnabled $Status)) {
        Write-NotifyLog ("sound skipped status={0} reason=disabled" -f $Status)
        return
    }
    if (-not (Test-AndMarkEvent $DedupeKey)) {
        Write-NotifyLog ("sound skipped status={0} reason=duplicate key={1}" -f $Status, $DedupeKey)
        return
    }
    Initialize-Sound
    $fallbackPath = switch ($Status) {
        "success" { Join-Path $SoundsDirectory "success.wav" }
        "error" { Join-Path $SoundsDirectory "error.wav" }
        "action" { Join-Path $SoundsDirectory "action.wav" }
    }
    $customPath = switch ($Status) {
        "success" { Join-Path $SoundsDirectory "success-custom.mp3" }
        "error" { Join-Path $SoundsDirectory "error-custom.mp3" }
        "action" { Join-Path $SoundsDirectory "action-custom.mp3" }
    }
    $path = if (-not [string]::IsNullOrWhiteSpace($customPath) -and (Test-Path -LiteralPath $customPath)) {
        $customPath
    }
    else {
        $fallbackPath
    }
    try {
        $playbackVolume = if ($Status -eq "action") { Get-WaitingVolume } else { Get-NotifyVolume }
        Invoke-AudioFile $path $playbackVolume
        Write-NotifyLog ("sound played status={0} path={1} key={2}" -f $Status, $path, $DedupeKey)
    }
    catch {
        if ($path -eq $fallbackPath) { throw }
        Write-NotifyLog ("sound fallback status={0} custom={1} error={2}" -f $Status, $path, $_.Exception.Message)
        Invoke-AudioFile $fallbackPath $playbackVolume
        Write-NotifyLog ("sound played status={0} path={1} key={2}" -f $Status, $fallbackPath, $DedupeKey)
    }
}

function Read-HookInput {
    $inputStream = [Console]::OpenStandardInput()
    $memory = New-Object System.IO.MemoryStream
    try {
        $inputStream.CopyTo($memory)
        $raw = $Utf8NoBom.GetString($memory.ToArray()).TrimStart([char]0xFEFF)
    }
    finally {
        $memory.Dispose()
        $inputStream.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return $raw | ConvertFrom-Json }
    catch { return $null }
}

function Get-StateFile {
    param([string]$Prefix, [string]$Id, [string]$Extension = "json")
    if ([string]::IsNullOrWhiteSpace($Id)) { $Id = "global" }
    return Join-Path $StateDirectory ("{0}-{1}.{2}" -f $Prefix, (Get-TextHash $Id).Substring(0, 20), $Extension)
}

function Get-WaitingFile { param([string]$Id) return Get-StateFile "waiting" $Id }
function Get-MonitorStopFile { param([string]$Id) return Get-StateFile "monitor-stop" $Id "flag" }

function ConvertTo-ProcessArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            if ($backslashes -gt 0) { [void]$builder.Append(((([string][char]92) * ($backslashes * 2)) -join '')) }
            [void]$builder.Append('\"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(((([string][char]92) * $backslashes) -join ''))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(((([string][char]92) * ($backslashes * 2)) -join '')) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-HiddenNotifyProcess {
    param([string]$ChildMode, [string]$ChildSessionId, [string]$ChildTurnId, [string]$ChildTranscriptPath, [int]$ChildParentProcessId = 0)
    $parts = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", (ConvertTo-ProcessArgument $ScriptPath), $ChildMode)
    if (-not [string]::IsNullOrWhiteSpace($ChildSessionId)) { $parts += @("-SessionId", (ConvertTo-ProcessArgument $ChildSessionId)) }
    if (-not [string]::IsNullOrWhiteSpace($ChildTurnId)) { $parts += @("-TurnId", (ConvertTo-ProcessArgument $ChildTurnId)) }
    if (-not [string]::IsNullOrWhiteSpace($ChildTranscriptPath)) { $parts += @("-TranscriptPath", (ConvertTo-ProcessArgument $ChildTranscriptPath)) }
    if ($ChildParentProcessId -gt 0) { $parts += @("-ParentProcessId", [string]$ChildParentProcessId) }
    Start-Process -FilePath $PowerShellPath -ArgumentList ($parts -join " ") -WindowStyle Hidden | Out-Null
}

function Invoke-HiddenStatusSound {
    param([ValidateSet("success", "error", "action")][string]$ChildStatus, [string]$ChildDedupeKey)
    $parts = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", (ConvertTo-ProcessArgument $ScriptPath), "play", "-Status", $ChildStatus)
    if (-not [string]::IsNullOrWhiteSpace($ChildDedupeKey)) { $parts += @("-DedupeKey", (ConvertTo-ProcessArgument $ChildDedupeKey)) }
    Start-Process -FilePath $PowerShellPath -ArgumentList ($parts -join " ") -WindowStyle Hidden | Out-Null
}

function Clear-Waiting {
    param([string]$Id, [string]$ExpectedTurnId)
    if ([string]::IsNullOrWhiteSpace($Id)) { $Id = "global" }
    $path = Get-WaitingFile $Id
    $mutexName = "Local\CodexNotifyWaitingState-" + $InstanceKey + "-" + (Get-TextHash $Id).Substring(0, 16)
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $acquired = $false
    try {
        $acquired = Enter-NotifyMutex $mutex 3000
        if (-not $acquired) { return }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedTurnId) -and (Test-Path -LiteralPath $path)) {
            try {
                $marker = [System.IO.File]::ReadAllText($path, $Utf8NoBom) | ConvertFrom-Json
                if ([string](Get-Setting $marker "turn_id" "") -ne $ExpectedTurnId) { return }
            }
            catch { return }
        }
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Test-WaitingForTurn {
    param([string]$Id, [string]$ExpectedTurnId)
    if ([string]::IsNullOrWhiteSpace($Id)) { $Id = "global" }
    $path = Get-WaitingFile $Id
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $marker = [System.IO.File]::ReadAllText($path, $Utf8NoBom) | ConvertFrom-Json
        return [string](Get-Setting $marker "turn_id" "") -eq $ExpectedTurnId
    }
    catch { return $false }
}

function Invoke-Waiting {
    param([string]$Id, [string]$ActiveTurnId, [string]$Reason = "user-input", [switch]$AsynchronousSound)
    $settings = Read-Configuration
    if (-not (Get-BooleanSetting $settings "waiting" $true)) { return }
    Initialize-Directory
    if ([string]::IsNullOrWhiteSpace($Id)) { $Id = "global" }
    if ([string]::IsNullOrWhiteSpace($ActiveTurnId)) { $ActiveTurnId = "unknown" }
    $marker = [pscustomobject][ordered]@{
        session_id = $Id
        turn_id = $ActiveTurnId
        reason = $Reason
        started_at = [DateTime]::UtcNow.ToString("o")
    }
    $waitingPath = Get-WaitingFile $Id
    $mutexName = "Local\CodexNotifyWaitingState-" + $InstanceKey + "-" + (Get-TextHash $Id).Substring(0, 16)
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $acquired = $false
    try {
        $acquired = Enter-NotifyMutex $mutex 3000
        if (-not $acquired) { return }
        Write-JsonAtomically $waitingPath $marker 10
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    $soundKey = "action|{0}|{1}|start" -f $Id, $ActiveTurnId
    if ($AsynchronousSound) { Invoke-HiddenStatusSound "action" $soundKey }
    else { Invoke-StatusSound "action" $soundKey }
    if (Get-BooleanSetting $settings "waiting_repeat" $false) {
        Invoke-HiddenNotifyProcess "wait-loop" $Id $ActiveTurnId $null 0
    }
}

function Invoke-WaitLoop {
    param([string]$Id, [string]$ActiveTurnId)
    Initialize-Directory
    $mutexName = "Local\CodexNotifyWait-" + $InstanceKey + "-" + (Get-TextHash ($Id + "|" + $ActiveTurnId)).Substring(0, 16)
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$created)
    if (-not $created) { $mutex.Dispose(); return }
    try {
        $settings = Read-Configuration
        $interval = Get-IntegerSetting $settings "waiting_interval" 10 8 60
        $maxSeconds = Get-IntegerSetting $settings "waiting_max_seconds" 120 $interval 3600
        $started = Get-Date
        $tick = 0
        while ((Test-WaitingForTurn $Id $ActiveTurnId) -and ((Get-Date) - $started).TotalSeconds -lt $maxSeconds) {
            Start-Sleep -Seconds $interval
            if (-not (Test-WaitingForTurn $Id $ActiveTurnId)) { break }
            $tick++
            Invoke-StatusSound "action" ("action|{0}|{1}|tick-{2}" -f $Id, $ActiveTurnId, $tick)
        }
    }
    finally {
        Clear-Waiting $Id $ActiveTurnId
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Test-MessageNeedsInput {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    if (-not (Get-BooleanSetting (Read-Configuration) "detect_question_waiting" $true)) { return $false }
    $pattern = '(?is)((?:请(?:确认|选择|回复|告诉我|提供|决定)|需要你(?:确认|选择|回复|提供|决定)|你(?:希望|想要|倾向于)|是否(?:需要|要|可以)|要不要|哪(?:个|一种)|可以吗|方便吗|please\s+(?:confirm|choose|select|reply|provide|decide)|do\s+you\s+(?:want|prefer)|would\s+you\s+like|can\s+you|could\s+you)\s*[。.!！?？]*\s*$|[?？]\s*$)'
    return $Message -match $pattern
}

function Resolve-Transcript {
    param([string]$Id, [string]$Candidate)
    if (-not [string]::IsNullOrWhiteSpace($Candidate) -and (Test-Path -LiteralPath $Candidate)) {
        return (Get-Item -LiteralPath $Candidate).FullName
    }
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $SessionsDirectory) {
            $transcriptMatches = @([System.IO.Directory]::EnumerateFiles($SessionsDirectory, ("*" + $Id + "*.jsonl"), [System.IO.SearchOption]::AllDirectories))
            if ($transcriptMatches.Count -gt 0) {
                return @($transcriptMatches | ForEach-Object { Get-Item -LiteralPath $_ } | Sort-Object LastWriteTime -Descending)[0].FullName
            }
        }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Get-ToolDiagnosticText {
    param([object]$Payload)
    $fragments = New-Object System.Collections.Generic.List[string]
    $nodes = @($Payload, (Get-Setting $Payload "result" $null))
    foreach ($node in $nodes) {
        if ($null -eq $node) { continue }
        foreach ($name in @("message", "error", "stderr", "stdout", "text", "content", "output")) {
            $value = Get-Setting $node $name $null
            if ($value -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace($value)) { $fragments.Add($value) }
                continue
            }
            if ($value -is [System.Collections.IEnumerable]) {
                foreach ($item in $value) {
                    if ($item -is [string]) {
                        if (-not [string]::IsNullOrWhiteSpace($item)) { $fragments.Add($item) }
                        continue
                    }
                    foreach ($childName in @("text", "content", "message", "error", "stderr", "stdout")) {
                        $child = Get-Setting $item $childName $null
                        if ($child -is [string] -and -not [string]::IsNullOrWhiteSpace($child)) { $fragments.Add($child) }
                    }
                }
            }
            elseif ($null -ne $value) {
                foreach ($childName in @("text", "content", "message", "error", "stderr", "stdout")) {
                    $child = Get-Setting $value $childName $null
                    if ($child -is [string] -and -not [string]::IsNullOrWhiteSpace($child)) { $fragments.Add($child) }
                }
            }
        }
    }
    return $fragments -join [Environment]::NewLine
}

function Test-ToolOutputFailed {
    param([object]$Payload)
    if (-not (Get-BooleanSetting (Read-Configuration) "error_on_tool_failure" $true)) { return $false }
    foreach ($node in @($Payload, (Get-Setting $Payload "result" $null))) {
        if ($null -eq $node) { continue }
        if ((Get-BooleanSetting $node "isError" $false) -or (Get-BooleanSetting $node "is_error" $false)) { return $true }
        $status = [string](Get-Setting $node "status" "")
        if ($status -match '(?i)^(failed|error|errored|cancelled|canceled|aborted)$') { return $true }
        foreach ($name in @("exit_code", "exitCode")) {
            $value = Get-Setting $node $name $null
            if ($null -ne $value) {
                $exitCode = 0
                if ([int]::TryParse([string]$value, [ref]$exitCode) -and $exitCode -ne 0) { return $true }
            }
        }
    }
    $text = Get-ToolDiagnosticText $Payload
    if ($text -match '(?im)^\s*(?:Script|Command) failed\b') { return $true }
    foreach ($match in [regex]::Matches($text, '(?im)^\s*Exit code:\s*(-?\d+)\s*$')) {
        if ([int]$match.Groups[1].Value -ne 0) { return $true }
    }
    foreach ($match in [regex]::Matches($text, '(?im)^\s*process exited with (?:status|code)\s*(-?\d+)\s*$')) {
        if ([int]$match.Groups[1].Value -ne 0) { return $true }
    }
    return $false
}

function Invoke-RolloutLine {
    param([string]$Line, [string]$Id)
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    try { $item = $Line | ConvertFrom-Json }
    catch { return }
    $claimKey = "rollout|{0}|{1}" -f $Id, (Get-TextHash $Line)
    if ([string]$item.method -eq "turn/completed") {
        if (-not (Test-AndMarkEvent $claimKey 300)) { return }
        $turn = Get-Setting $item.params "turn" $null
        $completedTurnId = [string](Get-Setting $turn "id" "unknown")
        $status = [string](Get-Setting $turn "status" "completed")
        Clear-Waiting $Id
        if ($status -match '(?i)failed|interrupted|cancelled|canceled|aborted') {
            Invoke-HiddenStatusSound "error" ("error|{0}|{1}|{2}" -f $Id, $completedTurnId, $status)
        }
        return
    }
    $topType = [string](Get-Setting $item "type" "")
    $payload = Get-Setting $item "payload" $null
    $payloadType = [string](Get-Setting $payload "type" "")
    $activeTurnId = [string](Get-Setting $payload "turn_id" "unknown")
    if ($topType -eq "event_msg") {
        if ($payloadType -match '^(error|stream_error|turn_aborted|task_failed|turn_failed)$') {
            if (-not (Test-AndMarkEvent $claimKey 300)) { return }
            Clear-Waiting $Id
            Invoke-HiddenStatusSound "error" ("error|{0}|{1}|{2}" -f $Id, $activeTurnId, $payloadType)
            return
        }
        if ($payloadType -match '^(exec_approval_request|apply_patch_approval_request|request_user_input|elicitation_request|mcp_elicitation_request)$') {
            if (-not (Test-AndMarkEvent $claimKey 300)) { return }
            Invoke-Waiting $Id $activeTurnId $payloadType -AsynchronousSound
            return
        }
        if ($payloadType -eq 'task_complete') {
            if (-not (Test-AndMarkEvent $claimKey 300)) { return }
            $completedTurnId = [string](Get-Setting $payload "turn_id" "unknown")
            $message = [string](Get-Setting $payload "last_agent_message" "")
            Clear-Waiting $Id
            if (Test-MessageNeedsInput $message) {
                Invoke-Waiting $Id $completedTurnId "assistant-question" -AsynchronousSound
            }
            else {
                Invoke-HiddenStatusSound "success" ("success|{0}|{1}" -f $Id, $completedTurnId)
            }
            return
        }
        if ($payloadType -eq 'turn_complete') {
            if (Test-AndMarkEvent $claimKey 300) { Clear-Waiting $Id }
            return
        }
        if ($payloadType -match '^(user_message|task_started)$') {
            if (Test-AndMarkEvent $claimKey 300) { Clear-Waiting $Id }
            return
        }
        if ($payloadType -match 'tool_call_end$' -and (Test-ToolOutputFailed $payload)) {
            if (-not (Test-AndMarkEvent $claimKey 300)) { return }
            Invoke-HiddenStatusSound "error" ("tool-error|{0}|{1}|{2}" -f $Id, $activeTurnId, $payloadType)
            return
        }
    }
    if ($topType -eq "response_item") {
        if ($payloadType -eq "custom_tool_call") {
            $name = [string](Get-Setting $payload "name" "")
            if ($name -match '^(request_user_input|request_permissions)$' -and (Test-AndMarkEvent $claimKey 300)) {
                Invoke-Waiting $Id $activeTurnId $name -AsynchronousSound
            }
            return
        }
        if ($payloadType -eq "custom_tool_call_output") {
            if (-not (Test-AndMarkEvent $claimKey 300)) { return }
            Clear-Waiting $Id
            if (Test-ToolOutputFailed $payload) {
                Invoke-HiddenStatusSound "error" ("tool-error|{0}|{1}" -f $Id, [string](Get-Setting $payload "call_id" "unknown"))
            }
        }
    }
}

function Split-CompleteUtf8Line {
    param([byte[]]$PreviousBytes, [byte[]]$NewBytes)
    if ($null -eq $PreviousBytes) { $PreviousBytes = [byte[]]@() }
    if ($null -eq $NewBytes) { $NewBytes = [byte[]]@() }
    $combined = New-Object byte[] ($PreviousBytes.Length + $NewBytes.Length)
    if ($PreviousBytes.Length -gt 0) { [System.Buffer]::BlockCopy($PreviousBytes, 0, $combined, 0, $PreviousBytes.Length) }
    if ($NewBytes.Length -gt 0) { [System.Buffer]::BlockCopy($NewBytes, 0, $combined, $PreviousBytes.Length, $NewBytes.Length) }
    $lastNewline = -1
    for ($index = $combined.Length - 1; $index -ge 0; $index--) {
        if ($combined[$index] -eq 10) { $lastNewline = $index; break }
    }
    if ($lastNewline -lt 0) {
        return [pscustomobject]@{ Lines = @(); PendingBytes = $combined }
    }
    $completeCount = $lastNewline + 1
    $text = $Utf8NoBom.GetString($combined, 0, $completeCount)
    $rawLines = @($text -split "`n")
    $lines = @()
    if ($rawLines.Count -gt 1) {
        foreach ($line in $rawLines[0..($rawLines.Count - 2)]) { $lines += $line.TrimEnd([char]13) }
    }
    $remainingCount = $combined.Length - $completeCount
    $remaining = New-Object byte[] $remainingCount
    if ($remainingCount -gt 0) { [System.Buffer]::BlockCopy($combined, $completeCount, $remaining, 0, $remainingCount) }
    return [pscustomobject]@{ Lines = $lines; PendingBytes = $remaining }
}

function Read-StreamRemainder {
    param([System.IO.Stream]$Stream)
    $memory = New-Object System.IO.MemoryStream
    try {
        $Stream.CopyTo($memory)
        return $memory.ToArray()
    }
    finally { $memory.Dispose() }
}

function Invoke-Monitor {
    param([string]$Id, [string]$CandidateTranscript, [int]$ParentId = 0)
    Initialize-Directory
    $globalWatcherCreated = $false
    $globalWatcherProbe = New-Object System.Threading.Mutex($false, ("Local\CodexNotifyGlobalWatcher-{0}" -f $InstanceKey), [ref]$globalWatcherCreated)
    $globalWatcherProbe.Dispose()
    if (-not $globalWatcherCreated) {
        Write-NotifyLog ("monitor skipped session={0} reason=global-watcher-running" -f $Id)
        return
    }
    $mutexName = "Local\CodexNotifyMonitor-" + $InstanceKey + "-" + (Get-TextHash $Id).Substring(0, 16)
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$created)
    if (-not $created) { $mutex.Dispose(); return }
    try {
        $path = Resolve-Transcript $Id $CandidateTranscript
        if ([string]::IsNullOrWhiteSpace($path)) { return }
        $stopFile = Get-MonitorStopFile $Id
        Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
        $offset = (Get-Item -LiteralPath $path).Length
        $pending = [byte[]]@()
        $started = Get-Date
        while (-not (Test-Path -LiteralPath $stopFile) -and ((Get-Date) - $started).TotalHours -lt 24) {
            if ($ParentId -gt 0 -and $null -eq (Get-Process -Id $ParentId -ErrorAction SilentlyContinue)) { break }
            try {
                $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    if ($stream.Length -lt $offset) { $offset = $stream.Length; $pending = [byte[]]@() }
                    if ($stream.Length -gt $offset) {
                        $stream.Seek($offset, [System.IO.SeekOrigin]::Begin) | Out-Null
                        $chunk = Read-StreamRemainder $stream
                        $offset = $stream.Position
                        $split = Split-CompleteUtf8Line $pending $chunk
                        $pending = [byte[]]$split.PendingBytes
                        foreach ($line in @($split.Lines)) {
                            try { Invoke-RolloutLine $line $Id }
                            catch { Write-NotifyLog ("monitor line-error session={0} error={1}" -f $Id, $_.Exception.Message) }
                        }
                    }
                }
                finally { $stream.Dispose() }
            }
            catch { Write-NotifyLog ("monitor read-error session={0} error={1}" -f $Id, $_.Exception.Message) }
            Start-Sleep -Milliseconds 200
        }
    }
    finally {
        Remove-Item -LiteralPath (Get-MonitorStopFile $Id) -Force -ErrorAction SilentlyContinue
        Clear-Waiting $Id
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Get-RolloutSessionId {
    param([string]$Path)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ($name -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') {
        return $Matches[1]
    }
    return "file-" + (Get-TextHash $Path).Substring(0, 20)
}

function Read-AppendedRollout {
    param(
        [string]$Path,
        [hashtable]$Offsets,
        [hashtable]$Pending,
        [switch]$InitializeOnly
    )
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($InitializeOnly) {
            $Offsets[$Path] = [long]$item.Length
            $Pending[$Path] = [byte[]]@()
            return
        }
        if (-not $Offsets.ContainsKey($Path)) {
            $Offsets[$Path] = [long]0
            $Pending[$Path] = [byte[]]@()
        }
        $offset = [long]$Offsets[$Path]
        if ($item.Length -lt $offset) {
            $Offsets[$Path] = [long]$item.Length
            $Pending[$Path] = [byte[]]@()
            Write-NotifyLog ("watch reset path={0} reason=file-truncated" -f $Path)
            return
        }
        if ($item.Length -le $offset) { return }
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $stream.Seek($offset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $chunk = Read-StreamRemainder $stream
            $Offsets[$Path] = [long]$stream.Position
        }
        finally { $stream.Dispose() }
        $split = Split-CompleteUtf8Line ([byte[]]$Pending[$Path]) $chunk
        $Pending[$Path] = [byte[]]$split.PendingBytes
        $id = Get-RolloutSessionId $Path
        foreach ($line in @($split.Lines)) {
            try { Invoke-RolloutLine $line $id }
            catch { Write-NotifyLog ("watch line-error session={0} error={1}" -f $id, $_.Exception.Message) }
        }
    }
    catch {
        Write-NotifyLog ("watch read-error path={0} error={1}" -f $Path, $_.Exception.Message)
    }
}

function Invoke-GlobalWatch {
    param([string]$WatcherReadyToken)
    Initialize-Directory
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, ("Local\CodexNotifyGlobalWatcher-{0}" -f $InstanceKey), [ref]$created)
    if (-not $created) {
        Write-NotifyLog "watch skipped reason=already-running"
        $mutex.Dispose()
        return
    }
    $watcher = $null
    $sourcePrefix = "CodexNotifyFile-{0}-{1}" -f $InstanceKey, $PID
    try {
        $readyMessage = if ([string]::IsNullOrWhiteSpace($WatcherReadyToken)) { "watch ready" } else { "watch ready token=$WatcherReadyToken" }
        Write-NotifyLog $readyMessage
        while (-not (Test-Path -LiteralPath $SessionsDirectory)) {
            Start-Sleep -Seconds 2
        }
        $offsets = @{}
        $pending = @{}
        foreach ($path in [System.IO.Directory]::EnumerateFiles($SessionsDirectory, "*.jsonl", [System.IO.SearchOption]::AllDirectories)) {
            Read-AppendedRollout $path $offsets $pending -InitializeOnly
        }
        $watcher = New-Object System.IO.FileSystemWatcher($SessionsDirectory, "*.jsonl")
        $watcher.IncludeSubdirectories = $true
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size
        Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier ($sourcePrefix + "-Created") | Out-Null
        Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier ($sourcePrefix + "-Changed") | Out-Null
        Register-ObjectEvent -InputObject $watcher -EventName Renamed -SourceIdentifier ($sourcePrefix + "-Renamed") | Out-Null
        $watcher.EnableRaisingEvents = $true
        $nextFallbackScan = (Get-Date).AddSeconds(5)
        Write-NotifyLog ("watch started files={0} mode=filesystem-watcher fallback_seconds=5" -f $offsets.Count)
        while ($true) {
            Wait-Event -Timeout 2 | Out-Null
            $changedPaths = @{}
            foreach ($eventRecord in @(Get-Event | Where-Object { $_.SourceIdentifier -like ($sourcePrefix + "-*") })) {
                try {
                    $path = [string]$eventRecord.SourceEventArgs.FullPath
                    if (-not [string]::IsNullOrWhiteSpace($path) -and [System.IO.Path]::GetExtension($path) -eq ".jsonl") {
                        $changedPaths[$path] = $true
                    }
                }
                finally {
                    Remove-Event -EventIdentifier $eventRecord.EventIdentifier -ErrorAction SilentlyContinue
                }
            }
            foreach ($path in @($changedPaths.Keys)) {
                Read-AppendedRollout $path $offsets $pending
            }
            if ((Get-Date) -ge $nextFallbackScan -and (Test-Path -LiteralPath $SessionsDirectory)) {
                $activePaths = @{}
                foreach ($path in [System.IO.Directory]::EnumerateFiles($SessionsDirectory, "*.jsonl", [System.IO.SearchOption]::AllDirectories)) {
                    $activePaths[$path] = $true
                    Read-AppendedRollout $path $offsets $pending
                }
                foreach ($knownPath in @($offsets.Keys)) {
                    if (-not $activePaths.ContainsKey($knownPath)) {
                        $offsets.Remove($knownPath)
                        $pending.Remove($knownPath)
                    }
                }
                $nextFallbackScan = (Get-Date).AddSeconds(5)
            }
        }
    }
    finally {
        if ($null -ne $watcher) {
            $watcher.EnableRaisingEvents = $false
            $watcher.Dispose()
        }
        Get-EventSubscriber -ErrorAction SilentlyContinue |
            Where-Object { $_.SourceIdentifier -like ($sourcePrefix + "-*") } |
            Unregister-Event -Force -ErrorAction SilentlyContinue
        Get-Event -ErrorAction SilentlyContinue |
            Where-Object { $_.SourceIdentifier -like ($sourcePrefix + "-*") } |
            Remove-Event -ErrorAction SilentlyContinue
        Write-NotifyLog "watch stopped"
        try { $mutex.ReleaseMutex() }
        catch { [System.Diagnostics.Debug]::WriteLine($_.Exception.Message) }
        $mutex.Dispose()
    }
}

function Invoke-WatchSupervisor {
    param([int]$RestartDelaySeconds = 2, [string]$WatcherReadyToken)
    while ($true) {
        try {
            Invoke-GlobalWatch $WatcherReadyToken
            return
        }
        catch {
            Write-NotifyLog ("watch restart error={0}" -f $_.Exception.ToString())
            if ($RestartDelaySeconds -gt 0) { Start-Sleep -Seconds $RestartDelaySeconds }
        }
    }
}

function Show-Help {
    @"
Codex task status sounds

  Version $Version

  .\notify.ps1 success
  .\notify.ps1 error
  .\notify.ps1 action
  .\notify.ps1 generate
  .\notify.ps1 watch
  .\notify.ps1 --silent
  .\notify.ps1 --unsilent
  .\notify.ps1 --version
"@
}

try {
    if ($ShowVersion) {
        Write-Output $Version
        exit 0
    }
    Initialize-Directory
    Write-NotifyLog ("invoke mode={0}" -f $Mode)
    if ($Silent -or $Mode -eq "--silent" -or $Mode -eq "silent") {
        Invoke-SilentModeUpdate $true
        Write-Output "Codex task sounds are muted."
        exit 0
    }
    if ($Unsilent -or $Mode -eq "--unsilent" -or $Mode -eq "unsilent") {
        Invoke-SilentModeUpdate $false
        Write-Output "Codex task sounds are enabled."
        exit 0
    }
    switch ($Mode.ToLowerInvariant()) {
        "success" { Invoke-StatusSound "success" $null }
        "error" { Invoke-StatusSound "error" $null }
        "action" { Invoke-StatusSound "action" $null }
        "play" {
            if ($Status -notmatch '^(success|error|action)$') { throw "Invalid status for play mode: $Status" }
            Invoke-StatusSound $Status $DedupeKey
        }
        "generate" { Initialize-Sound -Force }
        "stop" {
            $payload = Read-HookInput
            if ($null -eq $payload) {
                Write-NotifyLog "hook skipped mode=stop reason=missing-or-invalid-input"
            }
            else {
                $id = [string](Get-Setting $payload "session_id" "global")
                $turn = [string](Get-Setting $payload "turn_id" "unknown")
                $message = [string](Get-Setting $payload "last_assistant_message" "")
                Clear-Waiting $id
                if (Test-MessageNeedsInput $message) { Invoke-Waiting $id $turn "assistant-question" -AsynchronousSound }
                else { Invoke-HiddenStatusSound "success" ("success|{0}|{1}" -f $id, $turn) }
            }
        }
        "permission" {
            $payload = Read-HookInput
            if ($null -ne $payload) {
                Invoke-Waiting ([string](Get-Setting $payload "session_id" "global")) ([string](Get-Setting $payload "turn_id" "unknown")) "permission-request" -AsynchronousSound
            }
        }
        "session-start" {
            $payload = Read-HookInput
            if ($null -ne $payload) {
                $id = [string](Get-Setting $payload "session_id" "")
                $path = [string](Get-Setting $payload "transcript_path" "")
                if (-not [string]::IsNullOrWhiteSpace($id)) {
                    Remove-Item -LiteralPath (Get-MonitorStopFile $id) -Force -ErrorAction SilentlyContinue
                    $parentId = 0
                    try {
                        $parentId = [int](Get-CimInstance Win32_Process -Filter ("ProcessId = " + $PID)).ParentProcessId
                    }
                    catch { Write-NotifyLog ("parent process lookup failed error={0}" -f $_.Exception.Message) }
                    Invoke-HiddenNotifyProcess "monitor" $id $null $path $parentId
                }
            }
        }
        "session-end" {
            $payload = Read-HookInput
            if ($null -ne $payload) {
                $id = [string](Get-Setting $payload "session_id" "global")
                [System.IO.File]::WriteAllText((Get-MonitorStopFile $id), [DateTime]::UtcNow.ToString("o"), $Utf8NoBom)
                Clear-Waiting $id
            }
        }
        "monitor" { Invoke-Monitor $SessionId $TranscriptPath $ParentProcessId }
        "watch" { Invoke-WatchSupervisor -WatcherReadyToken $ReadyToken }
        "wait-loop" { Invoke-WaitLoop $SessionId $TurnId }
        "version" { Write-Output $Version }
        "--version" { Write-Output $Version }
        default { Show-Help }
    }
}
catch {
    Write-NotifyLog ("fatal mode={0} error={1}" -f $Mode, $_.Exception.ToString())
    if ($env:CODEX_NOTIFY_DEBUG -eq "1") { Write-Warning $_.Exception.Message }
    if ($Mode -match '^(?i)(stop|permission|session-start|session-end)$') { exit 0 }
    exit 1
}
