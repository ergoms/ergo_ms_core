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
            Write-ColorOutput "  Cleared VIRTUAL_ENV for project virtual environment" Gray
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

    Write-ColorOutput "  Stopping processes that may lock project files..." Gray

    $services = Get-Service -Name "ergo-*" -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Stopped' }
    foreach ($svc in $services) {
        try {
            Stop-Service -Name $svc.Name -Force -ErrorAction Stop
            Write-ColorOutput "  Stopped service: $($svc.Name)" Gray
        }
        catch {
            Write-ColorOutput "  [WARNING] Could not stop service $($svc.Name) (Administrator may be required)" Yellow
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
            Write-ColorOutput "  Stopped: $($p.Name) (PID $($p.ProcessId))" Gray
            $stopped++
        }
        catch {
            Write-ColorOutput "  [WARNING] Could not stop PID $($p.ProcessId): $($p.Name)" Yellow
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
        Write-ColorOutput "[SKIP] $Label not found" Gray
        return
    }

    $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' }

    if (-not $items -or $items.Count -eq 0) {
        Write-ColorOutput "[SKIP] $Label is already empty" Gray
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
        Write-ColorOutput "[ERROR] Failed to clean ${Label}: could not remove: $($failedItems -join ', ')" Red
        Write-ColorOutput "  Close terminals with activated venv, stop dev servers, then run ergoms clean again" Yellow
        return
    }

    if ($removedCount -gt 0) {
        Write-ColorOutput "[OK] Removed $removedCount items from $Label" Green
    }
    else {
        Write-ColorOutput "[SKIP] $Label is already empty" Gray
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
        @{Path = "virtual_env\cache";           Label = "virtual_env/cache";           FullRemove = $false}
    )

    Write-ColorOutput "`n=== Cleaning Project Dependencies ===" Cyan
    Write-ColorOutput ""
    Write-ColorOutput "This will remove:" Yellow
    foreach ($target in $cleanTargets) {
        Write-ColorOutput "  - $($target.Label)" Gray
    }
    Write-ColorOutput ""
    Write-ColorOutput "Media folder will NOT be deleted." Green
    Write-ColorOutput ""

    $confirmation = Read-Host "Are you sure you want to continue? (y/N)"
    if ($confirmation -notmatch '^[yY]$') {
        Write-ColorOutput "Operation cancelled by user." Yellow
        return
    }

    Stop-BlockingProcessesForClean -Root $Root
    Clear-ProjectShellEnvironment -VenvPath (Join-Path $Root "virtual_env\python")

    $total = $cleanTargets.Count
    for ($i = 0; $i -lt $total; $i++) {
        $target = $cleanTargets[$i]
        $step = $i + 1
        $fullPath = Join-Path $Root $target.Path
        Write-ColorOutput "`n-> Step ${step}/${total}: Cleaning $($target.Label)..." Yellow

        if ($target.FullRemove) {
            if (Test-Path -LiteralPath $fullPath) {
                if (Remove-PathRobust -Path $fullPath) {
                    Write-ColorOutput "[OK] $($target.Label) removed" Green
                }
                else {
                    Stop-BlockingProcessesForClean -Root $Root
                    if (Remove-PathRobust -Path $fullPath -MaxRetries 5 -RetryDelayMs 1000) {
                        Write-ColorOutput "[OK] $($target.Label) removed" Green
                    }
                    else {
                        Write-ColorOutput "[ERROR] Failed to remove $($target.Label)" Red
                        Write-ColorOutput "  Close other terminals and dev servers, then run ergoms clean again" Yellow
                    }
                }
            }
            else {
                Write-ColorOutput "[SKIP] $($target.Label) not found" Gray
            }
        }
        else {
            Remove-DirectoryContents -Path $fullPath -Label $target.Label -Root $Root
        }
    }

    Write-ColorOutput "`n=== Cleaning Complete ===" Green
    Write-ColorOutput ""
    Write-ColorOutput "To reinstall dependencies, run:" Cyan
    Write-ColorOutput "  ergoms setup" Yellow
    Write-ColorOutput ""
}
