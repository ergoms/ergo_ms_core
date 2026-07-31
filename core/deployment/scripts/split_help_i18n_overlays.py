"""
Одноразово: nested {ru,en,fr} в help YAML → ru inline + locales/<lang>/ overlays.

  py core/deployment/scripts/split_help_i18n_overlays.py
"""

from __future__ import annotations

import sys
from copy import deepcopy
from pathlib import Path
from typing import Any

import yaml

_ROOT = Path(__file__).resolve().parents[3]
_DEPLOYMENT = _ROOT / 'core' / 'deployment'
_LANGS = ('en', 'fr')
_LOCALE_KEYS = frozenset({'ru', 'en', 'fr'})


def _is_locale_map(value: Any) -> bool:
    if not isinstance(value, dict) or not value:
        return False
    if not any(k in value for k in ('ru', 'en', 'fr')):
        return False
    return all(isinstance(v, str) for v in value.values()) and set(value).issubset(
        _LOCALE_KEYS | set(value)
    ) and set(value.keys()) <= _LOCALE_KEYS


def _split_node(node: Any) -> tuple[Any, dict[str, Any]]:
    """Возвращает (ru_node, {lang: overlay_node})."""
    overlays: dict[str, Any] = {lang: None for lang in _LANGS}

    if _is_locale_map(node):
        base = node.get('ru', '')
        for lang in _LANGS:
            overlays[lang] = node.get(lang, base)
        return base, overlays

    if isinstance(node, list):
        base_list: list[Any] = []
        overlay_lists: dict[str, list[Any]] = {lang: [] for lang in _LANGS}
        for item in node:
            item_base, item_overlays = _split_node(item)
            base_list.append(item_base)
            for lang in _LANGS:
                overlay_lists[lang].append(item_overlays[lang])
        return base_list, overlay_lists

    if isinstance(node, dict):
        base_dict: dict[str, Any] = {}
        overlay_dicts: dict[str, dict[str, Any]] = {lang: {} for lang in _LANGS}
        for key, value in node.items():
            item_base, item_overlays = _split_node(value)
            base_dict[key] = item_base
            for lang in _LANGS:
                ov = item_overlays[lang]
                if ov is not None:
                    overlay_dicts[lang][key] = ov
        return base_dict, overlay_dicts

    return node, {lang: node for lang in _LANGS}


def _dump(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = yaml.dump(
        data,
        allow_unicode=True,
        default_flow_style=False,
        sort_keys=False,
        width=120,
    )
    path.write_text(text, encoding='utf-8')


def _convert_file(base_path: Path, overlay_root: Path) -> None:
    raw = yaml.safe_load(base_path.read_text(encoding='utf-8'))
    if not isinstance(raw, dict):
        print(f'[SKIP] not a mapping: {base_path}')
        return
    # Уже без nested maps?
    sample = yaml.dump(raw)
    if 'ru:' not in sample or ('en:' not in sample and 'fr:' not in sample):
        # грубая эвристика: если нет типичных nested блоков title/summary — skip
        pass

    base, overlays = _split_node(deepcopy(raw))
    header = (
        '# Source of truth (ru). Translations: locales/<lang>/'
        f'{base_path.name}\n'
    )
    _dump(base_path, base)
    # prepend header
    base_path.write_text(header + base_path.read_text(encoding='utf-8'), encoding='utf-8')

    for lang in _LANGS:
        ov_path = overlay_root / lang / base_path.name
        ov_header = f'# {lang} overlay for {base_path.name} (merged over Russian source)\n'
        _dump(ov_path, overlays[lang])
        ov_path.write_text(ov_header + ov_path.read_text(encoding='utf-8'), encoding='utf-8')
        print(f'[OK] {ov_path.relative_to(_ROOT)}')
    print(f'[OK] {base_path.relative_to(_ROOT)} (ru inline)')


def main() -> int:
    manifest = _DEPLOYMENT / 'help.manifest.yaml'
    if manifest.is_file():
        _convert_file(manifest, _DEPLOYMENT / 'locales')

    modules_dir = _ROOT / 'modules'
    if modules_dir.is_dir():
        for help_path in sorted(modules_dir.glob('*/ergoms.help.yaml')):
            module_dir = help_path.parent
            _convert_file(help_path, module_dir / 'locales')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
