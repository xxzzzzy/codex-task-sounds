[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$TestHome = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-task-sounds-runtime-" + [Guid]::NewGuid().ToString("N"))
$SecondHome = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-task-sounds-runtime-路径 & %TEMP% O'Brien " + [Guid]::NewGuid().ToString("N"))
$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutSeconds = 8)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Get-WavePeak {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $peak = 0
    for ($index = 44; $index + 1 -lt $bytes.Length; $index += 2) {
        $sample = [Math]::Abs([int][System.BitConverter]::ToInt16($bytes, $index))
        if ($sample -gt $peak) { $peak = $sample }
    }
    return $peak
}

try {
    [System.IO.Directory]::CreateDirectory($TestHome) | Out-Null
    & (Join-Path $ProjectRoot "install.ps1") -CodexHome $TestHome -SkipStartup -NoStart
    $installedScript = Join-Path $TestHome "codex-task-sounds\notify.ps1"
    $settingsPath = Join-Path $TestHome "codex-task-sounds\config.json"
    $sessionsDirectory = Join-Path $TestHome "sessions"
    [System.IO.Directory]::CreateDirectory($sessionsDirectory) | Out-Null

    . $installedScript help | Out-Null
    Assert-True ($Version -eq "1.1.2") "runtime reports version 1.1.2"
    $reportedVersion = & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $installedScript --version
    Assert-True ($LASTEXITCODE -eq 0 -and $reportedVersion -eq "1.1.2") "the documented --version command succeeds"
    Assert-True ($null -eq (Get-Setting (Get-DefaultConfiguration) "waiting_repeat" $null)) "hook-only defaults omit repeating waiting loops"
    Assert-True ($null -eq (Get-Setting (Get-DefaultConfiguration) "error_on_tool_failure" $null)) "hook-only defaults omit watcher-only tool failure handling"
    Assert-True ([bool](Get-Setting (Get-DefaultConfiguration) "verify_task_completion" $false)) "fallback Stop Hook verification is enabled"
    Assert-True ([int](Get-Setting (Get-DefaultConfiguration) "completion_grace_ms" 0) -eq 3000) "hook-only completion grace covers measured terminal-write delays"
    Assert-True ([Math]::Abs((Get-WaitingVolume) - 0.65) -lt 0.0001) "action-required events use the documented independent volume"
    $defaultSuccessPeak = Get-WavePeak (Join-Path $TestHome "codex-task-sounds\sounds\success.wav")
    $defaultActionPeak = Get-WavePeak (Join-Path $TestHome "codex-task-sounds\sounds\action.wav")
    Assert-True ($defaultActionPeak -gt ($defaultSuccessPeak * 1.8)) "the default action-required sound is substantially more audible than the completion fallback"

    Assert-True (Test-MessageNeedsInput "请确认是否继续？") "Chinese confirmation questions are recognized as waiting for input"
    Assert-True (Test-MessageNeedsInput "Could you choose one?") "English questions are recognized as waiting for input"
    Assert-True (-not (Test-MessageNeedsInput "The task is complete.")) "declarative completion text is not treated as waiting for input"

    $waitingId = "runtime-session"
    $waitingPath = Get-WaitingFile $waitingId
    $waitingMarker = [pscustomobject]@{ session_id = $waitingId; turn_id = "new-turn"; started_at = [DateTime]::UtcNow.ToString("o") }
    Write-JsonAtomically $waitingPath $waitingMarker 10
    Clear-Waiting $waitingId "old-turn"
    Assert-True (Test-Path -LiteralPath $waitingPath) "a stale event cannot clear a newer waiting turn"
    Clear-Waiting $waitingId "new-turn"
    Assert-True (-not (Test-Path -LiteralPath $waitingPath)) "the matching wait state can be cleared"

    Set-Variable -Name MaxLogBytes -Scope Script -Value 256
    Set-Variable -Name MaxLogArchives -Scope Script -Value 2
    [System.IO.File]::WriteAllText($LogPath, ("x" * 300), $Utf8NoBom)
    Write-NotifyLog "rotation-test"
    Assert-True (Test-Path -LiteralPath ($LogPath + ".1")) "oversized log is rotated"
    Assert-True ([System.IO.File]::ReadAllText($LogPath, $Utf8NoBom).Contains("rotation-test")) "logging continues after rotation"
    foreach ($rotation in 1..4) {
        [System.IO.File]::WriteAllText($LogPath, (([string]$rotation) * 300), $Utf8NoBom)
        Write-NotifyLog ("rotation-cycle-{0}" -f $rotation)
    }
    Assert-True ((Test-Path -LiteralPath ($LogPath + ".1")) -and (Test-Path -LiteralPath ($LogPath + ".2"))) "configured log archives are retained across repeated rotations"
    Assert-True (-not (Test-Path -LiteralPath ($LogPath + ".3"))) "repeated log rotation never exceeds the configured archive count"

    $originalSettings = [System.IO.File]::ReadAllText($settingsPath, $Utf8NoBom)
    [System.IO.File]::WriteAllText($settingsPath, '{invalid-json', $Utf8NoBom)
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $installedScript --silent
    Assert-True ($LASTEXITCODE -ne 0) "invalid config is not silently overwritten"
    Assert-True ([System.IO.File]::ReadAllText($settingsPath, $Utf8NoBom) -eq '{invalid-json') "invalid config remains available for manual repair"
    [System.IO.File]::WriteAllText($settingsPath, $originalSettings, $Utf8NoBom)

    $soundsPath = Join-Path $TestHome "codex-task-sounds\sounds"
    Remove-Item -LiteralPath $soundsPath -Recurse -Force
    [System.IO.File]::WriteAllText($soundsPath, "blocking-file", $Utf8NoBom)
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $installedScript generate
    Assert-True ($LASTEXITCODE -ne 0) "manual generation returns a nonzero exit code on fatal error"
    Remove-Item -LiteralPath $soundsPath -Force
    [System.IO.Directory]::CreateDirectory($soundsPath) | Out-Null
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $installedScript generate
    Assert-True ($LASTEXITCODE -eq 0) "sound generation recovers after the filesystem error is fixed"

    $settings = [System.IO.File]::ReadAllText($settingsPath, $Utf8NoBom) | ConvertFrom-Json
    $settings | Add-Member -NotePropertyName volume -NotePropertyValue 0 -Force
    $settings | Add-Member -NotePropertyName waiting_volume -NotePropertyValue 0 -Force
    $settings | Add-Member -NotePropertyName silent -NotePropertyValue $false -Force
    Write-JsonAtomically $settingsPath $settings 20
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $installedScript generate
    Assert-True ($LASTEXITCODE -eq 0) "silent test sounds are generated"

    $hookSessionId = 'session with spaces & quote"'
    $hookTurnId = 'turn with spaces & quote"'
    $hookTranscript = Join-Path $sessionsDirectory ("rollout-hook-" + $hookSessionId.Replace('"', '') + ".jsonl")
    $hookMetadata = [pscustomobject]@{ type = "session_meta"; payload = [pscustomobject]@{ type = "session_meta"; id = $hookSessionId; source = "vscode" } } | ConvertTo-Json -Depth 10 -Compress
    $hookComplete = [pscustomobject]@{ type = "event_msg"; payload = [pscustomobject]@{ type = "task_complete"; turn_id = $hookTurnId; last_agent_message = "done" } } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText($hookTranscript, ($hookMetadata + [Environment]::NewLine + $hookComplete + [Environment]::NewLine), $Utf8NoBom)
    $hookPayload = [pscustomobject]@{ session_id = $hookSessionId; turn_id = $hookTurnId; transcript_path = $hookTranscript; last_assistant_message = "done" } | ConvertTo-Json -Compress
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $PowerShellExe
    $processInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $installedScript + '" stop'
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardInput = $true
    $hookProcess = New-Object System.Diagnostics.Process
    $hookProcess.StartInfo = $processInfo
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    [void]$hookProcess.Start()
    $hookProcess.StandardInput.Write($hookPayload)
    $hookProcess.StandardInput.Close()
    Assert-True ($hookProcess.WaitForExit(5000)) "Stop Hook returns"
    $stopwatch.Stop()
    Assert-True ($hookProcess.ExitCode -eq 0 -and $stopwatch.ElapsedMilliseconds -lt 2000) "Stop Hook dispatches sound asynchronously"
    $expectedHookKey = "success|{0}|{1}" -f $hookSessionId, $hookTurnId
    $expectedStamp = Join-Path $StateDirectory ("event-" + (Get-TextHash $expectedHookKey) + ".stamp")
    Assert-True (Wait-Until { Test-Path -LiteralPath $expectedStamp }) "quoted Hook identifiers survive child-process argument passing"

    $failedSessionId = "failed-stop-session"
    $failedTurnId = "failed-stop-turn"
    $failedTranscript = Join-Path $sessionsDirectory ("rollout-" + $failedSessionId + ".jsonl")
    $failedMetadata = [pscustomobject]@{ type = "session_meta"; payload = [pscustomobject]@{ type = "session_meta"; id = $failedSessionId; source = "vscode" } } | ConvertTo-Json -Depth 10 -Compress
    $failedEvent = [pscustomobject]@{ type = "event_msg"; payload = [pscustomobject]@{ type = "turn_failed"; turn_id = $failedTurnId; message = "simulated final failure" } } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText($failedTranscript, ($failedMetadata + [Environment]::NewLine + $failedEvent + [Environment]::NewLine), $Utf8NoBom)
    $failedPayload = [pscustomobject]@{ session_id = $failedSessionId; turn_id = $failedTurnId; transcript_path = $failedTranscript; last_assistant_message = "failed" } | ConvertTo-Json -Compress
    $failedInfo = New-Object System.Diagnostics.ProcessStartInfo
    $failedInfo.FileName = $PowerShellExe
    $failedInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $installedScript + '" stop'
    $failedInfo.UseShellExecute = $false
    $failedInfo.CreateNoWindow = $true
    $failedInfo.RedirectStandardInput = $true
    $failedProcess = New-Object System.Diagnostics.Process
    $failedProcess.StartInfo = $failedInfo
    [void]$failedProcess.Start()
    $failedProcess.StandardInput.Write($failedPayload)
    $failedProcess.StandardInput.Close()
    Assert-True ($failedProcess.WaitForExit(5000) -and $failedProcess.ExitCode -eq 0) "a final failure Stop Hook returns safely"
    $failedStamp = Join-Path $StateDirectory ("event-" + (Get-TextHash ("error|{0}|{1}" -f $failedSessionId, $failedTurnId)) + ".stamp")
    Assert-True (Wait-Until { Test-Path -LiteralPath $failedStamp }) "a verified final failure triggers the failure sound path"

    $delayedSessionId = "delayed-terminal-session"
    $delayedTurnId = "delayed-terminal-turn"
    $delayedTranscript = Join-Path $sessionsDirectory ("rollout-" + $delayedSessionId + ".jsonl")
    $delayedMetadata = [pscustomobject]@{ type = "session_meta"; payload = [pscustomobject]@{ type = "session_meta"; id = $delayedSessionId; source = "vscode" } } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText($delayedTranscript, ($delayedMetadata + [Environment]::NewLine), $Utf8NoBom)
    $delayedPayload = [pscustomobject]@{ session_id = $delayedSessionId; turn_id = $delayedTurnId; transcript_path = $delayedTranscript; last_assistant_message = "done" } | ConvertTo-Json -Compress
    $delayedInfo = New-Object System.Diagnostics.ProcessStartInfo
    $delayedInfo.FileName = $PowerShellExe
    $delayedInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $installedScript + '" stop'
    $delayedInfo.UseShellExecute = $false
    $delayedInfo.CreateNoWindow = $true
    $delayedInfo.RedirectStandardInput = $true
    $delayedProcess = New-Object System.Diagnostics.Process
    $delayedProcess.StartInfo = $delayedInfo
    [System.IO.File]::WriteAllText($LogPath, "", $Utf8NoBom)
    [void]$delayedProcess.Start()
    $delayedProcess.StandardInput.Write($delayedPayload)
    $delayedProcess.StandardInput.Close()
    Assert-True (Wait-Until { (Test-Path -LiteralPath $LogPath) -and ((Get-Content -LiteralPath $LogPath -Tail 10) -match 'invoke mode=stop') }) "the delayed-event timing starts after the Stop Hook is running"
    Start-Sleep -Milliseconds 2200
    $delayedComplete = [pscustomobject]@{ type = "event_msg"; payload = [pscustomobject]@{ type = "task_complete"; turn_id = $delayedTurnId; last_agent_message = "done" } } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::AppendAllText($delayedTranscript, ($delayedComplete + [Environment]::NewLine), $Utf8NoBom)
    Assert-True ($delayedProcess.WaitForExit(5000) -and $delayedProcess.ExitCode -eq 0) "a delayed terminal event is accepted before the Hook timeout"
    $delayedStamp = Join-Path $StateDirectory ("event-" + (Get-TextHash ("success|{0}|{1}" -f $delayedSessionId, $delayedTurnId)) + ".stamp")
    Assert-True (Wait-Until { Test-Path -LiteralPath $delayedStamp }) "a terminal event written after the former 1.5-second grace still triggers success"

    $intermediateSessionId = "intermediate-stop-session"
    $intermediateTurnId = "intermediate-stop-turn"
    $intermediateTranscript = Join-Path $sessionsDirectory ("rollout-" + $intermediateSessionId + ".jsonl")
    [System.IO.File]::WriteAllText($intermediateTranscript, ($hookMetadata + [Environment]::NewLine), $Utf8NoBom)
    $intermediatePayload = [pscustomobject]@{ session_id = $intermediateSessionId; turn_id = $intermediateTurnId; transcript_path = $intermediateTranscript; last_assistant_message = "still working" } | ConvertTo-Json -Compress
    $intermediateInfo = New-Object System.Diagnostics.ProcessStartInfo
    $intermediateInfo.FileName = $PowerShellExe
    $intermediateInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $installedScript + '" stop'
    $intermediateInfo.UseShellExecute = $false
    $intermediateInfo.CreateNoWindow = $true
    $intermediateInfo.RedirectStandardInput = $true
    $intermediateProcess = New-Object System.Diagnostics.Process
    $intermediateProcess.StartInfo = $intermediateInfo
    [void]$intermediateProcess.Start()
    $intermediateProcess.StandardInput.Write($intermediatePayload)
    $intermediateProcess.StandardInput.Close()
    Assert-True ($intermediateProcess.WaitForExit(5000) -and $intermediateProcess.ExitCode -eq 0) "an intermediate Stop Hook returns safely"
    $intermediateKey = "success|{0}|{1}" -f $intermediateSessionId, $intermediateTurnId
    $intermediateStamp = Join-Path $StateDirectory ("event-" + (Get-TextHash $intermediateKey) + ".stamp")
    Start-Sleep -Milliseconds 300
    Assert-True (-not (Test-Path -LiteralPath $intermediateStamp)) "an intermediate Stop without a terminal event stays quiet"

    $subagentId = "subagent-runtime-session"
    $subagentTurn = "subagent-runtime-turn"
    $subagentTranscript = Join-Path $sessionsDirectory ("rollout-" + $subagentId + ".jsonl")
    $subagentMetadata = [pscustomobject]@{ type = "session_meta"; payload = [pscustomobject]@{ type = "session_meta"; id = $subagentId; source = [pscustomobject]@{ subagent = [pscustomobject]@{ other = "worker" } } } } | ConvertTo-Json -Depth 10 -Compress
    $subagentComplete = [pscustomobject]@{ type = "event_msg"; payload = [pscustomobject]@{ type = "task_complete"; turn_id = $subagentTurn; last_agent_message = "done" } } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText($subagentTranscript, ($subagentMetadata + [Environment]::NewLine + $subagentComplete + [Environment]::NewLine), $Utf8NoBom)
    $subagentPayload = [pscustomobject]@{ session_id = $subagentId; turn_id = $subagentTurn; transcript_path = $subagentTranscript; last_assistant_message = "done" } | ConvertTo-Json -Compress
    $subagentInfo = New-Object System.Diagnostics.ProcessStartInfo
    $subagentInfo.FileName = $PowerShellExe
    $subagentInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $installedScript + '" stop'
    $subagentInfo.UseShellExecute = $false
    $subagentInfo.CreateNoWindow = $true
    $subagentInfo.RedirectStandardInput = $true
    $subagentProcess = New-Object System.Diagnostics.Process
    $subagentProcess.StartInfo = $subagentInfo
    [void]$subagentProcess.Start()
    $subagentProcess.StandardInput.Write($subagentPayload)
    $subagentProcess.StandardInput.Close()
    Assert-True ($subagentProcess.WaitForExit(5000) -and $subagentProcess.ExitCode -eq 0) "a subagent Stop Hook returns safely"
    $subagentStamp = Join-Path $StateDirectory ("event-" + (Get-TextHash ("success|{0}|{1}" -f $subagentId, $subagentTurn)) + ".stamp")
    Start-Sleep -Milliseconds 300
    Assert-True (-not (Test-Path -LiteralPath $subagentStamp)) "subagent completion does not play a global success sound"

    $runtimeHooks = [System.IO.File]::ReadAllText((Join-Path $TestHome "hooks.json"), $Utf8NoBom) | ConvertFrom-Json
    $permissionCommand = [string]@($runtimeHooks.hooks.PermissionRequest | ForEach-Object { $_.hooks })[0].command
    $permissionSessionId = '授权 session & % "quote"'
    $permissionTurnId = '等待 turn & % "quote"'
    $permissionPayload = [pscustomobject]@{ session_id = $permissionSessionId; turn_id = $permissionTurnId } | ConvertTo-Json -Compress
    $permissionBytes = $Utf8NoBom.GetBytes($permissionPayload)
    $permissionInfo = New-Object System.Diagnostics.ProcessStartInfo
    $permissionInfo.FileName = $env:ComSpec
    $permissionInfo.Arguments = '/d /s /c "' + $permissionCommand + '"'
    $permissionInfo.UseShellExecute = $false
    $permissionInfo.CreateNoWindow = $true
    $permissionInfo.RedirectStandardInput = $true
    $permissionProcess = New-Object System.Diagnostics.Process
    $permissionProcess.StartInfo = $permissionInfo
    $permissionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    [void]$permissionProcess.Start()
    $permissionProcess.StandardInput.BaseStream.Write($permissionBytes, 0, $permissionBytes.Length)
    $permissionProcess.StandardInput.BaseStream.Close()
    Assert-True ($permissionProcess.WaitForExit(5000)) "PermissionRequest Hook returns"
    $permissionStopwatch.Stop()
    Assert-True ($permissionProcess.ExitCode -eq 0 -and $permissionStopwatch.ElapsedMilliseconds -lt 2000) "PermissionRequest Hook dispatches sound asynchronously"
    $permissionKey = "action|{0}|{1}|start" -f $permissionSessionId, $permissionTurnId
    $permissionStamp = Join-Path $StateDirectory ("event-" + (Get-TextHash $permissionKey) + ".stamp")
    Assert-True (Wait-Until { Test-Path -LiteralPath $permissionStamp }) "UTF-8 Hook input reaches the action-required sound path"
    Assert-True (Test-WaitingForTurn $permissionSessionId $permissionTurnId) "UTF-8 Hook input preserves the waiting session and turn identifiers"
    Clear-Waiting $permissionSessionId $permissionTurnId

    $stampCountBefore = @(Get-ChildItem -LiteralPath $StateDirectory -Filter "event-*.stamp" -File).Count
    $emptyHookInfo = New-Object System.Diagnostics.ProcessStartInfo
    $emptyHookInfo.FileName = $PowerShellExe
    $emptyHookInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $installedScript + '" stop'
    $emptyHookInfo.UseShellExecute = $false
    $emptyHookInfo.CreateNoWindow = $true
    $emptyHookInfo.RedirectStandardInput = $true
    $emptyHookProcess = New-Object System.Diagnostics.Process
    $emptyHookProcess.StartInfo = $emptyHookInfo
    [void]$emptyHookProcess.Start()
    $emptyHookProcess.StandardInput.Close()
    Assert-True ($emptyHookProcess.WaitForExit(5000) -and $emptyHookProcess.ExitCode -eq 0) "an empty Stop Hook input is ignored safely"
    Start-Sleep -Milliseconds 300
    Assert-True (@(Get-ChildItem -LiteralPath $StateDirectory -Filter "event-*.stamp" -File).Count -eq $stampCountBefore) "empty Hook input does not create a false success event"

    $settings | Add-Member -NotePropertyName silent -NotePropertyValue $true -Force
    Write-JsonAtomically $settingsPath $settings 20
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $installedScript watch | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "legacy watch mode exits without starting a resident process"
    $legacyBackground = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine.IndexOf($installedScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $_.CommandLine -match '(?i)\b(watch|monitor|wait-loop)\b'
    })
    Assert-True ($legacyBackground.Count -eq 0) "hook-only runtime leaves no watcher, monitor, or waiting loop"

    [System.IO.Directory]::CreateDirectory((Join-Path $SecondHome "sessions")) | Out-Null
    & (Join-Path $ProjectRoot "install.ps1") -CodexHome $SecondHome -SkipStartup -NoStart
    $secondScript = Join-Path $SecondHome "codex-task-sounds\notify.ps1"

    $secondHooks = [System.IO.File]::ReadAllText((Join-Path $SecondHome "hooks.json"), $Utf8NoBom) | ConvertFrom-Json
    $sessionStartCommand = [string]@($secondHooks.hooks.SessionStart | ForEach-Object { $_.hooks })[0].command
    $sessionEndCommand = [string]@($secondHooks.hooks.SessionEnd | ForEach-Object { $_.hooks })[0].command
    $specialSessionId = "encoded-path-session"
    $specialPayload = [pscustomobject]@{ session_id = $specialSessionId } | ConvertTo-Json -Compress
    $sessionStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $sessionStartInfo.FileName = $env:ComSpec
    $sessionStartInfo.Arguments = '/d /s /c "' + $sessionStartCommand + '"'
    $sessionStartInfo.UseShellExecute = $false
    $sessionStartInfo.CreateNoWindow = $true
    $sessionStartInfo.RedirectStandardInput = $true
    $sessionStartProcess = New-Object System.Diagnostics.Process
    $sessionStartProcess.StartInfo = $sessionStartInfo
    [void]$sessionStartProcess.Start()
    $sessionStartProcess.StandardInput.Write($specialPayload)
    $sessionStartProcess.StandardInput.Close()
    Assert-True ($sessionStartProcess.WaitForExit(5000) -and $sessionStartProcess.ExitCode -eq 0) "SessionStart Hook returns in hook-only mode"
    Start-Sleep -Milliseconds 300
    $secondBackground = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine.IndexOf($secondScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $_.CommandLine -match '(?i)\b(watch|monitor|wait-loop)\b'
    })
    Assert-True ($secondBackground.Count -eq 0) "SessionStart does not create a per-session monitor"

    $secondStateDirectory = Join-Path $SecondHome "codex-task-sounds\notify-state"
    [System.IO.Directory]::CreateDirectory($secondStateDirectory) | Out-Null
    $secondWaitingPath = Join-Path $secondStateDirectory ("waiting-" + (Get-TextHash $specialSessionId).Substring(0, 20) + ".json")
    [System.IO.File]::WriteAllText($secondWaitingPath, (([pscustomobject]@{ session_id = $specialSessionId; turn_id = "special-turn" } | ConvertTo-Json -Compress)), $Utf8NoBom)
    $encodedHookInfo = New-Object System.Diagnostics.ProcessStartInfo
    $encodedHookInfo.FileName = $env:ComSpec
    $encodedHookInfo.Arguments = '/d /s /c "' + $sessionEndCommand + '"'
    $encodedHookInfo.UseShellExecute = $false
    $encodedHookInfo.CreateNoWindow = $true
    $encodedHookInfo.RedirectStandardInput = $true
    $encodedHookProcess = New-Object System.Diagnostics.Process
    $encodedHookProcess.StartInfo = $encodedHookInfo
    [void]$encodedHookProcess.Start()
    $encodedHookProcess.StandardInput.Write($specialPayload)
    $encodedHookProcess.StandardInput.Close()
    Assert-True ($encodedHookProcess.WaitForExit(5000) -and $encodedHookProcess.ExitCode -eq 0) "an encoded Hook executes through cmd.exe from a path containing Chinese, ampersand, percent, and apostrophe"
    Assert-True (-not (Test-Path -LiteralPath $secondWaitingPath)) "the encoded SessionEnd Hook reached the exact special-character installation path"

    & (Join-Path $ProjectRoot "uninstall.ps1") -CodexHome $SecondHome -SkipStartup

    & (Join-Path $ProjectRoot "install.ps1") -CodexHome $TestHome -SkipStartup
    $installedBackground = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine.IndexOf($installedScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $_.CommandLine -match '(?i)\b(watch|monitor|wait-loop)\b'
    })
    Assert-True ($installedBackground.Count -eq 0) "installer leaves no resident background process"
    & (Join-Path $ProjectRoot "uninstall.ps1") -CodexHome $TestHome -SkipStartup
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $TestHome "codex-task-sounds"))) "runtime install can be safely removed"

    Write-Output "Runtime test passed."
}
finally {
    foreach ($temporaryHome in @($TestHome, $SecondHome)) {
        if (-not (Test-Path -LiteralPath $temporaryHome)) { continue }
        $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedTest = [System.IO.Path]::GetFullPath($temporaryHome)
        if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
            [System.IO.Path]::GetFileName($resolvedTest) -like "codex-task-sounds-runtime-*") {
            Remove-Item -LiteralPath $resolvedTest -Recurse -Force
        }
    }
}
