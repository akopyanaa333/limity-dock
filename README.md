# Limity Dock

Лимиты Claude и Codex — у края экрана Mac. Стеклянная ручка у правого края: подведи курсор — откроется панель Liquid Glass.

Что показывает:
- **Кольца Claude и Codex** — сколько израсходовано лимита (у Claude окно 5 часов, у Codex неделя) и когда сброс. Клик по кольцу — подробности по всем окнам.
- **Бюджет недели на день** — «сегодня X% из ~Y%»: сколько можно тратить в день, чтобы недельного лимита хватило до сброса.
- **Расход** — за сегодня, 7 и 30 дней, график по дням (цена по прайсу API — относительная мера, а не счёт по подписке).
- **Уведомления macOS** — при 80% и 90% лимита и при сбросе.
- Темы: день / ночь / как в системе.

Если какой-то подписки нет — её кольцо просто не появится.

## Требования

- macOS 26 (Tahoe) или новее — нужен Liquid Glass.
- Вход в Claude Code и/или Codex на этом Маке.
- [codeburn](https://github.com/getagentseal/codeburn) — откуда берутся цифры. Установщик поставит его сам через Homebrew или npm.

## Установка

Скачай `LimityDock.zip` из [Releases](../../releases/latest), распакуй в «Загрузки» и выполни:

```bash
bash ~/Downloads/LimityDock/install.sh
```

Проба без изменений: `DRY=1 bash ~/Downloads/LimityDock/install.sh`.

Программа ставится в `~/Applications`, автозапуск — `~/Library/LaunchAgents/app.limitydock.plist`. При первом запуске macOS спросит доступ к связке ключей для `security` (так codeburn читает лимиты Claude) — «Всегда разрешать». Уведомления — по желанию.

Удалить: `bash ~/Downloads/LimityDock/uninstall.sh` — программа и автозапуск уходят в Корзину.

Сборка не подписана Apple: установщик снимает пометку карантина (`xattr -dr com.apple.quarantine`). Не доверяешь — собери сам.

## Сборка из исходников

Нужны Xcode Command Line Tools (`swiftc`).

```bash
bash build.sh
```

Собирает универсальное приложение (Apple Silicon + Intel), архив `dist/LimityDock.zip` и сразу ставит его тем же установщиком.

## Откуда данные

Только с твоего Мака и у самих Anthropic и OpenAI — через `codeburn quota` (лимиты, раз в 5 мин) и `codeburn report` (расход, раз в 10 мин). Сама программа в сеть ничего не отправляет.

Блок «Сессии сейчас» (контекст открытых сессий Claude Code) читает файлы `~/.claude/limity/*.json`. Их пишет отдельный мод Claude Code, который в этот репозиторий не входит, — без него блок показывает «нет открытых».

---

**English.** A macOS 26+ edge panel (Liquid Glass) showing Claude and Codex usage limits, reset times, daily budget for the weekly limit, and spend history. Data comes from [codeburn](https://github.com/getagentseal/codeburn). Install: download `LimityDock.zip` from Releases, unzip to Downloads, run `bash ~/Downloads/LimityDock/install.sh`. Build from source: `bash build.sh`. UI is in Russian.

## Лицензия

MIT
