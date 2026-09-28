# Yap 定位和信息层级

所有宣发文案（release、社媒、官网）从这一页取句子和数字。这里没写的功能不写进外发文案；这里的数字都能在 `docs/` 或代码里找到出处，出处写在每条后面。

依据：wisp `yap/topics/positioning.md`（2026-09-26 Jackson 定）。Yap 首先是开源听写 app；Yap Cloud 是三种用法之一，价格和余额只在 Yap Cloud 那一节出现。

## 一句话

- 中文：**开源的 Mac 听写 app。一句话里中英混着说，松开快捷键就粘贴；可以只用本机模型，完全不联网。**
- English: **Open-source dictation for Mac. Talk in Chinese and English in the same sentence, let go of the key, and the text is pasted. Run it on a local model and nothing goes over the network.**

副标（放在一句话下面，交代来历）：GPL-3.0，fork 自 VoiceInk（Beingpax）。需要 macOS 15 或更高版本。

## 三个卖点，每条一个证据

顺序固定：中英混说是 Yap 和上游、和别的听写工具最大的不同，排第一；离线是隐私取向读者的门槛，排第二；纠错学习是用久了才体会到的，排第三。

### 1. 中英混说，测试集和分数都在仓库里

- **说法：** 一句中文里夹着 OAuth、Redis、Priya 这类英文词和人名，Yap 按语言分段转写，不会把英文翻成中文，也不会把中文翻成英文。测试集公开，谁都能在自己的 Mac 上重跑。
- **数字：** 11 段中英混说音频、82 个关键英文术语和人名。
  - 云端 `microsoft/mai-transcribe-2`（推荐配置，OpenRouter 或 Yap Cloud 同一个模型）：**59/82**。
  - 本地 Whisper Large v3 Turbo（量化版，547 MB，峰值内存 0.9 GB）：45/82；把术语加进词典后 **54/82**。
- **证据：** `docs/dictation-accuracy.md`、`docs/local-models.md`；音频在 `setup/asr/clips/`，`python3 setup/asr/bench.py score` 打印这些分数。
- **必须带上的限定：** 音频是 macOS `say` 合成的（Tingting、Reed 两个声音），还没有真人录音。外发文案里写"合成语音测试集"，不写"准确率 72%"这种脱离测试集的百分比。

### 2. 离线可以自己验证

- **说法：** 选本地模型、关掉润色，一次听写不发起任何网络连接。这不是一句声明：`make offline-check` 在拒绝所有 IP 流量的沙箱里跑一次听写，必须出字；再在联网状态下每 0.2 秒记录一次 app 的 socket，听写期间开了连接就判失败。
- **证据：** `docs/local-models.md` 的 "Is it really offline?" 一节（2026-09-26 的实测输出），`scripts/offline-check.sh`、`scripts/offline.sb`。
- **必须带上的限定：** 离线推荐配置把 AI 润色关掉了（本地润色模型 Yap Refine 会把英文术语翻成中文，见 `docs/local-models.md`）。不登录 Yap Cloud 的用户，唯一的联网是检查更新。模型第一次下载要联网（Hugging Face）。

### 3. 纠错学习在本地，每条规则你审过才生效

- **说法：** 你改了 Yap 粘贴出去的字，Yap 会记下改动，变成词典里的一条替换规则或词汇。它只用辅助功能读那个输入框，不装键盘监听。学到的修正先排队，由你选的模型审核（选 Ollama 就不出这台 Mac）；审核设成"手动"时，每条提议要你批准、修改或丢弃后才进词典。所有规则都在词典页里，能看、能删、能导出。
- **证据：** `VoiceInk/Features/Dictionary/AutoLearn/`：`AutoLearnAXTextReader.swift`（读输入框）、`CorrectionDiffEngine.swift`（diff）、`AutoLearnAIReviewer.swift`（审核，四种动作：加替换并加词汇 / 只加替换 / 只加词汇 / 拒绝）、`AutoLearnTypes.swift` 里的 `AutoLearnReviewSchedule.manually`、`AutoLearnService.applyReviewProposals`。导出在 `DictionaryImportExportService.swift`。
- **必须带上的限定：** 这个功能来自上游 VoiceInk，不是 Yap 新做的；外发时不说"Yap 首创"。没有数字，所以不写"准确率提升 X%"。

## 信息层级

读者从上往下读，每一层回答一个问题：

| 层级 | 回答什么 | 内容 |
|---|---|---|
| 1 | 这是什么 | 一句话 + 副标 |
| 2 | 为什么选它 | 三个卖点，各一句 + 一个数字或命令 |
| 3 | 怎么用 | 按住右 Option 说话，松开粘贴；三种用法（本地模型 / 自带 key / Yap Cloud）并列 |
| 4 | 能不能信 | 隐私：每种用法音频去哪；`make offline-check`；GPL 源码 |
| 5 | 和别的工具比 | 对比表（只放有公开出处的行） |
| 6 | 细节 | 配置文件 `~/.config/yap/config.json`、Modes、词典、历史 |
| 7 | 价格 | 只在 Yap Cloud 一节：app 免费；Yap Cloud 按量付费 |

## 可以用 / 不能用的说法

| 可以用 | 不能用 | 原因 |
|---|---|---|
| 59/82 个关键词（合成语音测试集） | "业界最准""准确率 72%" | 没有和竞品在同一测试集上比过；百分比会被读成通用准确率 |
| 本地 + 词典 54/82 | "本地和云端一样准" | 54 < 59 |
| `make offline-check` 断网也能出字 | "绝对隐私""零数据" | 云端用法会把音频发给你选的服务商 |
| 不收集使用数据（代码里没有统计上报） | "从不联网" | 检查更新会联网；登录 Yap Cloud 后账户刷新和同步会联网 |
| 纠错学习：只读输入框，不监听键盘 | "AI 自动学会你的说话方式" | 它学的是替换规则和词汇，不是说话方式 |
| 会议记录：在做 | 发布日期、"即将上线" | 只有设计稿，没有代码 |

## 1.2.0 之后已合进 main、但不在 1.2.0 发布说明里的功能

`docs/releases/1.2.0.md` 是 1.2.0 宣发的唯一功能清单。下面三项已经在 `main`（本分支 HEAD cdb2ea5）上，但发布说明没写：

- 光标上下文：润色时带上当前 app、窗口标题和光标前后的文字；读不到才退回屏幕 OCR；密码框不读（80983d0）。
- 语音改上一次粘贴：说一句撤销，或让它按你说的改写，替换前用辅助功能核对原文还在（cdb2ea5）。
- 离线中文清理：不经模型去掉"嗯""呃"、处理口述的"换行"、繁转简，可选中英之间加空格（01ea260）。

如果 1.2.0 从当前 main 打包，这三项先写进 `docs/releases/1.2.0.md`，再加进宣发；第三项会补上"离线时语气词去不掉"这个短板，值得放进卖点 2。在那之前，本目录的外发文案都不提它们。
