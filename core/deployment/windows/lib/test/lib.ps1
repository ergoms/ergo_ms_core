$ErrorActionPreference = "Stop"
try {
    & "$env:SystemRoot\System32\chcp.com" 65001 > $null
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RootDir = (Resolve-Path "$ScriptDir\..\..\..\..\..").ProviderPath
$TestLogFile = Join-Path $RootDir "logs\test.log"

function Ensure-LogDir {
    $logDir = Split-Path $TestLogFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
}

function Add-ContentSafe {
    param([string]$Path, [string]$Value, [int]$Retries = 20, [int]$DelayMs = 150)
    Ensure-LogDir
    for ($i = 0; $i -lt $Retries; $i++) {
        try {
            Add-Content -LiteralPath $Path -Value $Value -Encoding UTF8 -ErrorAction Stop
            return $true
        } catch { Start-Sleep -Milliseconds $DelayMs }
    }
    Write-Host ("[WARNING] Failed to write test log (file locked): " + $Path) -ForegroundColor Yellow
    return $false
}

function Log {
    param([string]$Message)
    Ensure-LogDir
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line
    [void](Add-ContentSafe -Path $TestLogFile -Value $line)
}

function Step {
    param([string]$Message)
    Ensure-LogDir
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
    [void](Add-ContentSafe -Path $TestLogFile -Value "")
    [void](Add-ContentSafe -Path $TestLogFile -Value ("=== " + $Message + " ==="))
}

# Строка попадает в test.log, если в ней есть «инфо»-блок [ТЕГ] — [INFO] [OK] [WARNING] [ERROR] [SKIP] и т.д.
# Первая буква тега — любая буква (в т.ч. кириллица): [\p{L}]; цифры/даты [2024] не считаем тегом.
function Test-TestLogSignificantLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    $t = $Line.Trim()
    if ($t -match '\[[\p{L}][^\]]*\]') { return $true }
    if ($t -match '\[(?:OK|ERR|ON|NO)\]') { return $true }
    if ($t -match '(?i)^fatal:') { return $true }
    if ($t -match '(?i)(NativeCommandError|ServiceCommandException|Start-Service|OpenError:|Command failed|Failed to start|Virtual environment not found)') { return $true }
    if ($t -match '^\s*(\+ )?(CategoryInfo|FullyQualifiedErrorId|Exception|ErrorRecord)\s*:') { return $true }
    return $false
}

function Log-FilteredMultilineText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    foreach ($ln in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        if (Test-TestLogSignificantLine $ln) { Log $ln.TrimEnd() }
    }
}

function Stop-StaleCeleryBeatProcessesForTests {
    $pythonExe = (Join-Path $RootDir "virtual_env\python\Scripts\python.exe").ToLowerInvariant()
    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $cmd = $_.CommandLine; $exe = $_.ExecutablePath
        if (-not $cmd -or -not $exe) { return $false }
        $cmdLower = $cmd.ToLowerInvariant(); $exeLower = $exe.ToLowerInvariant()
        if ($exeLower -ne $pythonExe) { return $false }
        if ($cmdLower.Contains("start_celery_beat.py")) { return $true }
        return $cmdLower.Contains(" -m celery ") -and $cmdLower.Contains(" beat")
    }
    foreach ($proc in $processes) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Log ("[INFO] Stopped stale Celery Beat process PID=" + $proc.ProcessId)
        } catch {
            Log ("[WARNING] Failed to stop stale Celery Beat process PID=" + $proc.ProcessId)
        }
    }
}

function Get-ModuleHostLifecycle {
    <#
    .SYNOPSIS
    Агрегат modules/*/host_lifecycle.yaml (stop/install команды модульных демонов).
    #>
    $pythonExe = Join-Path $RootDir "virtual_env\python\Scripts\python.exe"
    $script = Join-Path $RootDir "core\deployment\scripts\host_lifecycle_loader.py"
    if (-not (Test-Path -LiteralPath $pythonExe) -or -not (Test-Path -LiteralPath $script)) {
        return [pscustomobject]@{
            stop_commands = @()
            install_service_commands = @()
            service_units = @()
            modules = @()
        }
    }
    try {
        $json = & $pythonExe $script --root $RootDir --json 2>$null
        if (-not $json) {
            return [pscustomobject]@{
                stop_commands = @()
                install_service_commands = @()
                service_units = @()
                modules = @()
            }
        }
        $data = $json | ConvertFrom-Json
        return [pscustomobject]@{
            stop_commands = @($data.stop_commands)
            install_service_commands = @($data.install_service_commands)
            service_units = @($data.service_units)
            modules = @($data.modules)
        }
    } catch {
        Log "[WARNING] Не удалось загрузить host_lifecycle модулей: $_"
        return [pscustomobject]@{
            stop_commands = @()
            install_service_commands = @()
            service_units = @()
            modules = @()
        }
    }
}

function Invoke-ModuleHostStopCommands {
    if (-not (Get-Command ergoms -ErrorAction SilentlyContinue)) { return }
    $lifecycle = Get-ModuleHostLifecycle
    foreach ($cmd in @($lifecycle.stop_commands)) {
        if (-not $cmd) { continue }
        try {
            ergoms $cmd
        } catch {
            Log "[WARNING] ergoms $cmd failed. Continuing."
        }
    }
}

function Invoke-ModuleHostInstallServiceCommands {
    if (-not (Get-Command ergoms -ErrorAction SilentlyContinue)) { return }
    $lifecycle = Get-ModuleHostLifecycle
    foreach ($cmd in @($lifecycle.install_service_commands)) {
        if (-not $cmd) { continue }
        Log "Установка службы модуля через утилиту ergoms: ergoms $cmd"
        try {
            ergoms $cmd
            Log "=== Проверка ergoms $cmd завершена. ==="
        } catch {
            Log "[WARNING] ergoms $cmd завершился с ошибкой. Continuing."
        }
    }
}

function Stop-AllErgoms {
    Log "Stopping all ergoms processes and services..."
    Set-Location $RootDir
    Stop-StaleCeleryBeatProcessesForTests
    $services = Get-Service -Name "ergo-*" -ErrorAction SilentlyContinue
    foreach ($svc in $services) {
        try { Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop } catch { }
        if ($svc.Status -ne 'Stopped') {
            try { Stop-Service -Name $svc.Name -Force -ErrorAction Stop } catch { }
        }
    }
    if (Get-Command ergoms -ErrorAction SilentlyContinue) {
        try { ergoms stop } catch { Log "[WARNING] ergoms stop failed (maybe no venv). Continuing." }
        Invoke-ModuleHostStopCommands
    }
    Start-Sleep -Seconds 3
}

function Stop-ProjectProcessesForClean {
    Log "Stopping node/python processes that block clean (project only)..."
    $libDir = Split-Path -Parent $ScriptDir
    . (Join-Path $libDir "core.ps1")
    . (Join-Path $libDir "clean.ps1")
    Stop-BlockingProcessesForClean -Root $RootDir
}

function Enable-ErgoServicesForStart {
    $services = Get-Service -Name "ergo-*" -ErrorAction SilentlyContinue
    foreach ($svc in $services) {
        try { Set-Service -Name $svc.Name -StartupType Automatic -ErrorAction Stop } catch { }
    }
}

function Require-InstallReadyForLaunch {
    Log "Checking launch prerequisites: project structure, venv, ergoms, services."
    if (-not (Get-Command ergoms -ErrorAction SilentlyContinue)) { throw "ergoms not found in PATH." }
    if (-not (Test-Path "$RootDir\core\api") -or -not (Test-Path "$RootDir\core\client")) { throw "Missing core/api or core/client directories." }
    if (-not (Test-Path "$RootDir\virtual_env\python\Scripts\activate.ps1")) { throw "Missing virtual_env/python." }
    if (-not (Test-Path "$RootDir\virtual_env\npm\node_modules") -and -not (Test-Path "$RootDir\node_modules") -and -not (Test-Path "$RootDir\core\client\node_modules")) { throw "Missing node_modules." }
    Log "Launch prerequisites: OK."
}

function Test-ServiceAction {
    param([string]$Action, [string]$ServiceName)
    if ($Action -eq "start") {
        if ($ServiceName -eq "ergo-celery-beat") {
            Stop-StaleCeleryBeatProcessesForTests
            Start-Sleep -Seconds 1
        }
        Start-Service -Name $ServiceName -ErrorAction Stop
    } elseif ($Action -eq "stop") {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    } elseif ($Action -eq "status") {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc) { Log ("Status " + $ServiceName + ": " + $svc.Status) }
        else { Log ("Service " + $ServiceName + " not found") }
    }
}

function Run-CeleryWorkerInspectPing {
    Set-Location "$RootDir\core\api"
    $pythonExe = "$RootDir\virtual_env\python\Scripts\python.exe"
    $env:PYTHONPATH = $RootDir
    Log "Running celery inspect ping..."
    $process = Start-Process -FilePath $pythonExe -ArgumentList "-m celery -A src.config.celery.celery_app inspect ping --timeout 8" -Wait -NoNewWindow -PassThru
    return ($process.ExitCode -eq 0)
}

function Run-CeleryBeatShowNextTasks {
    Set-Location $RootDir
    Log "Running ergoms api show_next_tasks..."
    $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c ergoms api show_next_tasks --count 5" -Wait -NoNewWindow -PassThru
    return ($process.ExitCode -eq 0)
}

function Invoke-CmdWithTimeout {
    param([string]$CommandLine, [int]$TimeoutSeconds = 10)
    Set-Location $RootDir
    $tmpDir = Join-Path $env:TEMP ("ergoms_test_" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $stdoutPath = Join-Path $tmpDir "stdout.txt"
    $stderrPath = Join-Path $tmpDir "stderr.txt"
    try {
        Log ("Running (timeout " + $TimeoutSeconds + "s): " + $CommandLine)
        $cmdLineUtf8 = "chcp 65001 >nul & " + $CommandLine
        $p = Start-Process -FilePath "cmd.exe" -ArgumentList ("/c " + $cmdLineUtf8) -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        if (-not $p.HasExited) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
            Log ("[WARNING] Command timed out and was killed. PID=" + $p.Id)
            return @{ ok = $false; exitCode = $null; stdout = (Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue); stderr = (Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue); timedOut = $true }
        }
        return @{ ok = ($p.ExitCode -eq 0); exitCode = $p.ExitCode; stdout = (Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue); stderr = (Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue); timedOut = $false }
    } finally {
        try { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Invoke-ErgomsClean {
    param([int]$TimeoutSeconds = 600)
    Set-Location $RootDir
    Log "Running ergoms clean (auto-confirm)..."
    $res = Invoke-CmdWithTimeout -CommandLine "echo y| ergoms clean" -TimeoutSeconds $TimeoutSeconds
    if ($res.stdout) { Log-FilteredMultilineText -Text $res.stdout }
    if ($res.stderr) { Log-FilteredMultilineText -Text $res.stderr }
    return [bool]$res.ok
}

function Test-ErgomsLogs {
    param([string]$ServiceName, [int]$Lines = 10)
    $res = Invoke-CmdWithTimeout -CommandLine ("ergoms logs " + $ServiceName + " " + $Lines) -TimeoutSeconds 8
    if ($res.stdout) { Log-FilteredMultilineText -Text $res.stdout }
    if ($res.stderr) { Log-FilteredMultilineText -Text $res.stderr }
    return [bool]$res.ok
}

function Get-KeysFromYamlMap {
    param(
        [Parameter(Mandatory=$true)][string]$YamlPath,
        [Parameter(Mandatory=$true)][string]$RootKey,
        [int]$Indent = 2
    )
    if (-not (Test-Path $YamlPath)) { return @() }
    $lines = Get-Content -LiteralPath $YamlPath -ErrorAction SilentlyContinue
    if (-not $lines) { return @() }

    $inRoot = $false
    $out = New-Object System.Collections.Generic.List[string]
    $reRoot = '^\s*' + [regex]::Escape($RootKey) + ':\s*$'
    $reKey = '^\s{' + $Indent + '}([A-Za-z0-9_-]+):\s*$'

    foreach ($line in $lines) {
        if ($line -match $reRoot) { $inRoot = $true; continue }
        if (-not $inRoot) { continue }
        # Выходим, когда начинается новый корневой ключ (0 пробелов + word + :)
        if ($line -match '^[A-Za-z0-9_-]+:\s*$') { break }
        if ($line -match $reKey) { $out.Add($Matches[1]) | Out-Null }
    }
    return ,$out.ToArray()
}

function Start-DetachedTaskCommand {
    param([Parameter(Mandatory=$true)][string]$CommandLine)
    # Для команд tasks.json: запускаем через cmd.exe (как в tasks.json), в фоне.
    $cmdLineUtf8 = "chcp 65001 >nul & " + $CommandLine
    Start-Process -FilePath "cmd.exe" -ArgumentList ("/d", "/c", $cmdLineUtf8) -WindowStyle Hidden | Out-Null
}

function Invoke-MultiTerminalTask {
    param(
        [Parameter(Mandatory=$true)][object]$Task,
        [Parameter(Mandatory=$true)][string]$TaskLabel,
        [switch]$InParallel
    )
    # Эмуляция VS Code multi-terminal: для каждого key из YAML запускаем commandTemplate.
    # В тестах не пытаемся “воссоздать терминалы”, просто стартуем процессы.
    $runDetached = $false
    if ($env:ERGO_RUN_TASK_DETACHED -eq "1") { $runDetached = $true }
    if ($InParallel) { $runDetached = $true }

    $sources = @()
    if ($Task.sources) { $sources = @($Task.sources) }
    elseif ($Task.source) { $sources = @($Task.source) }
    else { throw ("Multi-terminal task '" + $TaskLabel + "' has no source(s)") }

    foreach ($src in $sources) {
        $fileRel = $src.file
        $rootKey = $src.path
        # В tasks.json встречаются оба формата:
        # - commandTemplate внутри source (как у Logs: All Services)
        # - commandTemplate на уровне Task (как у Celery Worker)
        $commandTemplate = $null
        if ($src.commandTemplate) { $commandTemplate = $src.commandTemplate }
        elseif ($Task.commandTemplate) { $commandTemplate = $Task.commandTemplate }

        if (-not $fileRel -or -not $rootKey -or -not $commandTemplate) {
            throw ("Multi-terminal task '" + $TaskLabel + "': source требует file/path и commandTemplate (в source или на уровне task)")
        }
        $yamlPath = Join-Path $RootDir $fileRel
        $keys = Get-KeysFromYamlMap -YamlPath $yamlPath -RootKey $rootKey -Indent 2
        if (-not $keys -or $keys.Count -eq 0) {
            Log ("[WARNING] Multi-terminal task '" + $TaskLabel + "': нет ключей в " + $fileRel + " (" + $rootKey + ")")
            continue
        }
        Log ("Multi-terminal '" + $TaskLabel + "': keys=" + ($keys -join ", "))

        foreach ($k in $keys) {
            $cmd = $commandTemplate.Replace('${workspaceFolder}', $RootDir)
            $cmd = $cmd.Replace('${key}', $k)
            Log ("Executing (multi-terminal " + $TaskLabel + " [" + $k + "]): " + $cmd)
            if ($runDetached) { Start-DetachedTaskCommand -CommandLine $cmd }
            else { Invoke-Expression $cmd }
        }
    }
}

function Run-Task {
    param([string]$Label, [switch]$InParallel)
    $tasksFile = "$RootDir\.vscode\tasks.json"
    if (-not (Test-Path $tasksFile)) { throw "tasks.json not found" }
    $jsonContent = Get-Content $tasksFile -Raw
    $jsonContent = $jsonContent -replace '(?m)^\s*//.*$', ''
    $tasksObj = $jsonContent | ConvertFrom-Json
    $task = $tasksObj.tasks | Where-Object { $_.label -eq $Label }
    if (-not $task) { throw ("Task '" + $Label + "' not found in tasks.json") }
    Log ("Starting task: " + $Label)
    if ($task.command) {
        $cmd = $task.command
        if ($task.windows -and $task.windows.command) { $cmd = $task.windows.command }
        $cmd = $cmd.Replace('${workspaceFolder}', $RootDir)
        Log ("Executing command: " + $cmd)
        if ($InParallel) { Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -WindowStyle Hidden }
        else { Invoke-Expression $cmd }
        return
    }
    if ($task.type -eq "multi-terminal") {
        Invoke-MultiTerminalTask -Task $task -TaskLabel $Label -InParallel:$InParallel
        return
    }
    if ($task.dependsOn) {
        $order = "parallel"
        if ($task.dependsOrder) { $order = $task.dependsOrder }
        Log ("Task '" + $Label + "' has dependsOn (order: " + $order + ")")
        foreach ($dep in $task.dependsOn) {
            if ($order -eq "sequence") { Run-Task -Label $dep }
            else { Run-Task -Label $dep -InParallel }
        }
        if ($order -eq "parallel") {
            Log "Waiting for parallel tasks (5s)..."
            Start-Sleep -Seconds 5
        }
        return
    }
    throw ("Task '" + $Label + "' has no command or dependsOn")
}
