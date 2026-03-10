# Full system setup
# Полная настройка системы

function Update-Submodules {
    param(
        [string]$Root
    )
    
    Write-ColorOutput "`n=== Updating Git Submodules ===" Cyan
    Write-ColorOutput ""
    
    Push-Location $Root
    try {
        Write-ColorOutput "-> Updating git submodules..." Yellow
        & git submodule update --init --remote core/api core/client core/django core/django_rest_framework core/media_api
        if ($LASTEXITCODE -ne 0) { throw "Git submodule update failed" }
        
        Write-ColorOutput "-> Switching submodules to dev branch..." Yellow
        
        Push-Location "core\api"
        & git checkout dev
        if ($LASTEXITCODE -ne 0) { Write-ColorOutput "[WARNING] Failed to checkout dev branch in core/api" Yellow }
        Pop-Location
        
        Push-Location "core\client"
        & git checkout dev
        if ($LASTEXITCODE -ne 0) { Write-ColorOutput "[WARNING] Failed to checkout dev branch in core/client" Yellow }
        Pop-Location
        
        Push-Location "core\django"
        & git checkout dev
        if ($LASTEXITCODE -ne 0) { Write-ColorOutput "[WARNING] Failed to checkout dev branch in core/django" Yellow }
        Pop-Location

        Push-Location "core\django_rest_framework"
        & git checkout dev
        if ($LASTEXITCODE -ne 0) { Write-ColorOutput "[WARNING] Failed to checkout dev branch in core/django_rest_framework" Yellow }
        Pop-Location
        
        Push-Location "core\media_api"
        & git checkout dev
        if ($LASTEXITCODE -ne 0) { Write-ColorOutput "[WARNING] Failed to checkout dev branch in core/media_api" Yellow }
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
}

function Setup-FullSystem {
    param(
        [string]$Root,
        [bool]$RecreateVenv = $false
    )
    
    Write-ColorOutput "`n=== Full System Setup ===" Cyan
    Write-ColorOutput ""
    
    # Step 0: Set PowerShell execution policy
    Write-ColorOutput "-> Step 0/8: Setting PowerShell execution policy..." Yellow
    try {
        $currentPolicy = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue
        if ($currentPolicy -eq "RemoteSigned") {
            Write-ColorOutput "  Execution policy already set to RemoteSigned" Gray
        }
        else {
            Write-ColorOutput "  Setting execution policy to RemoteSigned..." Gray
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
            Write-ColorOutput "[OK] Execution policy set to RemoteSigned" Green
        }
    }
    catch {
        Write-ColorOutput "[WARNING] Failed to set execution policy: $($_.Exception.Message)" Yellow
        Write-ColorOutput "  You may need to run this command manually:" Gray
        Write-ColorOutput "  Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned" Yellow
    }
    
    # Step 1: Git submodules
    Write-ColorOutput "-> Step 1/8: Updating git submodules..." Yellow
    Update-Submodules -Root $Root
    
    # Create configuration files from examples if they don't exist
    Write-ColorOutput "  Creating configuration files from examples..." Gray
    
    # Special handling for databases.yaml - only first 8 lines
    $databasesSourcePath = Join-Path $Root "databases.yaml.example"
    $databasesTargetPath = Join-Path $Root "databases.yaml"
    if (Test-Path $databasesSourcePath) {
        if (-not (Test-Path $databasesTargetPath)) {
            try {
                $content = Get-Content $databasesSourcePath -TotalCount 8
                $content | Set-Content $databasesTargetPath
                Write-ColorOutput "    Created databases.yaml (first 8 lines)" Green
            }
            catch {
                Write-ColorOutput "    [WARNING] Failed to create databases.yaml: $($_.Exception.Message)" Yellow
            }
        }
        else {
            Write-ColorOutput "    databases.yaml already exists, skipping" Gray
        }
    }
    else {
        Write-ColorOutput "    [WARNING] Example file databases.yaml.example not found" Yellow
    }
    
    # Other configuration files - full copy
    $configFiles = @(
        @{Source = "celery_workers.yaml.example"; Target = "celery_workers.yaml"},
        @{Source = ".env.example"; Target = ".env"}
    )
    
    foreach ($config in $configFiles) {
        $sourcePath = Join-Path $Root $config.Source
        $targetPath = Join-Path $Root $config.Target
        
        if (Test-Path $sourcePath) {
            if (-not (Test-Path $targetPath)) {
                try {
                    Copy-Item -Path $sourcePath -Destination $targetPath -Force
                    Write-ColorOutput "    Created $($config.Target)" Green
                }
                catch {
                    Write-ColorOutput "    [WARNING] Failed to create $($config.Target): $($_.Exception.Message)" Yellow
                }
            }
            else {
                Write-ColorOutput "    $($config.Target) already exists, skipping" Gray
            }
        }
        else {
            Write-ColorOutput "    [WARNING] Example file $($config.Source) not found" Yellow
        }
    }
    
    # Step 2: Create virtual environment
    Write-ColorOutput "-> Step 2/8: Creating Python virtual environment..." Yellow
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
    Write-ColorOutput "-> Step 3/8: Installing Poetry..." Yellow
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
    Write-ColorOutput "-> Step 4/8: Installing ErgoMS CLI..." Yellow
    Install-CliWrapper
    
    # Step 5: Run setup (poetry install + npm install && npm run build) — без ergoms/api, только venv + poetry
    Write-ColorOutput "-> Step 5/8: Installing dependencies (poetry + npm)..." Yellow
    Push-Location $Root
    try {
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
        $env:POETRY_VIRTUALENVS_CREATE = "false"
        
        $poetryExe = Join-Path $venvPath "Scripts\poetry.exe"
        if (-not (Test-Path $poetryExe)) {
            throw "poetry not found in virtual environment at $poetryExe"
        }
        Write-ColorOutput "  Running: poetry install --no-root (from project root)..." Gray
        & $poetryExe install --no-root
        if ($LASTEXITCODE -ne 0) { throw "poetry install failed" }
        Write-ColorOutput "  Running: python -m commands install (module deps)..." Gray
        $env:PYTHONPATH = $Root
        $env:PYTHONIOENCODING = "utf-8"
        Push-Location (Join-Path $Root "core\api")
        try {
            & $pythonExe -m commands install
            if ($LASTEXITCODE -ne 0) { Write-ColorOutput "[WARNING] commands install (module deps) failed, continuing" Yellow }
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
        
        # api commands must run from core\api with project root in PYTHONPATH
        Push-Location (Join-Path $Root "core\api")
        try {
            $env:PYTHONPATH = $Root
            $env:PYTHONIOENCODING = "utf-8"
            & $pythonExe -m commands migrate
            if ($LASTEXITCODE -ne 0) { throw "API migrate failed" }
            & $pythonExe -m commands warmup_caches
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
    Write-ColorOutput "-> Step 6/8: Collecting static files..." Yellow
    Push-Location $Root
    try {
        # Activate virtual environment and run command
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
        
        Push-Location (Join-Path $Root "core\api")
        try {
            $env:PYTHONPATH = $Root
            $env:PYTHONIOENCODING = "utf-8"
            & $pythonExe -m commands collectstatic --noinput
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
    Write-ColorOutput "-> Step 7/8: Setup complete" Yellow
    
    Write-ColorOutput "`n=== Full System Setup Complete ===" Green
    Write-ColorOutput ""
    Write-ColorOutput "System is ready! To install and start services, run:" Cyan
    Write-ColorOutput "  ergoms install-services" Yellow
    Write-ColorOutput ""
    Write-ColorOutput "You can now use 'ergoms' commands to manage your system." Cyan
}

# Clean project dependencies
# Очистка зависимостей проекта

function Remove-DirectoryContents {
    param(
        [string]$Path,
        [string]$Label
    )
    
    if (-not (Test-Path $Path)) {
        Write-ColorOutput "[SKIP] $Label not found" Gray
        return
    }
    try {
        $items = Get-ChildItem -Path $Path -Force -ErrorAction Stop
        $removedCount = 0
        foreach ($item in $items) {
            if ($item.Name -ne '.gitkeep') {
                Remove-Item $item.FullName -Recurse -Force -ErrorAction Stop
                $removedCount++
            }
        }
        if ($removedCount -gt 0) {
            Write-ColorOutput "[OK] Removed $removedCount items from $Label" Green
        }
        else {
            Write-ColorOutput "[SKIP] $Label is already empty" Gray
        }
    }
    catch {
        Write-ColorOutput "[ERROR] Failed to clean ${Label}: $($_.Exception.Message)" Red
    }
}

function Clear-ProjectDependencies {
    param(
        [string]$Root
    )
    
    $cleanTargets = @(
        @{Path = "node_modules";               Label = "node_modules";               FullRemove = $true},
        @{Path = "virtual_env\python";          Label = "virtual_env/python";          FullRemove = $false},
        @{Path = "virtual_env\static_api";      Label = "virtual_env/static_api";      FullRemove = $false},
        @{Path = "virtual_env\celery";          Label = "virtual_env/celery";          FullRemove = $false},
        @{Path = "virtual_env\nodejs";          Label = "virtual_env/nodejs";          FullRemove = $false},
        @{Path = "virtual_env\packages";        Label = "virtual_env/packages";        FullRemove = $false},
        @{Path = "virtual_env\resources";       Label = "virtual_env/resources";       FullRemove = $false},
        @{Path = "virtual_env\trained_models";  Label = "virtual_env/trained_models";  FullRemove = $false}
    )
    
    Write-ColorOutput "`n=== Cleaning Project Dependencies ===" Cyan
    Write-ColorOutput ""
    Write-ColorOutput "This will remove:" Yellow
    foreach ($target in $cleanTargets) {
        Write-ColorOutput "  - $($target.Label)" Gray
    }
    Write-ColorOutput ""
    Write-ColorOutput "Media folder will NOT be deleted." Green
    Write-ColorOutput ""
    
    $confirmation = Read-Host "Are you sure you want to continue? (y/N)"
    if ($confirmation -notmatch '^[yY]$') {
        Write-ColorOutput "Operation cancelled by user." Yellow
        return
    }
    
    $total = $cleanTargets.Count
    for ($i = 0; $i -lt $total; $i++) {
        $target = $cleanTargets[$i]
        $step = $i + 1
        $fullPath = Join-Path $Root $target.Path
        Write-ColorOutput "`n-> Step ${step}/${total}: Cleaning $($target.Label)..." Yellow
        
        if ($target.FullRemove) {
            if (Test-Path $fullPath) {
                try {
                    Remove-Item $fullPath -Recurse -Force -ErrorAction Stop
                    Write-ColorOutput "[OK] $($target.Label) removed" Green
                }
                catch {
                    Write-ColorOutput "[ERROR] Failed to remove $($target.Label): $($_.Exception.Message)" Red
                }
            }
            else {
                Write-ColorOutput "[SKIP] $($target.Label) not found" Gray
            }
        }
        else {
            Remove-DirectoryContents -Path $fullPath -Label $target.Label
        }
    }
    
    Write-ColorOutput "`n=== Cleaning Complete ===" Green
    Write-ColorOutput ""
    Write-ColorOutput "To reinstall dependencies, run:" Cyan
    Write-ColorOutput "  ergoms setup" Yellow
    Write-ColorOutput ""
}

# Export-ModuleMember -Function *  # Удалено, так как это не модуль

