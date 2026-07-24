# Вход из core/deployment/bin/ergoms.cmd: проверка cwd, затем ergo_ms.ps1.

$ErrorActionPreference = 'Stop'

$projectRoot = $env:ERGO_MS_ROOT
if ([string]::IsNullOrWhiteSpace($projectRoot)) {
    $projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
} else {
    $projectRoot = (Resolve-Path $projectRoot).Path
}

$projectRoot = $projectRoot.TrimEnd('\', '/')
$cwd = (Get-Location).Path.TrimEnd('\', '/')

$inProject = $cwd.Equals($projectRoot, [StringComparison]::OrdinalIgnoreCase)
if (-not $inProject) {
    $prefix = $projectRoot + [IO.Path]::DirectorySeparatorChar
    $inProject = $cwd.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

if (-not $inProject) {
    Write-Host "[ERROR] Запускайте ergoms из каталога проекта или его подпапок: $projectRoot" -ForegroundColor Red
    exit 1
}

$mainScript = Join-Path $PSScriptRoot 'ergo_ms.ps1'
& $mainScript -Root $projectRoot @args
exit $LASTEXITCODE
