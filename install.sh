#!/bin/bash
# Установка Limity Dock: bash install.sh
# Проба без изменений: DRY=1 bash install.sh — только покажет, что будет сделано.
set -e
cd "$(dirname "$0")"
run() { if [ -n "$DRY" ]; then echo "  [проба] $*"; else "$@"; fi; }

ver=$(sw_vers -productVersion)
major=${ver%%.*}
if [ "$major" -lt 26 ]; then
  echo "Нужна macOS 26 или новее (из-за Liquid Glass), у тебя $ver."
  exit 1
fi

# codeburn — откуда программа берёт лимиты и расход
cb=$(command -v codeburn || true)
for p in /opt/homebrew/bin/codeburn /usr/local/bin/codeburn; do
  if [ -z "$cb" ] && [ -x "$p" ]; then cb=$p; fi
done
if [ -z "$cb" ]; then
  if command -v brew >/dev/null 2>&1; then
    echo "Ставлю codeburn через Homebrew…"
    run brew install codeburn
  elif command -v npm >/dev/null 2>&1; then
    echo "Ставлю codeburn через npm…"
    run npm install -g codeburn
  else
    echo "Нужен codeburn. Поставь Homebrew (https://brew.sh) и запусти установку ещё раз."
    exit 1
  fi
fi

dest="$HOME/Applications/LimityDock.app"
label="app.limitydock"
agent="$HOME/Library/LaunchAgents/$label.plist"

run mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
if [ -z "$DRY" ]; then
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  pkill -x LimityDock 2>/dev/null || true
else
  echo "  [проба] остановить прежнюю версию, если запущена"
fi
# прежняя версия — в Корзину целиком: если копировать поверх, старые файлы ломают подпись программы
if [ -e "$dest" ]; then run mv "$dest" "$HOME/.Trash/LimityDock-old-$(date +%s).app"; fi
run ditto LimityDock.app "$dest"
# снять пометку «скачано из интернета», иначе macOS не даст запустить программу без подписи Apple
run xattr -dr com.apple.quarantine "$dest"

plist="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$dest/Contents/MacOS/LimityDock</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>"
if [ -n "$DRY" ]; then
  echo "  [проба] записать автозапуск $agent"
else
  printf '%s\n' "$plist" > "$agent"
fi
run launchctl bootstrap "gui/$(id -u)" "$agent"

echo "Готово. Ручка — у правого края экрана: подведи к ней курсор."
