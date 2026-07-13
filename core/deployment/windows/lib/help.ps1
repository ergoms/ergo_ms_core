# Справка ergoms (ядро и модули через ergoms_help.py)

function Show-Help {
    param(
        [string]$ProjectRoot = '',
        [string[]]$HelpArgs = @()
    )

    $root = $ProjectRoot
    if (-not $root) {
        try {
            $root = Get-ProjectRoot -ProvidedRoot ''
        }
        catch {
            $root = ''
        }
    }

    if ($root) {
        $pythonExe = Join-Path $root 'virtual_env\python\Scripts\python.exe'
        $scriptPath = Join-Path $root 'core\deployment\scripts\ergoms_help.py'
        if ((Test-Path $pythonExe) -and (Test-Path $scriptPath)) {
            & $pythonExe $scriptPath --platform windows --root $root @HelpArgs
            if ($LASTEXITCODE -ne 0) {
                exit $LASTEXITCODE
            }
            return
        }
    }

    Write-ColorOutput '[ERROR] Справка недоступна: не найдено виртуальное окружение или ergoms_help.py' Red
    Write-ColorOutput '  Выполните первичную настройку: ergoms setup или ergoms setup-full' Yellow
    Write-ColorOutput '  Подробнее: .docs/cli.md' Cyan
    exit 1
}
