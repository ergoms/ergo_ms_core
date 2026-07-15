# Clean project dependencies
# Очистка зависимостей проекта

function Clear-ProjectShellEnvironment {
    param(
        [string]$VenvPath
    )

    $venvNorm = [System.IO.Path]::GetFullPath($VenvPath).TrimEnd('\')

    if ($env:VIRTUAL_ENV) {
        $activeNorm = [System.IO.Path]::GetFullPath($env:VIRTUAL_ENV).TrimEnd('\')
        if ($activeNorm -eq $venvNorm) {
            Remove-Item Env:VIRTUAL_ENV -ErrorAction SilentlyContinue
            Write-ColorOutput "  Сброшена переменная VIRTUAL_ENV для виртуального окружения проекта" Gray
        }
    }

    $scriptsPath = Join-Path $venvNorm "Scripts"
    if ($env:PATH) {
        $parts = $env:PATH -split ';' | Where-Object {
            $_ -and ([System.IO.Path]::GetFullPath($_).TrimEnd('\') -ne $scriptsPath)
        }
        $env:PATH = ($parts -join ';')
    }
}

function Stop-BlockingProcessesForClean {
    param(
        [string]$Root
    )

    Write-ColorOutput "  Останавливаю процессы, которые могут блокировать файлы проекта..." Gray

    $services = Get-Service -Name "ergo-*" -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Stopped' }
    foreach ($svc in $services) {
        try {
            Stop-Service -Name $svc.Name -Force -ErrorAction Stop
            Write-ColorOutput "  Остановлена служба: $($svc.Name)" Gray
        }
        catch {
            Write-ColorOutput "  [WARNING] Не удалось остановить службу $($svc.Name) (может потребоваться запуск от администратора)" Yellow
        }
    }

    $rootLower = $Root.ToLowerInvariant()
    $venvLower = (Join-Path $Root "virtual_env\python").ToLowerInvariant()
    $pythonExe = (Join-Path $Root "virtual_env\python\Scripts\python.exe").ToLowerInvariant()

    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $exe = $_.ExecutablePath
        $cmd = $_.CommandLine
        if (-not $exe) { return $false }
        $exeLower = $exe.ToLowerInvariant()
        $cmdLower = if ($cmd) { $cmd.ToLowerInvariant() } else { "" }

        if ($exeLower.StartsWith($venvLower) -or $cmdLower.Contains($venvLower)) { return $true }
        if ($exeLower -eq $pythonExe) { return $true }
        if ($exeLower.EndsWith("\python.exe") -and $cmdLower.Contains($rootLower)) { return $true }
        if ($exeLower.EndsWith("\pythonw.exe") -and ($exeLower.StartsWith($rootLower) -or $cmdLower.Contains($rootLower))) { return $true }
        if ($exeLower.EndsWith("\pip.exe") -and $exeLower.StartsWith($venvLower)) { return $true }
        if ($exeLower.EndsWith("\esbuild.exe") -and ($exeLower.StartsWith($rootLower) -or $cmdLower.Contains($rootLower))) { return $true }
        if ($exeLower.EndsWith("\node.exe") -and $cmdLower.Contains($rootLower)) { return $true }

        return $false
    }

    $stopped = 0
    foreach ($p in $procs) {
        if ($p.ProcessId -eq $PID) { continue }
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-ColorOutput "  Остановлен: $($p.Name) (PID $($p.ProcessId))" Gray
            $stopped++
        }
        catch {
            Write-ColorOutput "  [WARNING] Не удалось остановить PID $($p.ProcessId): $($p.Name)" Yellow
        }
    }

    if ($stopped -gt 0) {
        Start-Sleep -Seconds 2
    }
}

function Test-RobocopySuccess {
    param([int]$ExitCode)
    return ($ExitCode -ge 0 -and $ExitCode -le 7)
}

function Remove-PathRobust {
    param(
        [string]$Path,
        [int]$MaxRetries = 3,
        [int]$RetryDelayMs = 500
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        }
        catch {
            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Milliseconds $RetryDelayMs
            }
        }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }

    $emptyDir = Join-Path $env:TEMP ("ergo_clean_empty_" + [Guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
        $rc = Start-Process -FilePath "robocopy.exe" -ArgumentList @(
            $emptyDir, $Path, "/mir", "/r:2", "/w:1",
            "/nfl", "/ndl", "/njh", "/njs", "/nc", "/ns", "/np"
        ) -Wait -PassThru -NoNewWindow
        if (Test-RobocopySuccess $rc.ExitCode) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        Remove-Item -LiteralPath $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    return -not (Test-Path -LiteralPath $Path)
}

function Remove-DirectoryContents {
    param(
        [string]$Path,
        [string]$Label,
        [string]$Root
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-ColorOutput "[SKIP] $Label не найден" Gray
        return
    }

    $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' }

    if (-not $items -or $items.Count -eq 0) {
        Write-ColorOutput "[SKIP] $Label уже пуст" Gray
        return
    }

    $removedCount = 0
    $failedItems = @()

    foreach ($item in $items) {
        if (Remove-PathRobust -Path $item.FullName) {
            $removedCount++
        }
        else {
            $failedItems += $item.Name
        }
    }

    if ($failedItems.Count -gt 0) {
        Stop-BlockingProcessesForClean -Root $Root
        foreach ($name in @($failedItems)) {
            $fullName = Join-Path $Path $name
            if (-not (Test-Path -LiteralPath $fullName)) { continue }
            if (Remove-PathRobust -Path $fullName -MaxRetries 5 -RetryDelayMs 1000) {
                $removedCount++
                $failedItems = $failedItems | Where-Object { $_ -ne $name }
            }
        }
    }

    if ($failedItems.Count -gt 0) {
        Write-ColorOutput "[ERROR] Не удалось очистить ${Label}: не удалось удалить: $($failedItems -join ', ')" Red
        Write-ColorOutput "  Закройте терминалы с активированным venv, остановите серверы разработки и снова выполните ergoms clean" Yellow
        return
    }

    if ($removedCount -gt 0) {
        Write-ColorOutput "[OK] Удалено $removedCount элементов из $Label" Green
    }
    else {
        Write-ColorOutput "[SKIP] $Label уже пуст" Gray
    }
}

function Clear-ProjectDependencies {
    param(
        [string]$Root
    )

    $cleanTargets = @(
        @{Path = "node_modules";               Label = "node_modules";               FullRemove = $true},
        @{Path = "virtual_env\python";          Label = "virtual_env/python";          FullRemove = $false},
        @{Path = "virtual_env\static_api";      Label = "virtual_env/static_api";      FullRemove = $false},
        @{Path = "virtual_env\celery";          Label = "virtual_env/celery";          FullRemove = $false},
        @{Path = "virtual_env\nodejs";          Label = "virtual_env/nodejs";          FullRemove = $false},
        @{Path = "virtual_env\packages";        Label = "virtual_env/packages";        FullRemove = $false},
        @{Path = "virtual_env\resources";       Label = "virtual_env/resources";       FullRemove = $false},
        @{Path = "virtual_env\trained_models";  Label = "virtual_env/trained_models";  FullRemove = $false},
        @{Path = "virtual_env\cache";           Label = "virtual_env/cache";           FullRemove = $false},
        @{Path = "virtual_env\docker-cache";    Label = "virtual_env/docker-cache";    FullRemove = $false}
    )

    Write-ColorOutput "`n=== Очистка зависимостей проекта ===" Cyan
    Write-ColorOutput ""
    Write-ColorOutput "Будут удалены:" Yellow
    foreach ($target in $cleanTargets) {
        Write-ColorOutput "  - $($target.Label)" Gray
    }
    Write-ColorOutput ""
    Write-ColorOutput "Папка media не будет удалена." Green
    Write-ColorOutput ""

    $confirmation = Read-Host "Продолжить? (y/N)"
    if ($confirmation -notmatch '^[yY]$') {
        Write-ColorOutput "Операция отменена пользователем." Yellow
        return
    }

    Stop-BlockingProcessesForClean -Root $Root
    Clear-ProjectShellEnvironment -VenvPath (Join-Path $Root "virtual_env\python")

    $total = $cleanTargets.Count
    for ($i = 0; $i -lt $total; $i++) {
        $target = $cleanTargets[$i]
        $step = $i + 1
        $fullPath = Join-Path $Root $target.Path
        Write-ColorOutput "`n-> Шаг ${step}/${total}: очистка $($target.Label)..." Yellow

        if ($target.FullRemove) {
            if (Test-Path -LiteralPath $fullPath) {
                if (Remove-PathRobust -Path $fullPath) {
                    Write-ColorOutput "[OK] $($target.Label) удалён" Green
                }
                else {
                    Stop-BlockingProcessesForClean -Root $Root
                    if (Remove-PathRobust -Path $fullPath -MaxRetries 5 -RetryDelayMs 1000) {
                        Write-ColorOutput "[OK] $($target.Label) удалён" Green
                    }
                    else {
                        Write-ColorOutput "[ERROR] Не удалось удалить $($target.Label)" Red
                        Write-ColorOutput "  Закройте другие терминалы и серверы разработки, затем снова выполните ergoms clean" Yellow
                    }
                }
            }
            else {
                Write-ColorOutput "[SKIP] $($target.Label) не найден" Gray
            }
        }
        else {
            Remove-DirectoryContents -Path $fullPath -Label $target.Label -Root $Root
        }
    }

    Write-ColorOutput "`n=== Очистка завершена ===" Green
    Write-ColorOutput ""
    Write-ColorOutput "Чтобы установить зависимости заново, выполните:" Cyan
    Write-ColorOutput "  ergoms setup" Yellow
    Write-ColorOutput ""
}
