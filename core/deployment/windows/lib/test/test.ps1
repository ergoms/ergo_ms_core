$ErrorActionPreference = "Stop"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RootDir = (Resolve-Path "$ScriptDir\..\..\..\..\..").ProviderPath
Set-Location $RootDir

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
    param([hashtable]$Status, [string]$ErrorMessage)
    Write-Host "`n=== Чек-лист проверок ===" -ForegroundColor Cyan
    $items = @(
        @{ key = "install"; name = "install_test.ps1 (Окружение)" },
        @{ key = "commands"; name = "commands_test.ps1 (Команды)" },
        @{ key = "run"; name = "run_test.ps1 (Запуск)" }
    )
    foreach ($it in $items) {
        $s = $Status[$it.key]
        if (-not $s) { $s = "pending" }
        if ($s -eq "ok") { Write-Dot Green }
        elseif ($s -eq "fail") { Write-Dot Red }
        else { Write-Dot Yellow }
        Write-Host (" " + $it.name)
    }
    if ($ErrorMessage) {
        Write-Host "`nОшибка, из-за которой остановился скрипт:" -ForegroundColor Red
        Write-Host $ErrorMessage
    }
}

$status = @{ install="pending"; commands="pending"; run="pending" }
$finalError = ""; $exitCode = 0

try {
    Write-Host "=== test.ps1: этап проверки окружения (install_test.ps1) ===" -ForegroundColor Cyan
    $status.install = "fail"
    Invoke-TestStageScript -Path $InstallTest
    $status.install = "ok"

    Write-Host "`n=== test.ps1: этап проверки запуска (run_test.ps1) ===" -ForegroundColor Cyan
    $status.run = "fail"
    Invoke-TestStageScript -Path $RunTest
    $status.run = "ok"

    Write-Host "`n=== test.ps1: этап проверки команд (commands_test.ps1) ===" -ForegroundColor Cyan
    $status.commands = "fail"
    Invoke-TestStageScript -Path $CommandsTest
    $status.commands = "ok"

    Write-Host "`n=== test.ps1: все этапы завершены ===" -ForegroundColor Green
} catch {
    $finalError = $_.Exception.Message
    $exitCode = 1
} finally {
    Print-Checklist -Status $status -ErrorMessage $finalError
    exit $exitCode
}
