<!-- V2EX，节点：分享创造。标题 + 正文（Markdown）。V2EX 读者会问"和 VoiceInk / Typeless 比呢""为什么没公证"，正文里先答掉。 -->
<!-- 第一人称是按 Jackson 的口吻起草的，发之前改成你自己的话。 -->
**标题：** Yap 1.2.0：开源的 Mac 听写 app，中英混说，本地模型可以完全离线（GPL，fork 自 VoiceInk）

**正文：**

Yap 是我 fork VoiceInk 改的听写 app：按住右 Option 说话，一句话里中英混着说，松开后转写、整理标点，粘贴进当前的 app。代码 GPL-3.0，在 GitHub 上：https://github.com/Sma1lboy/yap

做它是因为写代码时说的话大多是这样的：「OAuth Refresh Token 现在存在 Local Storage 里，有 XSS 风险」。常见的听写工具要么让你只选一种语言，要么把英文词写成汉字，要么把半句翻译掉。

### 1.2.0 改了什么

- **按语言分段转写。** Whisper 对录音里每一段用它自己的语言解码。以前一段以英文开头的录音，后面的中文可能被翻成英文输出。超过 30 秒的录音按停顿切成小段，长听写不再丢句子。
- **本地模型换成支持中文的。** 引导流程的「本地」选项改为下载 Whisper Large v3 Turbo（量化版，547 MB，峰值内存 0.9 GB），不再是只支持英文的 Parakeet。8 GB 内存的 Mac 也跑得动。
- **三种用法并列：** 本地模型；自己的 OpenRouter 或其他服务商的 key（请求直接发给服务商，key 只存在钥匙串里）；不想申请 key 可以用 Yap Cloud（可选的托管服务）。
- **设置在 `~/.config/yap/config.json` 里**，有 JSON Schema，可以放进 dotfiles；快捷键写成 `"cmd+shift+space"` 这种可读的形式。
- 错误提示：转写失败会保留录音并提供重试；粘贴不了（没给辅助功能权限）时文字留在剪贴板里。

完整更新说明：https://github.com/Sma1lboy/yap/blob/main/docs/releases/1.2.0.md

### 数字和怎么复现

`setup/asr/` 里有 11 段中英混说的测试音频，82 个关键英文术语和人名（Redis、Tailwind、IndexedDB、Priya 这类）：

| 配置 | 命中 /82 |
|---|---|
| 云端 mai-transcribe-2（推荐配置） | 59 |
| 本地 Large v3 Turbo（量化版）+ 词典 | 54 |
| 本地 Large v3 Turbo（量化版），不加词典 | 45 |

先说清楚：音频是 macOS `say` 合成的，还没有真人录音。其中 Reed 这个声音英文发音很差，所有引擎在它上面都丢一半。`python3 setup/asr/bench.py score` 打印这张表，你可以换自己的模型或录音重跑。详细数据：`docs/dictation-accuracy.md`、`docs/local-models.md`。

本地模型加词典比换更大的模型有用：默认的 Turbo 量化版加词典从 45 到 54，比升到 Large v3（47，3.1 GB）多。

### 离线怎么验证

`make offline-check MODEL=<模型路径>` 跑两遍：第一遍在拒绝所有 IP 流量的沙箱里听写，必须出字；第二遍联网，每 0.2 秒记录一次 app 的 socket，听写期间出现连接就算失败。不登录 Yap Cloud 的话，app 唯一的联网是检查更新。离线配置下 AI 润色是关的，因为本地润色模型会把英文术语翻成中文（数据在 `docs/local-models.md`）。

### 可能会问的

- **和 VoiceInk 什么关系？** Yap 是 VoiceInk 的 fork，致谢在 README。想要官方、经过 Apple 公证的版本请买 VoiceInk。Yap 加的是中英混说的调校、配置文件和同步、可选的 Yap Cloud。
- **为什么没公证？** 公证要付费的 Apple 开发者账号。每个版本用同一张自签名证书签名，更新后权限不丢。用 Homebrew 安装不会弹「无法验证开发者」；直接下载的 zip 第一次要在「隐私与安全性」里点一次「仍要打开」。
- **收费吗？** app 免费。本地模型不花钱；云端模型由你选的服务商收费。

安装：
```
brew tap sma1lboy/yap https://github.com/Sma1lboy/yap
brew install --cask sma1lboy/yap/yap
```

需要 macOS 15 或更高版本。欢迎提 issue，尤其是中英混说转错的例子。
