#!/bin/bash
# Удаление Limity Dock: bash uninstall.sh — программа и автозапуск уходят в Корзину.
label="app.limitydock"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
pkill -x LimityDock 2>/dev/null || true
for f in "$HOME/Applications/LimityDock.app" "$HOME/Library/LaunchAgents/$label.plist"; do
  [ -e "$f" ] && mv "$f" "$HOME/.Trash/"
done
echo "Limity Dock удалён (лежит в Корзине)."
