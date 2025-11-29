# ERGO MS User Config Extension Uninstaller for Windows
# Removes the extension from VS Code and Cursor

$ExtensionName = "ergo-user-config"

function Uninstall-Extension {
    $removed = 0
    
    Write-Host "-> Uninstalling $ExtensionName..." -ForegroundColor Cyan
    
    # Check VS Code extensions
    $vscodeDir = Join-Path $env:USERPROFILE ".vscode\extensions\$ExtensionName"
    if (Test-Path $vscodeDir) {
        Remove-Item $vscodeDir -Recurse -Force
        Write-Host "[OK] Removed from VS Code: $vscodeDir" -ForegroundColor Green
        $removed++
    }
    
    # Check Cursor extensions
    $cursorDir = Join-Path $env:USERPROFILE ".cursor\extensions\$ExtensionName"
    if (Test-Path $cursorDir) {
        Remove-Item $cursorDir -Recurse -Force
        Write-Host "[OK] Removed from Cursor: $cursorDir" -ForegroundColor Green
        $removed++
    }
    
    if ($removed -eq 0) {
        Write-Host "[SKIP] Extension not found in any location" -ForegroundColor Gray
    }
    else {
        Write-Host ""
        Write-Host "Extension removed from $removed location(s)." -ForegroundColor Green
        Write-Host "Please restart VS Code/Cursor to complete uninstallation." -ForegroundColor Yellow
    }
}

Uninstall-Extension

