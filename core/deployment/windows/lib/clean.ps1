# Clean project dependencies
# Очистка зависимостей проекта

function Clear-ProjectShellEnvironment {
    param(
        [string]$VenvPath
    )

    if (-not (Test-Path -LiteralPath $VenvPath)) {
        if ($env:VIRTUAL_ENV) {
            Remove-Item Env:VIRTUAL_ENV -ErrorAction SilentlyContinue
        }
        return
    }

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

    # ergo-* — службы приложения; ergo_ms_* — portable nginx/redis/postgres (NSSM)
    $services = @(
        Get-Service -Name 'ergo-*' -ErrorAction SilentlyContinue
        Get-Service -Name 'ergo_ms_*' -ErrorAction SilentlyContinue
    ) | Where-Object { $_ -and $_.Status -ne 'Stopped' } | Sort-Object -Property Name -Unique

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
    $packagesLower = (Join-Path $Root "virtual_env\packages").ToLowerInvariant()
    $packagesLowerFwd = $packagesLower.Replace('\', '/')
    $pythonExe = (Join-Path $Root "virtual_env\python\Scripts\python.exe").ToLowerInvariant()

    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $exe = $_.ExecutablePath
        $cmd = $_.CommandLine
        if (-not $exe -and -not $cmd) { return $false }
        $exeLower = if ($exe) { $exe.ToLowerInvariant() } else { "" }
        $cmdLower = if ($cmd) { $cmd.ToLowerInvariant() } else { "" }
        $cmdNorm = $cmdLower.Replace('/', '\')

        # portable nginx / redis / postgres / nssm — иначе clean не удалит virtual_env/packages
        if ($exeLower.StartsWith($packagesLower) -or $cmdNorm.Contains($packagesLower) -or $cmdLower.Contains($packagesLowerFwd)) {
            return $true
        }
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

    if ($stopped -gt 0 -or $services.Count -gt 0) {
        Start-Sleep -Milliseconds 800
    }
}

function Test-RobocopySuccess {
    param([int]$ExitCode)
    return ($ExitCode -ge 0 -and $ExitCode -le 7)
}

function Invoke-RobocopyMirrorEmpty {
    param(
        [string]$TargetPath,
        [string[]]$ExcludeFiles = @(),
        [string]$ProjectRoot = ''
    )

    if (-not (Test-Path -LiteralPath $TargetPath -PathType Container)) {
        return $false
    }

    if (-not $ProjectRoot) {
        $cursor = (Resolve-Path -LiteralPath $TargetPath).Path
        while ($cursor) {
            if (Test-Path -LiteralPath (Join-Path $cursor 'core\deployment')) {
                $ProjectRoot = $cursor
                break
            }
            $parent = Split-Path -Parent $cursor
            if (-not $parent -or $parent -eq $cursor) { break }
            $cursor = $parent
        }
    }

    if (-not $ProjectRoot) {
        return $false
    }

    $cacheTmp = Join-Path $ProjectRoot "virtual_env\cache\tmp"
    New-Item -ItemType Directory -Path $cacheTmp -Force | Out-Null
    $emptyDir = Join-Path $cacheTmp ("ergo_clean_empty_" + [Guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
        $argumentList = @(
            "`"$emptyDir`"",
            "`"$TargetPath`"",
            "/mir", "/mt:16", "/r:1", "/w:1",
            "/nfl", "/ndl", "/njh", "/njs", "/nc", "/ns", "/np"
        )
        foreach ($name in $ExcludeFiles) {
            $argumentList += @("/xf", "`"$name`"")
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "robocopy.exe"
        $psi.Arguments = ($argumentList -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $null = $proc.StandardOutput.ReadToEnd()
        $null = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        return (Test-RobocopySuccess $proc.ExitCode)
    }
    finally {
        Remove-Item -LiteralPath $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-PathWithCmdRmdir {
    param([string]$Path)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c rd /s /q `"$Path`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $null = $proc.StandardOutput.ReadToEnd()
    $null = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return -not (Test-Path -LiteralPath $Path)
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

    $isDirectory = Test-Path -LiteralPath $Path -PathType Container

    if ($isDirectory) {
        if ((Invoke-RobocopyMirrorEmpty -TargetPath $Path) -and (Remove-PathWithCmdRmdir -Path $Path)) {
            return $true
        }
        if (-not (Test-Path -LiteralPath $Path)) {
            return $true
        }
        if (Remove-PathWithCmdRmdir -Path $Path) {
            return $true
        }
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

    if ($isDirectory -and (Invoke-RobocopyMirrorEmpty -TargetPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) {
            return $true
        }
        return (Remove-PathWithCmdRmdir -Path $Path)
    }

    return -not (Test-Path -LiteralPath $Path)
}

function Test-CleanTargetHasWork {
    param(
        [string]$Path,
        [bool]$FullRemove
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    if ($FullRemove) {
        return $true
    }

    $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' })
    return ($items.Count -gt 0)
}

function New-CleanTrashStaging {
    param(
        [string]$Root
    )

    # Каталог в корне проекта — тот же том, что и цели (мгновенный Move-Item)
    $staging = Join-Path $Root (".ergo_clean_trash_" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    return $staging
}

function Move-PathToCleanTrash {
    param(
        [string]$Path,
        [string]$StagingRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $leaf = Split-Path -Leaf $Path
    $dest = Join-Path $StagingRoot $leaf
    if (Test-Path -LiteralPath $dest) {
        $dest = Join-Path $StagingRoot ($leaf + "_" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    }

    try {
        Move-Item -LiteralPath $Path -Destination $dest -Force -ErrorAction Stop
        return $dest
    }
    catch {
        return $null
    }
}

function Start-BackgroundTrashRemoval {
    param(
        [string]$StagingRoot
    )

    if (-not $StagingRoot -or -not (Test-Path -LiteralPath $StagingRoot)) {
        return
    }

    # Фоновый процесс: не блокируем ergoms clean
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c rd /s /q `"$StagingRoot`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    [void][System.Diagnostics.Process]::Start($psi)
}

function Restore-CleanDirectorySkeleton {
    param(
        [string]$Path,
        [bool]$WithGitkeep
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    if ($WithGitkeep) {
        $gitkeep = Join-Path $Path '.gitkeep'
        if (-not (Test-Path -LiteralPath $gitkeep)) {
            Set-Content -LiteralPath $gitkeep -Value '' -Encoding ASCII
        }
    }
}

function Remove-DirectoryContents {
    param(
        [string]$Path,
        [string]$Label,
        [string]$Root,
        [string]$StagingRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-ColorOutput "[SKIP] $Label не найден" Gray
        return @{ Ok = $true; Async = $false; Count = 0 }
    }

    $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' })

    if ($items.Count -eq 0) {
        Write-ColorOutput "[SKIP] $Label уже пуст" Gray
        return @{ Ok = $true; Async = $false; Count = 0 }
    }

    $removedCount = $items.Count
    $moved = Move-PathToCleanTrash -Path $Path -StagingRoot $StagingRoot
    if ($moved) {
        Restore-CleanDirectorySkeleton -Path $Path -WithGitkeep $true
        Write-ColorOutput "[OK] Удалено $removedCount элементов из $Label (фон)" Green
        return @{ Ok = $true; Async = $true; Count = $removedCount }
    }

    # Запасной путь: синхронная очистка на месте
    $cleared = Invoke-RobocopyMirrorEmpty -TargetPath $Path -ExcludeFiles @('.gitkeep')
    $failedItems = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' } |
        ForEach-Object { $_.Name })

    if (-not $cleared -or $failedItems.Count -gt 0) {
        Stop-BlockingProcessesForClean -Root $Root
        $retryFailed = @()
        foreach ($name in $failedItems) {
            $fullName = Join-Path $Path $name
            if (-not (Test-Path -LiteralPath $fullName)) { continue }
            if (-not (Remove-PathRobust -Path $fullName -MaxRetries 5 -RetryDelayMs 400)) {
                $retryFailed += $name
            }
        }
        $failedItems = $retryFailed
    }

    if ($failedItems.Count -gt 0) {
        Write-ColorOutput "[ERROR] Не удалось очистить ${Label}: не удалось удалить: $($failedItems -join ', ')" Red
        Write-ColorOutput "  Закройте терминалы с активированным venv, остановите серверы разработки и снова выполните ergoms clean" Yellow
        return @{ Ok = $false; Async = $false; Count = 0 }
    }

    Write-ColorOutput "[OK] Удалено $removedCount элементов из $Label" Green
    return @{ Ok = $true; Async = $false; Count = $removedCount }
}

function Remove-FullPathFast {
    param(
        [string]$Path,
        [string]$Label,
        [string]$Root,
        [string]$StagingRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-ColorOutput "[SKIP] $Label не найден" Gray
        return @{ Ok = $true; Async = $false }
    }

    $moved = Move-PathToCleanTrash -Path $Path -StagingRoot $StagingRoot
    if ($moved) {
        Write-ColorOutput "[OK] $Label удалён (фон)" Green
        return @{ Ok = $true; Async = $true }
    }

    if (Remove-PathRobust -Path $Path) {
        Write-ColorOutput "[OK] $Label удалён" Green
        return @{ Ok = $true; Async = $false }
    }

    Stop-BlockingProcessesForClean -Root $Root
    if (Remove-PathRobust -Path $Path -MaxRetries 5 -RetryDelayMs 400) {
        Write-ColorOutput "[OK] $Label удалён" Green
        return @{ Ok = $true; Async = $false }
    }

    Write-ColorOutput "[ERROR] Не удалось удалить $Label" Red
    Write-ColorOutput "  Закройте другие терминалы и серверы разработки, затем снова выполните ergoms clean" Yellow
    return @{ Ok = $false; Async = $false }
}

function Clear-ProjectDependencies {
    param(
        [string]$Root
    )

    $cleanTargets = @(
        @{Path = "virtual_env\npm\node_modules"; Label = "virtual_env/npm/node_modules"; FullRemove = $true},
        @{Path = "node_modules";               Label = "node_modules (legacy)";       FullRemove = $true},
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

    $workTargets = @()
    foreach ($target in $cleanTargets) {
        $fullPath = Join-Path $Root $target.Path
        if (Test-CleanTargetHasWork -Path $fullPath -FullRemove:$target.FullRemove) {
            $workTargets += $target
        }
    }

    if ($workTargets.Count -eq 0) {
        Write-ColorOutput "`n[SKIP] Нечего очищать — все цели уже пусты" Gray
        Write-ColorOutput "`n=== Очистка завершена ===" Green
        Write-ColorOutput ""
        return
    }

    Stop-BlockingProcessesForClean -Root $Root
    Clear-ProjectShellEnvironment -VenvPath (Join-Path $Root "virtual_env\python")

    $staging = New-CleanTrashStaging -Root $Root
    $anyAsync = $false
    $total = $cleanTargets.Count

    for ($i = 0; $i -lt $total; $i++) {
        $target = $cleanTargets[$i]
        $step = $i + 1
        $fullPath = Join-Path $Root $target.Path
        Write-ColorOutput "`n-> Шаг ${step}/${total}: очистка $($target.Label)..." Yellow

        if (-not (Test-CleanTargetHasWork -Path $fullPath -FullRemove:$target.FullRemove)) {
            if ($target.FullRemove -and -not (Test-Path -LiteralPath $fullPath)) {
                Write-ColorOutput "[SKIP] $($target.Label) не найден" Gray
            }
            elseif (-not $target.FullRemove) {
                if (-not (Test-Path -LiteralPath $fullPath)) {
                    Write-ColorOutput "[SKIP] $($target.Label) не найден" Gray
                }
                else {
                    Write-ColorOutput "[SKIP] $($target.Label) уже пуст" Gray
                }
            }
            else {
                Write-ColorOutput "[SKIP] $($target.Label) уже пуст" Gray
            }
            continue
        }

        if ($target.FullRemove) {
            $result = Remove-FullPathFast -Path $fullPath -Label $target.Label -Root $Root -StagingRoot $staging
        }
        else {
            $result = Remove-DirectoryContents -Path $fullPath -Label $target.Label -Root $Root -StagingRoot $staging
        }

        if ($result.Async) {
            $anyAsync = $true
        }
    }

    if ($anyAsync) {
        Start-BackgroundTrashRemoval -StagingRoot $staging
        Write-ColorOutput "`n[INFO] Тяжёлое удаление продолжается в фоне" Gray
    }
    else {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-ColorOutput "`n=== Очистка завершена ===" Green
    Write-ColorOutput ""
    Write-ColorOutput "Чтобы установить зависимости заново, выполните:" Cyan
    Write-ColorOutput "  ergoms setup" Yellow
    Write-ColorOutput ""
}