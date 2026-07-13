#!/usr/bin/env bash
# Единые метки консольного вывода ergoms (не переводить на русский).
# Источник истины: core/deployment/console_tags.py

ERGO_TAG_OK='[OK]'
ERGO_TAG_ERROR='[ERROR]'
ERGO_TAG_WARNING='[WARNING]'
ERGO_TAG_SKIP='[SKIP]'
ERGO_TAG_INFO='[INFO]'

export ERGO_TAG_OK ERGO_TAG_ERROR ERGO_TAG_WARNING ERGO_TAG_SKIP ERGO_TAG_INFO

format_ergo_console() {
  local level="$1"
  shift
  local message="$*"
  case "$level" in
    ok|OK) printf '%s' "$ERGO_TAG_OK" ;;
    error|ERROR) printf '%s' "$ERGO_TAG_ERROR" ;;
    warning|WARNING) printf '%s' "$ERGO_TAG_WARNING" ;;
    skip|SKIP) printf '%s' "$ERGO_TAG_SKIP" ;;
    info|INFO) printf '%s' "$ERGO_TAG_INFO" ;;
    *)
      echo "[ERROR] Unknown console tag level: $level" >&2
      return 1
      ;;
  esac
  if [[ -n "$message" ]]; then
    printf ' %s' "$message"
  fi
}

export -f format_ergo_console
