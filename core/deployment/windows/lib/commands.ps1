# Custom commands management
# Управление пользовательскими командами

function Get-CustomCommands {
    param([string]$ProjectRoot)
    
    $commands = @{}
    
    # Load core commands
    $configPath = Join-Path $ProjectRoot "core\deployment\commands.conf"
    if (Test-Path $configPath) {
        Get-Content $configPath | ForEach-Object {
            $line = $_.Trim()
            # Skip comments and empty lines
            if ($line -and -not $line.StartsWith('#') -and -not $line.StartsWith('=')) {
                if ($line -match '^([a-zA-Z0-9_-]+)=(.+)$') {
                    $cmdName = $matches[1].Trim()
                    $cmdValue = $matches[2].Trim()
                    $commands[$cmdName] = $cmdValue
                }
            }
        }
    }
    
    # Load module commands
    $modulesPath = Join-Path $ProjectRoot "modules"
    if (Test-Path $modulesPath) {
        Get-ChildItem -Path $modulesPath -Directory | ForEach-Object {
            $moduleName = $_.Name
            $moduleConfigPath = Join-Path $_.FullName "ergoms.conf"
            
            if (Test-Path $moduleConfigPath) {
                Get-Content $moduleConfigPath | ForEach-Object {
                    $line = $_.Trim()
                    # Skip comments and empty lines
                    if ($line -and -not $line.StartsWith('#') -and -not $line.StartsWith('=')) {
                        if ($line -match '^([a-zA-Z0-9_-]+)=(.+)$') {
                            $cmdName = $matches[1].Trim()
                            $cmdValue = $matches[2].Trim()
                            
                            # Add module prefix to command name
                            $prefixedName = "$moduleName`:$cmdName"
                            $commands[$prefixedName] = $cmdValue
                            
                            # Also add without prefix if no conflict
                            if (-not $commands.ContainsKey($cmdName)) {
                                $commands[$cmdName] = $cmdValue
                            }
                        }
                    }
                }
            }
        }
    }
    
    return $commands
}

function Invoke-CustomCommand {
    param(
        [string]$CommandName,
        [string[]]$Args,
        [string]$ProjectRoot
    )
    
    $customCommands = Get-CustomCommands -ProjectRoot $ProjectRoot
    
    if (-not $customCommands.ContainsKey($CommandName)) {
        Write-ColorOutput "[ERROR] Unknown command: $CommandName" Red
        Write-ColorOutput "Available custom commands: $($customCommands.Keys -join ', ')" Yellow
        Write-ColorOutput "Run 'ergoms help' for all available commands" Cyan
        exit 1
    }
    
    $commandDef = $customCommands[$CommandName]
    
    # Check if it's a composite command (contains &&)
    if ($commandDef -match '&&') {
        $subCommands = $commandDef -split '&&' | ForEach-Object { $_.Trim() }
        Write-ColorOutput "-> Executing composite command: $CommandName" Cyan
        
        foreach ($subCmd in $subCommands) {
            Write-ColorOutput "   -> $subCmd" Yellow
            Execute-CommandString -CommandString $subCmd -ProjectRoot $ProjectRoot -Args $Args
            if ($LASTEXITCODE -ne 0) {
                Write-ColorOutput "[ERROR] Command failed: $subCmd" Red
                exit $LASTEXITCODE
            }
        }
    }
    else {
        Execute-CommandString -CommandString $commandDef -ProjectRoot $ProjectRoot -Args $Args
    }
}

function Execute-CommandString {
    param(
        [string]$CommandString,
        [string]$ProjectRoot,
        [string[]]$Args
    )
    
    # Parse command type (poetry:, api:, npm:, shell:, win:, linux:)
    if ($CommandString -match '^(poetry|api|npm|shell|win|linux):(.+)$') {
        $cmdType = $matches[1]
        $cmdArgs = $matches[2].Trim()
        
        # Skip linux commands on Windows
        if ($cmdType -eq 'linux') {
            Write-ColorOutput "[INFO] Skipping Linux-only command on Windows: $cmdArgs" Gray
            return
        }
        
        # Split command arguments and add user arguments
        $allArgs = ($cmdArgs -split '\s+') + $Args
        
        switch ($cmdType) {
            'poetry' {
                Push-Location $ProjectRoot
                try {
                    & poetry $allArgs
                }
                finally {
                    Pop-Location
                }
            }
            'api' {
                $venvPath = Join-Path $ProjectRoot "virtual_env\python"
                if (-not (Test-Path $venvPath)) {
                    Write-ColorOutput "[ERROR] Virtual environment not found" Red
                    exit 1
                }
                Push-Location (Join-Path $ProjectRoot "core")
                try {
                    # Activate virtual environment
                    $env:VIRTUAL_ENV = $venvPath
                    $env:PATH = "$venvPath\Scripts;$env:PATH"
                    
                    $argsString = $allArgs -join ' '
                    & api $argsString
                }
                finally {
                    Pop-Location
                }
            }
            'npm' {
                Push-Location $ProjectRoot
                try {
                    # Check if npm is available
                    & npm --version 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-ColorOutput "[ERROR] npm is not available or not working" Red
                        Write-ColorOutput "  Please install Node.js and npm" Yellow
                        exit 1
                    }
                    
                    # Check if package.json exists
                    if (-not (Test-Path "package.json")) {
                        Write-ColorOutput "[ERROR] package.json not found in project root" Red
                        Write-ColorOutput "  Current directory: $(Get-Location)" Gray
                        exit 1
                    }
                    
                    # For npm commands, pass arguments correctly
                    $npmCommand = "npm " + ($allArgs -join ' ')
                    Invoke-Expression $npmCommand
                }
                finally {
                    Pop-Location
                }
            }
            'shell' {
                Push-Location $ProjectRoot
                try {
                    # Execute shell command as-is
                    $fullCommand = $cmdArgs
                    if ($Args.Count -gt 0) {
                        $fullCommand += " " + ($Args -join ' ')
                    }
                    & cmd /c $fullCommand
                }
                finally {
                    Pop-Location
                }
            }
            'win' {
                Push-Location $ProjectRoot
                try {
                    # Execute Windows-specific command
                    $fullCommand = $cmdArgs
                    if ($Args.Count -gt 0) {
                        $fullCommand += " " + ($Args -join ' ')
                    }
                    & cmd /c $fullCommand
                }
                finally {
                    Pop-Location
                }
            }
        }
    }
    else {
        # Execute as shell command (backward compatibility)
        Push-Location $ProjectRoot
        try {
            $allArgs = ($CommandString -split '\s+') + $Args
            $mainCmd = $allArgs[0]
            $cmdArgs = $allArgs[1..($allArgs.Length-1)]
            & $mainCmd $cmdArgs
        }
        finally {
            Pop-Location
        }
    }
}

function Invoke-PoetryCommand {
    param([string[]]$Args, [string]$Root)
    
    # Activate virtual environment if it exists
    $venvPath = Join-Path $Root "virtual_env\python"
    if (Test-Path $venvPath) {
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
    }
    
    Push-Location $Root
    try {
        & poetry $Args
    }
    finally {
        Pop-Location
    }
}

function Invoke-ApiCommand {
    param([string[]]$Args, [string]$Root)
    
    $venvPath = Join-Path $Root "virtual_env\python"
    
    if (-not (Test-Path $venvPath)) {
        Write-ColorOutput "[ERROR] Virtual environment not found at: $venvPath" Red
        Write-ColorOutput "  Please run 'poetry install' first" Yellow
        exit 1
    }
    
    Push-Location (Join-Path $Root "core")
    try {
        # Activate virtual environment
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
        
        & api $($Args -join ' ')
    }
    finally {
        Pop-Location
    }
}

function Invoke-NpmCommand {
    param([string[]]$Args, [string]$Root)
    
    Push-Location $Root
    try {
        $npmCommand = "npm " + ($Args -join ' ')
        Invoke-Expression $npmCommand
    }
    finally {
        Pop-Location
    }
}

Export-ModuleMember -Function *

