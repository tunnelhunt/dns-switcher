# AI DNS Switcher (macOS)

Нативное приложение в строке меню macOS для избирательного переключения DNS (Split-DNS через локальный DoH-прокси + системный DNS) для AI-сервисов и выбранных доменов.

## Возможности

- **Menu Bar приложение** (macOS 13+) без иконки в Dock (`LSUIElement`)
- **Локальный DNS-over-HTTPS (DoH) прокси** с маршрутизацией только выбранных доменов через DoH и пробросом остальных запросов на апстрим-DNS
- **Мост на порт 53 (`127.0.0.1:53`)** и автоматическое переключение системных DNS-настроек macOS с сохранением и восстановлением исходных параметров
- **Удобный интерфейс настроек** для управления группами доменов, кастомными правилами и провайдерами DNS

## Сборка вручную

Требуется macOS 13+ и Swift 5.10+ (Xcode или Command Line Tools).

```bash
# Сборка под текущую архитектуру
./build-app.sh

# Сборка Universal Binary (Apple Silicon arm64 + Intel x86_64)
./build-app.sh --universal
```

Готовый бандл приложения появится в `./DNSSwitcher.app`.

## Сборка через GitHub Actions

В репозитории настроен workflow [`.github/workflows/build.yml`](.github/workflows/build.yml):
- При каждом `push` или `pull_request` в `main`/`master` (а также вручную через `workflow_dispatch`) собирается **Universal Binary** (`arm64` + `x86_64`) и публикуются артефакты `DNSSwitcher-macOS.zip` и `DNSSwitcher.dmg`.
- При отправке тега вида `v*` (например, `v1.0.0`) автоматически создаётся GitHub Release с прикреплёнными `.zip` и `.dmg` файлами.
