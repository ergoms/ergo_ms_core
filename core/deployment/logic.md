Все команды должны быть реализованы для двух операционных систем: Linux, Windows. Windows через Powershell, Linux через bash.

Файл core/deployment/commands.conf позволяет создавать пользовательские команды и алиасы для них.

Виртуальное окружение устанавливается в папку virtual_env/python/, эта папка по умолчанию существует, поэтому установка виртуального окружения не должна пересоздавать эту папку.

Команды должны быть декомпозированны по файлам.

Папка wrappers предназначена для временных файлов и создаваемых в процессе работы команд скриптов.

## GeoIP (DB-IP City Lite)

Локальная геолокация IP для сессий пользователя и журнала аудита. Lookup только по файлу на диске — IP не уходит во внешние API.

| Что | Где |
|-----|-----|
| База MMDB | `virtual_env/resources/geoip/dbip-city-lite.mmdb` (не в git) |
| Настройки | `.env`: `GEOIP_ENABLED`, `GEOIP_DOWNLOAD_URL` (см. `.env.example`) |
| Код | `core/api/src/core/utils/geoip.py`, `core/api/src/config/settings/geoip.py` |

Команды (через `ergoms help`):

- `ergoms geoip-download` — скачать/обновить MMDB с db-ip.com (URL из `.env` или авто по месяцу)
- `ergoms geoip-backfill` — заполнить city/country у существующих `UserDevice` (`--dry-run` для проверки)

Первичная настройка: `ergoms python-install` → `ergoms geoip-download` → при необходимости `ergoms geoip-backfill`.

Обновление базы: раз в месяц `ergoms geoip-download`, затем перезапуск API (reader кэшируется в процессе).