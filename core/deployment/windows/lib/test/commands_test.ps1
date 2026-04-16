$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$ScriptDir\lib.ps1"

Set-Location $RootDir

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "=      Начало проверки команд системы.          =" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

Step "1. Проверка команд базы данных"
Log "Выполнение ergoms db-makemigrations"
try {
    ergoms db-makemigrations
    Log "db-makemigrations: OK"
} catch {
    Log "[WARNING] db-makemigrations завершился с ошибкой"
}

Log "Выполнение ergoms db-migrate"
try {
    ergoms db-migrate
    Log "db-migrate: OK"
} catch {
    Log "[WARNING] db-migrate завершился с ошибкой"
}

Step "2. Проверка команды очистки (clean)"
Log "Выполнение ergoms clean"
try {
    Stop-AllErgoms
    Stop-ProjectProcessesForClean
    if (Invoke-ErgomsClean) { Log "clean: OK" } else { Log "[WARNING] clean завершился с ошибкой или таймаутом" }
} catch {
    Log "[WARNING] clean завершился с ошибкой"
}

Step "3. Проверка команды логов (logs)"
Log "Выполнение ergoms logs ergo-api-dev 10"
try {
    if (Test-ErgomsLogs -ServiceName "ergo-api-dev" -Lines 10) {
        Log "logs ergo-api-dev: OK"
    } else {
        Log "[WARNING] logs ergo-api-dev завершился с ошибкой или таймаутом"
    }
} catch {
    Log "[WARNING] logs ergo-api-dev завершился с ошибкой"
}

Step "3.1. Run Task: Logs: All Services (multi-terminal)"
try {
    $LogsTaskTest = Join-Path $ScriptDir "logs_task_test.ps1"
    if (-not (Test-Path $LogsTaskTest)) { throw "Не найден $LogsTaskTest" }
    & $LogsTaskTest
} catch {
    Log "[WARNING] Logs: All Services test завершился с ошибкой"
}

Step "4. Подготовка системы к работе (финальный ergoms setup)"
Log "Выполнение ergoms setup"
try {
    ergoms setup
    Log "ergoms setup: OK"
} catch {
    Log "[WARNING] ergoms setup завершился с ошибкой"
}

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "=     Проверка команд системы завершена.        =" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
