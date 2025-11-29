#!/bin/bash
# Удаление расширения Multi-Terminal Tasks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTENSION_NAME="multi-terminal"

# Подключаем модуль IDE (локальный)
IDE_MODULE="$SCRIPT_DIR/lib/ide.sh"

if [[ -f "$IDE_MODULE" ]]; then
    source "$IDE_MODULE"
    
    echo "========================================"
    echo "  Удаление расширения Multi-Terminal"
    echo "========================================"
    echo ""
    
    if uninstall_extension_all "$EXTENSION_NAME"; then
        echo ""
        echo "[SUCCESS] Расширение удалено!"
        echo "Перезапустите VS Code/Cursor для применения."
    else
        echo "[WARN] Расширение не было найдено"
    fi
else
    # Fallback
    echo "[INFO] Удаление расширения из всех IDE..."
    
    for dir in \
        "$HOME/.cursor-server/extensions" \
        "$HOME/.cursor/extensions" \
        "$HOME/.vscode-server/extensions" \
        "$HOME/.vscode/extensions"; do
        
        target="$dir/$EXTENSION_NAME"
        if [[ -L "$target" ]] || [[ -d "$target" ]]; then
            rm -rf "$target"
            echo "[OK] Удалено из: $dir"
        fi
    done
    
    echo ""
    echo "[SUCCESS] Готово! Перезапустите VS Code/Cursor."
fi
