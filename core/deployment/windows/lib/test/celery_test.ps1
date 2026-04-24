$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$ScriptDir\lib.ps1"

Set-Location $RootDir

function Backup-AndPrepareWorkersYaml {
    $yaml = Join-Path $RootDir "celery_workers.yaml"
    $bak = Join-Path $RootDir "celery_workers.yaml.test.bak"
    if (-not (Test-Path $yaml)) {
        # Если файла нет, всё равно создадим бэкап-метку, чтобы restore был безопасным.
        "" | Set-Content -LiteralPath $bak -Encoding UTF8
        return @{ yaml = $yaml; bak = $bak; existed = $false }
    }
    Copy-Item -LiteralPath $yaml -Destination $bak -Force
    return @{ yaml = $yaml; bak = $bak; existed = $true }
}

function Restore-WorkersYaml {
    param([hashtable]$State)
    if (-not $State) { return }
    $yaml = $State.yaml
    $bak = $State.bak
    try {
        if (Test-Path $bak) {
            if ($State.existed) {
                Copy-Item -LiteralPath $bak -Destination $yaml -Force
            } else {
                # Если исходного файла не было — удаляем созданный в тесте.
                if (Test-Path $yaml) { Remove-Item -LiteralPath $yaml -Force -ErrorAction SilentlyContinue }
            }
            Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Write-WorkersYaml {
    param([string[]]$Keys)
    $yaml = Join-Path $RootDir "celery_workers.yaml"

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("workers:") | Out-Null
    foreach ($k in $Keys) {
        $lines.Add(("  {0}:" -f $k)) | Out-Null
        $lines.Add(("    description: ""autotest worker {0}""" -f $k)) | Out-Null
        $lines.Add(("    hostname: ""{0}_worker""" -f $k)) | Out-Null
        $lines.Add("    queues: all") | Out-Null
        $lines.Add("    concurrency: 1") | Out-Null
        $lines.Add("") | Out-Null
    }
    $lines.Add("defaults:") | Out-Null
    $lines.Add("  pool: solo") | Out-Null
    $lines.Add("  loglevel: info") | Out-Null
    $lines.Add("  events: true") | Out-Null

    $lines | Set-Content -LiteralPath $yaml -Encoding UTF8
}

function Reinstall-WorkerServicesFromYaml {
    Log "Переустановка worker-служб: ergoms install-worker-service (перечитать celery_workers.yaml)"
    try {
        ergoms install-worker-service
        Start-Sleep -Seconds 3
        return $true
    } catch {
        Log "[WARNING] ergoms install-worker-service завершился с ошибкой"
        return $false
    }
}

function Get-CeleryWorkersFromYaml {
    $yamlPath = Join-Path $RootDir "celery_workers.yaml"
    if (-not (Test-Path $yamlPath)) { return @() }
    $lines = Get-Content -LiteralPath $yamlPath -ErrorAction SilentlyContinue
    if (-not $lines) { return @() }

    $inWorkers = $false
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '^\s*workers:\s*$') { $inWorkers = $true; continue }
        if (-not $inWorkers) { continue }
        if ($line -match '^\s*defaults:\s*$') { break }

        # Ключ воркера: "  name:" (2 пробела + word + :)
        if ($line -match '^\s{2}([A-Za-z0-9_-]+):\s*$') {
            $out.Add($Matches[1]) | Out-Null
        }
    }
    return ,$out.ToArray()
}

function Assert-WorkersServicesMatchConfig {
    $keys = Get-CeleryWorkersFromYaml
    if (-not $keys -or $keys.Count -eq 0) {
        Log "[WARNING] celery_workers.yaml не найден или пустой; проверка соответствия воркеров пропущена"
        return $false
    }

    $expected = $keys | ForEach-Object { "ergo-celery-worker-$($_)" } | Sort-Object
    $actual = (Get-Service -Name "ergo-celery-worker-*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) | Sort-Object

    Log ("Workers в celery_workers.yaml: " + ($keys -join ", "))
    Log ("Ожидаемые службы: " + ($expected -join ", "))
    Log ("Найденные службы: " + ($actual -join ", "))

    $missing = @($expected | Where-Object { $_ -notin $actual })
    $extra = @($actual | Where-Object { $_ -notin $expected })
    if ($missing.Count -gt 0) { Log ("[WARNING] Нет служб для воркеров из celery_workers.yaml: " + ($missing -join ", ")) }
    if ($extra.Count -gt 0) { Log ("[WARNING] Есть лишние worker-службы (не из celery_workers.yaml): " + ($extra -join ", ")) }

    return ($missing.Count -eq 0)
}

function Start-AndCheckWorkerServices {
    $workers = Get-Service -Name "ergo-celery-worker-*" -ErrorAction SilentlyContinue
    if (-not $workers) {
        Log "[WARNING] Не найдено ни одной службы ergo-celery-worker-*"
        return $false
    }

    $allOk = $true
    foreach ($w in $workers) {
        Log ("Запуск воркера-службы: " + $w.Name)
        try { Start-Service -Name $w.Name -ErrorAction Stop } catch { $allOk = $false; Log ("[WARNING] Не удалось запустить " + $w.Name) }
    }
    Start-Sleep -Seconds 6

    foreach ($w in $workers) {
        $svc = Get-Service -Name $w.Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") { Log ($w.Name + ": Running") }
        else { $allOk = $false; Log ("[WARNING] " + $w.Name + ": NOT Running") }
    }

    foreach ($w in $workers) {
        try { Stop-Service -Name $w.Name -Force -ErrorAction SilentlyContinue } catch { }
    }
    return $allOk
}

function Run-CeleryWorkerTaskTest {
    $pythonExe = Join-Path $RootDir "virtual_env\python\Scripts\python.exe"
    if (-not (Test-Path $pythonExe)) { throw "Не найден python venv: $pythonExe" }

    $tmpDir = Join-Path $env:TEMP ("ergo_celery_test_" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $tmpTask = Join-Path $tmpDir "_ergo_celery_test_task.py"
    $tmpSend = Join-Path $tmpDir "_ergo_celery_send_task.py"

    try {
        @"
from src.config.celery import celery_app

@celery_app.task(name='ergo_test_ping')
def ergo_test_ping():
    return 'pong'
"@ | Set-Content -LiteralPath $tmpTask -Encoding UTF8

        Set-Location (Join-Path $RootDir "core\api")
        # Нужен доступ к пакету `src` из core/api/src при запуске временных скриптов из %TEMP%.
        # Добавляем core/api в PYTHONPATH, иначе django.setup() не находит settings-модуль `src.*`.
        $env:PYTHONPATH = ($tmpDir + ";" + $RootDir + ";" + (Join-Path $RootDir "core\\api"))
        # Важно: `development`/`local` определяют загрузку settings через sys.argv (ищут "beat"),
        # а временные файлы лежат в %TEMP% с путём, содержащим "beat", из-за чего импортируется
        # `celery_beat` раньше `base` и Django может упасть при инициализации.
        # Для тестов используем стабильный settings pattern `test` (не зависит от argv).
        $env:DJANGO_SETTINGS_MODULE = "src.config.patterns.test"

        Log "Запуск test worker с задачей ergo_test_ping..."
        # Windows: prefork/billiard часто падает с WinError 5 (semlock). Для автотеста используем solo pool.
        $workerArgs = "-m celery -A src.config.celery.celery_app worker --loglevel=info -Q default --pool=solo --concurrency=1 -n test_worker@%h --include=_ergo_celery_test_task"
        $workerProc = Start-Process -FilePath $pythonExe -ArgumentList $workerArgs -NoNewWindow -PassThru
        Start-Sleep -Seconds 10

        if ($workerProc.HasExited) {
            Log ("[WARNING] worker завершился преждевременно, ExitCode=" + $workerProc.ExitCode)
            return $false
        }

        Log "Отправка задачи ergo_test_ping и ожидание результата..."
        $sendScript = @"
import os, sys
import django
django.setup()
from src.config.celery import celery_app
r = celery_app.send_task('ergo_test_ping')
val = r.get(timeout=15)
print(val)
sys.exit(0 if val == 'pong' else 1)
"@
        Set-Content -LiteralPath $tmpSend -Value $sendScript -Encoding UTF8

        $res = Start-Process -FilePath $pythonExe -ArgumentList $tmpSend -Wait -NoNewWindow -PassThru
        if ($res.ExitCode -ne 0) {
            Log "[WARNING] celery task test: FAILED (результат не получен или не 'pong')"
            return $false
        }
        Log "celery task test: OK (pong)"
        return $true
    } finally {
        try {
            if ($workerProc -and -not $workerProc.HasExited) {
                Log ("Остановка test worker PID=" + $workerProc.Id)
                try { Stop-Process -Id $workerProc.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
        } catch { }
        try { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        Set-Location $RootDir
    }
}

function Run-CeleryBeatExecutionTest {
    $pythonExe = Join-Path $RootDir "virtual_env\python\Scripts\python.exe"
    if (-not (Test-Path $pythonExe)) { throw "Не найден python venv: $pythonExe" }

    $tmpDir = Join-Path $env:TEMP ("ergo_celery_beat_test_" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $tmpTask = Join-Path $tmpDir "_ergo_celery_test_task.py"
    $tmpCreate = Join-Path $tmpDir "_ergo_celery_create_periodic.py"
    $tmpCheck = Join-Path $tmpDir "_ergo_celery_check_periodic.py"
    $tmpCleanup = Join-Path $tmpDir "_ergo_celery_cleanup_periodic.py"
    $taskName = "ergo_test_ping"
    $periodicName = "ergo_test_periodic_ping"
    $scheduleEverySeconds = 5

    $workerProc = $null
    try {
        @"
from src.config.celery import celery_app

@celery_app.task(name='$taskName')
def ergo_test_ping():
    return 'pong'
"@ | Set-Content -LiteralPath $tmpTask -Encoding UTF8

        Set-Location (Join-Path $RootDir "core\api")
        # Нужен доступ к пакету `src` из core/api/src при запуске временных скриптов из %TEMP%.
        $env:PYTHONPATH = ($tmpDir + ";" + $RootDir + ";" + (Join-Path $RootDir "core\\api"))
        # См. пояснение выше: используем стабильный `test` вместо `development`.
        $env:DJANGO_SETTINGS_MODULE = "src.config.patterns.test"

        Log "Создание временной periodic task в django_celery_beat..."
        $createScript = @"
import django
django.setup()
from django_celery_beat.models import IntervalSchedule, PeriodicTask

name = '$periodicName'
task = '$taskName'

PeriodicTask.objects.filter(name=name).delete()
schedule, _ = IntervalSchedule.objects.get_or_create(every=$scheduleEverySeconds, period=IntervalSchedule.SECONDS)
pt = PeriodicTask.objects.create(
    name=name,
    task=task,
    interval=schedule,
    enabled=True,
    one_off=False,
    start_time=None,
)
print(pt.id)
"@
        Set-Content -LiteralPath $tmpCreate -Value $createScript -Encoding UTF8

        $createRes = Start-Process -FilePath $pythonExe -ArgumentList $tmpCreate -Wait -NoNewWindow -PassThru
        if ($createRes.ExitCode -ne 0) {
            Log "[WARNING] Не удалось создать PeriodicTask"
            return $false
        }

        Log "Запуск test worker (для приема задач от beat) с include задаче..."
        # Windows: prefork/billiard часто падает с WinError 5 (semlock). Для автотеста используем solo pool.
        $workerArgs = "-m celery -A src.config.celery.celery_app worker --loglevel=info -Q default --pool=solo --concurrency=1 -n beat_test_worker@%h --include=_ergo_celery_test_task"
        $workerProc = Start-Process -FilePath $pythonExe -ArgumentList $workerArgs -NoNewWindow -PassThru
        Start-Sleep -Seconds 8
        if ($workerProc.HasExited) {
            Log ("[WARNING] beat-test worker завершился преждевременно, ExitCode=" + $workerProc.ExitCode)
            return $false
        }

        Log "Ожидание срабатывания periodic task (до 25с)..."
        $deadline = (Get-Date).AddSeconds(25)
        $ok = $false
        while ((Get-Date) -lt $deadline) {
            $checkScript = @"
import django
django.setup()
from django_celery_beat.models import PeriodicTask
pt = PeriodicTask.objects.filter(name='$periodicName').first()
if not pt:
    raise SystemExit(2)
cnt = pt.total_run_count or 0
print(cnt)
raise SystemExit(0 if cnt >= 1 else 1)
"@
            Set-Content -LiteralPath $tmpCheck -Value $checkScript -Encoding UTF8
            $chk = Start-Process -FilePath $pythonExe -ArgumentList $tmpCheck -Wait -NoNewWindow -PassThru
            if ($chk.ExitCode -eq 0) { $ok = $true; break }
            Start-Sleep -Seconds 3
        }

        if ($ok) {
            Log "beat execution test: OK (PeriodicTask.total_run_count >= 1)"
            return $true
        } else {
            Log "[WARNING] beat execution test: FAILED (PeriodicTask не сработала за таймаут)"
            return $false
        }
    } finally {
        try {
            Log "Удаление временной PeriodicTask..."
            $cleanupScript = @"
import django
django.setup()
from django_celery_beat.models import PeriodicTask
PeriodicTask.objects.filter(name='$periodicName').delete()
"@
            Set-Content -LiteralPath $tmpCleanup -Value $cleanupScript -Encoding UTF8
            [void](Start-Process -FilePath $pythonExe -ArgumentList $tmpCleanup -Wait -NoNewWindow -PassThru)
        } catch { }
        try {
            if ($workerProc -and -not $workerProc.HasExited) {
                Log ("Остановка beat-test worker PID=" + $workerProc.Id)
                try { Stop-Process -Id $workerProc.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
        } catch { }
        try { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        Set-Location $RootDir
    }
}

Step "Celery: подготовка (стоп) и запуск API + beat"
Stop-AllErgoms
Enable-ErgoServicesForStart
Test-ServiceAction -Action "start" -ServiceName "ergo-api-dev"
Start-Sleep -Seconds 4
Test-ServiceAction -Action "start" -ServiceName "ergo-celery-beat"
Start-Sleep -Seconds 3
Test-ServiceAction -Action "status" -ServiceName "ergo-celery-beat"

Step "Celery Beat: show_next_tasks (расписание)"
if (Run-CeleryBeatShowNextTasks) { Log "show_next_tasks: OK" } else { Log "[WARNING] show_next_tasks: FAILED" }

Step "Celery Beat: проверка фактического исполнения (временная periodic task)"
if (Run-CeleryBeatExecutionTest) { Log "beat execution: OK" } else { Log "[WARNING] beat execution: FAILED" }

Step "Celery Workers: соответствие celery_workers.yaml и служб (много/мало)"
$yamlState = $null
try {
    $yamlState = Backup-AndPrepareWorkersYaml

    Step "Celery Workers: сценарий 'мало' (1 worker) -> install-worker-service -> сверка служб"
    Write-WorkersYaml -Keys @("one")
    [void](Reinstall-WorkerServicesFromYaml)
    [void](Assert-WorkersServicesMatchConfig)

    Step "Celery Workers: сценарий 'много' (8 workers) -> install-worker-service -> сверка служб"
    Write-WorkersYaml -Keys @("w1","w2","w3","w4","w5","w6","w7","w8")
    [void](Reinstall-WorkerServicesFromYaml)
    [void](Assert-WorkersServicesMatchConfig)

    Step "Celery Workers: возврат к исходному celery_workers.yaml -> install-worker-service -> сверка служб"
    Restore-WorkersYaml -State $yamlState
    $yamlState = $null
    [void](Reinstall-WorkerServicesFromYaml)
    [void](Assert-WorkersServicesMatchConfig)
} finally {
    # Если что-то упало посреди сценариев — всё равно восстановим yaml.
    if ($yamlState) { Restore-WorkersYaml -State $yamlState }
}

Step "Celery Workers: запуск служб (все ergo-celery-worker-*)"
if (Start-AndCheckWorkerServices) { Log "worker services: OK" } else { Log "[WARNING] worker services: FAILED" }

Step "Celery Worker: проверка через задачу (send_task -> result.get)"
if (Run-CeleryWorkerTaskTest) { Log "worker task execution: OK" } else { Log "[WARNING] worker task execution: FAILED" }

Step "Celery: стоп"
try { Stop-Service -Name "ergo-celery-beat" -Force -ErrorAction SilentlyContinue } catch { }
try { Stop-Service -Name "ergo-api-dev" -Force -ErrorAction SilentlyContinue } catch { }
Stop-AllErgoms

