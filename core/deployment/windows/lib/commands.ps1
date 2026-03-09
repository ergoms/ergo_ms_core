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
        [string[]]$CommandArgs,
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
            Execute-CommandString -CommandString $subCmd -ProjectRoot $ProjectRoot -UserArgs $CommandArgs
            if ($LASTEXITCODE -ne 0) {
                Write-ColorOutput "[ERROR] Command failed: $subCmd" Red
                exit $LASTEXITCODE
            }
        }
    }
    else {
        Execute-CommandString -CommandString $commandDef -ProjectRoot $ProjectRoot -UserArgs $CommandArgs
    }
}

function Execute-CommandString {
    param(
        [string]$CommandString,
        [string]$ProjectRoot,
        [string[]]$UserArgs
    )
    
    # Mark as internal so wrappers in init_terminal.ps1 pass through
    $env:ERGOMS_INTERNAL = '1'
    
    # Parse command type (poetry:, api:, media_api:, npm:, shell:, win:, linux:)
    if ($CommandString -match '^(poetry|api|media_api|npm|shell|win|linux):(.+)$') {
        $cmdType = $matches[1]
        $cmdArgs = $matches[2].Trim()
        
        # Skip linux commands on Windows
        if ($cmdType -eq 'linux') {
            return
        }
        
        # Split command arguments and add user arguments
        $allArgs = ($cmdArgs -split '\s+') + $UserArgs
        
        switch ($cmdType) {
            'poetry' {
                Push-Location $ProjectRoot
                try {
                    & poetry @allArgs
                }
                finally {
                    Pop-Location
                }
            }
            'api' {
                $venvPath = Join-Path $ProjectRoot "virtual_env\python"
                $pythonExe = Join-Path $venvPath "Scripts\python.exe"
                if (-not (Test-Path $pythonExe)) {
                    Write-ColorOutput "[ERROR] Virtual environment not found" Red
                    exit 1
                }
                Push-Location (Join-Path $ProjectRoot "core")
                try {
                    $env:VIRTUAL_ENV = $venvPath
                    $env:PATH = "$venvPath\Scripts;$env:PATH"
                    & $pythonExe -m commands @allArgs
                }
                finally {
                    Pop-Location
                }
            }
            'media_api' {
                $venvPath = Join-Path $ProjectRoot "virtual_env\python"
                $pythonExe = Join-Path $venvPath "Scripts\python.exe"
                if (-not (Test-Path $pythonExe)) {
                    Write-ColorOutput "[ERROR] Virtual environment not found" Red
                    exit 1
                }
                Push-Location $ProjectRoot
                try {
                    $env:VIRTUAL_ENV = $venvPath
                    $env:PATH = "$venvPath\Scripts;$env:PATH"
                    $env:PYTHONPATH = Join-Path $ProjectRoot "core\media_api\src"
                    & $pythonExe -m media_server.manage @allArgs
                }
                finally {
                    Pop-Location
                }
            }
            'npm' {
                Push-Location $ProjectRoot
                try {
                    if (-not (Test-Path "package.json")) {
                        Write-ColorOutput "[ERROR] package.json not found in project root" Red
                        Write-ColorOutput "  Current directory: $(Get-Location)" Gray
                        exit 1
                    }
                    # Use cmd /c to avoid PowerShell argument passing issues with npm.cmd on Windows
                    # (direct invocation can cause "run" to become "pm" -> "Unknown command: 'pm'")
                    $npmCmdLine = "npm " + ($allArgs -join ' ')
                    & cmd /c $npmCmdLine
                }
                finally {
                    Pop-Location
                }
            }
            'shell' {
                Push-Location $ProjectRoot
                try {
                    $fullCommand = $cmdArgs
                    if ($UserArgs.Count -gt 0) {
                        $fullCommand += " " + ($UserArgs -join ' ')
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
                    $fullCommand = $cmdArgs
                    if ($UserArgs.Count -gt 0) {
                        $fullCommand += " " + ($UserArgs -join ' ')
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
            $allArgs = ($CommandString -split '\s+') + $UserArgs
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
    param([string[]]$CommandArgs, [string]$Root)
    
    $env:ERGOMS_INTERNAL = '1'
    
    $venvPath = Join-Path $Root "virtual_env\python"
    if (Test-Path $venvPath) {
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
    }
    
    Push-Location $Root
    try {
        & poetry $CommandArgs
    }
    finally {
        Pop-Location
    }
}

function Invoke-ApiCommand {
    param([string[]]$CommandArgs, [string]$Root)
    
    $env:ERGOMS_INTERNAL = '1'
    
    $venvPath = Join-Path $Root "virtual_env\python"
    
    $pythonExe = Join-Path $venvPath "Scripts\python.exe"
    if (-not (Test-Path $pythonExe)) {
        Write-ColorOutput "[ERROR] Virtual environment not found at: $venvPath" Red
        Write-ColorOutput "  Please run 'ergoms python-install' first" Yellow
        exit 1
    }
    
    Push-Location (Join-Path $Root "core")
    try {
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
        & $pythonExe -m commands $CommandArgs
    }
    finally {
        Pop-Location
    }
}

function Invoke-MediaApiCommand {
    param([string[]]$CommandArgs, [string]$Root)
    
    $env:ERGOMS_INTERNAL = '1'
    
    $venvPath = Join-Path $Root "virtual_env\python"
    $pythonExe = Join-Path $venvPath "Scripts\python.exe"
    if (-not (Test-Path $pythonExe)) {
        Write-ColorOutput "[ERROR] Virtual environment not found at: $venvPath" Red
        Write-ColorOutput "  Please run 'ergoms python-install' first" Yellow
        exit 1
    }
    
    Push-Location $Root
    try {
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
        $env:PYTHONPATH = Join-Path $Root "core\media_api\src"
        & $pythonExe -m media_server.manage $CommandArgs
    }
    finally {
        Pop-Location
    }
}

function Invoke-NpmCommand {
    param([string[]]$CommandArgs, [string]$Root)
    
    $env:ERGOMS_INTERNAL = '1'
    
    Push-Location $Root
    try {
        # Use cmd /c to avoid PowerShell argument passing issues with npm.cmd on Windows
        $npmCmdLine = "npm " + ($CommandArgs -join ' ')
        & cmd /c $npmCmdLine
    }
    finally {
        Pop-Location
    }
}

# Export-ModuleMember -Function *  # Удалено, так как это не модуль
