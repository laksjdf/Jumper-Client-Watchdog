param(
    [string]$InstallDir = 'C:\Program Files\jumper-health',
    [string]$DataDir = 'C:\ProgramData\jumper-health',
    [string]$TaskName = 'JumperClientHealthWatchdog',
    [int]$IntervalMinutes = 2
)

$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    $argsList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-InstallDir', "`"$InstallDir`"",
        '-DataDir', "`"$DataDir`"",
        '-TaskName', "`"$TaskName`"",
        '-IntervalMinutes', $IntervalMinutes
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -Verb RunAs
    exit
}

$sourceDir = Split-Path -Parent $PSCommandPath
$requiredFiles = @('watchdog.ps1', 'config.json')

foreach ($file in $requiredFiles) {
    $path = Join-Path $sourceDir $file
    if (-not (Test-Path $path)) {
        throw "Missing required file: $path"
    }
}

$configPath = Join-Path $sourceDir 'config.json'
try {
    $config = Get-Content $configPath -Raw -Encoding utf8 | ConvertFrom-Json
} catch {
    throw "config.json is not valid JSON: $($_.Exception.Message)"
}

if (-not $config.root) {
    throw 'config.json must set root.'
}

New-Item -ItemType Directory -Force -Path $InstallDir, $DataDir | Out-Null

foreach ($file in @('watchdog.ps1', 'config.json', 'README.md', 'install.ps1')) {
    $source = Join-Path $sourceDir $file
    $target = Join-Path $InstallDir $file
    $sourcePath = if (Test-Path $source) { (Resolve-Path -LiteralPath $source).Path } else { $null }
    $targetPath = if (Test-Path $target) { (Resolve-Path -LiteralPath $target).Path } else { $null }
    if ($sourcePath -and ($sourcePath -ne $targetPath)) {
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
}

$watchdogPath = Join-Path $InstallDir 'watchdog.ps1'
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($watchdogPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw "watchdog.ps1 parse failed: $($parseErrors[0].Message)"
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdogPath`""

$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).Date `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Checks Jumper Client components every $IntervalMinutes minutes and restarts failed components." `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 5

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName

Write-Host ''
Write-Host 'Jumper Client Watchdog installed.'
Write-Host "InstallDir      : $InstallDir"
Write-Host "DataDir         : $DataDir"
Write-Host "TaskName        : $TaskName"
Write-Host "TaskState       : $($task.State)"
Write-Host "LastRunTime     : $($info.LastRunTime)"
Write-Host "LastTaskResult  : $($info.LastTaskResult)"
Write-Host "NextRunTime     : $($info.NextRunTime)"

if ($info.LastTaskResult -ne 0) {
    Write-Warning "Task ran but returned $($info.LastTaskResult). Check $DataDir\watchdog.log and config.json."
    exit 1
}
