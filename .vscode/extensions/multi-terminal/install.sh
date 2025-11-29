#!/bin/bash
# Установка расширения Multi-Terminal Tasks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTENSION_NAME="multi-terminal"

# Подключаем модуль IDE (локальный)
IDE_MODULE="$SCRIPT_DIR/lib/ide.sh"

if [[ -f "$IDE_MODULE" ]]; then
    source "$IDE_MODULE"
    
    echo "========================================"
    echo "  Установка расширения Multi-Terminal"
    echo "========================================"
    echo ""
    
    # Показываем информацию об IDE
    print_ide_info
    echo ""
    
    # Устанавливаем во все IDE
    echo "Установка расширения..."
    echo ""
    
    if install_extension_all "$SCRIPT_DIR" "$EXTENSION_NAME"; then
        echo ""
        echo "========================================"
        echo "[SUCCESS] Расширение установлено!"
        echo "========================================"
        echo ""
        echo "Перезапустите VS Code/Cursor для активации."
        echo ""
        echo "Использование в tasks.json:"
        echo ""
        echo '  {'
        echo '    "label": "My Multi-Terminal Task",'
        echo '    "type": "multi-terminal",'
        echo '    "source": {'
        echo '      "file": "celery_workers.yaml",'
        echo '      "path": "workers"'
        echo '    },'
        echo '    "commandTemplate": "ergoms start-worker --worker=\${key}",'
        echo '    "nameTemplate": "Worker: \${key}"'
        echo '  }'
    else
        echo ""
        echo "[ERROR] Ошибка установки"
        exit 1
    fi
else
    # Fallback - если модуль не найден
    echo "[WARN] Модуль IDE не найден, используем fallback..."
    
    # Определяем папку расширений
    for candidate in \
        "$HOME/.cursor-server/extensions" \
        "$HOME/.cursor/extensions" \
        "$HOME/.vscode-server/extensions" \
        "$HOME/.vscode/extensions"; do
        if [[ -d "$(dirname "$candidate")" ]]; then
            EXTENSIONS_DIR="$candidate"
            mkdir -p "$EXTENSIONS_DIR"
            break
        fi
    done
    
    if [[ -z "$EXTENSIONS_DIR" ]]; then
        EXTENSIONS_DIR="$HOME/.vscode/extensions"
        mkdir -p "$EXTENSIONS_DIR"
    fi
    
    TARGET_DIR="$EXTENSIONS_DIR/$EXTENSION_NAME"
    
    # Удаляем старую версию
    [[ -L "$TARGET_DIR" ]] || [[ -d "$TARGET_DIR" ]] && rm -rf "$TARGET_DIR"
    
    # Создаём symlink
    ln -s "$SCRIPT_DIR" "$TARGET_DIR"
    
    echo "[SUCCESS] Установлено в: $EXTENSIONS_DIR"
    echo "Перезапустите VS Code/Cursor для активации."
fi
