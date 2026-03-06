# init_terminal.sh - Project shell with ergoms-only wrappers
# Source at terminal start so pip, poetry, npm, api and python manage.py are redirected to ergoms.
# Location: core/deployment/linux/init_terminal.sh (project root is 3 levels up).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Activate venv if present
if [[ -f "$PROJECT_ROOT/virtual_env/python/bin/activate" ]]; then
  source "$PROJECT_ROOT/virtual_env/python/bin/activate"
fi

# Local ergoms (same folder as this script)
ergoms() {
  bash "$SCRIPT_DIR/ergo_ms.sh" "$@"
}

# Wrappers: pass through when ergoms sets ERGOMS_INTERNAL=1; show hint for direct user calls.

pip() {
  echo -e "\033[33mUse: ergoms python-install or ergoms poetry add <package>\033[0m"
}

pip3() {
  echo -e "\033[33mUse: ergoms python-install or ergoms poetry add <package>\033[0m"
}

poetry() {
  if [[ -n "${ERGOMS_INTERNAL:-}" ]]; then
    command poetry "$@"
    return
  fi
  echo -e "\033[33mUse: ergoms poetry <args>, e.g. ergoms poetry install, ergoms python-install, ergoms python-update\033[0m"
}

npm() {
  if [[ -n "${ERGOMS_INTERNAL:-}" ]]; then
    command npm "$@"
    return
  fi
  echo -e "\033[33mUse: ergoms npm <args>, ergoms start-client, ergoms client-build, ergoms install-deps\033[0m"
}

api() {
  if [[ -n "${ERGOMS_INTERNAL:-}" ]]; then
    command api "$@"
    return
  fi
  echo -e "\033[33mUse: ergoms api <args> or ergoms dev, ergoms db-migrate, ergoms migrate-all, ergoms collectstatic\033[0m"
}

python() {
  local first="$1"
  if [[ -n "$first" && ("$first" == *manage.py || "$first" == *"/manage.py") ]]; then
    echo -e "\033[33mUse: ergoms api <command>, e.g. ergoms dev, ergoms db-migrate, ergoms migrate-all, ergoms collectstatic\033[0m"
    return 1
  fi
  command python "$@"
}

python3() {
  local first="$1"
  if [[ -n "$first" && ("$first" == *manage.py || "$first" == *"/manage.py") ]]; then
    echo -e "\033[33mUse: ergoms api <command>, e.g. ergoms dev, ergoms db-migrate, ergoms migrate-all, ergoms collectstatic\033[0m"
    return 1
  fi
  command python3 "$@"
}

export -f pip
export -f pip3
export -f poetry
export -f npm
export -f api
export -f python
export -f python3
