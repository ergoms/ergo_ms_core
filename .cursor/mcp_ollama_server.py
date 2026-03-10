"""
MCP сервер для работы с Ollama
Предоставляет инструменты для отправки запросов к Ollama моделям, управления моделями и проверки статуса
"""

import asyncio
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, List, Optional

import httpx
import psutil

_cursor_dir = Path(__file__).parent.resolve()
if str(_cursor_dir) not in sys.path:
    sys.path.insert(0, str(_cursor_dir))
from os_abstraction import get_background_popen_kwargs

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent


# Определяем корневую директорию проекта
PROJECT_DIR = Path(__file__).parent.parent.absolute()
ENV_FILE = PROJECT_DIR / '.env'

# Глобальные переменные для конфигурации
OLLAMA_BASE_URL = None
OLLAMA_DEFAULT_MODEL = None


def load_env() -> dict:
    """Загружает переменные окружения из .env файла"""
    env_vars = {}
    
    if not ENV_FILE.exists():
        # Если .env не найден, используем значения по умолчанию
        return {}
    
    with open(ENV_FILE, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                # Убираем кавычки, если они есть
                value = value.strip().strip('"').strip("'")
                env_vars[key.strip()] = value
    
    return env_vars


# Создаем экземпляр сервера
server = Server("ergo-ollama-server")


def find_ollama_process() -> Optional[psutil.Process]:
    """
    Ищет запущенный процесс Ollama.

    Returns:
        Optional[psutil.Process]: Объект процесса если Ollama запущен, иначе None
    """
    for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
        try:
            cmdline = proc.info.get('cmdline') or []
            cmdline_lower = [part.lower() for part in cmdline]
            
            # Ищем процесс ollama serve
            if 'ollama' in cmdline_lower and 'serve' in cmdline_lower:
                return proc
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return None


def start_ollama_background() -> bool:
    """
    Запускает Ollama сервер в фоновом режиме.

    Returns:
        bool: True если запуск успешен, False иначе
    """
    try:
        # Определяем путь к core/api/
        api_dir = PROJECT_DIR / "core" / "api"
        cmd: List[str] = ['ollama', 'serve']
        
        popen_kwargs = {
            'cwd': str(api_dir),
            'stdout': subprocess.DEVNULL,
            'stderr': subprocess.DEVNULL,
            **get_background_popen_kwargs()
        }
        process = subprocess.Popen(cmd, **popen_kwargs)
        
        # Ждем немного, чтобы сервер успел запуститься
        time.sleep(2)
        
        # Проверяем, что процесс все еще работает
        if process.poll() is None:
            return True
        else:
            return False
            
    except FileNotFoundError:
        return False
    except Exception:
        return False


async def ensure_ollama_running(base_url: str) -> bool:
    """
    Убеждается, что Ollama сервер запущен. Если нет - запускает его.

    Args:
        base_url: Базовый URL Ollama API

    Returns:
        bool: True если Ollama доступен, False иначе
    """
    # Проверяем, запущен ли процесс
    if not find_ollama_process():
        print("🦙 Ollama не запущен. Запускаю...", file=sys.stderr)
        
        if not start_ollama_background():
            print("❌ Не удалось запустить Ollama", file=sys.stderr)
            return False
        
        # Ждем, пока Ollama станет доступен
        print("⏳ Ожидание запуска Ollama...", file=sys.stderr)
        for i in range(30):
            try:
                async with httpx.AsyncClient(timeout=2.0) as client:
                    response = await client.get(f"{base_url}/api/tags")
                    if response.status_code == 200:
                        print("✅ Ollama готов к работе", file=sys.stderr)
                        return True
            except:
                pass
            await asyncio.sleep(1)
            if (i + 1) % 5 == 0:
                print(f"   ... еще {30 - i - 1} секунд", file=sys.stderr)
        
        print("❌ Ollama не стал доступен за отведенное время", file=sys.stderr)
        return False
    
    # Проверяем доступность API
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            response = await client.get(f"{base_url}/api/tags")
            if response.status_code == 200:
                return True
    except:
        pass
    
    return False


async def initialize_config():
    """Инициализирует конфигурацию при запуске сервера"""
    global OLLAMA_BASE_URL, OLLAMA_DEFAULT_MODEL
    
    # Загружаем конфигурацию из .env
    env_vars = load_env()
    
    # Получаем настройки из .env или используем значения по умолчанию
    OLLAMA_BASE_URL = env_vars.get('OLLAMA_BASE_URL', 'http://localhost:11434')
    OLLAMA_DEFAULT_MODEL = env_vars.get('OLLAMA_DEFAULT_MODEL', 'mistral')
    
    # Проверяем доступность Ollama
    is_running = await ensure_ollama_running(OLLAMA_BASE_URL)
    
    if is_running:
        print(f"✓ MCP Ollama сервер инициализирован", file=sys.stderr)
        print(f"  - Ollama URL: {OLLAMA_BASE_URL}", file=sys.stderr)
        print(f"  - Модель по умолчанию: {OLLAMA_DEFAULT_MODEL}", file=sys.stderr)
        print(f"  - Статус: доступен", file=sys.stderr)
    else:
        print(f"⚠ MCP Ollama сервер инициализирован", file=sys.stderr)
        print(f"  - Ollama URL: {OLLAMA_BASE_URL}", file=sys.stderr)
        print(f"  - Модель по умолчанию: {OLLAMA_DEFAULT_MODEL}", file=sys.stderr)
        print(f"  - Статус: недоступен (будет запущен автоматически при первом запросе)", file=sys.stderr)


@server.list_tools()
async def list_tools() -> list[Tool]:
    """Список доступных инструментов для работы с Ollama"""
    return [
        Tool(
            name="ollama_generate",
            description="Отправляет запрос к Ollama модели и получает ответ. Автоматически запускает Ollama если он не запущен.",
            inputSchema={
                "type": "object",
                "properties": {
                    "prompt": {
                        "type": "string",
                        "description": "Текст запроса к модели"
                    },
                    "model": {
                        "type": "string",
                        "description": "Название модели Ollama (по умолчанию: mistral)",
                        "default": "mistral"
                    },
                    "temperature": {
                        "type": "number",
                        "description": "Температура генерации (0.0-1.0, по умолчанию: 0.7)",
                        "default": 0.7,
                        "minimum": 0.0,
                        "maximum": 1.0
                    },
                    "max_tokens": {
                        "type": "integer",
                        "description": "Максимальное количество токенов в ответе (по умолчанию: 2048)",
                        "default": 2048
                    }
                },
                "required": ["prompt"]
            }
        ),
        Tool(
            name="ollama_list_models",
            description="Получает список установленных моделей Ollama",
            inputSchema={
                "type": "object",
                "properties": {}
            }
        ),
        Tool(
            name="ollama_status",
            description="Проверяет статус Ollama сервера и возвращает информацию о доступных моделях",
            inputSchema={
                "type": "object",
                "properties": {}
            }
        ),
        Tool(
            name="ollama_pull_model",
            description="Скачивает модель Ollama. Может занять много времени в зависимости от размера модели.",
            inputSchema={
                "type": "object",
                "properties": {
                    "model": {
                        "type": "string",
                        "description": "Название модели для скачивания (например: mistral, llama2, codellama)"
                    }
                },
                "required": ["model"]
            }
        )
    ]


@server.call_tool()
async def call_tool(name: str, arguments: Any) -> list[TextContent]:
    """Обработка вызовов инструментов"""
    
    # Убеждаемся, что Ollama запущен (только для команд, требующих API)
    if name in ["ollama_generate", "ollama_list_models", "ollama_status", "ollama_pull_model"]:
        base_url = OLLAMA_BASE_URL or "http://localhost:11434"
        await ensure_ollama_running(base_url)
    
    if name == "ollama_generate":
        return await handle_generate(arguments)
    elif name == "ollama_list_models":
        return await handle_list_models()
    elif name == "ollama_status":
        return await handle_status()
    elif name == "ollama_pull_model":
        return await handle_pull_model(arguments)
    else:
        raise ValueError(f"Неизвестный инструмент: {name}")


async def handle_generate(arguments: dict) -> list[TextContent]:
    """Обработка запроса генерации"""
    prompt = arguments.get("prompt", "")
    model = arguments.get("model", OLLAMA_DEFAULT_MODEL)
    temperature = arguments.get("temperature", 0.7)
    max_tokens = arguments.get("max_tokens", 2048)
    
    if not prompt:
        return [TextContent(
            type="text",
            text=json.dumps({"error": "Параметр 'prompt' обязателен"}, ensure_ascii=False, indent=2)
        )]
    
    try:
        url = f"{OLLAMA_BASE_URL}/api/generate"
        payload = {
            "model": model,
            "prompt": prompt,
            "stream": False,
            "options": {
                "temperature": temperature,
                "num_predict": max_tokens
            }
        }
        
        async with httpx.AsyncClient(timeout=120.0) as client:
            response = await client.post(url, json=payload)
            response.raise_for_status()
            data = response.json()
            
            result = {
                "model": model,
                "response": data.get("response", ""),
                "done": data.get("done", False),
                "context": data.get("context", []),
                "total_duration": data.get("total_duration", 0),
                "load_duration": data.get("load_duration", 0),
                "prompt_eval_count": data.get("prompt_eval_count", 0),
                "prompt_eval_duration": data.get("prompt_eval_duration", 0),
                "eval_count": data.get("eval_count", 0),
                "eval_duration": data.get("eval_duration", 0)
            }
            
            # Вычисляем скорость генерации
            if result["eval_duration"] > 0 and result["eval_count"] > 0:
                tokens_per_sec = result["eval_count"] / (result["eval_duration"] / 1e9)
                result["tokens_per_second"] = round(tokens_per_sec, 2)
            
            return [TextContent(
                type="text",
                text=json.dumps(result, ensure_ascii=False, indent=2)
            )]
            
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 404:
            error_msg = {
                "error": f"Модель '{model}' не найдена",
                "suggestion": f"Установите модель командой: ollama pull {model}"
            }
        else:
            error_msg = {
                "error": f"Ошибка HTTP: {e.response.status_code}",
                "details": e.response.text
            }
        return [TextContent(
            type="text",
            text=json.dumps(error_msg, ensure_ascii=False, indent=2)
        )]
    except httpx.TimeoutException:
        return [TextContent(
            type="text",
            text=json.dumps({"error": "Таймаут запроса к Ollama"}, ensure_ascii=False, indent=2)
        )]
    except Exception as e:
        return [TextContent(
            type="text",
            text=json.dumps({"error": str(e)}, ensure_ascii=False, indent=2)
        )]


async def handle_list_models() -> list[TextContent]:
    """Обработка запроса списка моделей"""
    try:
        url = f"{OLLAMA_BASE_URL}/api/tags"
        
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(url)
            response.raise_for_status()
            data = response.json()
            
            models = data.get("models", [])
            model_list = [{"name": m.get("name", ""), "modified_at": m.get("modified_at", "")} for m in models]
            
            result = {
                "available": True,
                "models": model_list,
                "count": len(model_list)
            }
            
            return [TextContent(
                type="text",
                text=json.dumps(result, ensure_ascii=False, indent=2)
            )]
            
    except Exception as e:
        return [TextContent(
            type="text",
            text=json.dumps({"error": str(e), "available": False}, ensure_ascii=False, indent=2)
        )]


async def handle_status() -> list[TextContent]:
    """Обработка запроса статуса"""
    try:
        url = f"{OLLAMA_BASE_URL}/api/tags"
        
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(url)
            response.raise_for_status()
            data = response.json()
            
            models = [m.get("name", "") for m in data.get("models", [])]
            
            result = {
                "available": True,
                "base_url": OLLAMA_BASE_URL,
                "models_count": len(models),
                "models": models,
                "process_running": find_ollama_process() is not None
            }
            
            return [TextContent(
                type="text",
                text=json.dumps(result, ensure_ascii=False, indent=2)
            )]
            
    except httpx.ConnectError:
        result = {
            "available": False,
            "error": "Не удалось подключиться к Ollama",
            "base_url": OLLAMA_BASE_URL,
            "process_running": find_ollama_process() is not None
        }
        return [TextContent(
            type="text",
            text=json.dumps(result, ensure_ascii=False, indent=2)
        )]
    except Exception as e:
        return [TextContent(
            type="text",
            text=json.dumps({"error": str(e), "available": False}, ensure_ascii=False, indent=2)
        )]


async def handle_pull_model(arguments: dict) -> list[TextContent]:
    """Обработка запроса скачивания модели"""
    model = arguments.get("model", "")
    
    if not model:
        return [TextContent(
            type="text",
            text=json.dumps({"error": "Параметр 'model' обязателен"}, ensure_ascii=False, indent=2)
        )]
    
    try:
        url = f"{OLLAMA_BASE_URL}/api/pull"
        payload = {
            "name": model,
            "stream": False
        }
        
        async with httpx.AsyncClient(timeout=600.0) as client:  # Большой таймаут для скачивания
            response = await client.post(url, json=payload)
            response.raise_for_status()
            data = response.json()
            
            result = {
                "model": model,
                "status": "downloaded" if data.get("status") == "success" else data.get("status", "unknown"),
                "message": data.get("message", "")
            }
            
            return [TextContent(
                type="text",
                text=json.dumps(result, ensure_ascii=False, indent=2)
            )]
            
    except httpx.TimeoutException:
        return [TextContent(
            type="text",
            text=json.dumps({
                "error": "Таймаут при скачивании модели",
                "note": "Скачивание больших моделей может занять много времени"
            }, ensure_ascii=False, indent=2)
        )]
    except Exception as e:
        return [TextContent(
            type="text",
            text=json.dumps({"error": str(e)}, ensure_ascii=False, indent=2)
        )]


async def main():
    """Запуск MCP сервера через stdio"""
    # Инициализируем конфигурацию перед запуском
    await initialize_config()
    
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options()
        )


if __name__ == "__main__":
    asyncio.run(main())

