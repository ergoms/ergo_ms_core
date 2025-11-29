#!/usr/bin/env bash
set -euo pipefail

# ERGO MS User Config Extension Uninstaller for Linux
# Removes the extension from VS Code and Cursor

EXTENSION_NAME="ergo-user-config"

uninstall_extension() {
    local removed=0
    
    echo "-> Uninstalling $EXTENSION_NAME..."
    
    # Check VS Code extensions
    local vscode_dir="$HOME/.vscode/extensions/$EXTENSION_NAME"
    if [[ -d "$vscode_dir" ]]; then
        rm -rf "$vscode_dir"
        echo "[OK] Removed from VS Code: $vscode_dir"
        removed=$((removed + 1))
    fi
    
    # Check Cursor extensions
    local cursor_dir="$HOME/.cursor/extensions/$EXTENSION_NAME"
    if [[ -d "$cursor_dir" ]]; then
        rm -rf "$cursor_dir"
        echo "[OK] Removed from Cursor: $cursor_dir"
        removed=$((removed + 1))
    fi
    
    if [[ $removed -eq 0 ]]; then
        echo "[SKIP] Extension not found in any location"
    else
        echo ""
        echo "Extension removed from $removed location(s)."
        echo "Please restart VS Code/Cursor to complete uninstallation."
    fi
}

uninstall_extension

