# CLI wrapper management
# Управление CLI wrapper

function Install-CliWrapper {
    $selfScript = $PSCommandPath
    # Navigate up to find main script
    $libDir = Split-Path -Parent $selfScript
    $windowsDir = Split-Path -Parent $libDir
    $mainScript = Join-Path $windowsDir "ergo_ms.ps1"
    
    $cliPath = Get-CliPath
    $content = @(
        '@echo off',
        "powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$mainScript`" %*"
    ) -join "`r`n"
    
    Set-Content -Path $cliPath -Value $content -Encoding ASCII
    Write-ColorOutput "[OK] CLI wrapper installed: $cliPath" Green
    $cliName = Get-CliName
    Write-ColorOutput "  You can now use: $cliName start|stop|restart|status" Cyan
}

function Uninstall-CliWrapper {
    $cliPath = Get-CliPath
    if (Test-Path $cliPath) {
        Remove-Item $cliPath -Force
        Write-ColorOutput "[OK] CLI wrapper removed: $cliPath" Green
    }
    else {
        Write-ColorOutput "- CLI wrapper not found" Gray
    }
}

# Export-ModuleMember -Function *  # Удалено, так как это не модуль

