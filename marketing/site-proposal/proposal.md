# 官网改版提案（yap.sma1lboy.me）

草稿：`marketing/site-proposal/index.html`（本地打开：在仓库根目录 `python3 -m http.server`，访问 `/marketing/site-proposal/`）。它引用 `site/` 的 tokens.css、site.css 和图片，没有改 `site/` 里任何文件；`site/` 一合进 main 就会被 GitHub Pages 部署。

## 参照了什么

| 做法 | Quill Meetings | Typeless | 用在 Yap 上 |
|---|---|---|---|
| 一句话定位 | "Your local-first AI meeting assistant" + "Built for conversations you can't send to the cloud" | "Speak, don't type" | 保留 h1「按住快捷键，说话，松开」，副句换成定位：中英混说、可以完全离线、开源 |
| 功能分区 | Before / During / After 三段 | Dictate / Translate / Ask anything | 不照搬功能罗列，改成「三件事 + 各自怎么核对」：Yap 能拿出来的是可复现的数字和命令 |
| 隐私表述 | "Your audio never leaves it"；cloud notetaker vs Quill 两栏 | "Private by design"，五条短句 | 保留现有「每种用法音频去哪」四行，加 `make offline-check` 的真实输出和「还会联网的」一行 |
| 对比表 | 云端 vs 本地两栏 | 没有 | 四家对比，只放有公开文档出处的格子，出处链接放表下 |
| 预告 | — | — | 会议记录「在做」，不写日期 |
| 收尾 CTA | "Start with your next meeting" + 下载 | "Free yourself from the keyboard" | 安装挪到 FAQ 前面（首屏已有下载按钮） |

没学的：客户证言（Yap 没有，不编）；按行业分的用例卡片（读者就是一类人）；首屏 SOC 2 之类的徽章。

## 信息架构（新 vs 现在）

| # | 区块 | 现在 | 提案 |
|---|---|---|---|
| 1 | 首屏 | 同 | 副句换成定位句 |
| 2 | 为什么是 Yap（新） | — | 三张卡：59/82、0 个连接、4 种处理；每张底部是证据（脚本或命令） |
| 3 | 演示 | 第 3 | 不变 |
| 4 | 三种用法 | 第 4 | 本地卡片改两条：模型写 547 MB / 0.9 GB；**删掉「整理也可以在本地做（Yap Refine）」**，这和 `docs/local-models.md` 的结论（离线配置关润色）矛盾 |
| 5 | 隐私与离线 | 隐私 | 加 offline-check 输出和「还会联网的」 |
| 6 | 对比（新） | — | Yap / Wispr Flow / Typeless / Apple 听写，5 行 |
| 7 | 在做（新） | — | 会议记录预告 |
| 8 | 安装 | 第 2 | 挪到这里 |
| 9 | FAQ、页脚 | 同 | 不变 |

## 对比表每一格的出处

| 格子 | 出处 |
|---|---|
| Wispr 中英混说 | [Wispr 文档](https://docs.wisprflow.ai/articles/3191899797-use-flow-with-multiple-languages)原文 "With Chinese and English selected, English words can appear in Chinese characters or vice versa" |
| Wispr 离线 | [Wispr 文档](https://docs.wisprflow.ai/articles/5094956927-fix-no-internet-connection-issues)：转写需要联网 |
| Wispr 纠错学习 | [What's new](https://wisprflow.ai/whats-new)（调研转述，发布前再核一次原文） |
| Typeless 云端 / 零留存 / 个人词典 | [typeless.com](https://www.typeless.com/) "Zero cloud data retention"、"Personal dictionary" |
| Apple 手动切换语言、本机 | [Apple 支持文档](https://support.apple.com/guide/mac-help/use-dictation-mh40584/26/mac/26) |
| Yap 各格 | `docs/dictation-accuracy.md`、`docs/local-models.md`、`VoiceInk/Features/Dictionary/AutoLearn/` |

Typeless 本机观察到的「词典自动添加」没放进表：那是装在 Jackson 机器上看到的，官网没写。

## 要 Jackson 定的

1. 对比表点名竞品可以吗？不点名的话换成「云端听写 / Apple 听写 / Yap」三列。
2. 会议记录预告放不放？现在只有设计稿（调研里的 process tap 方案），放了会有人问什么时候上。
3. 隐私标题「Yap 不收集使用数据」保留（代码里确实没有统计上报）。`docs/local-models.md` 第 83 行写着 "besides the update check and telemetry"，和代码不符，建议把 "and telemetry" 删掉；那是 docs 的事，这个分支没改。
4. 接受后的落地：把新增 CSS 挪进 `site/site.css`，内容合进 `site/index.html`，走 PR。
