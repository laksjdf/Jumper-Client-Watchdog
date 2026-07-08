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

function Get-JarProcessInfo([string]$root, [string]$jarName) {
    $jcmd = Join-Path $root 'jre\bin\jcmd.exe'
    $escaped = [regex]::Escape($jarName)
    $wmiMatches = @(Get-CimInstance Win32_Process -Filter "Name = 'javaw.exe' OR Name = 'java.exe'" |
        Where-Object { $_.CommandLine -match $escaped })
    $wmiPids = @($wmiMatches | ForEach-Object { [int]$_.ProcessId })
    $jcmdCount = -1

    if (Test-Path $jcmd) {
        $jcmdMatches = @(& $jcmd 2>$null | Where-Object { $_ -match $escaped })
        $jcmdCount = $jcmdMatches.Count
    }

    return [PSCustomObject]@{ Count = $wmiMatches.Count; Pids = $wmiPids; Source = 'wmi'; JcmdCount = $jcmdCount }
}

function Test-EstablishedRemotePort([int[]]$pids, [int]$remotePort) {
    if (-not $pids -or $pids.Count -eq 0) {
        return [PSCustomObject]@{ Healthy = $false; Count = 0 }
    }

    $connections = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { ($pids -contains $_.OwningProcess) -and ([int]$_.RemotePort -eq $remotePort) })
    return [PSCustomObject]@{ Healthy = ($connections.Count -gt 0); Count = $connections.Count }
}

function Test-LocalListenPort([int[]]$pids, [int]$localPort) {
    if (-not $pids -or $pids.Count -eq 0) {
        return [PSCustomObject]@{ Healthy = $false; Count = 0 }
    }

    $connections = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { ($pids -contains $_.OwningProcess) -and ([int]$_.LocalPort -eq $localPort) })
    return [PSCustomObject]@{ Healthy = ($connections.Count -gt 0); Count = $connections.Count }
}

function Test-ComponentHealth([object]$component, [string]$root) {
    $jar = [string]$component.jar
    $process = Get-JarProcessInfo $root $jar
    $reasons = @("processSource=$($process.Source)", "processCount=$($process.Count)", "jcmdCount=$($process.JcmdCount)")

    if ($process.Count -ne 1) {
        return [PSCustomObject]@{ Healthy = $false; Reasons = $reasons -join ' '; Process = $process }
    }

    if ($component.health -and $component.health.localListenPort) {
        $localPort = [int]$component.health.localListenPort
        $tcp = Test-LocalListenPort $process.Pids $localPort
        $reasons += "localListenPort=$localPort"
        $reasons += "listenCount=$($tcp.Count)"
        if (-not $tcp.Healthy) {
            return [PSCustomObject]@{ Healthy = $false; Reasons = $reasons -join ' '; Process = $process }
        }
    }

    if ($component.health -and $component.health.establishedRemotePort) {
        $remotePort = [int]$component.health.establishedRemotePort
        $tcp = Test-EstablishedRemotePort $process.Pids $remotePort
        $reasons += "establishedRemotePort=$remotePort"
        $reasons += "establishedCount=$($tcp.Count)"
        if (-not $tcp.Healthy) {
            return [PSCustomObject]@{ Healthy = $false; Reasons = $reasons -join ' '; Process = $process }
        }
    }

    return [PSCustomObject]@{ Healthy = $true; Reasons = $reasons -join ' '; Process = $process }
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

function Stop-JarProcesses([string]$jarName) {
    $escaped = [regex]::Escape($jarName)
    $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'javaw.exe' OR Name = 'java.exe'" |
        Where-Object { $_.CommandLine -match $escaped })

    foreach ($process in $processes) {
        Write-WatchdogLog "killing leftover $jarName pid=$($process.ProcessId)"
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Restart-Component([string]$name, [string]$componentDir, [string]$jarName) {
    $stopBat = Join-Path $componentDir 'stop.bat'
    $startBat = Join-Path $componentDir 'start.bat'

    if ((Test-Path $startBat) -and (Test-Path $stopBat)) {
        Write-WatchdogLog "restarting $name via $stopBat then $startBat"
        try {
            Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "`"$stopBat`" skip") -WorkingDirectory $componentDir -WindowStyle Hidden -Wait
            Start-Sleep -Seconds 3
            Stop-JarProcesses $jarName
            Start-Sleep -Seconds 2
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
    $health = Test-ComponentHealth $component $root

    if ($health.Healthy) {
        $failures = Get-FailureCount $state $name
        if ($failures -gt 0) {
            Write-WatchdogLog "$name OK jar=$jar $($health.Reasons) (clearing failures=$failures)"
        }
        Set-FailureCount $state $name 0
        return
    }

    $failures = (Get-FailureCount $state $name) + 1
    Set-FailureCount $state $name $failures
    Write-WatchdogLog "$name FAIL jar=$jar $($health.Reasons) failures=$failures/$failThreshold"

    if ($failures -ge $failThreshold) {
        if (Restart-Component $name $componentDir $jar) {
            foreach ($attempt in 1..6) {
                Start-Sleep -Seconds 5
                $postRestartHealth = Test-ComponentHealth $component $root
                if ($postRestartHealth.Healthy) {
                    Write-WatchdogLog "$name restart verified OK jar=$jar $($postRestartHealth.Reasons)"
                    Set-FailureCount $state $name 0
                    return
                }
                Write-WatchdogLog "$name restart verification pending attempt=$attempt jar=$jar $($postRestartHealth.Reasons)"
            }
            Write-WatchdogLog "$name restart submitted but health verification failed; keeping failures=$failures"
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
