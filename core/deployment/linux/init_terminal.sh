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

# Wrappers: show hint and do not run the underlying command (ASCII to avoid encoding issues)
pip() {
  echo -e "\033[33mUse: ergoms python-install or ergoms poetry add <package>\033[0m"
}

poetry() {
  echo -e "\033[33mUse: ergoms poetry <args>, e.g. ergoms poetry install, ergoms python-install, ergoms python-update\033[0m"
}

npm() {
  echo -e "\033[33mUse: ergoms npm <args>, ergoms start-client, ergoms client-build, ergoms install-deps\033[0m"
}

api() {
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
