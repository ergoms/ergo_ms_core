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

function Test-ShouldRunOnThisPlatform {
    param([string]$CommandString)
    if ($CommandString -match '^linux:') {
        return $false
    }
    return $true
}

function Invoke-CustomCommand {
    param(
        [string]$CommandName,
        [string[]]$CommandArgs,
        [string]$ProjectRoot
    )
    
    $customCommands = Get-CustomCommands -ProjectRoot $ProjectRoot
    
    if (-not $customCommands.ContainsKey($CommandName)) {
        Write-ErgomsMessage -Key 'unknown_command' -Color Red -Stderr -Param @{ name = $CommandName }
        Write-ColorOutput "Доступные пользовательские команды: $($customCommands.Keys -join ', ')" Yellow
        Write-ErgomsMessage -Key 'help_hint' -Color Cyan
        exit 1
    }
    
    $commandDef = $customCommands[$CommandName]
    
    # Check if it's a composite command (contains &&)
    if ($commandDef -match '&&') {
        $subCommands = $commandDef -split '&&' | ForEach-Object { $_.Trim() }
        Write-ColorOutput "-> Выполнение составной команды: $CommandName" Cyan
        
        foreach ($subCmd in $subCommands) {
            if (-not (Test-ShouldRunOnThisPlatform -CommandString $subCmd)) {
                continue
            }
            Write-ColorOutput "   -> $subCmd" Yellow
            Execute-CommandString -CommandString $subCmd -ProjectRoot $ProjectRoot -UserArgs $CommandArgs
            if ($LASTEXITCODE -ne 0) {
                Write-ErgomsMessage -Key 'command_failed' -Color Red -Stderr -Param @{ name = $subCmd }
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
                    Write-ErgomsMessage -Key 'venv_not_found' -Color Red -Stderr
                    exit 1
                }
                Push-Location (Join-Path $ProjectRoot "core\api")
                try {
                    $env:VIRTUAL_ENV = $venvPath
                    $env:PATH = "$venvPath\Scripts;$env:PATH"
                    $env:PYTHONPATH = $ProjectRoot
                    $env:PYTHONIOENCODING = "utf-8"
                    $env:PYTHONUNBUFFERED = "1"
                    $pipCache = Join-Path $ProjectRoot "virtual_env\cache\pip"
                    $poetryCache = Join-Path $ProjectRoot "virtual_env\cache\poetry"
                    $npmCache = Join-Path $ProjectRoot "virtual_env\cache\npm"
                    New-Item -ItemType Directory -Path $pipCache -Force | Out-Null
                    New-Item -ItemType Directory -Path $poetryCache -Force | Out-Null
                    New-Item -ItemType Directory -Path $npmCache -Force | Out-Null
                    $env:PIP_CACHE_DIR = $pipCache
                    $env:POETRY_CACHE_DIR = $poetryCache
                    $env:npm_config_cache = $npmCache
                    $env:NPM_CONFIG_CACHE = $npmCache
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
                    Write-ErgomsMessage -Key 'venv_not_found' -Color Red -Stderr
                    exit 1
                }
                Push-Location $ProjectRoot
                try {
                    $env:VIRTUAL_ENV = $venvPath
                    $env:PATH = "$venvPath\Scripts;$env:PATH"
                    $env:PYTHONPATH = (Join-Path $ProjectRoot "core\media_api\src") + ";" + $ProjectRoot
                    & $pythonExe -m media_server.manage @allArgs
                }
                finally {
                    Pop-Location
                }
            }
            'npm' {
                $npmRoot = Join-Path $ProjectRoot "virtual_env\npm"
                Push-Location $npmRoot
                try {
                    if (-not (Test-Path "package.json")) {
                        Write-ColorOutput "[ERROR] package.json не найден в virtual_env/npm" Red
                        Write-ColorOutput "  Текущий каталог: $(Get-Location)" Gray
                        exit 1
                    }
                    $npmCache = Join-Path $ProjectRoot "virtual_env\cache\npm"
                    New-Item -ItemType Directory -Path $npmCache -Force | Out-Null
                    $env:npm_config_cache = $npmCache
                    $env:NPM_CONFIG_CACHE = $npmCache
                    $nodeDir = Join-Path $ProjectRoot "virtual_env\packages\nodejs"
                    if (Test-Path -LiteralPath $nodeDir) {
                        $env:PATH = "$nodeDir;$env:PATH"
                    }
                    $npmBin = Join-Path $nodeDir "npm.cmd"
                    if (-not (Test-Path -LiteralPath $npmBin)) {
                        $npmBin = "npm"
                    }
                    if ($npmBin -eq "npm") {
                        $npmCmdLine = "npm " + ($allArgs -join ' ')
                    } else {
                        $npmCmdLine = "`"$npmBin`" " + ($allArgs -join ' ')
                    }
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

function Invoke-ModulePoetryCommand {
    param([string]$ModuleName, [string[]]$CommandArgs, [string]$Root)

    $env:ERGOMS_INTERNAL = '1'

    if ($CommandArgs.Count -eq 0) {
        Write-ColorOutput "Использование:" Yellow
        Write-ColorOutput "  ergoms ${ModuleName}:poetry add PACKAGE              — добавить зависимость (версия определяется автоматически)" Yellow
        Write-ColorOutput "  ergoms ${ModuleName}:poetry add PACKAGE `">=1.0.0`"  — добавить с явным ограничением версии" Yellow
        Write-ColorOutput "  ergoms ${ModuleName}:poetry remove PACKAGE           — удалить зависимость" Yellow
        Write-ColorOutput "  ergoms ${ModuleName}:poetry list                     — список зависимостей модуля" Yellow
        return
    }

    $subCmd = $CommandArgs[0].ToLower()
    $restArgs = if ($CommandArgs.Count -gt 1) { $CommandArgs[1..($CommandArgs.Count - 1)] } else { @() }

    switch ($subCmd) {
        'add' {
            if ($restArgs.Count -eq 0) {
                Write-ColorOutput "[ERROR] Укажите имя пакета: ergoms ${ModuleName}:poetry add PACKAGE" Red
                return
            }
            Invoke-ApiCommand -CommandArgs (@('module-add', $ModuleName) + $restArgs) -Root $Root
        }
        'remove' {
            if ($restArgs.Count -eq 0) {
                Write-ColorOutput "[ERROR] Укажите имя пакета: ergoms ${ModuleName}:poetry remove PACKAGE" Red
                return
            }
            Invoke-ApiCommand -CommandArgs (@('module-remove', $ModuleName) + $restArgs) -Root $Root
        }
        { $_ -in 'list', 'show' } {
            Invoke-ApiCommand -CommandArgs @('module-list', $ModuleName) -Root $Root
        }
        default {
            Write-ColorOutput "[ERROR] Неизвестная подкоманда: $subCmd" Red
            Write-ColorOutput "Доступные: add, remove, list" Yellow
        }
    }
}

function Invoke-PoetryCommand {
    param([string[]]$CommandArgs, [string]$Root)
    
    $env:ERGOMS_INTERNAL = '1'

    # Перехватываем "poetry install [...]" и заменяем собственной реализацией,
    # которая устанавливает ядро + зависимости всех модулей.
    # Остальные poetry-подкоманды выполняются напрямую.
    if ($CommandArgs.Count -gt 0 -and $CommandArgs[0] -eq 'install') {
        $extraArgs = if ($CommandArgs.Count -gt 1) { $CommandArgs[1..($CommandArgs.Count - 1)] } else { @() }
        Invoke-ApiCommand -CommandArgs (@('install') + $extraArgs) -Root $Root
        return
    }

    if ($CommandArgs.Count -gt 0 -and $CommandArgs[0] -eq 'list') {
        Invoke-ApiCommand -CommandArgs @('module-list') -Root $Root
        return
    }
    
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
        Write-ErgomsMessage -Key 'venv_not_found_at' -Color Red -Stderr -Param @{ path = $venvPath }
        Write-ErgomsMessage -Key 'venv_setup_hint' -Color Yellow -Stderr
        exit 1
    }
    
    Push-Location (Join-Path $Root "core\api")
    try {
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
        $env:PYTHONPATH = $Root
        $env:PYTHONIOENCODING = "utf-8"
        $env:PYTHONUNBUFFERED = "1"
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
        Write-ErgomsMessage -Key 'venv_not_found_at' -Color Red -Stderr -Param @{ path = $venvPath }
        Write-ErgomsMessage -Key 'venv_setup_hint' -Color Yellow -Stderr
        exit 1
    }
    
    Push-Location $Root
    try {
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
        $env:PYTHONPATH = (Join-Path $Root "core\media_api\src") + ";" + $Root
        & $pythonExe -m media_server.manage $CommandArgs
    }
    finally {
        Pop-Location
    }
}

function Invoke-NpmCommand {
    param([string[]]$CommandArgs, [string]$Root)
    
    $env:ERGOMS_INTERNAL = '1'
    
    $npmRoot = Join-Path $Root "virtual_env\npm"
    Push-Location $npmRoot
    try {
        $npmCache = Join-Path $Root "virtual_env\cache\npm"
        New-Item -ItemType Directory -Path $npmCache -Force | Out-Null
        $env:npm_config_cache = $npmCache
        $env:NPM_CONFIG_CACHE = $npmCache
        $nodeDir = Join-Path $Root "virtual_env\packages\nodejs"
        if (Test-Path -LiteralPath $nodeDir) {
            $env:PATH = "$nodeDir;$env:PATH"
        }
        $npmBin = Join-Path $nodeDir "npm.cmd"
        if (-not (Test-Path -LiteralPath $npmBin)) {
            $npmBin = "npm"
        }
        if ($npmBin -eq "npm") {
            $npmCmdLine = "npm " + ($CommandArgs -join ' ')
        } else {
            $npmCmdLine = "`"$npmBin`" " + ($CommandArgs -join ' ')
        }
        & cmd /c $npmCmdLine
    }
    finally {
        Pop-Location
    }
}

# Export-ModuleMember -Function *  # Удалено, так как это не модуль
