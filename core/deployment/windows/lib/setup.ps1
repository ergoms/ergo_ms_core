# Full system setup
# Полная настройка системы

function Setup-FullSystem {
    param(
        [string]$Root,
        [bool]$RecreateVenv = $false
    )
    
    Write-ColorOutput "`n=== Full System Setup ===" Cyan
    Write-ColorOutput ""
    
    # Step 1: Git submodules
    Write-ColorOutput "-> Step 1/7: Updating git submodules..." Yellow
    Push-Location $Root
    try {
        & git submodule update --init --remote core/api core/client
        if ($LASTEXITCODE -ne 0) { throw "Git submodule update failed" }
        
        Push-Location "core\api"
        & git checkout dev
        Pop-Location
        
        Push-Location "core\client"
        & git checkout dev
        Pop-Location
        
        Write-ColorOutput "[OK] Git submodules updated" Green
    }
    catch {
        Write-ColorOutput "[ERROR] Failed to update git submodules: $($_.Exception.Message)" Red
        Pop-Location
        exit 1
    }
    finally {
        Pop-Location
    }
    
    # Step 2: Create virtual environment
    Write-ColorOutput "-> Step 2/7: Creating Python virtual environment..." Yellow
    $venvPath = Join-Path $Root "virtual_env\python"
    $venvActivate = Join-Path $venvPath "Scripts\activate.bat"
    $pipExe = Join-Path $venvPath "Scripts\pip.exe"
    $pythonExe = Join-Path $venvPath "Scripts\python.exe"
    
    $needsRecreation = $false
    
    if (Test-Path $venvPath) {
        # Check if directory is empty or contains only .gitkeep
        $dirContents = Get-ChildItem -Path $venvPath -Force -ErrorAction SilentlyContinue
        $isEmpty = $dirContents -eq $null -or $dirContents.Count -eq 0
        $onlyGitkeep = $dirContents -and $dirContents.Count -eq 1 -and $dirContents[0].Name -eq '.gitkeep'
        
        if ($isEmpty -or $onlyGitkeep) {
            Write-ColorOutput "  Directory exists but is empty, will create virtual environment..." Gray
            $needsRecreation = $true
        }
        else {
            Write-ColorOutput "  Virtual environment already exists" Gray
            
            # Force recreation if RecreateVenv flag is set
            if ($RecreateVenv) {
                Write-ColorOutput "  Force recreation requested" Yellow
                $needsRecreation = $true
            }
            else {
                # Check if virtual environment is valid
                $isValid = $true
                
                # Check for essential files
                if (-not (Test-Path $pythonExe)) {
                    Write-ColorOutput "  Missing python.exe, will recreate..." Yellow
                    $isValid = $false
                }
                elseif (-not (Test-Path $pipExe)) {
                    Write-ColorOutput "  Missing pip.exe, will recreate..." Yellow
                    $isValid = $false
                }
                elseif (-not (Test-Path $venvActivate)) {
                    Write-ColorOutput "  Missing activate.bat, will recreate..." Yellow
                    $isValid = $false
                }
                else {
                    # Test if Python works in the virtual environment
                    try {
                        & $pythonExe --version 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) {
                            Write-ColorOutput "  Python in virtual environment not working, will recreate..." Yellow
                            $isValid = $false
                        } else {
                            Write-ColorOutput "  Virtual environment is valid" Green
                        }
                    }
                    catch {
                        Write-ColorOutput "  Error testing virtual environment, will recreate..." Yellow
                        $isValid = $false
                    }
                }
                
                if (-not $isValid) {
                    $needsRecreation = $true
                }
            }
        }
    }
    else {
        $needsRecreation = $true
    }
    
    if ($needsRecreation) {
        # Check if directory exists and what's in it
        if (Test-Path $venvPath) {
            $dirContents = Get-ChildItem -Path $venvPath -Force -ErrorAction SilentlyContinue
            $isEmpty = $dirContents -eq $null -or $dirContents.Count -eq 0
            $onlyGitkeep = $dirContents -and $dirContents.Count -eq 1 -and $dirContents[0].Name -eq '.gitkeep'
            
            if (-not $isEmpty -and -not $onlyGitkeep) {
                # Directory has content other than .gitkeep, remove it
                Write-ColorOutput "  Removing corrupted virtual environment..." Yellow
                Remove-Item $venvPath -Recurse -Force
            }
            else {
                # Directory is empty or only has .gitkeep, create venv in existing directory
                Write-ColorOutput "  Directory exists but is empty, will create virtual environment in existing directory..." Gray
            }
        }
        else {
            # Directory doesn't exist, create it
            Write-ColorOutput "  Creating directory and virtual environment..." Gray
            New-Item -ItemType Directory -Path $venvPath -Force | Out-Null
        }
        
        try {
            Write-ColorOutput "  Creating new virtual environment..." Gray
            & py -3.12 -m venv $venvPath
            if ($LASTEXITCODE -ne 0) { throw "Failed to create venv" }
            Write-ColorOutput "[OK] Virtual environment created" Green
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to create virtual environment: $($_.Exception.Message)" Red
            Write-ColorOutput "  Python command used: py -3.12 -m venv" Gray
            Write-ColorOutput "  Target path: $venvPath" Gray
            exit 1
        }
    }
    
    # Step 3: Install Poetry
    Write-ColorOutput "-> Step 3/7: Installing Poetry..." Yellow
    $venvActivate = Join-Path $venvPath "Scripts\activate.bat"
    $pipExe = Join-Path $venvPath "Scripts\pip.exe"
    
    if (-not (Test-Path $pipExe)) {
        Write-ColorOutput "[ERROR] pip not found in virtual environment" Red
        exit 1
    }
    
    try {
        Write-ColorOutput "  Installing Poetry using: $pipExe" Gray
        & $pipExe install poetry
        if ($LASTEXITCODE -ne 0) { 
            Write-ColorOutput "  pip exit code: $LASTEXITCODE" Red
            throw "Poetry installation failed" 
        }
        # Verify Poetry installation
        $poetryExe = Join-Path $venvPath "Scripts\poetry.exe"
        if (Test-Path $poetryExe) {
            Write-ColorOutput "[OK] Poetry installed and verified" Green
        } else {
            Write-ColorOutput "[WARNING] Poetry installed but executable not found at: $poetryExe" Yellow
        }
    }
    catch {
        Write-ColorOutput "[ERROR] Failed to install Poetry: $($_.Exception.Message)" Red
        Write-ColorOutput "  pip executable: $pipExe" Gray
        Write-ColorOutput "  Virtual environment: $venvPath" Gray
        exit 1
    }
    
    # Step 4: Install CLI wrapper
    Write-ColorOutput "-> Step 4/7: Installing ErgoMS CLI..." Yellow
    Install-CliWrapper
    
    # Step 5: Run setup (poetry install && npm install && npm run build && api migrate)
    Write-ColorOutput "-> Step 5/7: Running ergoms setup..." Yellow
    Push-Location $Root
    try {
        # Activate virtual environment and run commands
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
        
        Push-Location "core"
        try {
            & poetry install
            if ($LASTEXITCODE -ne 0) { throw "Poetry install failed" }
            
            & npm install
            if ($LASTEXITCODE -ne 0) { throw "NPM install failed" }
            
            & npm run build
            if ($LASTEXITCODE -ne 0) { throw "NPM run build failed" }
            
            & api migrate
            if ($LASTEXITCODE -ne 0) { throw "API migrate failed" }
        }
        finally {
            Pop-Location
        }
        
        Write-ColorOutput "[OK] Setup completed" Green
    }
    catch {
        Write-ColorOutput "[ERROR] Setup failed: $($_.Exception.Message)" Red
        Pop-Location
        exit 1
    }
    finally {
        Pop-Location
    }
    
    # Step 6: Collect static
    Write-ColorOutput "-> Step 6/7: Collecting static files..." Yellow
    Push-Location $Root
    try {
        # Activate virtual environment and run command
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
        
        Push-Location "core"
        try {
            & api collectstatic --noinput
            if ($LASTEXITCODE -ne 0) { throw "Collectstatic failed" }
        }
        finally {
            Pop-Location
        }
        
        Write-ColorOutput "[OK] Static files collected" Green
    }
    catch {
        Write-ColorOutput "[ERROR] Failed to collect static: $($_.Exception.Message)" Red
        Pop-Location
        exit 1
    }
    finally {
        Pop-Location
    }
    
    # Step 7: Setup complete (services not installed)
    Write-ColorOutput "-> Step 7/7: Setup complete" Yellow
    
    Write-ColorOutput "`n=== Full System Setup Complete ===" Green
    Write-ColorOutput ""
    Write-ColorOutput "System is ready! To install and start services, run:" Cyan
    Write-ColorOutput "  ergoms install-services" Yellow
    Write-ColorOutput ""
    Write-ColorOutput "You can now use 'ergoms' commands to manage your system." Cyan
}

# Export-ModuleMember -Function *  # Удалено, так как это не модуль

