#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
enable_test_traps

cd "$ROOT_DIR"

read_jsonc_py() {
  # Prints JSON to stdout (as python object via json), or empty on failure.
  local path="${1:?}"
  python3 - "$path" <<'PY' 2>/dev/null || true
import json, re, sys
path = sys.argv[1]
try:
    raw = open(path, "r", encoding="utf-8").read()
except OSError:
    sys.exit(0)
raw = re.sub(r"(?m)^\s*//.*$", "", raw)
raw = re.sub(r"(?s)/\*.*?\*/", "", raw)
raw = re.sub(r",(\s*[}\]])", r"\1", raw)
raw = raw.strip()
if not raw:
    sys.exit(0)
obj = json.loads(raw)
print(json.dumps(obj, ensure_ascii=False))
PY
}

get_required_extensions() {
  # outputs: local_required (line), then '---', then recommended (line)
  local local_required=()
  local recommended=()

  # Local shipped extensions
  if [[ -d "$ROOT_DIR/.vscode/extensions" ]]; then
    while IFS= read -r pkg; do
      [[ -f "$pkg" ]] || continue
      local json
      json="$(read_jsonc_py "$pkg")"
      [[ -n "$json" ]] || continue
      local id
      id="$(python3 - <<PY 2>/dev/null || true
import json
o=json.loads('''$json''')
pub=o.get('publisher'); name=o.get('name')
print(f"{pub}.{name}".lower() if pub and name else "")
PY
)"
      [[ -n "$id" ]] && local_required+=("$id")
    done < <(find "$ROOT_DIR/.vscode/extensions" -name package.json -type f 2>/dev/null || true)
  fi

  # Recommendations
  if [[ -f "$ROOT_DIR/.vscode/extensions.json" ]]; then
    local json
    json="$(read_jsonc_py "$ROOT_DIR/.vscode/extensions.json")"
    if [[ -n "$json" ]]; then
      while IFS= read -r id; do
        [[ -n "$id" ]] && recommended+=("${id,,}")
      done < <(python3 - <<PY 2>/dev/null || true
import json
o=json.loads('''$json''')
for x in (o.get("recommendations") or []):
    if isinstance(x,str) and x.strip():
        print(x.strip())
PY
)
    fi
  fi

  printf '%s\n' "${local_required[@]}" | sort -u
  echo "---"
  printf '%s\n' "${recommended[@]}" | sort -u
}

get_installed_extensions() {
  if command -v code >/dev/null 2>&1; then
    code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort -u || true
    return 0
  fi

  # Fallback by dirs (VS Code/Cursor)
  local out=()
  local d
  for d in "$HOME/.vscode/extensions" "$HOME/.cursor/extensions"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      # publisher.name-version -> publisher.name
      if [[ "$name" =~ ^(.+)-[0-9]+\.[0-9]+\.[0-9]+.*$ ]]; then
        out+=("${BASH_REMATCH[1],,}")
      fi
    done < <(find "$d" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null || true)
  done
  printf '%s\n' "${out[@]}" | sort -u
}

test_http_alive() {
  local url="${1:?}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "$url" >/dev/null 2>&1 && return 0
    # any response (even non-200) still indicates server is listening; try without -f
    curl -sS --max-time 2 "$url" >/dev/null 2>&1 && return 0
    return 1
  fi
  return 1
}

extension_is_installed() {
  local id="${1,,}"
  local inst
  for inst in "${installed[@]}"; do
    [[ "${inst,,}" == "$id" ]] && return 0
  done
  return 1
}

show_extensions_status() {
  local -a ids=() types=()
  local id

  for id in "${local_required[@]}"; do
    [[ -z "$id" ]] && continue
    ids+=("$id")
    types+=("local(required)")
  done
  for id in "${recommended[@]}"; do
    [[ -z "$id" ]] && continue
    ids+=("$id")
    types+=("marketplace(recommended)")
  done

  [[ "${#ids[@]}" -eq 0 ]] && return 0

  step "Статус расширений: список и статус каждого"
  local i status line
  for i in "${!ids[@]}"; do
    id="${ids[$i]}"
    if extension_is_installed "$id"; then
      status="INSTALLED"
      line="- [${status}] ${id} — ${types[$i]}"
      echo "$line"
      log "[OK] $line"
    else
      status="MISSING"
      line="- [${status}] ${id} — ${types[$i]}"
      echo "$line"
      log "[WARNING] $line"
    fi
  done
}

echo "================================================="
echo "=   Проверка VS Code расширений (наличие/OK)    ="
echo "================================================="

step "1. Проверка доступности VS Code CLI (code)"
if command -v code >/dev/null 2>&1; then
  log "[OK] code найден в PATH"
else
  log "[WARNING] code не найден в PATH. Используем fallback-проверку по директориям расширений."
fi

step "2. Проверка наличия расширений (локальные обязательные + marketplace рекомендованные)"
ERGO_TEST_CURRENT_STEP="extensions: presence"

mapfile -t req_block < <(get_required_extensions)
sep_idx=-1
for i in "${!req_block[@]}"; do
  [[ "${req_block[$i]}" == "---" ]] && sep_idx="$i" && break
done

local_required=()
recommended=()
if [[ "$sep_idx" -ge 0 ]]; then
  local_required=("${req_block[@]:0:$sep_idx}")
  recommended=("${req_block[@]:$((sep_idx+1))}")
else
  local_required=("${req_block[@]}")
fi

installed=()
mapfile -t installed < <(get_installed_extensions)

if [[ "${#local_required[@]}" -gt 0 ]]; then
  log "Локальные обязательные расширения: ${local_required[*]}"
else
  log "[WARNING] Не найден список локальных обязательных расширений (.vscode/extensions/*)."
fi
if [[ "${#recommended[@]}" -gt 0 ]]; then
  log "Marketplace рекомендованные расширения: ${recommended[*]}"
fi

log "Установленные расширения (кол-во=${#installed[@]}): $(printf '%s' "${installed[*]:0:20}")$( [[ "${#installed[@]}" -gt 20 ]] && printf ', ...' || true)"

missing_local=()
for id in "${local_required[@]}"; do
  [[ -z "$id" ]] && continue
  found=false
  for inst in "${installed[@]}"; do
    [[ "$inst" == "$id" ]] && found=true && break
  done
  [[ "$found" == false ]] && missing_local+=("$id")
done

missing_rec=()
for id in "${recommended[@]}"; do
  [[ -z "$id" ]] && continue
  found=false
  for inst in "${installed[@]}"; do
    [[ "$inst" == "$id" ]] && found=true && break
  done
  [[ "$found" == false ]] && missing_rec+=("$id")
done

if [[ "${#missing_local[@]}" -eq 0 ]]; then
  log "[OK] Все локальные обязательные расширения установлены."
else
  log "[WARNING] Отсутствуют локальные обязательные расширения: ${missing_local[*]}"
fi

if [[ "${#missing_rec[@]}" -gt 0 ]]; then
  log "[WARNING] Отсутствуют рекомендованные расширения (может быть допустимо): ${missing_rec[*]}"
fi

show_extensions_status

step "3. Валидация работоспособности расширения автоматизации (HTTP 127.0.0.1:45678)"
ERGO_TEST_CURRENT_STEP="extensions: http"
if test_http_alive "http://127.0.0.1:45678/run-task"; then
  log "[OK] HTTP сервер расширения отвечает (порт 45678)."
else
  log "[WARNING] HTTP сервер расширения НЕ отвечает (порт 45678). IDE может быть не запущена/расширение не активно."
fi

echo "================================================="
echo "=     Проверка VS Code расширений завершена     ="
echo "================================================="

if [[ "${#missing_local[@]}" -gt 0 ]]; then
  log "[WARNING] Не установлены локальные расширения проекта: ${missing_local[*]}"
fi

