#!/bin/bash
# Сборка Limity Dock: bash build.sh
# Собирает приложение (Apple Silicon + Intel), пакет для отправки dist/LimityDock.zip
# и ставит у себя тем же установщиком, что получат другие.
set -e
cd "$(dirname "$0")"
PKG=dist/LimityDock
APP=$PKG/LimityDock.app
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos26 main.swift -o build/arm64
swiftc -O -swift-version 5 -target x86_64-apple-macos26 main.swift -o build/x86_64
lipo -create build/arm64 build/x86_64 -output "$APP/Contents/MacOS/LimityDock"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/provider-claude.svg Resources/provider-codex.svg "$APP/Contents/Resources/"
codesign --force -s - "$APP"
cp install.sh uninstall.sh README.txt "$PKG/"
(cd dist && ditto -c -k --keepParent LimityDock LimityDock.zip)
bash "$PKG/install.sh"
