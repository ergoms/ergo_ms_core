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

    if (Get-Command Write-ErgomsMessage -ErrorAction SilentlyContinue) {
        Write-ErgomsMessage -Key 'help_unavailable_full' -Color Red -Stderr
        Write-ErgomsMessage -Key 'help_setup_hint_full' -Color Yellow -Stderr
        Write-ErgomsMessage -Key 'help_doc_hint' -Color Cyan -Stderr
    }
    else {
        Write-ColorOutput '[ERROR] Help unavailable: virtual environment or ergoms_help.py not found' Red
        Write-ColorOutput '  Run initial setup: ergoms setup or ergoms setup-full' Yellow
        Write-ColorOutput '  See: .docs/cli.md' Cyan
    }
    exit 1
}
