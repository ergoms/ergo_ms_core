# Full system setup
# Полная настройка системы

. (Join-Path $PSScriptRoot "lifecycle.ps1")

function Update-Submodules {
    param(
        [string]$Root
    )
    
    Push-Location $Root
    try {
        & git submodule update --init --remote core/api core/client core/media_api
        if ($LASTEXITCODE -ne 0) { throw "Git submodule update failed" }
        
        Write-ErgomsMessage -Key 'setup_switch_dev_branch' -Color Yellow
        
        Push-Location "core\api"
        & git checkout dev
        if ($LASTEXITCODE -ne 0) { Write-ErgomsMessage -Key 'setup_warn_dev_branch' -Color Yellow -Param @{ path = 'core/api' } }
        Pop-Location
        
        Push-Location "core\client"
        & git checkout dev
        if ($LASTEXITCODE -ne 0) { Write-ErgomsMessage -Key 'setup_warn_dev_branch' -Color Yellow -Param @{ path = 'core/client' } }
        Pop-Location
        
        Push-Location "core\media_api"
        & git checkout dev
        if ($LASTEXITCODE -ne 0) { Write-ErgomsMessage -Key 'setup_warn_dev_branch' -Color Yellow -Param @{ path = 'core/media_api' } }
        Pop-Location
        
        Write-ErgomsMessage -Key 'setup_ok_submodules' -Color Green
    }
    catch {
        Write-ErgomsMessage -Key 'setup_error_submodules' -Color Red -Stderr -Param @{ error = $_.Exception.Message }
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

    Write-Host ""; Write-ErgomsMessage -Key 'setup_heading_modules' -Color Cyan
    Write-ColorOutput ""

    Push-Location $Root
    try {
        $entries = Get-ModuleSubmoduleEntries -Root $Root
        if ($entries.Count -eq 0) {
            Write-ErgomsMessage -Key 'setup_warn_no_module_submodules' -Color Yellow
            return
        }

        Write-ErgomsMessage -Key 'setup_updating_modules' -Color Yellow -Param @{ count = $entries.Count }

        $succeeded = @()
        $failed = @()
        $skipped = @()

        foreach ($entry in $entries) {
            $known = & git ls-files -s -- $entry.Path
            if (-not $known) {
                Write-ErgomsMessage -Key 'setup_skip_not_in_index' -Color Gray -Param @{ path = $entry.Path }
                $skipped += $entry.Path
                continue
            }

            Write-ColorOutput "  $($entry.Path)..." Gray
            & git submodule update --init --remote $entry.Path
            if ($LASTEXITCODE -ne 0) {
                Write-ErgomsMessage -Key 'setup_warn_update_failed' -Color Yellow -Param @{ path = $entry.Path }
                $failed += $entry.Path
                continue
            }

            Push-Location $entry.Path
            & git checkout $entry.Branch
            if ($LASTEXITCODE -ne 0) {
                Write-ErgomsMessage -Key 'setup_warn_switch_branch' -Color Yellow -Param @{ branch = $entry.Branch; path = $entry.Path }
            }
            Pop-Location

            $succeeded += $entry.Path
        }

        if ($succeeded.Count -gt 0) {
            if ($skipped.Count -gt 0 -or $failed.Count -gt 0) {
                Write-ErgomsMessage -Key 'setup_ok_modules_summary_full' -Color Green -Param @{ succeeded = $succeeded.Count; skipped = $skipped.Count; failed = $failed.Count }
            } else {
                Write-ErgomsMessage -Key 'setup_ok_modules_summary' -Color Green -Param @{ succeeded = $succeeded.Count }
            }
            foreach ($path in $failed) {
                Write-ColorOutput "  - $path" Yellow
            }
        }
        elseif ($failed.Count -gt 0) {
            Write-ErgomsMessage -Key 'setup_error_no_modules' -Color Red -Stderr -Param @{ failed = $failed.Count }
            foreach ($path in $failed) {
                Write-ColorOutput "  - $path" Red
            }
            exit 1
        }
        else {
            Write-ErgomsMessage -Key 'setup_warn_no_modules' -Color Yellow
        }
    }
    catch {
        Write-ErgomsMessage -Key 'setup_error_modules_exception' -Color Red -Stderr -Param @{ error = $_.Exception.Message }
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
        Write-ErgomsMessage -Key 'setup_warn_python_missing_config' -Color Yellow
        return $false
    }

    if (-not (Test-Path $script)) {
        Write-ErgomsMessage -Key 'setup_warn_config_script_missing' -Color Yellow -Param @{ path = $script }
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

    $extra = @()
    if ($RecreateVenv) { $extra += '--recreate-venv' }
    Invoke-LifecycleRunner -Root $Root -Recipe 'setup-full' -ExtraArgs $extra
}

. (Join-Path $PSScriptRoot "clean.ps1")
