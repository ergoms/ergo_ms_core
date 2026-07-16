# Full system setup
# Полная настройка системы

. (Join-Path $PSScriptRoot "lifecycle.ps1")

function Update-Submodules {
    param(
        [string]$Root
    )
    
    Push-Location $Root
    try {
        & git submodule update --init --remote core/api core/client core/media_api
        if ($LASTEXITCODE -ne 0) { throw "Git submodule update failed" }
        
        Write-ColorOutput "-> Переключение submodule на ветку dev..." Yellow
        
        Push-Location "core\api"
        & git checkout dev
        if ($LASTEXITCODE -ne 0) { Write-ColorOutput "[WARNING] Не удалось переключить ветку dev в core/api" Yellow }
        Pop-Location
        
        Push-Location "core\client"
        & git checkout dev
        if ($LASTEXITCODE -ne 0) { Write-ColorOutput "[WARNING] Не удалось переключить ветку dev в core/client" Yellow }
        Pop-Location
        
        Push-Location "core\media_api"
        & git checkout dev
        if ($LASTEXITCODE -ne 0) { Write-ColorOutput "[WARNING] Не удалось переключить ветку dev в core/media_api" Yellow }
        Pop-Location
        
        Write-ColorOutput "[OK] Git submodule обновлены" Green
    }
    catch {
        Write-ColorOutput "[ERROR] Не удалось обновить git submodule: $($_.Exception.Message)" Red
        Pop-Location
        exit 1
    }
    finally {
        Pop-Location
    }
}

function Get-ModuleSubmoduleEntries {
    param(
        [string]$Root
    )

    $gitmodules = Join-Path $Root ".gitmodules"
    if (-not (Test-Path $gitmodules)) {
        throw ".gitmodules not found at $gitmodules"
    }

    Push-Location $Root
    try {
        $output = & git config -f .gitmodules --get-regexp '^submodule\..*\.path$'
        if (-not $output) {
            return @()
        }

        $entries = @()
        foreach ($line in @($output)) {
            if ($line -match '^submodule\.(.+)\.path\s+(.+)$') {
                $name = $Matches[1]
                $path = $Matches[2]
                if ($path -like 'modules/*') {
                    $branch = & git config -f .gitmodules "submodule.$name.branch"
                    if (-not $branch) {
                        $branch = 'dev'
                    }
                    $entries += [PSCustomObject]@{
                        Name   = $name
                        Path   = $path
                        Branch = $branch
                    }
                }
            }
        }
        return $entries
    }
    finally {
        Pop-Location
    }
}

function Update-ModuleSubmodules {
    param(
        [string]$Root
    )

    Write-ColorOutput "`n=== Обновление git submodule модулей ===" Cyan
    Write-ColorOutput ""

    Push-Location $Root
    try {
        $entries = Get-ModuleSubmoduleEntries -Root $Root
        if ($entries.Count -eq 0) {
            Write-ColorOutput "[WARNING] В .gitmodules не найдено submodule модулей" Yellow
            return
        }

        Write-ColorOutput "-> Обновление submodule модулей ($($entries.Count))..." Yellow

        $succeeded = @()
        $failed = @()
        $skipped = @()

        foreach ($entry in $entries) {
            $known = & git ls-files -s -- $entry.Path
            if (-not $known) {
                Write-ColorOutput "[SKIP] $($entry.Path) не зарегистрирован в git (нет в индексе)" Gray
                $skipped += $entry.Path
                continue
            }

            Write-ColorOutput "  $($entry.Path)..." Gray
            & git submodule update --init --remote $entry.Path
            if ($LASTEXITCODE -ne 0) {
                Write-ColorOutput "[WARNING] Не удалось обновить $($entry.Path)" Yellow
                $failed += $entry.Path
                continue
            }

            Push-Location $entry.Path
            & git checkout $entry.Branch
            if ($LASTEXITCODE -ne 0) {
                Write-ColorOutput "[WARNING] Не удалось переключить $($entry.Branch) в $($entry.Path)" Yellow
            }
            Pop-Location

            $succeeded += $entry.Path
        }

        if ($succeeded.Count -gt 0) {
            $summary = "[OK] Обновлено модулей: $($succeeded.Count)"
            if ($skipped.Count -gt 0 -or $failed.Count -gt 0) {
                $summary += ". Пропущено: $($skipped.Count). С ошибкой: $($failed.Count)"
            }
            Write-ColorOutput $summary Green
            foreach ($path in $failed) {
                Write-ColorOutput "  - $path" Yellow
            }
        }
        elseif ($failed.Count -gt 0) {
            Write-ColorOutput "[ERROR] Не удалось обновить ни одного модуля ($($failed.Count))" Red
            foreach ($path in $failed) {
                Write-ColorOutput "  - $path" Red
            }
            exit 1
        }
        else {
            Write-ColorOutput "[WARNING] Нет модулей для обновления" Yellow
        }
    }
    catch {
        Write-ColorOutput "[ERROR] Не удалось обновить git submodule модулей: $($_.Exception.Message)" Red
        exit 1
    }
    finally {
        Pop-Location
    }
}

function Invoke-ConfigScaffold {
    param(
        [string]$Root
    )

    $script = Join-Path $Root "core\deployment\scripts\scaffold_config_files.py"
    $pythonCmd = $null

    foreach ($cmd in @('python', 'python3', 'python3.12')) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            $pythonCmd = $cmd
            break
        }
    }

    if (-not $pythonCmd) {
        Write-ColorOutput "    [WARNING] Python не найден, невозможно создать конфигурационные файлы из примеров" Yellow
        return $false
    }

    if (-not (Test-Path $script)) {
        Write-ColorOutput "    [WARNING] Скрипт создания конфигурации не найден: $script" Yellow
        return $false
    }

    & $pythonCmd $script --root $Root
    return ($LASTEXITCODE -eq 0)
}

function Setup-FullSystem {
    param(
        [string]$Root,
        [bool]$RecreateVenv = $false
    )

    $extra = @()
    if ($RecreateVenv) { $extra += '--recreate-venv' }
    Invoke-LifecycleRunner -Root $Root -Recipe 'setup-full' -ExtraArgs $extra
}

. (Join-Path $PSScriptRoot "clean.ps1")
