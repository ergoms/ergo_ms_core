# CLI wrapper management
# Управление CLI wrapper

function Install-CliWrapper {
    $selfScript = $PSCommandPath
    # Navigate up to find main script
    $libDir = Split-Path -Parent $selfScript
    $windowsDir = Split-Path -Parent $libDir
    $mainScript = Join-Path $windowsDir "ergo_ms.ps1"

    # 1. Batch file — backward compatibility & non-PowerShell terminals
    $cliPath = Get-CliPath
    $batContent = @(
        '@echo off',
        "powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$mainScript`" %*"
    ) -join "`r`n"
    Set-Content -Path $cliPath -Value $batContent -Encoding ASCII
    Write-ColorOutput "[OK] CLI batch wrapper installed: $cliPath" Green

    # 2. PowerShell profile function — correctly handles special characters like >= <= | &
    #    The batch file passes %* through CMD which interprets > as redirect.
    #    The PS function calls the script directly with @args, bypassing CMD entirely.
    $profilePath = $PROFILE
    $profileDir  = Split-Path -Parent $profilePath
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }

    $startMarker = "# <<ergoms-cli>>"
    $endMarker   = "# <</ergoms-cli>>"
    $funcBlock   = @"

$startMarker
function ergoms { & "$mainScript" @args }
$endMarker
"@

    $profileContent = if (Test-Path $profilePath) { Get-Content $profilePath -Raw -Encoding UTF8 } else { "" }

    if ($profileContent -match [regex]::Escape($startMarker)) {
        # Replace existing block
        $profileContent = $profileContent -replace "(?s)$([regex]::Escape($startMarker)).*?$([regex]::Escape($endMarker))", $funcBlock.Trim()
        Set-Content -Path $profilePath -Value $profileContent -Encoding UTF8
        Write-ColorOutput "[OK] PowerShell profile function updated: $profilePath" Green
    } else {
        Add-Content -Path $profilePath -Value $funcBlock -Encoding UTF8
        Write-ColorOutput "[OK] PowerShell profile function added: $profilePath" Green
    }

    $cliName = Get-CliName
    Write-ColorOutput "  Перезапустите терминал или выполните: . `$PROFILE" Cyan
    Write-ColorOutput "  Команды: $cliName start|stop|restart|status" Cyan
    Write-ColorOutput "  Зависимости модулей: $cliName <модуль>:poetry add <пакет>" Cyan
}

function Uninstall-CliWrapper {
    # Remove batch file
    $cliPath = Get-CliPath
    if (Test-Path $cliPath) {
        Remove-Item $cliPath -Force
        Write-ColorOutput "[OK] CLI batch wrapper removed: $cliPath" Green
    } else {
        Write-ColorOutput "- CLI batch wrapper not found" Gray
    }

    # Remove PowerShell profile function
    $profilePath = $PROFILE
    $startMarker = "# <<ergoms-cli>>"
    $endMarker   = "# <</ergoms-cli>>"
    if (Test-Path $profilePath) {
        $profileContent = Get-Content $profilePath -Raw -Encoding UTF8
        if ($profileContent -match [regex]::Escape($startMarker)) {
            $profileContent = $profileContent -replace "(?s)\r?\n?$([regex]::Escape($startMarker)).*?$([regex]::Escape($endMarker))\r?\n?", ""
            Set-Content -Path $profilePath -Value $profileContent.TrimEnd() -Encoding UTF8
            Write-ColorOutput "[OK] PowerShell profile function removed: $profilePath" Green
        } else {
            Write-ColorOutput "- PowerShell profile function not found" Gray
        }
    }
}

# Export-ModuleMember -Function *  # Удалено, так как это не модуль

