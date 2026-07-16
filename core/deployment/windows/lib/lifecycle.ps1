# Lifecycle runner invocation for Windows ergo_ms

function Invoke-LifecycleRunner {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$Recipe,
        [string[]]$ExtraArgs = @()
    )

    $runner = Join-Path $Root 'core\deployment\lifecycle\runner.py'
    if (-not (Test-Path $runner)) {
        Write-ColorOutput "[ERROR] lifecycle runner не найден: $runner" Red
        exit 1
    }

    $venvPy = Join-Path $Root 'virtual_env\python\Scripts\python.exe'
    $argv = @($runner, $Recipe) + $ExtraArgs

    if ($Recipe -eq 'setup-full' -and -not (Test-Path $venvPy)) {
        if (Get-Command py -ErrorAction SilentlyContinue) {
            & py -3.12 @argv
        } else {
            & python @argv
        }
    } elseif (Test-Path $venvPy) {
        & $venvPy @argv
    } elseif (Get-Command py -ErrorAction SilentlyContinue) {
        & py -3.12 @argv
    } else {
        & python @argv
    }

    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
