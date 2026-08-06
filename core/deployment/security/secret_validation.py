"""Проверка API_SECRET_KEY для production без печати значения."""

from __future__ import annotations

# Каталог refs.insecure_secret_values + legacy aliases media/API.
INSECURE_SECRET_VALUES: frozenset[str] = frozenset({
    '',
    'secret_key',
    'changeme',
    'django-insecure',
    'secret-key',
    'media-api-insecure-key',
})

MIN_PRODUCTION_SECRET_LENGTH = 32


def is_insecure_secret(secret_key: str | None) -> bool:
    key = (secret_key or '').strip()
    if not key:
        return True
    if key in INSECURE_SECRET_VALUES:
        return True
    return False


def production_secret_is_valid(secret_key: str | None) -> bool:
    key = (secret_key or '').strip()
    if is_insecure_secret(key):
        return False
    return len(key) >= MIN_PRODUCTION_SECRET_LENGTH


def validate_production_secret_key(secret_key: str | None) -> None:
    """
    Fail-fast для ERGO_ENV=production.

    Raises:
        ValueError: пустой, шаблонный или слишком короткий ключ (без значения в тексте).
    """
    key = (secret_key or '').strip()
    if not key:
        raise ValueError(
            'ERGO_ENV=production: API_SECRET_KEY пуст. '
            'Сгенерируйте ключ: ergoms generate-secret'
        )
    if key in INSECURE_SECRET_VALUES:
        raise ValueError(
            'ERGO_ENV=production: API_SECRET_KEY совпадает с шаблонным/небезопасным значением. '
            'Сгенерируйте ключ: ergoms generate-secret'
        )
    if len(key) < MIN_PRODUCTION_SECRET_LENGTH:
        raise ValueError(
            f'ERGO_ENV=production: API_SECRET_KEY короче '
            f'{MIN_PRODUCTION_SECRET_LENGTH} символов. '
            'Сгенерируйте ключ: ergoms generate-secret'
        )
