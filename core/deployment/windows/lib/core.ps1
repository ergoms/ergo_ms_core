# Core utilities for ErgoMS deployment
# Базовые утилиты для развертывания ErgoMS

# Константы
$script:ServiceNames = @(
    'ergo-api-dev',
    'ergo-client-dev',
    'ergo-celery-worker',
    'ergo-celery-beat'
)

$script:CliName = 'ergoms'
$script:CliPath = "$env:SystemRoot\System32\$script:CliName.bat"

function Write-ColorOutput {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ProjectRoot {
    param([string]$ProvidedRoot)

    if ($ProvidedRoot) {
        if (Test-Path $ProvidedRoot) {
            return (Resolve-Path $ProvidedRoot).Path
        }
        throw "Provided root path does not exist: $ProvidedRoot"
    }

    # Auto-detect from script location
    $scriptDir = Split-Path -Parent $PSCommandPath
    $projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)

    # Try git root
    try {
        Push-Location $scriptDir
        $gitRoot = git rev-parse --show-toplevel 2>$null
        if ($gitRoot) {
            Pop-Location
            return (Resolve-Path $gitRoot).Path
        }
    }
    catch {
        # Ignore git errors
    }
    finally {
        Pop-Location
    }

    return $projectRoot
}

function Get-ProjectLogsDir {
    param([string]$ProjectRoot)
    return Join-Path $ProjectRoot "logs"
}

function Get-ProjectWrappersDir {
    param([string]$ProjectRoot)
    return Join-Path $ProjectRoot "core\deployment\wrappers"
}

function Test-ProjectStructure {
    param([string]$Root)

    $apiPath = Join-Path $Root "core\api"
    $clientPath = Join-Path $Root "core\client"

    if (-not (Test-Path $apiPath)) {
        Write-ColorOutput "[ERROR] Invalid project root: $apiPath not found" Red
        Write-ColorOutput "Run 'ergoms setup' to initialize all submodules." Yellow
        throw "Invalid project root: $apiPath not found"
    }
    if (-not (Test-Path $clientPath)) {
        Write-ColorOutput "[ERROR] Invalid project root: $clientPath not found" Red
        Write-ColorOutput "Run 'ergoms setup' to initialize all submodules." Yellow
        throw "Invalid project root: $clientPath not found"
    }

    Write-ColorOutput "[OK] Project structure validated" Green
}

function Get-ServiceNames {
    return $script:ServiceNames
}

function Get-CliName {
    return $script:CliName
}

function Get-CliPath {
    return $script:CliPath
}

# Export-ModuleMember -Function *  # Удалено, так как это не модуль

