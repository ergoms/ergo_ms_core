#!/bin/bash
# =============================================================================
# Централизованный модуль для определения IDE и путей расширений
# Поддерживает: VS Code, Cursor (локальный и remote/server режим)
# =============================================================================

# Определяет текущую IDE по переменным окружения
detect_current_ide() {
    # Cursor
    if [[ -n "$CURSOR_TRACE_ID" ]] || [[ "$TERM_PROGRAM" == "cursor" ]]; then
        echo "cursor"
        return
    fi
    
    # VS Code
    if [[ -n "$VSCODE_INJECTION" ]] || [[ "$TERM_PROGRAM" == "vscode" ]] || [[ -n "$VSCODE_GIT_IPC_HANDLE" ]]; then
        echo "vscode"
        return
    fi
    
    # Проверяем по процессам
    if pgrep -x "cursor" > /dev/null 2>&1; then
        echo "cursor"
        return
    fi
    
    if pgrep -x "code" > /dev/null 2>&1; then
        echo "vscode"
        return
    fi
    
    # По умолчанию - неизвестно
    echo "unknown"
}

# Определяет режим работы (local/remote)
detect_ide_mode() {
    # Remote/Server режим
    if [[ -n "$SSH_CONNECTION" ]] || [[ -n "$SSH_CLIENT" ]]; then
        echo "remote"
        return
    fi
    
    # Проверяем наличие server папок
    if [[ -d "$HOME/.cursor-server" ]] || [[ -d "$HOME/.vscode-server" ]]; then
        echo "remote"
        return
    fi
    
    echo "local"
}

# Возвращает путь к папке расширений для указанной IDE
# Использование: get_extensions_dir [ide_name]
# Если ide_name не указан, определяется автоматически
get_extensions_dir() {
    local ide="${1:-$(detect_current_ide)}"
    local mode=$(detect_ide_mode)
    
    local dir=""
    
    case "$ide" in
        cursor)
            if [[ "$mode" == "remote" ]] && [[ -d "$HOME/.cursor-server/extensions" ]]; then
                dir="$HOME/.cursor-server/extensions"
            elif [[ -d "$HOME/.cursor/extensions" ]]; then
                dir="$HOME/.cursor/extensions"
            fi
            ;;
        vscode)
            if [[ "$mode" == "remote" ]] && [[ -d "$HOME/.vscode-server/extensions" ]]; then
                dir="$HOME/.vscode-server/extensions"
            elif [[ -d "$HOME/.vscode/extensions" ]]; then
                dir="$HOME/.vscode/extensions"
            fi
            ;;
    esac
    
    # Если не нашли - пробуем все варианты
    if [[ -z "$dir" ]]; then
        for candidate in \
            "$HOME/.cursor-server/extensions" \
            "$HOME/.cursor/extensions" \
            "$HOME/.vscode-server/extensions" \
            "$HOME/.vscode/extensions"; do
            if [[ -d "$candidate" ]]; then
                dir="$candidate"
                break
            fi
        done
    fi
    
    # Создаём папку если не существует
    if [[ -z "$dir" ]]; then
        if [[ -d "$HOME/.cursor-server" ]]; then
            dir="$HOME/.cursor-server/extensions"
        elif [[ -d "$HOME/.cursor" ]]; then
            dir="$HOME/.cursor/extensions"
        elif [[ -d "$HOME/.vscode-server" ]]; then
            dir="$HOME/.vscode-server/extensions"
        else
            dir="$HOME/.vscode/extensions"
        fi
        mkdir -p "$dir"
    fi
    
    echo "$dir"
}

# Возвращает все пути к папкам расширений (для установки во все IDE)
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
    
    # VS Code (local)
    # Всегда добавляем как fallback
    mkdir -p "$HOME/.vscode/extensions"
    dirs+=("$HOME/.vscode/extensions")
    
    # Возвращаем уникальные пути
    printf '%s\n' "${dirs[@]}" | sort -u
}

# Устанавливает расширение во все доступные IDE
# Использование: install_extension_all <source_dir> <extension_name>
install_extension_all() {
    local source_dir="$1"
    local extension_name="$2"
    
    if [[ -z "$source_dir" ]] || [[ -z "$extension_name" ]]; then
        echo "[ERROR] Использование: install_extension_all <source_dir> <extension_name>"
        return 1
    fi
    
    local installed=0
    
    while IFS= read -r ext_dir; do
        local target="$ext_dir/$extension_name"
        
        # Удаляем старую версию
        if [[ -L "$target" ]] || [[ -d "$target" ]]; then
            rm -rf "$target"
        fi
        
        # Создаём symlink
        if ln -s "$source_dir" "$target" 2>/dev/null; then
            echo "[OK] Установлено в: $ext_dir"
            ((installed++))
        else
            echo "[WARN] Не удалось установить в: $ext_dir"
        fi
    done < <(get_all_extensions_dirs)
    
    if [[ $installed -eq 0 ]]; then
        echo "[ERROR] Расширение не было установлено ни в одну IDE"
        return 1
    fi
    
    return 0
}

# Удаляет расширение из всех IDE
# Использование: uninstall_extension_all <extension_name>
uninstall_extension_all() {
    local extension_name="$1"
    
    if [[ -z "$extension_name" ]]; then
        echo "[ERROR] Использование: uninstall_extension_all <extension_name>"
        return 1
    fi
    
    local removed=0
    
    while IFS= read -r ext_dir; do
        local target="$ext_dir/$extension_name"
        
        if [[ -L "$target" ]] || [[ -d "$target" ]]; then
            rm -rf "$target"
            echo "[OK] Удалено из: $ext_dir"
            ((removed++))
        fi
    done < <(get_all_extensions_dirs)
    
    echo "[INFO] Удалено из $removed расположений"
    return 0
}

# Выводит информацию о текущей IDE
print_ide_info() {
    local ide=$(detect_current_ide)
    local mode=$(detect_ide_mode)
    local ext_dir=$(get_extensions_dir)
    
    echo "IDE: $ide"
    echo "Режим: $mode"
    echo "Папка расширений: $ext_dir"
    echo ""
    echo "Все папки расширений:"
    get_all_extensions_dirs | while read -r dir; do
        if [[ -d "$dir" ]]; then
            echo "  [EXISTS] $dir"
        else
            echo "  [MISSING] $dir"
        fi
    done
}

# Если скрипт вызван напрямую - показать информацию
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-info}" in
        info)
            print_ide_info
            ;;
        extensions-dir)
            get_extensions_dir "$2"
            ;;
        all-extensions-dirs)
            get_all_extensions_dirs
            ;;
        *)
            echo "Использование: ide.sh [info|extensions-dir|all-extensions-dirs]"
            ;;
    esac
fi

