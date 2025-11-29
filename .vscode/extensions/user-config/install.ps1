# ERGO MS User Config Extension Installer for Windows
# Installs the extension to VS Code or Cursor

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExtensionName = "ergo-user-config"

function Get-Editor {
    # Check for Cursor first
    $cursorPath = Get-Command cursor -ErrorAction SilentlyContinue
    if ($cursorPath) {
        return "cursor"
    }
    
    # Check for VS Code
    $codePath = Get-Command code -ErrorAction SilentlyContinue
    if ($codePath) {
        return "code"
    }
    
    return $null
}

function Get-ExtensionsDir {
    param([string]$Editor)
    
    $userProfile = $env:USERPROFILE
    
    if ($Editor -eq "cursor") {
        return Join-Path $userProfile ".cursor\extensions"
    }
    else {
        return Join-Path $userProfile ".vscode\extensions"
    }
}

function Install-Extension {
    $editor = Get-Editor
    
    if (-not $editor) {
        Write-Host "[WARN] Neither VS Code nor Cursor found in PATH" -ForegroundColor Yellow
        Write-Host "  Trying to install to default locations..." -ForegroundColor Gray
        
        # Try both locations
        $locations = @(
            (Join-Path $env:USERPROFILE ".vscode\extensions"),
            (Join-Path $env:USERPROFILE ".cursor\extensions")
        )
        
        foreach ($extDir in $locations) {
            $parentDir = Split-Path -Parent $extDir
            if (Test-Path $parentDir) {
                if (-not (Test-Path $extDir)) {
                    New-Item -ItemType Directory -Path $extDir -Force | Out-Null
                }
                
                $targetDir = Join-Path $extDir $ExtensionName
                
                if (Test-Path $targetDir) {
                    Remove-Item $targetDir -Recurse -Force
                }
                
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                Copy-Item (Join-Path $ScriptDir "package.json") -Destination $targetDir
                Copy-Item (Join-Path $ScriptDir "extension.js") -Destination $targetDir
                
                Write-Host "[OK] Installed to: $targetDir" -ForegroundColor Green
            }
        }
        return
    }
    
    $extDir = Get-ExtensionsDir -Editor $editor
    
    Write-Host "-> Installing $ExtensionName for $editor..." -ForegroundColor Cyan
    Write-Host "   Extensions directory: $extDir" -ForegroundColor Gray
    
    # Create extensions directory if needed
    if (-not (Test-Path $extDir)) {
        New-Item -ItemType Directory -Path $extDir -Force | Out-Null
    }
    
    $targetDir = Join-Path $extDir $ExtensionName
    
    # Remove old version if exists
    if (Test-Path $targetDir) {
        Write-Host "   Removing old version..." -ForegroundColor Gray
        Remove-Item $targetDir -Recurse -Force
    }
    
    # Create extension directory
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    
    # Copy extension files
    Copy-Item (Join-Path $ScriptDir "package.json") -Destination $targetDir
    Copy-Item (Join-Path $ScriptDir "extension.js") -Destination $targetDir
    
    Write-Host "[OK] Extension installed to: $targetDir" -ForegroundColor Green
    Write-Host ""
    Write-Host "Please restart VS Code/Cursor to activate the extension." -ForegroundColor Yellow
    Write-Host "The extension will automatically apply settings from:" -ForegroundColor Cyan
    Write-Host "  - .vscode/user_settings.json" -ForegroundColor Gray
    Write-Host "  - .vscode/user_keybindings.json" -ForegroundColor Gray
}

Install-Extension

