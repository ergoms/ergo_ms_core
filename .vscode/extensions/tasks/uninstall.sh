#!/bin/bash
# Удаление расширения ERGO MS Tasks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTENSION_NAMES=("ergo-ms.ergo-ms-tasks" "multi-terminal" "tasks")
LEGACY_PREFIXES=("ergo-ms.ergo-ms-tasks-" "ergo-ms.ergo-ms-multi-terminal-")

IDE_MODULE="$SCRIPT_DIR/lib/ide.sh"

remove_task_extension_dirs() {
    local dirs=("$@")
    local removed=0
    for ext_dir in "${dirs[@]}"; do
        [[ -d "$ext_dir" ]] || continue
        for name in "${EXTENSION_NAMES[@]}"; do
            local target="$ext_dir/$name"
            if [[ -L "$target" ]] || [[ -d "$target" ]]; then
                rm -rf "$target"
                echo "[OK] Удалено из: $ext_dir ($name)"
                removed=$((removed + 1))
            fi
        done
        for entry in "$ext_dir"/*; do
            [[ -d "$entry" ]] || continue
            local base
            base="$(basename "$entry")"
            for prefix in "${LEGACY_PREFIXES[@]}"; do
                if [[ "$base" == "$prefix"* ]]; then
                    rm -rf "$entry"
                    echo "[OK] Удалено из: $entry"
                    removed=$((removed + 1))
                fi
            done
        done
    done
    return $(( removed > 0 ? 0 : 1 ))
}

if [[ -f "$IDE_MODULE" ]]; then
    source "$IDE_MODULE"

    echo "========================================"
    echo "  Удаление расширения ERGO MS Tasks"
    echo "========================================"
    echo ""

    mapfile -t all_dirs < <(get_all_extensions_dirs 2>/dev/null || true)
    if remove_task_extension_dirs "${all_dirs[@]}"; then
        echo ""
        echo "[SUCCESS] Расширение удалено!"
        echo "Перезапустите VS Code/Cursor для применения."
    else
        echo "[WARN] Расширение не было найдено"
    fi
else
    echo "[INFO] Удаление расширения из всех IDE..."

    dirs=(
        "$HOME/.cursor-server/extensions"
        "$HOME/.cursor/extensions"
        "$HOME/.vscode-server/extensions"
        "$HOME/.vscode/extensions"
    )
    remove_task_extension_dirs "${dirs[@]}" || true

    echo ""
    echo "[SUCCESS] Готово! Перезапустите VS Code/Cursor."
fi
