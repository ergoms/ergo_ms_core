# Detached: free Cursor :8000, restart Docker API on 8000, restore menu.
$ErrorActionPreference = 'Continue'
$root = 'C:\projects\ergo_ms'
$log = Join-Path $root 'logs\docker\free8000_and_up.log'
function Log([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Add-Content -Path $log -Value $line -Encoding UTF8
  Write-Output $line
}

Set-Location $root
Log 'start'

# 1) Stop stack so 18000 is released
Log 'docker-down'
& ergoms docker-down *>> $log 2>&1
Log "docker-down exit=$LASTEXITCODE"

# 2) Kill non-docker listeners on 8000 (Cursor port-forward)
$conns = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue
foreach ($c in $conns) {
  $procId = $c.OwningProcess
  if (-not $procId) { continue }
  $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
  $name = if ($proc) { $proc.ProcessName } else { 'unknown' }
  if ($name -match 'docker|com.docker|vpnkit') {
    Log "skip docker-related pid=$procId name=$name"
    continue
  }
  Log "taskkill pid=$procId name=$name"
  & taskkill /PID $procId /F *>> $log 2>&1
}
Start-Sleep -Seconds 2

# 3) Bring stack up on API_PORT=8000
Log 'docker-up'
& ergoms docker-up *>> $log 2>&1
Log "docker-up exit=$LASTEXITCODE"

# 4) Wait for API
$ok = $false
for ($i = 0; $i -lt 60; $i++) {
  try {
    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8000/api/cms/adp/password-reset-settings/' -Headers @{ Origin = 'http://localhost:8001' } -UseBasicParsing -TimeoutSec 3
    if ($r.StatusCode -eq 200 -and $r.Headers['Access-Control-Allow-Origin']) {
      $ok = $true
      Log "api ok status=$($r.StatusCode) ACAO=$($r.Headers['Access-Control-Allow-Origin'])"
      break
    }
  } catch {
    # retry
  }
  Start-Sleep -Seconds 2
}
if (-not $ok) { Log 'api not ready after wait' }

# 5) Restore CMS menu in container DB
Log 'restore_menu'
docker exec ergo_ms-api-1 ergoms api restore_menu *>> $log 2>&1
Log "restore_menu exit=$LASTEXITCODE"

docker ps --format '{{.Names}} {{.Ports}}' *>> $log 2>&1
Log 'done'
