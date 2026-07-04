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
        & git submodule update --init --remote core/api core/client core/media_api
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

function Get-ModuleSubmoduleEntries {
    param(
        [string]$Root
    )

    $gitmodules = Join-Path $Root ".gitmodules"
    if (-not (Test-Path $gitmodules)) {
        throw ".gitmodules not found at $gitmodules"
    }

    Push-Location $Root
    try {
        $output = & git config -f .gitmodules --get-regexp '^submodule\..*\.path$'
        if (-not $output) {
            return @()
        }

        $entries = @()
        foreach ($line in @($output)) {
            if ($line -match '^submodule\.(.+)\.path\s+(.+)$') {
                $name = $Matches[1]
                $path = $Matches[2]
                if ($path -like 'modules/*') {
                    $branch = & git config -f .gitmodules "submodule.$name.branch"
                    if (-not $branch) {
                        $branch = 'dev'
                    }
                    $entries += [PSCustomObject]@{
                        Name   = $name
                        Path   = $path
                        Branch = $branch
                    }
                }
            }
        }
        return $entries
    }
    finally {
        Pop-Location
    }
}

function Update-ModuleSubmodules {
    param(
        [string]$Root
    )

    Write-ColorOutput "`n=== Updating Module Git Submodules ===" Cyan
    Write-ColorOutput ""

    Push-Location $Root
    try {
        $entries = Get-ModuleSubmoduleEntries -Root $Root
        if ($entries.Count -eq 0) {
            Write-ColorOutput "[WARNING] No module submodules found in .gitmodules" Yellow
            return
        }

        $paths = @($entries | ForEach-Object { $_.Path })
        Write-ColorOutput "-> Updating $($paths.Count) module submodule(s)..." Yellow
        & git submodule update --init --remote @paths
        if ($LASTEXITCODE -ne 0) { throw "Git submodule update failed" }

        Write-ColorOutput "-> Switching modules to configured branches..." Yellow
        foreach ($entry in $entries) {
            Write-ColorOutput "  $($entry.Path) -> $($entry.Branch)" Gray
            Push-Location $entry.Path
            & git checkout $entry.Branch
            if ($LASTEXITCODE -ne 0) {
                Write-ColorOutput "[WARNING] Failed to checkout $($entry.Branch) in $($entry.Path)" Yellow
            }
            Pop-Location
        }

        Write-ColorOutput "[OK] Module git submodules updated" Green
    }
    catch {
        Write-ColorOutput "[ERROR] Failed to update module git submodules: $($_.Exception.Message)" Red
        Pop-Location
        exit 1
    }
    finally {
        Pop-Location
    }
}

function Invoke-ConfigScaffold {
    param(
        [string]$Root
    )

    $script = Join-Path $Root "core\deployment\scripts\scaffold_config_files.py"
    $pythonCmd = $null

    foreach ($cmd in @('python', 'python3', 'python3.12')) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            $pythonCmd = $cmd
            break
        }
    }

    if (-not $pythonCmd) {
        Write-ColorOutput "    [WARNING] Python not found, cannot scaffold configuration files" Yellow
        return $false
    }

    if (-not (Test-Path $script)) {
        Write-ColorOutput "    [WARNING] Config scaffold script not found: $script" Yellow
        return $false
    }

    & $pythonCmd $script --root $Root
    return ($LASTEXITCODE -eq 0)
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
    Invoke-ConfigScaffold -Root $Root | Out-Null
    
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
    
    # Step 5: Python (ядро + модули через commands install) + npm
    Write-ColorOutput "-> Step 5/8: Installing dependencies (python + npm)..." Yellow
    Push-Location $Root
    try {
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
        $env:POETRY_VIRTUALENVS_CREATE = "false"
        
        Write-ColorOutput "  Running: python -m commands install (core + module deps)..." Gray
        $env:PYTHONPATH = $Root
        $env:PYTHONIOENCODING = "utf-8"
        Push-Location (Join-Path $Root "core\api")
        try {
            & $pythonExe -m commands install
            if ($LASTEXITCODE -ne 0) { throw "commands install failed" }
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
            Write-ColorOutput "  Running: npm run install:all (from: $(Get-Location))" Gray
            # Call npm directly using full path with argument array to avoid command truncation
            # Using argument array prevents PowerShell from interpreting the command incorrectly
            & $npmExe run install:all
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

. (Join-Path $PSScriptRoot "clean.ps1")

# Export-ModuleMember -Function *  # Удалено, так как это не модуль

