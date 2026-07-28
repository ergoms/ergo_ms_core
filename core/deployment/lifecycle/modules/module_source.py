"""Разбор module_source пунктов меню (modules/<name>/… → <name>)."""


def top_level_from_module_source(module_source: str) -> str | None:
    """
    Верхний уровень модуля из module_source.

    ``modules/<name>`` и ``modules/<name>/…`` → ``<name>``;
    пути вне ``modules/`` (например ``core/cms``) → ``None``.
    """
    if not module_source:
        return None
    normalized = module_source.strip().replace('\\', '/')
    if not normalized.startswith('modules/'):
        return None
    parts = [p for p in normalized.split('/') if p]
    if len(parts) < 2:
        return None
    return parts[1]
