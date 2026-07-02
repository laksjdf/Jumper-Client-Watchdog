# Jumper Client Watchdog 一键安装手册

这个工具会每 2 分钟检查 Jumper Client 的 Java 进程。某个组件连续失败达到阈值后，只重启该组件自己的 `stop.bat` / `start.bat`，不会调用 `stopAll.bat` / `startAll.bat`。

## 1. 文件清单

请把以下文件放在同一个目录中分发：

```text
jumper-health\
  install.ps1
  watchdog.ps1
  config.json
  README.md
```

推荐最终安装目录：

```text
C:\Program Files\jumper-health\
```

状态和日志目录：

```text
C:\ProgramData\jumper-health\
```

## 2. 安装前配置

打开 `config.json`，只需要确认 `root` 是否是本机 Jumper Client 的实际目录。

```json
{
  "root": "C:\\Users\\Public\\Desktop\\jumper-Client-20251128",
  "failureThreshold": 2,
  "components": [
    {
      "name": "FileSyncEtransBlue",
      "jar": "FileSyncEtransBlue.jar",
      "dir": "FileSyncEtransBlueClient"
    },
    {
      "name": "Netproxy",
      "jar": "net-proxy-client.jar",
      "dir": "NetproxyClient"
    }
  ]
}
```

字段说明：

| 字段 | 说明 |
|---|---|
| `root` | Jumper Client 根目录 |
| `failureThreshold` | 连续失败几次后重启，默认 `2` |
| `name` | 日志和状态文件里的组件名 |
| `jar` | 要检查的 jar 进程名 |
| `dir` | 组件目录，相对于 `root` |

脚本默认调用组件目录下的 `stop.bat` 和 `start.bat`。

## 3. 一键安装

右键 `install.ps1`，选择“使用 PowerShell 运行”。

如果系统弹出管理员授权窗口，点击允许。安装脚本会自动完成：

1. 创建 `C:\Program Files\jumper-health\`
2. 创建 `C:\ProgramData\jumper-health\`
3. 复制 `watchdog.ps1`、`config.json`、`README.md`、`install.ps1`
4. 注册计划任务 `JumperClientHealthWatchdog`
5. 每 2 分钟运行一次 watchdog
6. 立即触发一次任务并输出验证结果

安装成功时会看到类似输出：

```text
Jumper Client Watchdog installed.
InstallDir      : C:\Program Files\jumper-health
DataDir         : C:\ProgramData\jumper-health
TaskName        : JumperClientHealthWatchdog
TaskState       : Ready
LastTaskResult  : 0
NextRunTime     : ...
```

重点确认：

```text
LastTaskResult  : 0
```

`0` 表示计划任务已成功运行。

## 4. 安装后验证

查看计划任务：

```powershell
Get-ScheduledTask -TaskName "JumperClientHealthWatchdog"
```

查看最近一次运行结果：

```powershell
Get-ScheduledTaskInfo -TaskName "JumperClientHealthWatchdog"
```

查看状态文件：

```powershell
Get-Content "C:\ProgramData\jumper-health\state.json" -Raw
```

正常状态类似：

```json
{
  "failures": {
    "FileSyncEtransBlue": 0,
    "Netproxy": 0
  }
}
```

查看日志：

```powershell
Get-Content "C:\ProgramData\jumper-health\watchdog.log" -Tail 50
```

说明：组件一直健康时，日志可能为空或很少。脚本主要记录失败、恢复和重启事件。

## 5. 工作逻辑

每次检查时，watchdog 会读取 `config.json`：

- 如果 `FileSyncEtransBlue.jar` 连续失败 2 次，只重启 `FileSyncEtransBlueClient`
- 如果 `net-proxy-client.jar` 连续失败 2 次，只重启 `NetproxyClient`
- 如果一个组件健康，会清零该组件的失败计数
- 组件之间独立计数，互不影响

以 `FileSyncEtransBlue` 为例，异常恢复时只调用：

```text
FileSyncEtransBlueClient\stop.bat
FileSyncEtransBlueClient\start.bat
```

不会调用：

```text
stopAll.bat
startAll.bat
NetproxyClient\stop.bat
NetproxyClient\start.bat
```

除非 `Netproxy` 自己也连续失败达到阈值。

## 6. 修改配置

安装后如需修改监控对象，编辑：

```text
C:\Program Files\jumper-health\config.json
```

修改后不需要重新安装。计划任务下一次运行时会自动读取新配置。

## 7. 停用、启用、卸载

停用：

```powershell
Disable-ScheduledTask -TaskName "JumperClientHealthWatchdog"
```

启用：

```powershell
Enable-ScheduledTask -TaskName "JumperClientHealthWatchdog"
```

删除计划任务：

```powershell
Unregister-ScheduledTask -TaskName "JumperClientHealthWatchdog" -Confirm:$false
```

如需彻底删除文件，可在删除计划任务后手动删除：

```text
C:\Program Files\jumper-health\
C:\ProgramData\jumper-health\
```

## 8. 常见问题

### `install.ps1` 无法运行

用管理员 PowerShell 执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1"
```

### `LastTaskResult` 不是 0

手动运行 watchdog 看具体错误：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\jumper-health\watchdog.ps1"
```

常见原因：

- `config.json` 不是合法 JSON
- `root` 路径写错
- 组件目录下没有 `start.bat` 或 `stop.bat`
- jar 文件名和实际进程命令行不一致

### 组件运行了但仍被判断失败

检查实际进程命令行：

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -match "FileSyncEtransBlue|net-proxy-client" } |
  Select-Object ProcessId, Name, CommandLine |
  Format-List
```

如果 jar 名不同，修改 `config.json` 里的 `jar` 字段。
