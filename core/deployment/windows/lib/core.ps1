# Core utilities for ErgoMS deployment
# Базовые утилиты для развертывания ErgoMS

# Константы (базовые службы)
$script:BaseServices = @(
    'ergo-api-dev',
    'ergo-client-dev',
    'ergo-media-api',
    'ergo-celery-beat'
)

$script:CliName = 'ergoms'
$script:CliPath = "$env:SystemRoot\System32\$script:CliName.bat"

# Кэш для списка служб
$script:CachedServiceNames = $null
$script:CachedProjectRoot = $null

function Write-ColorOutput {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ProjectRoot {
    param([string]$ProvidedRoot)

    if ($ProvidedRoot) {
        if (Test-Path $ProvidedRoot) {
            return (Resolve-Path $ProvidedRoot).Path
        }
        throw "Provided root path does not exist: $ProvidedRoot"
    }

    # Auto-detect from script location
    $scriptDir = Split-Path -Parent $PSCommandPath
    $projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)

    # Try git root
    try {
        Push-Location $scriptDir
        $gitRoot = git rev-parse --show-toplevel 2>$null
        if ($gitRoot) {
            Pop-Location
            return (Resolve-Path $gitRoot).Path
        }
    }
    catch {
        # Ignore git errors
    }
    finally {
        Pop-Location
    }

    return $projectRoot
}

function Get-ProjectLogsDir {
    param([string]$ProjectRoot)
    return Join-Path $ProjectRoot "logs"
}

function Get-ProjectWrappersDir {
    param([string]$ProjectRoot)
    return Join-Path $ProjectRoot "core\deployment\wrappers"
}

function Test-ProjectStructure {
    param([string]$Root)

    $apiPath = Join-Path $Root "core\api"
    $clientPath = Join-Path $Root "core\client"

    if (-not (Test-Path $apiPath)) {
        Write-ColorOutput "[ERROR] Invalid project root: $apiPath not found" Red
        Write-ColorOutput "Run 'ergoms setup' to initialize all submodules." Yellow
        throw "Invalid project root: $apiPath not found"
    }
    if (-not (Test-Path $clientPath)) {
        Write-ColorOutput "[ERROR] Invalid project root: $clientPath not found" Red
        Write-ColorOutput "Run 'ergoms setup' to initialize all submodules." Yellow
        throw "Invalid project root: $clientPath not found"
    }

    Write-ColorOutput "[OK] Project structure validated" Green
}

# Парсинг YAML файла для получения имён воркеров
# Простой парсер без внешних зависимостей (PowerShell-yaml не установлен по умолчанию)
function Get-CeleryWorkersFromYaml {
    param([string]$YamlFile)
    
    if (-not (Test-Path $YamlFile)) {
        return @()
    }
    
    $workers = @()
    $inWorkers = $false
    
    $lines = Get-Content $YamlFile -Encoding UTF8
    
    foreach ($line in $lines) {
        # Пропускаем комментарии и пустые строки
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        
        # Проверяем начало секции workers:
        if ($line -match '^workers:\s*$') {
            $inWorkers = $true
            continue
        }
        
        # Если мы в секции workers
        if ($inWorkers) {
            # Проверяем, не началась ли новая секция верхнего уровня
            if ($line -match '^[a-z_]+:\s*$' -and $line -notmatch '^\s') {
                $inWorkers = $false
                continue
            }
            
            # Ищем имена воркеров (строки с отступом в 2 пробела и двоеточием)
            if ($line -match '^\s{2}([a-z_]+):\s*$') {
                $workerName = $Matches[1]
                $workers += $workerName
            }
        }
    }
    
    return $workers
}

# Получение списка воркеров из celery_workers.yaml
function Get-CeleryWorkers {
    param([string]$ProjectRoot)
    
    if (-not $ProjectRoot) {
        try {
            $ProjectRoot = Get-ProjectRoot
        }
        catch {
            return @()
        }
    }
    
    $workersConfig = Join-Path $ProjectRoot "celery_workers.yaml"
    return Get-CeleryWorkersFromYaml -YamlFile $workersConfig
}

# Генерация списка служб на основе конфигурации воркеров
function Get-ServiceNames {
    param([string]$ProjectRoot)
    
    # Используем кэш если проект и nginx-сценарий не изменились
    $nginxEnabled = Test-NginxEnabled -ProjectRoot $ProjectRoot
    if ($script:CachedServiceNames -and $script:CachedProjectRoot -eq $ProjectRoot -and $script:CachedNginxEnabled -eq $nginxEnabled) {
        return $script:CachedServiceNames
    }
    
    $services = @() + $script:BaseServices

    if ($nginxEnabled) {
        $services = $services | Where-Object { $_ -ne 'ergo-client-dev' }
    }
    
    $workers = Get-CeleryWorkers -ProjectRoot $ProjectRoot
    
    if ($workers.Count -gt 0) {
        # Добавляем службы для каждого воркера из конфига
        foreach ($worker in $workers) {
            $services += "ergo-celery-worker-$worker"
        }
    }
    else {
        # Если конфиг не найден, используем один общий воркер
        $services += "ergo-celery-worker"
    }
    
    # Кэшируем результат
    $script:CachedServiceNames = $services
    $script:CachedProjectRoot = $ProjectRoot
    $script:CachedNginxEnabled = $nginxEnabled
    
    return $services
}

# Получение только имён воркеров (службы celery-worker-*)
function Get-WorkerServiceNames {
    param([string]$ProjectRoot)
    
    $services = @()
    
    $workers = Get-CeleryWorkers -ProjectRoot $ProjectRoot
    
    if ($workers.Count -gt 0) {
        foreach ($worker in $workers) {
            $services += "ergo-celery-worker-$worker"
        }
    }
    else {
        $services += "ergo-celery-worker"
    }
    
    return $services
}

# Сброс кэша списка служб
function Reset-ServiceNamesCache {
    $script:CachedServiceNames = $null
    $script:CachedProjectRoot = $null
    $script:CachedNginxEnabled = $null
}

function Get-CliName {
    return $script:CliName
}

function Get-CliPath {
    return $script:CliPath
}

# Export-ModuleMember -Function *  # Удалено, так как это не модуль
