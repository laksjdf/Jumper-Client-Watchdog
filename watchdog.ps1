$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = Join-Path $scriptDir 'config.json'
$stateDir = 'C:\ProgramData\jumper-health'
$stateFile = Join-Path $stateDir 'state.json'
$log = Join-Path $stateDir 'watchdog.log'

New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

if ((Test-Path $log) -and (Get-Item $log).Length -gt 10MB) {
    $tail = Get-Content $log -Tail 5000 -Encoding utf8
    Set-Content -Path $log -Value $tail -Encoding utf8
}

function Write-WatchdogLog([string]$message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message
    Add-Content -Path $log -Value $line -Encoding utf8
}

function Read-JsonFile([string]$path) {
    try {
        return Get-Content $path -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        Write-WatchdogLog "failed to read JSON ${path}: $($_.Exception.Message)"
        throw
    }
}

function Read-WatchdogState {
    if (Test-Path $stateFile) {
        try {
            $state = Read-JsonFile $stateFile
            if (-not ($state.PSObject.Properties.Name -contains 'failures')) {
                $state | Add-Member -NotePropertyName 'failures' -NotePropertyValue ([PSCustomObject]@{})
            }
            return $state
        } catch {
            Write-WatchdogLog "state parse failed, resetting state: $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{ failures = [PSCustomObject]@{} }
}

function Get-JarProcessCount([string]$root, [string]$jarName) {
    $jcmd = Join-Path $root 'jre\bin\jcmd.exe'
    $escaped = [regex]::Escape($jarName)

    if (Test-Path $jcmd) {
        $matches = @(& $jcmd 2>$null | Where-Object { $_ -match $escaped })
        return $matches.Count
    }

    Write-WatchdogLog "jcmd not found under $root; falling back to WMI for $jarName"
    $matches = @(Get-CimInstance Win32_Process -Filter "Name = 'javaw.exe' OR Name = 'java.exe'" |
        Where-Object { $_.CommandLine -match $escaped })
    return $matches.Count
}

function Get-FailureCount([object]$state, [string]$name) {
    if (-not ($state.failures.PSObject.Properties.Name -contains $name)) {
        $state.failures | Add-Member -NotePropertyName $name -NotePropertyValue 0
    }

    return [int]$state.failures.$name
}

function Set-FailureCount([object]$state, [string]$name, [int]$count) {
    if ($state.failures.PSObject.Properties.Name -contains $name) {
        $state.failures.$name = $count
    } else {
        $state.failures | Add-Member -NotePropertyName $name -NotePropertyValue $count
    }
}

function Restart-Component([string]$name, [string]$componentDir) {
    $stopBat = Join-Path $componentDir 'stop.bat'
    $startBat = Join-Path $componentDir 'start.bat'

    if ((Test-Path $startBat) -and (Test-Path $stopBat)) {
        Write-WatchdogLog "restarting $name via $stopBat then $startBat"
        try {
            Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "`"$stopBat`" skip") -WorkingDirectory $componentDir -WindowStyle Hidden -Wait
            Start-Sleep -Seconds 5
            Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "`"$startBat`" skip") -WorkingDirectory $componentDir -WindowStyle Hidden
            Write-WatchdogLog "$name restart command submitted OK"
            return $true
        } catch {
            Write-WatchdogLog "$name restart failed: $($_.Exception.Message)"
            return $false
        }
    }

    Write-WatchdogLog "$name restart skipped: missing start or stop bat under $componentDir"
    return $false
}

function Update-ComponentHealth([object]$state, [object]$component, [string]$root, [int]$failThreshold) {
    $name = [string]$component.name
    $jar = [string]$component.jar
    $componentDir = Join-Path $root ([string]$component.dir)
    $processCount = Get-JarProcessCount $root $jar
    $isHealthy = $processCount -eq 1

    if ($isHealthy) {
        $failures = Get-FailureCount $state $name
        if ($failures -gt 0) {
            Write-WatchdogLog "$name OK jar=$jar count=$processCount (clearing failures=$failures)"
        }
        Set-FailureCount $state $name 0
        return
    }

    $failures = (Get-FailureCount $state $name) + 1
    Set-FailureCount $state $name $failures
    Write-WatchdogLog "$name FAIL jar=$jar count=$processCount failures=$failures/$failThreshold"

    if ($failures -ge $failThreshold) {
        if (Restart-Component $name $componentDir) {
            Set-FailureCount $state $name 0
        }
    }
}

if (-not (Test-Path $configFile)) {
    Write-WatchdogLog "missing config file: $configFile"
    exit 1
}

$config = Read-JsonFile $configFile
$state = Read-WatchdogState
foreach ($oldName in @('fileSyncFailures', 'netproxyFailures', 'lastRestartEpoch')) {
    if ($state.PSObject.Properties.Name -contains $oldName) {
        $state.PSObject.Properties.Remove($oldName)
    }
}
$root = [string]$config.root
$failThreshold = if ($config.failureThreshold) { [int]$config.failureThreshold } else { 2 }

foreach ($component in @($config.components)) {
    Update-ComponentHealth $state $component $root $failThreshold
}

$state | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile -Encoding utf8
