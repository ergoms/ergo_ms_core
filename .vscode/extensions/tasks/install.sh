#!/bin/bash
# Установка расширения ERGO MS Tasks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTENSION_NAME="ergo-ms.ergo-ms-tasks"
LEGACY_EXACT=("multi-terminal" "tasks")
LEGACY_PREFIXES=("ergo-ms.ergo-ms-multi-terminal-")

IDE_MODULE="$SCRIPT_DIR/lib/ide.sh"

remove_legacy_task_extensions() {
    local dirs=("$@")
    for ext_dir in "${dirs[@]}"; do
        [[ -d "$ext_dir" ]] || continue
        for name in "${LEGACY_EXACT[@]}"; do
            local target="$ext_dir/$name"
            if [[ -L "$target" ]] || [[ -d "$target" ]]; then
                rm -rf "$target"
                echo "[OK] Удалено устаревшее: $target"
            fi
        done
        for entry in "$ext_dir"/*; do
            [[ -d "$entry" ]] || continue
            local base
            base="$(basename "$entry")"
            for prefix in "${LEGACY_PREFIXES[@]}"; do
                if [[ "$base" == "$prefix"* ]]; then
                    rm -rf "$entry"
                    echo "[OK] Удалено устаревшее: $entry"
                fi
            done
        done
    done
}

if [[ -f "$IDE_MODULE" ]]; then
    source "$IDE_MODULE"

    echo "========================================"
    echo "  Установка расширения ERGO MS Tasks"
    echo "========================================"
    echo ""

    print_ide_info
    echo ""

    mapfile -t all_dirs < <(get_all_extensions_dirs 2>/dev/null || true)
    if [[ ${#all_dirs[@]} -gt 0 ]]; then
        remove_legacy_task_extensions "${all_dirs[@]}"
    fi

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
        echo 'Использование: multi-terminal в tasks.json и modules/<name>/vscode.tasks.yaml'
    else
        echo ""
        echo "[ERROR] Ошибка установки"
        exit 1
    fi
else
    echo "[WARN] Модуль IDE не найден, используем fallback..."

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

    remove_legacy_task_extensions "$EXTENSIONS_DIR"

    TARGET_DIR="$EXTENSIONS_DIR/$EXTENSION_NAME"

    [[ -L "$TARGET_DIR" ]] || [[ -d "$TARGET_DIR" ]] && rm -rf "$TARGET_DIR"

    ln -s "$SCRIPT_DIR" "$TARGET_DIR"

    echo "[SUCCESS] Установлено в: $EXTENSIONS_DIR"
    echo "Перезапустите VS Code/Cursor для активации."
fi
