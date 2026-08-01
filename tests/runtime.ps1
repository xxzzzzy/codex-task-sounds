[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$TestHome = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-task-sounds-runtime-" + [Guid]::NewGuid().ToString("N"))
$SecondHome = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-task-sounds-runtime-路径 & %TEMP% O'Brien " + [Guid]::NewGuid().ToString("N"))
$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$watcherProcess = $null
$secondWatcherProcess = $null
$duplicateWatcherProcess = $null

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

try {
    [System.IO.Directory]::CreateDirectory($TestHome) | Out-Null
    & (Join-Path $ProjectRoot "install.ps1") -CodexHome $TestHome -SkipStartup -NoStart
    $installedScript = Join-Path $TestHome "codex-task-sounds\notify.ps1"
    $settingsPath = Join-Path $TestHome "codex-task-sounds\config.json"

    . $installedScript help | Out-Null
    Assert-True ($Version -eq "1.0.1") "runtime reports version 1.0.1"
    Assert-True (-not [bool](Get-Setting (Get-DefaultConfiguration) "waiting_repeat" $true)) "fallback waiting_repeat is disabled"

    $documentationPayload = [pscustomobject]@{
        output = @([pscustomobject]@{ type = "input_text"; text = "Documentation may contain the phrase Command failed inline without representing a failure." })
    }
    Assert-True (-not (Test-ToolOutputFailed $documentationPayload)) "inline diagnostic wording does not create a false failure"
    $failedPayload = [pscustomobject]@{
        output = @([pscustomobject]@{ type = "input_text"; text = "Script failed`nExit code: 7" })
    }
    Assert-True (Test-ToolOutputFailed $failedPayload) "rendered nonzero tool failure is detected"
    Assert-True (Test-ToolOutputFailed ([pscustomobject]@{ isError = $true })) "structured tool failure is detected"
    Assert-True (Test-MessageNeedsInput "请确认是否继续？") "Chinese confirmation questions are recognized as waiting for input"
    Assert-True (Test-MessageNeedsInput "Could you choose one?") "English questions are recognized as waiting for input"
    Assert-True (-not (Test-MessageNeedsInput "The task is complete.")) "declarative completion text is not treated as waiting for input"

    $utf8Line = '{"message":"半写入中文"}' + [Environment]::NewLine
    $utf8Bytes = $Utf8NoBom.GetBytes($utf8Line)
    $multibyteIndex = 0
    for ($index = 0; $index -lt $utf8Bytes.Length; $index++) {
        if ($utf8Bytes[$index] -ge 128) { $multibyteIndex = $index; break }
    }
    $firstChunk = New-Object byte[] ($multibyteIndex + 1)
    [System.Buffer]::BlockCopy($utf8Bytes, 0, $firstChunk, 0, $firstChunk.Length)
    $secondChunk = New-Object byte[] ($utf8Bytes.Length - $firstChunk.Length)
    [System.Buffer]::BlockCopy($utf8Bytes, $firstChunk.Length, $secondChunk, 0, $secondChunk.Length)
    $firstSplit = Split-CompleteUtf8Line ([byte[]]@()) $firstChunk
    Assert-True (@($firstSplit.Lines).Count -eq 0) "a partial UTF-8 line is not decoded early"
    $secondSplit = Split-CompleteUtf8Line ([byte[]]$firstSplit.PendingBytes) $secondChunk
    Assert-True (@($secondSplit.Lines).Count -eq 1 -and $secondSplit.Lines[0] -eq '{"message":"半写入中文"}') "split UTF-8 characters are reconstructed without corruption"

    $originalGlobalWatch = (Get-Item Function:\Invoke-GlobalWatch).ScriptBlock
    $script:SupervisorAttempts = 0
    Set-Item Function:\Invoke-GlobalWatch -Value {
        $script:SupervisorAttempts++
        if ($script:SupervisorAttempts -eq 1) { throw "simulated watcher failure" }
    }
    Invoke-WatchSupervisor 0
    Assert-True ($script:SupervisorAttempts -eq 2) "watch supervisor restarts after a transient failure"
    Set-Item Function:\Invoke-GlobalWatch -Value $originalGlobalWatch

    $sessionsDirectory = Join-Path $TestHome "sessions"
    [System.IO.Directory]::CreateDirectory($sessionsDirectory) | Out-Null
    $lineTestPath = Join-Path $sessionsDirectory ("rollout-lines-" + [Guid]::NewGuid().ToString() + ".jsonl")
    $lineOne = [pscustomobject]@{ type = "event_msg"; payload = [pscustomobject]@{ type = "task_complete"; turn_id = "line-one"; last_agent_message = "done" } } | ConvertTo-Json -Depth 10 -Compress
    $lineTwo = [pscustomobject]@{ type = "event_msg"; payload = [pscustomobject]@{ type = "task_complete"; turn_id = "line-two"; last_agent_message = "done" } } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText($lineTestPath, ($lineOne + [Environment]::NewLine + $lineTwo + [Environment]::NewLine), $Utf8NoBom)
    $originalHiddenStatusSound = (Get-Item Function:\Invoke-HiddenStatusSound).ScriptBlock
    $script:LineProcessingCalls = 0
    Set-Item Function:\Invoke-HiddenStatusSound -Value {
        param([string]$ChildStatus, [string]$ChildDedupeKey)
        $null = $ChildStatus
        $null = $ChildDedupeKey
        $script:LineProcessingCalls++
        if ($script:LineProcessingCalls -eq 1) { throw "simulated playback failure" }
    }
    $lineOffsets = @{}
    $linePending = @{}
    Read-AppendedRollout $lineTestPath $lineOffsets $linePending
    Assert-True ($script:LineProcessingCalls -eq 2) "one malformed or failed rollout event does not discard later lines"
    Invoke-RolloutLine $lineTwo (Get-RolloutSessionId $lineTestPath)
    Assert-True ($script:LineProcessingCalls -eq 2) "two monitors process an identical rollout line only once"
    Set-Item Function:\Invoke-HiddenStatusSound -Value $originalHiddenStatusSound
    $claimCountBefore = @(Get-ChildItem -LiteralPath $StateDirectory -Filter "event-*.stamp" -File).Count
    $uninterestingLine = [pscustomobject]@{ type = "event_msg"; payload = [pscustomobject]@{ type = "agent_reasoning"; turn_id = "noise-only" } } | ConvertTo-Json -Depth 10 -Compress
    Invoke-RolloutLine $uninterestingLine "noise-session"
    Assert-True (@(Get-ChildItem -LiteralPath $StateDirectory -Filter "event-*.stamp" -File).Count -eq $claimCountBefore) "uninteresting rollout lines do not create persistent deduplication files"

    $truncatePath = Join-Path $sessionsDirectory ("rollout-truncate-" + [Guid]::NewGuid().ToString() + ".jsonl")
    $longHistoricalLine = [pscustomobject]@{ type = "event_msg"; payload = [pscustomobject]@{ type = "task_complete"; turn_id = "historical"; last_agent_message = ("old" * 200) } } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText($truncatePath, ($longHistoricalLine + [Environment]::NewLine), $Utf8NoBom)
    $truncateOffsets = @{}
    $truncatePending = @{}
    Read-AppendedRollout $truncatePath $truncateOffsets $truncatePending -InitializeOnly
    $script:TruncateProcessingCalls = 0
    Set-Item Function:\Invoke-HiddenStatusSound -Value {
        param([string]$ChildStatus, [string]$ChildDedupeKey)
        $null = $ChildStatus
        $null = $ChildDedupeKey
        $script:TruncateProcessingCalls++
    }
    $replacementHistory = [pscustomobject]@{ type = "event_msg"; payload = [pscustomobject]@{ type = "task_complete"; turn_id = "replacement-history"; last_agent_message = "old" } } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText($truncatePath, ($replacementHistory + [Environment]::NewLine), $Utf8NoBom)
    Read-AppendedRollout $truncatePath $truncateOffsets $truncatePending
    Assert-True ($script:TruncateProcessingCalls -eq 0) "file truncation does not replay replacement history"
    $postTruncateLine = [pscustomobject]@{ type = "event_msg"; payload = [pscustomobject]@{ type = "task_complete"; turn_id = "post-truncate"; last_agent_message = "new" } } | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::AppendAllText($truncatePath, ($postTruncateLine + [Environment]::NewLine), $Utf8NoBom)
    Read-AppendedRollout $truncatePath $truncateOffsets $truncatePending
    Assert-True ($script:TruncateProcessingCalls -eq 1) "new events after truncation are still processed"
    Set-Item Function:\Invoke-HiddenStatusSound -Value $originalHiddenStatusSound

    $waitingId = "runtime-session"
    $waitingPath = Get-WaitingFile $waitingId
    $waitingMarker = [pscustomobject]@{ session_id = $waitingId; turn_id = "new-turn"; started_at = [DateTime]::UtcNow.ToString("o") }
    Write-JsonAtomically $waitingPath $waitingMarker 10
    Clear-Waiting $waitingId "old-turn"
    Assert-True (Test-Path -LiteralPath $waitingPath) "an old wait loop cannot clear a newer turn"
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
    $settings | Add-Member -NotePropertyName silent -NotePropertyValue $false -Force
    Write-JsonAtomically $settingsPath $settings 20
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $installedScript generate
    Assert-True ($LASTEXITCODE -eq 0) "silent test sounds are generated"

    $hookSessionId = 'session with spaces & quote"'
    $hookTurnId = 'turn with spaces & quote"'
    $hookPayload = [pscustomobject]@{ session_id = $hookSessionId; turn_id = $hookTurnId; last_assistant_message = "done" } | ConvertTo-Json -Compress
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
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $installedScript + '" watch'
    $watcherProcess = Start-Process -FilePath $PowerShellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Assert-True (Wait-Until { (Test-Path -LiteralPath $LogPath) -and [System.IO.File]::ReadAllText($LogPath, $Utf8NoBom).Contains("mode=filesystem-watcher") }) "filesystem watcher starts"

    $duplicateWatcherProcess = Start-Process -FilePath $PowerShellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Assert-True ($duplicateWatcherProcess.WaitForExit(5000)) "a duplicate watcher exits instead of running beside the owner"
    Assert-True (-not $watcherProcess.HasExited -and $duplicateWatcherProcess.ExitCode -eq 0) "the watcher mutex keeps the original process and rejects the duplicate cleanly"
    $duplicateWatcherProcess = $null
    $monitorSkipWatch = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Monitor "global-watch-owned-session" $null 0
    $monitorSkipWatch.Stop()
    Assert-True ($monitorSkipWatch.ElapsedMilliseconds -lt 2000) "a per-session monitor exits quickly while the global watcher owns the instance"

    [System.IO.Directory]::CreateDirectory((Join-Path $SecondHome "sessions")) | Out-Null
    & (Join-Path $ProjectRoot "install.ps1") -CodexHome $SecondHome -SkipStartup -NoStart
    $secondScript = Join-Path $SecondHome "codex-task-sounds\notify.ps1"
    $secondLog = Join-Path $SecondHome "codex-task-sounds\notify.log"

    $secondHooks = [System.IO.File]::ReadAllText((Join-Path $SecondHome "hooks.json"), $Utf8NoBom) | ConvertFrom-Json
    $sessionEndCommand = [string]@($secondHooks.hooks.SessionEnd | ForEach-Object { $_.hooks })[0].command
    $specialSessionId = "encoded-path-session"
    $specialPayload = [pscustomobject]@{ session_id = $specialSessionId } | ConvertTo-Json -Compress
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
    $expectedStopFlag = Join-Path (Join-Path $SecondHome "codex-task-sounds\notify-state") ("monitor-stop-" + (Get-TextHash $specialSessionId).Substring(0, 20) + ".flag")
    Assert-True (Test-Path -LiteralPath $expectedStopFlag) "the encoded Hook reached the exact special-character installation path"

    $secondArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $secondScript + '" watch'
    $secondWatcherProcess = Start-Process -FilePath $PowerShellExe -ArgumentList $secondArguments -WindowStyle Hidden -PassThru
    Assert-True (Wait-Until { (Test-Path -LiteralPath $secondLog) -and [System.IO.File]::ReadAllText($secondLog, $Utf8NoBom).Contains("mode=filesystem-watcher") }) "a second CODEX_HOME can run an independent watcher"
    Assert-True (-not $watcherProcess.HasExited -and -not $secondWatcherProcess.HasExited) "watcher mutexes are isolated by CODEX_HOME"

    $sessionId = [Guid]::NewGuid().ToString()
    $sessionPath = Join-Path $sessionsDirectory ("rollout-test-" + $sessionId + ".jsonl")
    $rolloutEvent = [pscustomobject][ordered]@{
        timestamp = [DateTime]::UtcNow.ToString("o")
        type = "event_msg"
        payload = [pscustomobject][ordered]@{
            type = "task_complete"
            turn_id = "runtime-turn"
            last_agent_message = "done"
        }
    }
    [System.IO.File]::WriteAllText($sessionPath, (($rolloutEvent | ConvertTo-Json -Depth 10 -Compress) + [Environment]::NewLine), $Utf8NoBom)
    Assert-True (Wait-Until { [System.IO.File]::ReadAllText($LogPath, $Utf8NoBom).Contains("sound skipped status=success reason=disabled") }) "new rollout events are processed without recursive busy polling"

    Stop-Process -Id $secondWatcherProcess.Id -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $secondWatcherProcess.Id -Timeout 5 -ErrorAction SilentlyContinue
    $secondWatcherProcess = $null
    & (Join-Path $ProjectRoot "uninstall.ps1") -CodexHome $SecondHome -SkipStartup

    Stop-Process -Id $watcherProcess.Id -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $watcherProcess.Id -Timeout 5 -ErrorAction SilentlyContinue
    $watcherProcess = $null
    & (Join-Path $ProjectRoot "install.ps1") -CodexHome $TestHome -SkipStartup
    $installedWatcher = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine.IndexOf($installedScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.CommandLine -match '(?i)\bwatch\b'
    })
    Assert-True ($installedWatcher.Count -eq 1) "installer verifies and leaves one watcher running"
    $installedWatcherReadyText = "pid={0} watch ready token=" -f $installedWatcher[0].ProcessId
    Assert-True ([System.IO.File]::ReadAllText($LogPath, $Utf8NoBom).Contains($installedWatcherReadyText)) "installer readiness validation is tied to the watcher process it launched"
    & (Join-Path $ProjectRoot "uninstall.ps1") -CodexHome $TestHome -SkipStartup
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $TestHome "codex-task-sounds"))) "runtime install can be safely removed"

    Write-Output "Runtime test passed."
}
finally {
    if ($null -ne $watcherProcess -and -not $watcherProcess.HasExited) {
        Stop-Process -Id $watcherProcess.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $watcherProcess.Id -Timeout 5 -ErrorAction SilentlyContinue
    }
    if ($null -ne $secondWatcherProcess -and -not $secondWatcherProcess.HasExited) {
        Stop-Process -Id $secondWatcherProcess.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $secondWatcherProcess.Id -Timeout 5 -ErrorAction SilentlyContinue
    }
    if ($null -ne $duplicateWatcherProcess -and -not $duplicateWatcherProcess.HasExited) {
        Stop-Process -Id $duplicateWatcherProcess.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $duplicateWatcherProcess.Id -Timeout 5 -ErrorAction SilentlyContinue
    }
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
