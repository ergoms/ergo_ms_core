"""Реестр runners контролей безопасности (этап 0–1)."""

from __future__ import annotations

from typing import Any, Callable

from security.catalog import Control, SecurityCatalog
from security.report import Finding

from . import (
    anonymous_endpoints,
    broker_redis,
    client_browser_log,
    deferred,
    env_value,
    jupyter_exposure,
    password_policy,
    presence,
    secrets,
)

CheckContext = dict[str, Any]
Checker = Callable[[Control, SecurityCatalog, CheckContext], Finding]

_REGISTRY: dict[str, Checker] = {
    'env_rate_max': env_value.env_rate_max,
    'env_int_max': env_value.env_int_max,
    'env_int_min': env_value.env_int_min,
    'env_bool_required_true': env_value.env_bool_required_true,
    'registration_mode_min': env_value.registration_mode_min,
    'reset_code_policy': env_value.reset_code_policy,
    'docs_exposure': env_value.docs_exposure,
    'nonempty_outside_dev': presence.nonempty_outside_dev,
    'secrets_no_defaults': secrets.secrets_no_defaults,
    'password_policy': password_policy.run,
    'jupyter_exposure': jupyter_exposure.run,
    'anonymous_endpoints': anonymous_endpoints.run,
    'client_browser_log': client_browser_log.run,
    'broker_redis_password': broker_redis.run,
    'code_fixed': deferred.code_fixed,
    'deferred': deferred.deferred,
}


def run_control_check(
    control: Control,
    catalog: SecurityCatalog,
    context: CheckContext,
) -> Finding:
    runner = _REGISTRY.get(control.check)
    if runner is None:
        return Finding(
            control_id=control.id,
            title=control.title,
            severity='skip',
            message=f'Неизвестный check={control.check}',
        )
    return runner(control, catalog, context)
