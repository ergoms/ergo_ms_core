$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RootDir = (Resolve-Path "$ScriptDir\..\..\..\..\..").ProviderPath
Set-Location $RootDir

$InstallTest = Join-Path $ScriptDir "install_test.ps1"
$RunTest = Join-Path $ScriptDir "run_test.ps1"
$CommandsTest = Join-Path $ScriptDir "commands_test.ps1"

$files = @($InstallTest, $RunTest, $CommandsTest)

foreach ($f in $files) {
    if (-not (Test-Path $f)) {
        Write-Error "Ошибка: не найден скрипт $f"
        exit 1
    }
}

Write-Host "=== test.ps1: этап установки (install_test.ps1) ===" -ForegroundColor Cyan
& $InstallTest

Write-Host "`n=== test.ps1: этап запуска (run_test.ps1) ===" -ForegroundColor Cyan
& $RunTest

Write-Host "`n=== test.ps1: этап команд (commands_test.ps1) ===" -ForegroundColor Cyan
& $CommandsTest

Write-Host "`n=== test.ps1: все этапы завершены ===" -ForegroundColor Green
