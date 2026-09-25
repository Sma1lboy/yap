#!/bin/bash
# 新机器一键安装 Yap：下载 Release → 写入 OpenRouter key → 你完成授权 → 写入模型和 prompt
# 用法: OPENROUTER_API_KEY=sk-or-... ./setup/install.sh   （或把 key 写进 ~/.env）
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOMAIN=me.sma1lboy.yap
URL=https://github.com/Sma1lboy/yap/releases/latest/download/Yap.zip

KEY="${OPENROUTER_API_KEY:-$(grep -s '^OPENROUTER_API_KEY=' ~/.env | cut -d= -f2- | tr -d "\"'" || true)}"
[ -n "$KEY" ] || { echo "缺少 OPENROUTER_API_KEY（环境变量或 ~/.env）"; exit 1; }

echo "==> 下载 Yap"
TMP=$(mktemp -d)
curl -fL --progress-bar "$URL" -o "$TMP/Yap.zip"   # curl 下载不带隔离标记，ad-hoc 签名也能直接打开
osascript -e 'quit app "Yap"' 2>/dev/null || true
while pgrep -x Yap >/dev/null; do sleep 0.5; done
[ -d /Applications/Yap.app ] && mv /Applications/Yap.app "$TMP/Yap.old.app"   # 旧版挪到临时目录，不直接删
ditto -x -k "$TMP/Yap.zip" /Applications

echo "==> 写入 OpenRouter key"
# 本地构建版找不到钥匙串条目时，会从这个字段读取并迁移进钥匙串
defaults write "$DOMAIN" LocalKeychain_openRouterAPIKey -data "$(printf %s "$KEY" | xxd -p | tr -d '\n')"

if ! defaults read "$DOMAIN" modeConfigurationsV2 >/dev/null 2>&1; then
  open -a /Applications/Yap.app
  echo
  echo "==> 在 Yap 窗口里完成首次引导："
  echo "    1. 授权麦克风、辅助功能（屏幕录制可跳过）"
  echo "    2. 转写和 AI 服务商都选 OpenRouter（key 已填好）"
  echo "    3. 设置快捷键，走到主界面"
  read -r -p "完成后按回车继续… "
  osascript -e 'quit app "Yap"'
  while pgrep -x Yap >/dev/null; do sleep 0.5; done
fi

echo "==> 写入模型和 prompt"
python3 "$HERE/apply.py"
open -a /Applications/Yap.app
echo "==> 完成。以后改了 prompt 或模型：git pull && ./setup/install.sh"
