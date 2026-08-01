# Codex Task Sounds for Windows

[![test](https://github.com/xxzzzzy/codex-task-sounds/actions/workflows/test.yml/badge.svg)](https://github.com/xxzzzzy/codex-task-sounds/actions/workflows/test.yml)
[![license](https://img.shields.io/github/license/xxzzzzy/codex-task-sounds)](LICENSE)

为 Codex CLI 和 Codex 桌面端补充任务状态提示音。Codex 原生的 Windows 右下角通知保持不变；本项目不创建额外 Toast，因此不会重复弹窗。

## 功能

- 任务正常结束：成功音。
- 任务失败、中断或明确的工具失败：失败音。
- 等待授权、输入或选择：需要操作音。
- 登录 Windows 后自动启动只读监听器，Codex 或电脑重启后仍可使用。
- 默认声音由 PowerShell 本地生成，不捆绑第三方音频。
- 可用自己的 MP3 覆盖成功音和失败音。
- 安装和卸载都会保留其他已有 Codex Hooks。

## 为什么只做声音

Codex Windows 桌面端已经提供原生系统通知，包括任务完成和需要回答问题等场景。本项目只补充声音，不重复实现通知中心弹窗。

## 环境要求

- Windows 10 或 Windows 11。
- Windows PowerShell 5.1（系统自带）。
- 已安装 Codex CLI 或 Codex 桌面端。

当前版本在 Windows 11 和 `codex-cli 0.146.0` 上完成实机验证。Codex 的 Hook 和 rollout 格式可能随版本变化；升级 Codex 后如出现漏报，请先运行本文的诊断命令。

## 安装

```powershell
git clone https://github.com/xxzzzzy/codex-task-sounds.git
cd codex-task-sounds
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

安装器会：

1. 将运行文件复制到 `%USERPROFILE%\.codex\codex-task-sounds`。
2. 严格校验后原子备份并合并 `%USERPROFILE%\.codex\hooks.json`，不会覆盖其他 Hook。
3. 在隔离目录生成并验证默认 WAV，再原子部署运行文件。
4. 在当前用户的 `HKCU\...\Run` 中注册登录自启，不需要管理员权限。
5. 立即启动并验证后台监听器；声音生成或监听器启动失败时安装会明确报错。

Hook 使用隐藏、非交互的编码 PowerShell 命令，安装路径即使含有中文、空格、`&`、`%` 或单引号也不会被命令行误解析。正常运行不会弹出 PowerShell 窗口。

如果使用了自定义 `CODEX_HOME`，安装器会自动读取；也可以显式指定：

```powershell
.\install.ps1 -CodexHome "D:\path\to\.codex"
```

## 测试声音

```powershell
$script = "$env:USERPROFILE\.codex\codex-task-sounds\notify.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script success
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script error
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script action
```

这三条命令只播放声音，不创建 Windows 通知。

查看已安装版本：

```powershell
& $script --version
```

## 自定义声音

将音频文件放到：

```text
%USERPROFILE%\.codex\codex-task-sounds\sounds\success-custom.mp3
%USERPROFILE%\.codex\codex-task-sounds\sounds\error-custom.mp3
```

脚本优先播放自定义 MP3；文件缺失或 Windows 无法解码时，会回退到本地生成的 WAV。`action.wav` 是默认的需要操作音。

## 配置

配置文件位于 `%USERPROFILE%\.codex\codex-task-sounds\config.json`：

```json
{
  "volume": 0.3,
  "success": true,
  "error": true,
  "waiting": true,
  "waiting_interval": 10,
  "waiting_repeat": false,
  "waiting_max_seconds": 120,
  "detect_question_waiting": true,
  "error_on_tool_failure": true,
  "quiet_hours": {
    "enabled": false,
    "start": "23:00",
    "end": "08:00"
  },
  "silent": false
}
```

- `volume`：自定义 MP3 音量，范围 0–1。
- `waiting_repeat`：默认关闭，避免等待音循环打扰。
- `detect_question_waiting`：根据明确的确认、选择或回复请求识别等待状态。
- `error_on_tool_failure`：工具返回明确失败时播放失败音；若觉得误报较多，可改为 `false`。
- `quiet_hours`：可配置夜间静音时段。

临时静音或恢复：

```powershell
$script = "$env:USERPROFILE\.codex\codex-task-sounds\notify.ps1"
& $script --silent
& $script --unsilent
```

## 工作原理

安装器注册 `SessionStart`、`PermissionRequest`、`Stop` 和 `SessionEnd` Hook。Hook 会快速返回，声音由隐藏子进程异步播放，不会因较长的自定义 MP3 阻塞 Codex。由于单个 Hook 不能稳定表达全部失败状态，后台监听器还会通过 Windows 文件事件只读处理 `%CODEX_HOME%\sessions` 中新增的 rollout 记录，并每 5 秒进行一次低频兜底检查。相同 rollout 事件会跨监听器去重，不再高频递归扫描全部会话文件。

监听器不修改 Codex 会话文件，不联网，也不发送遥测。诊断日志保存在本机安装目录的 `notify.log`，单个日志达到 2 MB 后自动轮转，最多保留三份归档。日志可能包含本地路径和 Codex 的会话/turn 标识；提交 Issue 前请先脱敏。

## 诊断

检查监听器：

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -match 'codex-task-sounds.+notify\.ps1.+watch' } |
  Select-Object ProcessId, CommandLine
```

查看最近日志：

```powershell
Get-Content "$env:USERPROFILE\.codex\codex-task-sounds\notify.log" -Tail 50
```

重新安装是幂等的：安装器会移除本项目的旧 Hook 后再写入一份，不会重复叠加。

## 升级

```powershell
git pull --ff-only
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

升级会保留并校验现有 `config.json`，并为每次实际发生的 `hooks.json` 替换创建唯一备份。若配置或 Hook 结构损坏，安装器会停止且保留原文件，便于手动修复。

## 卸载

在仓库目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

卸载器会先完成结构和路径安全校验，再停止监听器、移除登录自启、只删除本项目的 Hook，并删除 `%USERPROFILE%\.codex\codex-task-sounds`。修改 `hooks.json` 前会创建时间戳备份；重复卸载不会改写已经干净的 Hook 文件。若安装目录或其子项是重解析点，卸载器会拒绝递归删除。

如果只想移除 Hook 和自启但保留声音、配置及日志：

```powershell
.\uninstall.ps1 -KeepFiles
```

## 开发与验证

两组隔离测试都不会修改真实 `%USERPROFILE%\.codex`：

```powershell
.\tests\smoke.ps1
.\tests\runtime.ps1
```

GitHub Actions 会在 `windows-latest` 上执行同一测试，覆盖安装、重复安装、原子备份、精确 Hook 所有权、特殊字符路径、隐藏异步 Hook、Toast 代码缺失、安全卸载、UTF-8 增量读取、错误识别、等待状态隔离、日志轮转、失败退出码、监听器互斥与文件事件监听。

## 隐私与安全

- 仓库不包含用户名、绝对用户路径、会话 ID、日志、备份或自定义 MP3。
- 安装器不会读取或保存 GitHub 凭据。
- 项目不会关闭或修改 Codex 原生桌面通知。
- 不要公开分享未经脱敏的 `notify.log`、`hooks.json` 或 rollout 文件。

## License

[MIT](LICENSE)
