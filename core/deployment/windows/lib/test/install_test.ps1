$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$ScriptDir\lib.ps1"

Set-Location $RootDir

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "=      Начало проверки установки системы.       =" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

Step "1. Установка системы через Setup Full System"
Log "Удаление кэша и зависимостей"
Stop-AllErgoms
Stop-ProjectProcessesForClean
Invoke-ErgomsClean | Out-Null
Write-Host ""
Log "=== Запуск Setup Full System ==="
$ErgomsScript = Join-Path $RootDir "core\deployment\windows\ergo_ms.ps1"
if (-not (Test-Path $ErgomsScript)) { throw "Не найден скрипт $ErgomsScript" }
powershell -ExecutionPolicy Bypass -File $ErgomsScript setup-full
ergoms install-extensions
Write-Host ""
Log "=== Проверка Setup Full System завершена. ==="

Step "2. Проверка команды setup через утилиту ergoms"
Log "Удаление кэша и зависимостей"
Stop-AllErgoms
Stop-ProjectProcessesForClean
Invoke-ErgomsClean | Out-Null
ergoms setup
Log "=== Проверка ergoms setup завершена. ==="

Step "3. Установка служб через команду ergoms install-services"
try { ergoms uninstall-services } catch { }
try {
    try {
        ergoms install-services
    } catch {
        ergoms install-services
    }
} catch {
    Log "[WARNING] установка служб завершилась с ошибкой. Продолжаем тест."
}
Log "=== Проверка установки служб завершена. ==="

Step "4. Установка служб через отдельные команды утилиты ergoms"
Log "Предварительная остановка и удаление всех служб для чистого теста"
Stop-AllErgoms
try { ergoms uninstall-services } catch { }
Start-Sleep -Seconds 3

Log "Установка API через утилиту ergoms: ergoms install-api-service"
ergoms install-api-service
Log "=== Проверка ergoms install-api-service завершена. ==="

Log "Установка Client через утилиту ergoms: ergoms install-client-service"
ergoms install-client-service
Log "=== Проверка ergoms install-client-service завершена. ==="

Log "Установка Worker через утилиту ergoms: ergoms install-worker-service"
ergoms install-worker-service
Log "=== Проверка ergoms install-worker-service завершена. ==="

Log "Установка Beat через утилиту ergoms: ergoms install-beat-service"
ergoms install-beat-service
Log "=== Проверка ergoms install-beat-service завершена. ==="

Log "Установка Media через утилиту ergoms: ergoms install-media-service"
ergoms install-media-service
Log "=== Проверка ergoms install-media-service завершена. ==="

Invoke-ModuleHostInstallServiceCommands

Log "=== Проверка установки служб через утилиту ergoms по отдельности завершена. ==="

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "=     Проверка установки системы завершена.     =" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
