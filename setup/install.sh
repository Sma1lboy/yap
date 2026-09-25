#!/bin/bash
# 新机器一键安装 Yap：下载 Release → 放好 ~/.config/yap/config.json 和 prompt.md → 打开 Yap
# Yap 每次启动读 config.json；key 写成 "env:OPENROUTER_API_KEY"，从环境变量或 ~/.env 取
# 用法: ./setup/install.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
URL=https://github.com/Sma1lboy/yap/releases/latest/download/Yap.zip
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/yap"

osascript -e 'quit app "Yap"' 2>/dev/null || true
while pgrep -x Yap >/dev/null; do sleep 0.5; done
if command -v brew >/dev/null; then
  echo "==> 用 Homebrew 安装/更新 Yap"
  brew tap sma1lboy/yap https://github.com/Sma1lboy/yap >/dev/null 2>&1 || true
  brew upgrade --cask sma1lboy/yap/yap 2>/dev/null || brew install --cask sma1lboy/yap/yap
else
  echo "==> 下载 Yap"
  TMP=$(mktemp -d)
  curl -fL --progress-bar "$URL" -o "$TMP/Yap.zip"   # curl 下载不带隔离标记，ad-hoc 签名也能直接打开
  [ -d /Applications/Yap.app ] && mv /Applications/Yap.app "$TMP/Yap.old.app"   # 旧版挪到临时目录，不直接删
  ditto -x -k "$TMP/Yap.zip" /Applications
fi

echo "==> 配置 $CONFIG_DIR（已有文件不覆盖）"
mkdir -p "$CONFIG_DIR"
[ -e "$CONFIG_DIR/config.json" ] || cp "$HERE/config.example.json" "$CONFIG_DIR/config.json"
[ -e "$CONFIG_DIR/prompt.md" ] || cp "$HERE/prompt.md" "$CONFIG_DIR/prompt.md"

open -a /Applications/Yap.app
echo "==> 完成。改模型或 prompt：编辑 $CONFIG_DIR 下的文件，再到 设置 → Config File 点 Reload（或重启 Yap）"
