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
        & git submodule update --init --remote core/api core/client core/django core/django_rest_framework core/media_api
        if ($LASTEXITCODE -ne 0) { throw "Git submodule update failed" }
        
        Push-Location "core\api"
        & git checkout dev
        Pop-Location
        
        Push-Location "core\client"
        & git checkout dev
        Pop-Location
        
        Push-Location "core\django"
        & git checkout dev
        Pop-Location

        Push-Location "core\django_rest_framework"
        & git checkout dev
        Pop-Location
        
        Push-Location "core\media_api"
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
        
        # Poetry install should be run from core directory
        Push-Location "core"
        try {
            & poetry install
            if ($LASTEXITCODE -ne 0) { throw "Poetry install failed" }
        }
        finally {
            Pop-Location
        }
        
        # npm commands should be run from project root (where package.json is)
        # Verify package.json exists in root
        $packageJsonPath = Join-Path $Root "package.json"
        if (-not (Test-Path $packageJsonPath)) {
            throw "package.json not found in project root: $Root"
        }
        
        # Find npm executable - try npm.cmd first (Windows batch file)
        $npmExe = $null
        try {
            $npmCmd = Get-Command npm.cmd -ErrorAction Stop
            $npmExe = $npmCmd.Source
            Write-ColorOutput "  Found npm: $npmExe" Gray
        }
        catch {
            try {
                $npmCmd = Get-Command npm -ErrorAction Stop
                $npmExe = $npmCmd.Source
                Write-ColorOutput "  Found npm: $npmExe" Gray
            }
            catch {
                throw "npm is not available or not working. Please install Node.js and npm, and ensure it's in your PATH."
            }
        }
        
        # Change to root directory for npm commands
        Push-Location $Root
        try {
            Write-ColorOutput "  Running: npm install (from: $(Get-Location))" Gray
            # Call npm directly using full path with argument array to avoid command truncation
            # Using argument array prevents PowerShell from interpreting the command incorrectly
            & $npmExe install
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) { 
                throw "NPM install failed with exit code: $exitCode" 
            }
            
            Write-ColorOutput "  Running: npm run build (from: $(Get-Location))" Gray
            & $npmExe run build
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) { 
                throw "NPM run build failed with exit code: $exitCode" 
            }
        }
        finally {
            Pop-Location
        }
        
        # api migrate should be run from core directory
        Push-Location "core"
        try {
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

# Clean project dependencies
# Очистка зависимостей проекта
function Clear-ProjectDependencies {
    param(
        [string]$Root
    )
    
    Write-ColorOutput "`n=== Cleaning Project Dependencies ===" Cyan
    Write-ColorOutput ""
    Write-ColorOutput "This will remove:" Yellow
    Write-ColorOutput "  - node_modules" Gray
    Write-ColorOutput "  - virtual_env/python/*" Gray
    Write-ColorOutput "  - virtual_env/static_api/*" Gray
    Write-ColorOutput "  - virtual_env/celery/*" Gray
    Write-ColorOutput "  - virtual_env/nodejs/*" Gray
    Write-ColorOutput "  - virtual_env/packages/*" Gray
    Write-ColorOutput "  - virtual_env/resources/*" Gray
    Write-ColorOutput "  - virtual_env/trained_models/*" Gray
    Write-ColorOutput "  - Project extensions (VS Code/Cursor)" Gray
    Write-ColorOutput ""
    Write-ColorOutput "Media folder will NOT be deleted." Green
    Write-ColorOutput ""
    
    $confirmation = Read-Host "Are you sure you want to continue? (y/N)"
    if ($confirmation -notmatch '^[yY]$') {
        Write-ColorOutput "Operation cancelled by user." Yellow
        return
    }
    
    # Step 1: Remove node_modules
    Write-ColorOutput "`n-> Step 1/8: Removing node_modules..." Yellow
    $nodeModulesPath = Join-Path $Root "node_modules"
    if (Test-Path $nodeModulesPath) {
        try {
            Remove-Item $nodeModulesPath -Recurse -Force -ErrorAction Stop
            Write-ColorOutput "[OK] node_modules removed" Green
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to remove node_modules: $($_.Exception.Message)" Red
        }
    }
    else {
        Write-ColorOutput "[SKIP] node_modules not found" Gray
    }
    
    # Step 2: Remove virtual_env/python/*
    Write-ColorOutput "`n-> Step 2/8: Cleaning virtual_env/python..." Yellow
    $pythonVenvPath = Join-Path $Root "virtual_env\python"
    if (Test-Path $pythonVenvPath) {
        try {
            $items = Get-ChildItem -Path $pythonVenvPath -Force -ErrorAction Stop
            $removedCount = 0
            foreach ($item in $items) {
                if ($item.Name -ne '.gitkeep') {
                    Remove-Item $item.FullName -Recurse -Force -ErrorAction Stop
                    $removedCount++
                }
            }
            if ($removedCount -gt 0) {
                Write-ColorOutput "[OK] Removed $removedCount items from virtual_env/python" Green
            }
            else {
                Write-ColorOutput "[SKIP] virtual_env/python is already empty" Gray
            }
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to clean virtual_env/python: $($_.Exception.Message)" Red
        }
    }
    else {
        Write-ColorOutput "[SKIP] virtual_env/python not found" Gray
    }
    
    # Step 3: Remove virtual_env/static_api/*
    Write-ColorOutput "`n-> Step 3/8: Cleaning virtual_env/static_api..." Yellow
    $staticPath = Join-Path $Root "virtual_env\static_api"
    if (Test-Path $staticPath) {
        try {
            $items = Get-ChildItem -Path $staticPath -Force -ErrorAction Stop
            $removedCount = 0
            foreach ($item in $items) {
                if ($item.Name -ne '.gitkeep') {
                    Remove-Item $item.FullName -Recurse -Force -ErrorAction Stop
                    $removedCount++
                }
            }
            if ($removedCount -gt 0) {
                Write-ColorOutput "[OK] Removed $removedCount items from virtual_env/static_api" Green
            }
            else {
                Write-ColorOutput "[SKIP] virtual_env/static_api is already empty" Gray
            }
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to clean virtual_env/static_api: $($_.Exception.Message)" Red
        }
    }
    else {
        Write-ColorOutput "[SKIP] virtual_env/static_api not found" Gray
    }
    
    # Step 4: Remove virtual_env/celery/*
    Write-ColorOutput "`n-> Step 4/8: Cleaning virtual_env/celery..." Yellow
    $celeryPath = Join-Path $Root "virtual_env\celery"
    if (Test-Path $celeryPath) {
        try {
            $items = Get-ChildItem -Path $celeryPath -Force -ErrorAction Stop
            $removedCount = 0
            foreach ($item in $items) {
                if ($item.Name -ne '.gitkeep') {
                    Remove-Item $item.FullName -Recurse -Force -ErrorAction Stop
                    $removedCount++
                }
            }
            if ($removedCount -gt 0) {
                Write-ColorOutput "[OK] Removed $removedCount items from virtual_env/celery" Green
            }
            else {
                Write-ColorOutput "[SKIP] virtual_env/celery is already empty" Gray
            }
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to clean virtual_env/celery: $($_.Exception.Message)" Red
        }
    }
    else {
        Write-ColorOutput "[SKIP] virtual_env/celery not found" Gray
    }
    
    # Step 5: Remove virtual_env/nodejs/*
    Write-ColorOutput "`n-> Step 5/8: Cleaning virtual_env/nodejs..." Yellow
    $nodejsPath = Join-Path $Root "virtual_env\nodejs"
    if (Test-Path $nodejsPath) {
        try {
            $items = Get-ChildItem -Path $nodejsPath -Force -ErrorAction Stop
            $removedCount = 0
            foreach ($item in $items) {
                if ($item.Name -ne '.gitkeep') {
                    Remove-Item $item.FullName -Recurse -Force -ErrorAction Stop
                    $removedCount++
                }
            }
            if ($removedCount -gt 0) {
                Write-ColorOutput "[OK] Removed $removedCount items from virtual_env/nodejs" Green
            }
            else {
                Write-ColorOutput "[SKIP] virtual_env/nodejs is already empty" Gray
            }
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to clean virtual_env/nodejs: $($_.Exception.Message)" Red
        }
    }
    else {
        Write-ColorOutput "[SKIP] virtual_env/nodejs not found" Gray
    }
    
    # Step 6: Remove virtual_env/packages/*
    Write-ColorOutput "`n-> Step 6/8: Cleaning virtual_env/packages..." Yellow
    $packagesPath = Join-Path $Root "virtual_env\packages"
    if (Test-Path $packagesPath) {
        try {
            $items = Get-ChildItem -Path $packagesPath -Force -ErrorAction Stop
            $removedCount = 0
            foreach ($item in $items) {
                if ($item.Name -ne '.gitkeep') {
                    Remove-Item $item.FullName -Recurse -Force -ErrorAction Stop
                    $removedCount++
                }
            }
            if ($removedCount -gt 0) {
                Write-ColorOutput "[OK] Removed $removedCount items from virtual_env/packages" Green
            }
            else {
                Write-ColorOutput "[SKIP] virtual_env/packages is already empty" Gray
            }
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to clean virtual_env/packages: $($_.Exception.Message)" Red
        }
    }
    else {
        Write-ColorOutput "[SKIP] virtual_env/packages not found" Gray
    }
    
    # Step 7: Remove virtual_env/resources/*
    Write-ColorOutput "`n-> Step 7/8: Cleaning virtual_env/resources..." Yellow
    $resourcesPath = Join-Path $Root "virtual_env\resources"
    if (Test-Path $resourcesPath) {
        try {
            $items = Get-ChildItem -Path $resourcesPath -Force -ErrorAction Stop
            $removedCount = 0
            foreach ($item in $items) {
                if ($item.Name -ne '.gitkeep') {
                    Remove-Item $item.FullName -Recurse -Force -ErrorAction Stop
                    $removedCount++
                }
            }
            if ($removedCount -gt 0) {
                Write-ColorOutput "[OK] Removed $removedCount items from virtual_env/resources" Green
            }
            else {
                Write-ColorOutput "[SKIP] virtual_env/resources is already empty" Gray
            }
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to clean virtual_env/resources: $($_.Exception.Message)" Red
        }
    }
    else {
        Write-ColorOutput "[SKIP] virtual_env/resources not found" Gray
    }
    
    # Step 8: Remove virtual_env/trained_models/*
    Write-ColorOutput "`n-> Step 8/8: Cleaning virtual_env/trained_models..." Yellow
    $modelsPath = Join-Path $Root "virtual_env\trained_models"
    if (Test-Path $modelsPath) {
        try {
            $items = Get-ChildItem -Path $modelsPath -Force -ErrorAction Stop
            $removedCount = 0
            foreach ($item in $items) {
                if ($item.Name -ne '.gitkeep') {
                    Remove-Item $item.FullName -Recurse -Force -ErrorAction Stop
                    $removedCount++
                }
            }
            if ($removedCount -gt 0) {
                Write-ColorOutput "[OK] Removed $removedCount items from virtual_env/trained_models" Green
            }
            else {
                Write-ColorOutput "[SKIP] virtual_env/trained_models is already empty" Gray
            }
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to clean virtual_env/trained_models: $($_.Exception.Message)" Red
        }
    }
    else {
        Write-ColorOutput "[SKIP] virtual_env/trained_models not found" Gray
    }
    
    Write-ColorOutput "`n=== Cleaning Complete ===" Green
    Write-ColorOutput ""
    Write-ColorOutput "To reinstall dependencies, run:" Cyan
    Write-ColorOutput "  ergoms setup" Yellow
    Write-ColorOutput ""
}

# Export-ModuleMember -Function *  # Удалено, так как это не модуль

