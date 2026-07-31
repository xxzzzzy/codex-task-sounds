[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Mode = "help",
    [string]$SessionId,
    [string]$TurnId,
    [string]$TranscriptPath,
    [int]$ParentProcessId = 0,
    [switch]$Silent,
    [switch]$Unsilent,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
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
try { [Console]::InputEncoding = $Utf8NoBom }
catch { }

function Ensure-Directories {
    [System.IO.Directory]::CreateDirectory($SoundsDirectory) | Out-Null
    [System.IO.Directory]::CreateDirectory($StateDirectory) | Out-Null
}

function Write-NotifyLog {
    param([string]$Message)
    try {
        $line = "{0} pid={1} {2}{3}" -f [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss.fff"), $PID, $Message, [Environment]::NewLine
        [System.IO.File]::AppendAllText($LogPath, $line, $Utf8NoBom)
    }
    catch { }
}

function New-DefaultSettings {
    [pscustomobject][ordered]@{
        volume = 0.3
        success = $true
        error = $true
        waiting = $true
        waiting_interval = 10
        waiting_repeat = $true
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

function Read-Settings {
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return New-DefaultSettings
    }
    try {
        return [System.IO.File]::ReadAllText($SettingsPath, $Utf8NoBom) | ConvertFrom-Json
    }
    catch {
        return New-DefaultSettings
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

function Set-SilentMode {
    param([bool]$Value)
    $settings = Read-Settings
    $settings | Add-Member -NotePropertyName silent -NotePropertyValue $Value -Force
    $json = $settings | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($SettingsPath, $json + [Environment]::NewLine, $Utf8NoBom)
}

function Get-Volume {
    $volume = [double](Get-Setting (Read-Settings) "volume" 0.3)
    return [Math]::Max(0.0, [Math]::Min(1.0, $volume))
}

function Test-QuietHours {
    param([object]$Settings)
    $quiet = Get-Setting $Settings "quiet_hours" $null
    if (-not [bool](Get-Setting $quiet "enabled" $false)) {
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
    $settings = Read-Settings
    if ([bool](Get-Setting $settings "silent" $false) -or (Test-QuietHours $settings)) {
        return $false
    }
    switch ($Status) {
        "success" { return [bool](Get-Setting $settings "success" $true) }
        "error" { return [bool](Get-Setting $settings "error" $true) }
        "action" { return [bool](Get-Setting $settings "waiting" $true) }
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

function Ensure-Sounds {
    param([switch]$Force)
    Ensure-Directories
    $volume = Get-Volume
    $volumeText = $volume.ToString("0.0000", [Globalization.CultureInfo]::InvariantCulture)
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
    $mutex = New-Object System.Threading.Mutex($false, "Local\CodexNotifySoundBuilder", [ref]$created)
    try {
        if (-not $mutex.WaitOne(5000)) { return }
        try {
            Write-WaveSequence $successPath @(
                [pscustomobject]@{ Frequency = 523.25; Duration = 0.120; Gap = 0.040 },
                [pscustomobject]@{ Frequency = 659.25; Duration = 0.120; Gap = 0.000 }
            ) ($volume * 0.78)
            Write-WaveSequence $errorPath @(
                [pscustomobject]@{ Frequency = 329.63; Duration = 0.150; Gap = 0.040 },
                [pscustomobject]@{ Frequency = 261.63; Duration = 0.150; Gap = 0.000 }
            ) ($volume * 0.68)
            Write-WaveSequence $actionPath @(
                [pscustomobject]@{ Frequency = 523.25; Duration = 0.120; Gap = 0.080 },
                [pscustomobject]@{ Frequency = 659.25; Duration = 0.120; Gap = 0.080 },
                [pscustomobject]@{ Frequency = 523.25; Duration = 0.120; Gap = 0.000 }
            ) ($volume * 0.72)
            [System.IO.File]::WriteAllText($volumeMarker, $volumeText, $Utf8NoBom)
        }
        finally { $mutex.ReleaseMutex() }
    }
    finally { $mutex.Dispose() }
}

function Get-TextHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Utf8NoBom.GetBytes($Text)))).Replace("-", "").ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-BoostedCompletionSoundPath {
    Ensure-Directories
    $source = "C:\Windows\Media\Windows Notify Email.wav"
    $destination = Join-Path $SoundsDirectory "success-email-150.wav"
    if ((Test-Path -LiteralPath $destination) -and ((Get-Item -LiteralPath $destination).LastWriteTimeUtc -ge (Get-Item -LiteralPath $source).LastWriteTimeUtc)) {
        return $destination
    }

    $bytes = [System.IO.File]::ReadAllBytes($source)
    $offset = 12
    $dataOffset = -1
    while ($offset + 8 -le $bytes.Length) {
        $chunkId = [System.Text.Encoding]::ASCII.GetString($bytes, $offset, 4)
        $chunkSize = [System.BitConverter]::ToInt32($bytes, $offset + 4)
        if ($chunkId -eq "data") {
            $dataOffset = $offset + 8
            break
        }
        $offset += 8 + $chunkSize + ($chunkSize % 2)
    }
    if ($dataOffset -lt 0) { return $source }

    for ($index = $dataOffset; $index + 1 -lt $bytes.Length; $index += 2) {
        $sample = [System.BitConverter]::ToInt16($bytes, $index)
        $amplified = [Math]::Max(-32768, [Math]::Min(32767, [Math]::Round($sample * 1.5)))
        $encoded = [System.BitConverter]::GetBytes([int16]$amplified)
        $bytes[$index] = $encoded[0]
        $bytes[$index + 1] = $encoded[1]
    }
    [System.IO.File]::WriteAllBytes($destination, $bytes)
    return $destination
}

function Test-AndMarkEvent {
    param([string]$Key, [int]$WindowSeconds = 3)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $true }
    Ensure-Directories
    $path = Join-Path $StateDirectory ("event-" + (Get-TextHash $Key) + ".stamp")
    $created = $false
    $mutex = New-Object System.Threading.Mutex($false, "Local\CodexNotifyEventState", [ref]$created)
    try {
        if (-not $mutex.WaitOne(3000)) { return $false }
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
    Ensure-Sounds
    $fallbackPath = switch ($Status) {
        "success" { Join-Path $SoundsDirectory "success.wav" }
        "error" { Join-Path $SoundsDirectory "error.wav" }
        "action" { Join-Path $SoundsDirectory "action.wav" }
    }
    $customPath = switch ($Status) {
        "success" { Join-Path $SoundsDirectory "success-custom.mp3" }
        "error" { Join-Path $SoundsDirectory "error-custom.mp3" }
        default { $null }
    }
    $path = if (-not [string]::IsNullOrWhiteSpace($customPath) -and (Test-Path -LiteralPath $customPath)) {
        $customPath
    }
    else {
        $fallbackPath
    }
    try {
        Invoke-AudioFile $path (Get-Volume)
        Write-NotifyLog ("sound played status={0} path={1} key={2}" -f $Status, $path, $DedupeKey)
    }
    catch {
        if ($path -eq $fallbackPath) { throw }
        Write-NotifyLog ("sound fallback status={0} custom={1} error={2}" -f $Status, $path, $_.Exception.Message)
        Invoke-AudioFile $fallbackPath (Get-Volume)
        Write-NotifyLog ("sound played status={0} path={1} key={2}" -f $Status, $fallbackPath, $DedupeKey)
    }
}

function Read-HookInput {
    $raw = [Console]::In.ReadToEnd()
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

function Quote-ProcessArgument {
    param([string]$Value)
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Start-HiddenNotifyProcess {
    param([string]$ChildMode, [string]$ChildSessionId, [string]$ChildTurnId, [string]$ChildTranscriptPath, [int]$ChildParentProcessId = 0)
    $parts = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", (Quote-ProcessArgument $ScriptPath), $ChildMode)
    if (-not [string]::IsNullOrWhiteSpace($ChildSessionId)) { $parts += @("-SessionId", (Quote-ProcessArgument $ChildSessionId)) }
    if (-not [string]::IsNullOrWhiteSpace($ChildTurnId)) { $parts += @("-TurnId", (Quote-ProcessArgument $ChildTurnId)) }
    if (-not [string]::IsNullOrWhiteSpace($ChildTranscriptPath)) { $parts += @("-TranscriptPath", (Quote-ProcessArgument $ChildTranscriptPath)) }
    if ($ChildParentProcessId -gt 0) { $parts += @("-ParentProcessId", [string]$ChildParentProcessId) }
    Start-Process -FilePath $PowerShellPath -ArgumentList ($parts -join " ") -WindowStyle Hidden | Out-Null
}

function Clear-Waiting {
    param([string]$Id)
    Remove-Item -LiteralPath (Get-WaitingFile $Id) -Force -ErrorAction SilentlyContinue
}

function Start-Waiting {
    param([string]$Id, [string]$ActiveTurnId, [string]$Reason = "user-input")
    $settings = Read-Settings
    if (-not [bool](Get-Setting $settings "waiting" $true)) { return }
    Ensure-Directories
    if ([string]::IsNullOrWhiteSpace($Id)) { $Id = "global" }
    if ([string]::IsNullOrWhiteSpace($ActiveTurnId)) { $ActiveTurnId = "unknown" }
    $marker = [pscustomobject][ordered]@{
        session_id = $Id
        turn_id = $ActiveTurnId
        reason = $Reason
        started_at = [DateTime]::UtcNow.ToString("o")
    }
    [System.IO.File]::WriteAllText((Get-WaitingFile $Id), ($marker | ConvertTo-Json -Compress), $Utf8NoBom)
    Invoke-StatusSound "action" ("action|{0}|{1}|start" -f $Id, $ActiveTurnId)
    if ([bool](Get-Setting $settings "waiting_repeat" $true)) {
        Start-HiddenNotifyProcess "wait-loop" $Id $ActiveTurnId $null 0
    }
}

function Invoke-WaitLoop {
    param([string]$Id, [string]$ActiveTurnId)
    Ensure-Directories
    $mutexName = "Local\CodexNotifyWait-" + (Get-TextHash ($Id + "|" + $ActiveTurnId)).Substring(0, 24)
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$created)
    if (-not $created) { $mutex.Dispose(); return }
    try {
        $settings = Read-Settings
        $interval = [Math]::Max(8, [Math]::Min(60, [int](Get-Setting $settings "waiting_interval" 10)))
        $maxSeconds = [Math]::Max($interval, [Math]::Min(3600, [int](Get-Setting $settings "waiting_max_seconds" 120)))
        $started = Get-Date
        $tick = 0
        while ((Test-Path -LiteralPath (Get-WaitingFile $Id)) -and ((Get-Date) - $started).TotalSeconds -lt $maxSeconds) {
            Start-Sleep -Seconds $interval
            if (-not (Test-Path -LiteralPath (Get-WaitingFile $Id))) { break }
            $tick++
            Invoke-StatusSound "action" ("action|{0}|{1}|tick-{2}" -f $Id, $ActiveTurnId, $tick)
        }
    }
    finally {
        Remove-Item -LiteralPath (Get-WaitingFile $Id) -Force -ErrorAction SilentlyContinue
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Test-MessageNeedsInput {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    if (-not [bool](Get-Setting (Read-Settings) "detect_question_waiting" $true)) { return $false }
    $pattern = '(?is)((?:请(?:确认|选择|回复|告诉我|提供|决定)|需要你(?:确认|选择|回复|提供|决定)|你(?:希望|想要|倾向于)|是否(?:需要|要|可以)|要不要|哪(?:个|一种)|可以吗|方便吗)\s*[。.!！?？]*\s*$)'
    return $Message -match $pattern
}

function Resolve-Transcript {
    param([string]$Id, [string]$Candidate)
    if (-not [string]::IsNullOrWhiteSpace($Candidate) -and (Test-Path -LiteralPath $Candidate)) {
        return (Get-Item -LiteralPath $Candidate).FullName
    }
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $SessionsDirectory) {
            $match = Get-ChildItem -LiteralPath $SessionsDirectory -Recurse -Filter ("*" + $Id + "*.jsonl") -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($null -ne $match) { return $match.FullName }
        }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Test-ToolOutputFailed {
    param([object]$Payload)
    if (-not [bool](Get-Setting (Read-Settings) "error_on_tool_failure" $true)) { return $false }
    $text = $Payload | ConvertTo-Json -Depth 20 -Compress
    return $text -match '(?is)"isError"\s*:\s*true|Script failed|Command failed|Exit code:\s*(?!0\b)\d+|process exited with (?:status|code)\s*(?!0\b)\d+'
}

function Process-RolloutLine {
    param([string]$Line, [string]$Id)
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    try { $item = $Line | ConvertFrom-Json }
    catch { return }
    if ([string]$item.method -eq "turn/completed") {
        $turn = Get-Setting $item.params "turn" $null
        $completedTurnId = [string](Get-Setting $turn "id" "unknown")
        $status = [string](Get-Setting $turn "status" "completed")
        Clear-Waiting $Id
        if ($status -match '(?i)failed|interrupted|cancelled|canceled|aborted') {
            Invoke-StatusSound "error" ("error|{0}|{1}|{2}" -f $Id, $completedTurnId, $status)
        }
        return
    }
    $topType = [string](Get-Setting $item "type" "")
    $payload = Get-Setting $item "payload" $null
    $payloadType = [string](Get-Setting $payload "type" "")
    $activeTurnId = [string](Get-Setting $payload "turn_id" "unknown")
    if ($topType -eq "event_msg") {
        if ($payloadType -match '^(error|stream_error|turn_aborted|task_failed|turn_failed)$') {
            Clear-Waiting $Id
            Invoke-StatusSound "error" ("error|{0}|{1}|{2}" -f $Id, $activeTurnId, $payloadType)
            return
        }
        if ($payloadType -match '^(exec_approval_request|apply_patch_approval_request|request_user_input|elicitation_request|mcp_elicitation_request)$') {
            Start-Waiting $Id $activeTurnId $payloadType
            return
        }
        if ($payloadType -eq 'task_complete') {
            $completedTurnId = [string](Get-Setting $payload "turn_id" "unknown")
            $message = [string](Get-Setting $payload "last_agent_message" "")
            Clear-Waiting $Id
            if (Test-MessageNeedsInput $message) {
                Start-Waiting $Id $completedTurnId "assistant-question"
            }
            else {
                Invoke-StatusSound "success" ("success|{0}|{1}" -f $Id, $completedTurnId)
            }
            return
        }
        if ($payloadType -eq 'turn_complete') { Clear-Waiting $Id; return }
        if ($payloadType -match '^(user_message|agent_reasoning|agent_message|task_started)$') { Clear-Waiting $Id; return }
        if ($payloadType -match 'tool_call_end$' -and (Test-ToolOutputFailed $payload)) {
            Invoke-StatusSound "error" ("tool-error|{0}|{1}|{2}" -f $Id, $activeTurnId, $payloadType)
            return
        }
    }
    if ($topType -eq "response_item") {
        if ($payloadType -eq "custom_tool_call") {
            $name = [string](Get-Setting $payload "name" "")
            if ($name -match '^(request_user_input|request_permissions)$') { Start-Waiting $Id $activeTurnId $name }
            return
        }
        if ($payloadType -eq "custom_tool_call_output") {
            Clear-Waiting $Id
            if (Test-ToolOutputFailed $payload) {
                Invoke-StatusSound "error" ("tool-error|{0}|{1}" -f $Id, [string](Get-Setting $payload "call_id" "unknown"))
            }
        }
    }
}

function Invoke-Monitor {
    param([string]$Id, [string]$CandidateTranscript, [int]$ParentId = 0)
    Ensure-Directories
    $mutexName = "Local\CodexNotifyMonitor-" + (Get-TextHash $Id).Substring(0, 24)
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$created)
    if (-not $created) { $mutex.Dispose(); return }
    try {
        $path = Resolve-Transcript $Id $CandidateTranscript
        if ([string]::IsNullOrWhiteSpace($path)) { return }
        $stopFile = Get-MonitorStopFile $Id
        Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
        $offset = (Get-Item -LiteralPath $path).Length
        $pending = ""
        $started = Get-Date
        while (-not (Test-Path -LiteralPath $stopFile) -and ((Get-Date) - $started).TotalHours -lt 24) {
            if ($ParentId -gt 0 -and $null -eq (Get-Process -Id $ParentId -ErrorAction SilentlyContinue)) { break }
            try {
                $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    if ($stream.Length -lt $offset) { $offset = 0; $pending = "" }
                    if ($stream.Length -gt $offset) {
                        $stream.Seek($offset, [System.IO.SeekOrigin]::Begin) | Out-Null
                        $reader = New-Object System.IO.StreamReader($stream, $Utf8NoBom, $true, 4096, $true)
                        try { $chunk = $reader.ReadToEnd(); $offset = $stream.Position }
                        finally { $reader.Dispose() }
                        $combined = $pending + $chunk
                        $parts = $combined -split "`r?`n", -1
                        if ($combined -match "`r?`n$") { $pending = "" }
                        else {
                            $pending = $parts[-1]
                            if ($parts.Count -gt 1) { $parts = $parts[0..($parts.Count - 2)] }
                            else { $parts = @() }
                        }
                        foreach ($line in $parts) { Process-RolloutLine $line $Id }
                    }
                }
                finally { $stream.Dispose() }
            }
            catch { }
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
            $Pending[$Path] = ""
            return
        }
        if (-not $Offsets.ContainsKey($Path)) {
            $Offsets[$Path] = [long]0
            $Pending[$Path] = ""
        }
        $offset = [long]$Offsets[$Path]
        if ($item.Length -lt $offset) {
            $offset = 0
            $Pending[$Path] = ""
        }
        if ($item.Length -le $offset) { return }
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $stream.Seek($offset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $reader = New-Object System.IO.StreamReader($stream, $Utf8NoBom, $true, 4096, $true)
            try { $chunk = $reader.ReadToEnd() }
            finally { $reader.Dispose() }
            $Offsets[$Path] = [long]$stream.Position
        }
        finally { $stream.Dispose() }
        $combined = [string]$Pending[$Path] + $chunk
        $parts = $combined -split "`r?`n", -1
        if ($combined -match "`r?`n$") {
            $Pending[$Path] = ""
        }
        else {
            $Pending[$Path] = $parts[-1]
            if ($parts.Count -gt 1) { $parts = $parts[0..($parts.Count - 2)] }
            else { $parts = @() }
        }
        $id = Get-RolloutSessionId $Path
        foreach ($line in $parts) { Process-RolloutLine $line $id }
    }
    catch {
        Write-NotifyLog ("watch read-error path={0} error={1}" -f $Path, $_.Exception.Message)
    }
}

function Invoke-GlobalWatch {
    Ensure-Directories
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, "Local\CodexNotifyGlobalWatcher", [ref]$created)
    if (-not $created) {
        Write-NotifyLog "watch skipped reason=already-running"
        $mutex.Dispose()
        return
    }
    try {
        $offsets = @{}
        $pending = @{}
        if (Test-Path -LiteralPath $SessionsDirectory) {
            foreach ($path in [System.IO.Directory]::EnumerateFiles($SessionsDirectory, "*.jsonl", [System.IO.SearchOption]::AllDirectories)) {
                Read-AppendedRollout $path $offsets $pending -InitializeOnly
            }
        }
        Write-NotifyLog ("watch started files={0}" -f $offsets.Count)
        while ($true) {
            if (Test-Path -LiteralPath $SessionsDirectory) {
                foreach ($path in [System.IO.Directory]::EnumerateFiles($SessionsDirectory, "*.jsonl", [System.IO.SearchOption]::AllDirectories)) {
                    Read-AppendedRollout $path $offsets $pending
                }
            }
            Start-Sleep -Milliseconds 250
        }
    }
    finally {
        Write-NotifyLog "watch stopped"
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Resolve-LegacyNotifier {
    $root = Join-Path $env:LOCALAPPDATA "OpenAI\Codex"
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $candidates = @()
    $runtimeRoot = Join-Path $root "runtimes\cua_node"
    if (Test-Path -LiteralPath $runtimeRoot) {
        foreach ($runtime in Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue) {
            $candidate = Join-Path $runtime.FullName "bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe"
            if (Test-Path -LiteralPath $candidate) { $candidates += Get-Item -LiteralPath $candidate }
        }
    }
    $patchedRoot = Join-Path $root "patched-copies"
    if ($candidates.Count -eq 0 -and (Test-Path -LiteralPath $patchedRoot)) {
        foreach ($copy in Get-ChildItem -LiteralPath $patchedRoot -Directory -ErrorAction SilentlyContinue) {
            $candidate = Join-Path $copy.FullName "app\resources\cua_node\bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe"
            if (Test-Path -LiteralPath $candidate) { $candidates += Get-Item -LiteralPath $candidate }
        }
    }
    return $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}

function Invoke-LegacyNotify {
    param([string[]]$Arguments)
    if ($null -ne $Arguments -and $Arguments.Count -gt 0) {
        try {
            $payload = $Arguments[-1] | ConvertFrom-Json
            $payloadType = [string](Get-Setting $payload "type" "")
            $wrappedTurnId = [string](Get-Setting $payload "turn_id" "")
            $wrappedThreadId = [string](Get-Setting $payload "thread_id" "")
            if ($payloadType -eq "agent-turn-complete") {
                $id = [string](Get-Setting $payload "thread-id" "global")
                $turn = [string](Get-Setting $payload "turn-id" "unknown")
                $message = [string](Get-Setting $payload "last-assistant-message" "")
                Clear-Waiting $id
                if (Test-MessageNeedsInput $message) { Start-Waiting $id $turn "assistant-question" }
                else { Invoke-StatusSound "success" ("success|{0}|{1}" -f $id, $turn) }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($wrappedTurnId)) {
                $id = if ([string]::IsNullOrWhiteSpace($wrappedThreadId)) { "global" } else { $wrappedThreadId }
                Clear-Waiting $id
                Invoke-StatusSound "success" ("success|{0}|{1}" -f $id, $wrappedTurnId)
            }
        }
        catch { }
    }
    $legacy = Resolve-LegacyNotifier
    if (-not [string]::IsNullOrWhiteSpace($legacy)) { & $legacy @Arguments 2>$null | Out-Null }
}

function Show-Help {
    @"
Codex task status sounds

  .\notify.ps1 success
  .\notify.ps1 error
  .\notify.ps1 action
  .\notify.ps1 generate
  .\notify.ps1 watch
  .\notify.ps1 --silent
  .\notify.ps1 --unsilent
"@
}

try {
    Ensure-Directories
    Write-NotifyLog ("invoke mode={0}" -f $Mode)
    if ($Silent -or $Mode -eq "--silent" -or $Mode -eq "silent") {
        Set-SilentMode $true
        Write-Output "Codex task sounds are muted."
        exit 0
    }
    if ($Unsilent -or $Mode -eq "--unsilent" -or $Mode -eq "unsilent") {
        Set-SilentMode $false
        Write-Output "Codex task sounds are enabled."
        exit 0
    }
    switch ($Mode.ToLowerInvariant()) {
        "success" { Invoke-StatusSound "success" $null }
        "error" { Invoke-StatusSound "error" $null }
        "action" { Invoke-StatusSound "action" $null }
        "generate" { Ensure-Sounds -Force }
        "stop" {
            $payload = Read-HookInput
            if ($null -eq $payload) {
                Invoke-StatusSound "success" $null
            }
            else {
                $id = [string](Get-Setting $payload "session_id" "global")
                $turn = [string](Get-Setting $payload "turn_id" "unknown")
                $message = [string](Get-Setting $payload "last_assistant_message" "")
                Clear-Waiting $id
                if (Test-MessageNeedsInput $message) { Start-Waiting $id $turn "assistant-question" }
                else { Invoke-StatusSound "success" ("success|{0}|{1}" -f $id, $turn) }
            }
        }
        "permission" {
            $payload = Read-HookInput
            if ($null -ne $payload) {
                Start-Waiting ([string](Get-Setting $payload "session_id" "global")) ([string](Get-Setting $payload "turn_id" "unknown")) "permission-request"
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
                    catch { }
                    Start-HiddenNotifyProcess "monitor" $id $null $path $parentId
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
        "watch" { Invoke-GlobalWatch }
        "wait-loop" { Invoke-WaitLoop $SessionId $TurnId }
        "legacy" { Invoke-LegacyNotify $RemainingArguments }
        default { Show-Help }
    }
}
catch {
    Write-NotifyLog ("fatal mode={0} error={1}" -f $Mode, $_.Exception.ToString())
    if ($env:CODEX_NOTIFY_DEBUG -eq "1") { Write-Warning $_.Exception.Message }
    exit 0
}
