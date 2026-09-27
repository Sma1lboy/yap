# 截图和配图清单

规矩：

- 截图只来自 `make ui-snapshots`（Debug 构建的一份拷贝，改成 `me.sma1lboy.yap.snapshots` 身份，沙箱断网，假数据，跑完删干净）或 `make mock`（`me.sma1lboy.yap.mock` 身份，假数据，退出时删掉）。不截 Jackson 正在用的 app 和桌面，不用 osascript、合成点击。
- 每张都要浅色、深色两份；中文渠道用 `-zh` 版。
- 成图（带标题的卡片）用 HTML + 真实截图拼，不让出图模型重画截图：`.studio/out/yap-1.2.0/release-card-draft-1.png` 是 gpt-image low 档的试稿，排版可用，但截图里的转写行被画成了乱码。gpt-image 只用来出排版草图。
- `make ui-snapshots` 会先 `rm -rf /tmp/yap-ui/snapshots`。别的会话可能正在用那个目录，跑之前确认没人在用。

## 现成的（`make ui-snapshots` 已经能出）

| 用途 | 文件（`/tmp/yap-ui/snapshots/`） | 用在哪 |
|---|---|---|
| 首屏 / 主视觉 | `page-home-{light,dark}`、`page-home-zh-{light,dark}` | 官网首屏（已在 `site/assets/`）、GitHub Release、X 第 3 条、小红书封面 |
| 三种用法 | `onboarding-3-model-{local,openrouter,yapcloud}-{light,dark}` | 官网「三种用法」、V2EX |
| 本地模型下载中 | `onboarding-3-model-local-downloading-*` | X / 即刻：547 MB、进度和剩余时间 |
| 词典 | `page-dictionary-{light,dark}`、`-zh-` | 卖点 3 |
| 录音浮窗 | `recorder-mini-*`、`recorder-notch-*` | 演示视频开头、社媒小图 |
| Modes | `page-modes-*`、`sheet-mode-editor-context-*` | 细节区 |
| 配置同步 | `settings-config-sync-*`、`sheet-version-history-*` | 细节区 |

注意：假数据里有一条 "The API returns a 402 when the balance is zero; we should show Add Funds"。宣发图要讲开源和中英混说，这条会让人以为在讲余额，裁掉或换一条。

## 缺的，需要先在 `UISnapshots.swift` 里加场景

| 图 | 为什么要 | 怎么做 |
|---|---|---|
| Auto Learn 审核面板，手动模式，2–3 条待批准的提议 | 卖点 3 目前没有图 | 在 `UISnapshots` 里用假的 `AutoLearnReviewProposal` 渲染审核面板 |
| 历史详情：一条中英混说的原文和整理后文字并排 | 卖点 1 最直观的图 | 假数据选一条 `setup/asr/clips.json` 里的句子 |

## 不是 app 截图的素材

| 素材 | 来源 | 尺寸 |
|---|---|---|
| `make offline-check` 输出 | 终端文字，照抄 `docs/local-models.md` 里 2026-09-26 的输出，用 HTML 等宽排版，不截 Jackson 的终端 | 1600×900 |
| 测试结果表 | `docs/dictation-accuracy.md` 的表，HTML 重排，只放 5 行（mai-transcribe-2、本地 Turbo+词典、gpt-4o-mini、本地 Turbo、本地 Base） | 1600×900 |
| 发布卡 | 左侧标题「Yap 1.2.0」+ 一行「中英混说 · 本地离线 · 开源」，右侧 `page-home-zh-light` | 1200×672 |
| 小红书封面 | 竖版，上半大字「中英混着说，Mac 听写不翻车」，下半 `page-home-zh-light` 裁左上 2/3 | 1088×1440 |
| OG 图 | 已有 `site/assets/og.png`，不动 | 1200×630 |
