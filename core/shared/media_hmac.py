"""
Единая HMAC-логика подписи URL и upload-токенов для core/api и media_api.
Без зависимостей от Django — только stdlib.
"""

import base64
import hashlib
import hmac
import json
import time
from typing import Optional


def sign_url(path: str, secret_key: str, expires_in: int = 3600) -> tuple:
    expires = int(time.time()) + expires_in
    message = f'{path}:{expires}'
    signature = hmac.new(
        secret_key.encode('utf-8'),
        message.encode('utf-8'),
        hashlib.sha256,
    ).hexdigest()
    return signature, expires


def verify_url(path: str, signature: str, expires: int, secret_key: str) -> bool:
    if int(time.time()) > expires:
        return False
    message = f'{path}:{expires}'
    expected = hmac.new(
        secret_key.encode('utf-8'),
        message.encode('utf-8'),
        hashlib.sha256,
    ).hexdigest()
    return hmac.compare_digest(signature, expected)


def create_upload_token(payload: dict, secret_key: str, expires_in: int = 300) -> str:
    data = dict(payload)
    data['expires'] = int(time.time()) + expires_in
    payload_json = json.dumps(data, sort_keys=True)
    signature = hmac.new(
        secret_key.encode('utf-8'),
        payload_json.encode('utf-8'),
        hashlib.sha256,
    ).hexdigest()
    token_data = {'payload': data, 'signature': signature}
    return base64.urlsafe_b64encode(
        json.dumps(token_data).encode('utf-8')
    ).decode('utf-8')


def verify_upload_token(token: str, secret_key: str) -> Optional[dict]:
    try:
        raw = base64.urlsafe_b64decode(token.encode('utf-8'))
        token_data = json.loads(raw)
        payload = token_data['payload']
        signature = token_data['signature']

        if int(time.time()) > payload.get('expires', 0):
            return None

        payload_json = json.dumps(payload, sort_keys=True)
        expected = hmac.new(
            secret_key.encode('utf-8'),
            payload_json.encode('utf-8'),
            hashlib.sha256,
        ).hexdigest()

        if not hmac.compare_digest(signature, expected):
            return None

        return payload
    except Exception:
        return None
