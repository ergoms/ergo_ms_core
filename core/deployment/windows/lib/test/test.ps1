$ErrorActionPreference = "Stop"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RootDir = (Resolve-Path "$ScriptDir\..\..\..\..\..").ProviderPath
Set-Location $RootDir

. "$ScriptDir\lib.ps1"

$InstallTest = Join-Path $ScriptDir "install_test.ps1"
$CommandsTest = Join-Path $ScriptDir "commands_test.ps1"
$RunTest = Join-Path $ScriptDir "run_test.ps1"

$files = @($InstallTest, $CommandsTest, $RunTest)
foreach ($f in $files) {
    if (-not (Test-Path $f)) {
        Write-Error "Ошибка: не найден скрипт $f"
        exit 1
    }
}

function Invoke-TestStageScript {
    param([string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    & $resolved
}

function Write-Dot {
    param([string]$Color)
    Write-Host "●" -NoNewline -ForegroundColor $Color
}

function Print-Checklist {
    param([hashtable]$Status, [string]$ErrorMessage, [int]$ExitCode = 0)
    Write-Host ""
    Step "Чек-лист проверок (test_system): итог"
    $items = @(
        @{ key = "install"; name = "install_test.ps1 (окружение)" },
        @{ key = "run"; name = "run_test.ps1 (запуск)" },
        @{ key = "commands"; name = "commands_test.ps1 (команды)" }
    )
    foreach ($it in $items) {
        $s = $Status[$it.key]
        if (-not $s) { $s = "pending" }
        if ($s -eq "ok") { Write-Dot Green }
        elseif ($s -eq "fail") { Write-Dot Red }
        else { Write-Dot Yellow }
        Write-Host (" " + $it.name)
        Log ("[RESULT] {0} - {1}" -f $it.name, $s)
    }
    if ($ErrorMessage) {
        Write-Host "`nОшибка, из-за которой остановился скрипт:" -ForegroundColor Red
        Write-Host $ErrorMessage
        Log ("[ERROR] test_system: " + $ErrorMessage)
    }
    Log ("[RESULT] test_system: код выхода = " + $ExitCode)
}

$status = @{ install="pending"; commands="pending"; run="pending" }
$finalError = ""; $exitCode = 0

try {
    Step "test.ps1: этап 1/3 - install_test.ps1 (окружение, установка)"
    $status.install = "fail"
    Invoke-TestStageScript -Path $InstallTest
    $status.install = "ok"
    Log "[OK] test_system: install_test.ps1 пройден; переход к run_test"

    Step "test.ps1: этап 2/3 - run_test.ps1 (запуск, сервисы)"
    $status.run = "fail"
    Invoke-TestStageScript -Path $RunTest
    $status.run = "ok"
    Log "[OK] test_system: run_test.ps1 пройден; переход к commands_test"

    Step "test.ps1: этап 3/3 - commands_test.ps1 (команды, fin setup)"
    $status.commands = "fail"
    Invoke-TestStageScript -Path $CommandsTest
    $status.commands = "ok"

    Log "[OK] test_system: все три этапа завершены (install, run, commands). Тесты прошли."
} catch {
    $finalError = $_.Exception.Message
    $exitCode = 1
    try { Log ("[ERROR] test_system: прервано - " + $finalError) } catch { }
} finally {
    Print-Checklist -Status $status -ErrorMessage $finalError -ExitCode $exitCode
    exit $exitCode
}
