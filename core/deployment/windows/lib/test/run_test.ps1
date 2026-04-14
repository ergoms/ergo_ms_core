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

Step "3.4. Celery: API + beat + worker -> ping -> show_next_tasks -> стоп"
Test-ServiceAction -Action "start" -ServiceName "ergo-api-dev"
Start-Sleep -Seconds 4
Test-ServiceAction -Action "start" -ServiceName "ergo-celery-beat"
Start-Sleep -Seconds 3

$workers = Get-Service -Name "ergo-celery-worker*" -ErrorAction SilentlyContinue
foreach ($w in $workers) {
    Log "Запуск воркера: $($w.Name)"
    Test-ServiceAction -Action "start" -ServiceName $w.Name
}
Start-Sleep -Seconds 6

if (Run-CeleryWorkerInspectPing) {
    Log "celery inspect ping: OK"
} else {
    Log "[WARNING] celery inspect ping не прошёл (брокер, worker или таймаут)"
}

if (Run-CeleryBeatShowNextTasks) {
    Log "show_next_tasks: выполнено"
} else {
    Log "[WARNING] show_next_tasks завершился с ошибкой"
}

foreach ($w in $workers) {
    Test-ServiceAction -Action "stop" -ServiceName $w.Name
}
Test-ServiceAction -Action "stop" -ServiceName "ergo-celery-beat"
Test-ServiceAction -Action "stop" -ServiceName "ergo-api-dev"

Stop-AllErgoms
Log "=== Шаг 3 (отдельные сервисы и Celery) завершён. ==="

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "=     Проверка запуска системы завершена.       =" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
