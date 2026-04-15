$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$ScriptDir\lib.ps1"

Set-Location $RootDir

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "=      Начало проверки запуска системы.         =" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

Step "Предусловие: проверка установки и артефактов перед проверкой запуска системы"
Require-InstallReadyForLaunch
Write-Host ""
Log "Предусловия выполнены. Система готова к запуску."

Step "1. Запуск системы через Run Task: Start All Services"
Log "Предварительная остановка системы"
Stop-AllErgoms
Enable-ErgoServicesForStart
Log "Запуск системы через Start All Services"
Run-Task -Label "Start All Services"
Log "Ожидание стабилизации сервисов перед проверкой статуса (5 с)..."
Start-Sleep -Seconds 5
Write-Host ""
try { ergoms status } catch { }
Stop-AllErgoms
Log "=== Запуск системы через Start All Services завершен. ==="

Step "2. Запуск системы через ergoms start"
Log "Предварительная остановка системы"
Stop-AllErgoms
Enable-ErgoServicesForStart
Log "Запуск системы через ergoms start"
ergoms start
Log "Ожидание стабилизации сервисов перед проверкой статуса (5 с)..."
Start-Sleep -Seconds 5
Write-Host ""
try { ergoms status } catch { }
Stop-AllErgoms
Log "=== Запуск при помощи ergoms start завершён. ==="

Step "3. Отдельный запуск сервисов (api, media, client, celery-beat, worker)"
Log "Условия для воркеров: проверяем celery inspect ping и celery beat show_next_tasks"
Stop-AllErgoms
Enable-ErgoServicesForStart

Step "3.1. API: старт -> статус -> стоп"
Test-ServiceAction -Action "start" -ServiceName "ergo-api-dev"
Start-Sleep -Seconds 3
Test-ServiceAction -Action "status" -ServiceName "ergo-api-dev"
Test-ServiceAction -Action "stop" -ServiceName "ergo-api-dev"

Step "3.2. Media API: старт -> статус -> стоп"
Test-ServiceAction -Action "start" -ServiceName "ergo-media-api"
Start-Sleep -Seconds 3
Test-ServiceAction -Action "status" -ServiceName "ergo-media-api"
Test-ServiceAction -Action "stop" -ServiceName "ergo-media-api"

Step "3.3. Client: старт -> статус -> стоп"
Test-ServiceAction -Action "start" -ServiceName "ergo-client-dev"
Start-Sleep -Seconds 3
Test-ServiceAction -Action "status" -ServiceName "ergo-client-dev"
Test-ServiceAction -Action "stop" -ServiceName "ergo-client-dev"

Step "3.4. Celery: beat + workers (yaml сценарии + worker через задачу)"
$CeleryTest = Join-Path $ScriptDir "celery_test.ps1"
if (-not (Test-Path $CeleryTest)) { throw "Не найден $CeleryTest" }
& $CeleryTest

Stop-AllErgoms
Log "=== Шаг 3 (отдельные сервисы и Celery) завершён. ==="

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "=     Проверка запуска системы завершена.       =" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
