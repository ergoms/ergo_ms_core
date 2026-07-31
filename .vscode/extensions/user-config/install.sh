#!/usr/bin/env bash
set -euo pipefail

# ERGO MS User Config Extension Installer for Linux
# Installs the extension to VS Code or Cursor (all locations)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTENSION_NAME="ergo-user-config"

# Get all extensions directories
get_all_extensions_dirs() {
    local dirs=()
    
    # Cursor Server (remote)
    if [[ -d "$HOME/.cursor-server" ]]; then
        mkdir -p "$HOME/.cursor-server/extensions"
        dirs+=("$HOME/.cursor-server/extensions")
    fi
    
    # Cursor (local)
    if [[ -d "$HOME/.cursor" ]]; then
        mkdir -p "$HOME/.cursor/extensions"
        dirs+=("$HOME/.cursor/extensions")
    fi
    
    # VS Code Server (remote)
    if [[ -d "$HOME/.vscode-server" ]]; then
        mkdir -p "$HOME/.vscode-server/extensions"
        dirs+=("$HOME/.vscode-server/extensions")
    fi
    
    # VS Code (local) - always add as fallback
    mkdir -p "$HOME/.vscode/extensions"
    dirs+=("$HOME/.vscode/extensions")
    
    # Return unique paths
    printf '%s\n' "${dirs[@]}" | sort -u
}

# Install extension to all locations
install_extension_all() {
    local source_dir="$1"
    local extension_name="$2"
    
    if [[ -z "$source_dir" ]] || [[ -z "$extension_name" ]]; then
        echo "[ERROR] Usage: install_extension_all <source_dir> <extension_name>"
        return 1
    fi
    
    local installed=0
    
    while IFS= read -r ext_dir; do
        local target="$ext_dir/$extension_name"
        
        # Remove old version
        if [[ -L "$target" ]] || [[ -d "$target" ]]; then
            rm -rf "$target"
        fi
        
        # Create symlink or copy files
        if ln -s "$source_dir" "$target" 2>/dev/null; then
            echo "[OK] Installed to: $ext_dir"
            ((installed++))
        else
            # Fallback: copy files if symlink fails
            mkdir -p "$target"
            cp "$source_dir/package.json" "$target/" 2>/dev/null || true
            cp "$source_dir/extension.js" "$target/" 2>/dev/null || true
            cp "$source_dir/icon.png" "$target/" 2>/dev/null || true
            if [[ -f "$target/package.json" ]]; then
                echo "[OK] Installed to: $ext_dir (copied)"
                ((installed++))
            else
                echo "[WARN] Failed to install to: $ext_dir"
            fi
        fi
    done < <(get_all_extensions_dirs)
    
    if [[ $installed -eq 0 ]]; then
        echo "[ERROR] Extension was not installed to any IDE"
        return 1
    fi
    
    return 0
}

echo "========================================"
echo "  Installing ERGO User Config Extension"
echo "========================================"
echo ""

echo "Installing extension to all IDE locations..."
echo ""

if install_extension_all "$SCRIPT_DIR" "$EXTENSION_NAME"; then
    echo ""
    echo "========================================"
    echo "[SUCCESS] Extension installed!"
    echo "========================================"
    echo ""
    echo "Please restart VS Code/Cursor to activate the extension."
    echo "The extension will automatically apply settings from:"
    echo "  - .vscode/user_settings.json"
    echo "  - .vscode/user_keybindings.json"
else
    echo ""
    echo "[ERROR] Installation failed"
    exit 1
fi

