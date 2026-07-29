# Core utilities for ErgoMS deployment

# Базовые утилиты для развертывания ErgoMS

. (Join-Path $PSScriptRoot 'portable_env.ps1')
. (Join-Path $PSScriptRoot 'nginx_env.ps1')

# Константы (базовые службы)

$script:BaseServices = @(

    'ergo_ms_api_dev',

    'ergo_ms_client_dev',

    'ergo_ms_media_api',

    'ergo_ms_celery_beat'

)




# Метки консольного вывода (см. core/deployment/console_tags.py)
$script:ErgoTagOk = '[OK]'
$script:ErgoTagError = '[ERROR]'
$script:ErgoTagWarning = '[WARNING]'
$script:ErgoTagSkip = '[SKIP]'
$script:ErgoTagInfo = '[INFO]'

function Format-ErgoConsole {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ok', 'error', 'warning', 'skip', 'info')]
        [string]$Level,
        [string]$Message = ''
    )

    $tag = switch ($Level) {
        'ok' { $script:ErgoTagOk }
        'error' { $script:ErgoTagError }
        'warning' { $script:ErgoTagWarning }
        'skip' { $script:ErgoTagSkip }
        'info' { $script:ErgoTagInfo }
    }

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $tag
    }
    return "$tag $Message"
}

# Кэш для списка служб

$script:CachedServiceNames = $null

$script:CachedProjectRoot = $null



function Write-ColorOutput {

    param([string]$Message, [string]$Color = 'White')

    Write-Host $Message -ForegroundColor $Color

}



function Write-ErgomsMessage {

    param(

        [Parameter(Mandatory = $true)]

        [string]$Key,

        [string]$Color = 'White',

        [switch]$Stderr,

        [hashtable]$Param = @{}

    )



    $root = $script:ErgomsProjectRoot

    if (-not $root) {

        try { $root = Get-ProjectRoot } catch { $root = $null }

    }



    $pythonExe = if ($root) { Join-Path $root 'virtual_env\python\Scripts\python.exe' } else { $null }

    $scriptPath = if ($root) { Join-Path $root 'core\deployment\scripts\ergoms_console.py' } else { $null }



    if ($pythonExe -and (Test-Path $pythonExe) -and $scriptPath -and (Test-Path $scriptPath)) {

        $args = @($scriptPath, '--key', $Key, '--color', $Color)

        if ($Stderr) { $args += '--stderr' }

        foreach ($entry in $Param.GetEnumerator()) {

            $args += @('--param', "$($entry.Key)=$($entry.Value)")

        }

        if ($Stderr) {

            & $pythonExe @args 2>&1 | ForEach-Object { Write-Host $_ -ForegroundColor $Color }

        }

        else {

            & $pythonExe @args | ForEach-Object { Write-Host $_ -ForegroundColor $Color }

        }

        return

    }



    Write-ColorOutput "[$Key]" $Color

}



function Write-ErgomsText {

    param(

        [Parameter(Mandatory = $true)]

        [string]$Text,

        [string]$Color = 'White',

        [switch]$Stderr

    )



    $root = $script:ErgomsProjectRoot

    if (-not $root) {

        try { $root = Get-ProjectRoot } catch { $root = $null }

    }



    $pythonExe = if ($root) { Join-Path $root 'virtual_env\python\Scripts\python.exe' } else { $null }

    $scriptPath = if ($root) { Join-Path $root 'core\deployment\scripts\ergoms_console.py' } else { $null }



    if ($pythonExe -and (Test-Path $pythonExe) -and $scriptPath -and (Test-Path $scriptPath)) {

        $args = @($scriptPath, '--text', $Text, '--color', $Color)

        if ($Stderr) { $args += '--stderr' }

        if ($Stderr) {

            & $pythonExe @args 2>&1 | ForEach-Object { Write-Host $_ -ForegroundColor $Color }

        }

        else {

            & $pythonExe @args | ForEach-Object { Write-Host $_ -ForegroundColor $Color }

        }

        return

    }



    Write-ColorOutput $Text $Color

}



function Initialize-ErgomsConsoleEncoding {

    if ($Host.Name -ne 'ConsoleHost') { return }

    try {

        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

        [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)

        $script:OutputEncoding = [System.Text.UTF8Encoding]::new($false)

    }

    catch {

        # Ignore: non-interactive hosts may not support console encoding changes

    }

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

        Write-ErgomsMessage -Key 'invalid_project_root' -Color Red -Stderr -Param @{ path = $apiPath }

        Write-ErgomsMessage -Key 'project_root_setup_hint' -Color Yellow -Stderr

        throw "Invalid project root: $apiPath not found"

    }

    if (-not (Test-Path $clientPath)) {

        Write-ErgomsMessage -Key 'invalid_project_root' -Color Red -Stderr -Param @{ path = $clientPath }

        Write-ErgomsMessage -Key 'project_root_setup_hint' -Color Yellow -Stderr

        throw "Invalid project root: $clientPath not found"

    }



    Write-ErgomsMessage -Key 'project_structure_ok' -Color Green

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

function Test-PostgresPortableEnabled {

    param([string]$ProjectRoot)

    $direct = Join-Path $ProjectRoot 'virtual_env\packages\postgres\bin\postgres.exe'

    $nested = Join-Path $ProjectRoot 'virtual_env\packages\postgres\pgsql\bin\postgres.exe'

    if ((Test-Path $direct) -or (Test-Path $nested)) { return $true }

    $svcName = 'ergo_ms_postgres'
    $fromEnv = Get-ErgoEnvValue -Root $ProjectRoot -Name 'POSTGRES_SERVICE_WINDOWS'
    if ($fromEnv) { $svcName = $fromEnv }

    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue

    return $null -ne $svc

}



function Get-ServiceNames {

    param([string]$ProjectRoot)

    

    # Используем кэш если проект / nginx / postgres не изменились

    $nginxEnabled = Test-NginxEnabled -ProjectRoot $ProjectRoot

    $postgresEnabled = Test-PostgresPortableEnabled -ProjectRoot $ProjectRoot

    if ($script:CachedServiceNames -and $script:CachedProjectRoot -eq $ProjectRoot -and $script:CachedNginxEnabled -eq $nginxEnabled -and $script:CachedPostgresEnabled -eq $postgresEnabled) {

        return $script:CachedServiceNames

    }

    

    $services = @() + $script:BaseServices



    if ($postgresEnabled) {

        $postgresServiceName = 'ergo_ms_postgres'
        $fromEnv = Get-ErgoEnvValue -Root $ProjectRoot -Name 'POSTGRES_SERVICE_WINDOWS'
        if ($fromEnv) { $postgresServiceName = $fromEnv }

        $services = @($postgresServiceName) + $services

    }



    if ($nginxEnabled) {

        $services = $services | Where-Object { $_ -ne 'ergo_ms_client_dev' }

    }

    

    $workers = Get-CeleryWorkers -ProjectRoot $ProjectRoot

    

    if ($workers.Count -gt 0) {

        # Добавляем службы для каждого воркера из конфига

        foreach ($worker in $workers) {

            $services += "ergo_ms_celery_worker_$worker"

        }

    }

    else {

        # Если конфиг не найден, используем один общий воркер

        $services += "ergo_ms_celery_worker"

    }

    

    # Кэшируем результат

    $script:CachedServiceNames = $services

    $script:CachedProjectRoot = $ProjectRoot

    $script:CachedNginxEnabled = $nginxEnabled

    $script:CachedPostgresEnabled = $postgresEnabled

    

    return $services

}



# Получение только имён воркеров (службы celery-worker-*)

function Get-WorkerServiceNames {

    param([string]$ProjectRoot)

    

    $services = @()

    

    $workers = Get-CeleryWorkers -ProjectRoot $ProjectRoot

    

    if ($workers.Count -gt 0) {

        foreach ($worker in $workers) {

            $services += "ergo_ms_celery_worker_$worker"

        }

    }

    else {

        $services += "ergo_ms_celery_worker"

    }

    

    return $services

}



# Сброс кэша списка служб

function Reset-ServiceNamesCache {

    $script:CachedServiceNames = $null

    $script:CachedProjectRoot = $null

    $script:CachedNginxEnabled = $null

}

# Export-ModuleMember -Function *  # Удалено, так как это не модуль

