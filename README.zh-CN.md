[English](README.md) | **简体中文**

<p align="center"><img src="design/logo-1024.png" width="160" alt="Yap 鸭子图标"></p>

<h1 align="center">Yap</h1>

<p align="center">按住快捷键说话，中英混着说也行，松开就是整理好的文字。</p>

Yap 是 Prakash Joshi Pax 的 [VoiceInk](https://github.com/Beingpax/VoiceInk) 的一个分支，沿用同样的 GPL-3.0 许可证。应用本身的功劳都属于原作者；如果你想要官方签名公证、自动更新的版本，请[购买 VoiceInk](https://tryvoiceink.com/)。

这个分支改了什么：

- 独立的身份：应用名、bundle ID `me.sma1lboy.yap`、Application Support 目录和钥匙串命名空间都是自己的，可以和 VoiceInk 并存、互不共享数据。去掉了上游的公告、GitHub 求星提示、Pro/授权页面和上游更新日志。
- 更安静的界面：单色侧边栏、显示默认模式和最近转写的主页、用 SF Symbols 代替 emoji。
- 引导流程可以跳过转写和 AI 服务商的设置（「稍后设置」），改用 JSON 配置文件配置。
- 自己的更新通道：CI 用固定的自签名证书给每个版本签名并发布，同时更新 Sparkle appcast（应用内更新）和 Homebrew cask。
- 鸭子图标（`design/logo.svg`）。
- `setup/`：一套针对中英混说、通过 OpenRouter 调好的配置，以及挑选模型用的评测脚本。

## 安装

```bash
git clone https://github.com/Sma1lboy/yap && cd yap
./setup/install.sh
```

脚本会用 Homebrew 安装应用（或下载最新发布版），在文件不存在时把 `setup/config.example.json` 复制到 `~/.config/yap/config.json`、把推荐提示词（`VoiceInk/Resources/RecommendedPrompt.md`，应用里也自带一份）复制到 `~/.config/yap/prompt.md`，然后打开 Yap。授予麦克风和辅助功能权限、选一个快捷键；如果配置文件里已经有你的 key，就跳过服务商那几步。

只装应用：`brew tap sma1lboy/yap https://github.com/Sma1lboy/yap && brew install --cask sma1lboy/yap/yap`。之后 Yap 会自己更新（应用菜单里的「检查更新…」），也可以用 `brew upgrade --cask yap`。

## Yap Cloud

Yap Cloud 是一个可选的账户：转写和润色的费用从预充值的余额里扣，不需要去 OpenRouter 或其他服务商申请 API key。用的模型和「自带 OpenRouter Key」配置相同。

**注册 / 登录。** 打开侧边栏的 **账户**，输入邮箱，再输入发到邮箱里的 6 位验证码。没有密码。新账户会得到 $1 的额度，在 **最近记录** 里显示为「注册赠送」。也可以在引导流程的模型那一步直接选 **使用 Yap Cloud(按量付费)**。

**怎么收费。** 每次转写或润色请求，按模型服务商的价格加 10% 收费。**账户 → 模型与价格** 列出了可用的模型；**本月花费** 显示这个月花了多少、花在哪些模型上；**最近记录** 列出每一笔扣费和充值。

**充值。** 在 **账户 → 充值** 里选 $5、$10、$20，或者「自定」（$5 到 $500 之间的整数美元），点 **充值…**。付款页面会在浏览器里打开，回到 Yap 后余额会更新。余额低于 $1 时 Yap 会提示余额不足；余额用完后，Yap Cloud 的请求会停止，并弹出通知带你去账户页。

**每月上限。** **账户 → 每月上限** 可以限制每个自然月的花费：选 $5、$10、$20、最多 $10,000 的自定金额，或者「无」。本月花费达到上限后，Yap Cloud 会停止扣费，直到下个月或你调高上限。上限设为 $0 会拦下所有 Yap Cloud 请求。

**设备。** 每台登录过的 Mac 都有自己的登录凭证（存在那台 Mac 的钥匙串里，不会同步）。**账户 → 已登录的设备** 列出这些设备和各自最后使用的时间；点 **移除** 会让那台 Mac 退出登录，不再从你的余额扣费，之后它可以用邮箱重新登录。账户页的 **退出登录** 让这台 Mac 退出；用到 Yap Cloud 的模式会停止工作，直到你重新登录或把它们换成别的服务商。

## 配置与同步

Yap 的全部设置可以写在一个文件里：`~/.config/yap/config.json`（或 `$XDG_CONFIG_HOME/yap/config.json`），并且可以通过 Yap Cloud 在你的几台 Mac 之间同步。下面提到的按钮都在 **设置 → 配置与同步**。

### 配置文件

Yap 每次启动都会读这个文件。文件里写了的字段会覆盖应用里的设置；没写或为空的字段保持不变。**打开** 会在文件不存在时用模板创建它，**在 Finder 中显示** 定位到文件，**重新加载** 不用重启就再应用一次。状态行会列出哪些字段生效了、哪些被跳过（比如 `env:` 引用的环境变量没设置）。

最简单的文件（schema v1）：

```json
{
  "keys": { "openrouter": "env:OPENROUTER_API_KEY" },
  "transcription": { "provider": "openrouter", "model": "microsoft/mai-transcribe-2" },
  "enhancement": { "enabled": true, "provider": "openrouter", "model": "deepseek/deepseek-v4.1-flash", "prompt": "prompt.md" },
  "defaultMode": { "screenContext": false, "clipboardContext": false, "selectedTextContext": false }
}
```

| 字段 | 含义 |
|---|---|
| `keys.<provider>` | API key，存进钥匙串。`env:NAME` 先读环境变量，再读 `~/.env`（从 Dock 打开的应用拿不到 shell 的环境变量）。 |
| `transcription` | 语音转文字的服务商和模型，应用到每个模式。 |
| `enhancement` | 开了润色的模式所用的服务商和模型。`prompt` 可以是配置文件旁边的文件名（或绝对路径），也可以直接是提示词文本；`"recommended"` 表示用应用自带的推荐提示词。它会成为默认模式的提示词。 |
| `defaultMode` | 默认模式会把哪些额外上下文发给模型。全部关掉，听写又快又私密。 |

Schema v2（`"version": 2`）可以描述全部设置。它和 **设置 → 备份 → 导出** 用同样的 JSON 结构，所以可以把导出文件里的段落直接贴进来。没有 `version` 的文件按 v1 读取，行为和以前一样。

| 字段（v2） | 含义 |
|---|---|
| `version` | `2`。不写就是 v1。更大的数字（来自更新版本 Yap 的文件）照样能读，**设置 → 配置与同步** 会提示不认识的字段已忽略。 |
| `modes` | 模式数组，和导出文件里 `modeConfigs` 的对象相同。按 `id` 合并：文件里的模式替换应用里同 id 的模式，只存在于应用里的模式保留。 |
| `modeShortcuts` | `{ "<模式 id>": <快捷键> }`，和导出文件里的 `modeShortcuts` 相同。`modes` 里没有的 id 会被忽略。快捷键（这里和 `general` 里）可以写成 `{ "shortcut": "cmd+shift+space" }`：修饰键 `cmd` `shift` `opt` `ctrl` `fn`，按键用美式键盘上的名字（`a`、`5`、`/`、`space`、`return`、`f13`、`left`…），也可以单独一个修饰键，比如 `right-opt` 或 `fn`。Yap 写出时会同时写这个字符串和原始的 `kind`/`keyCode`/`modifierFlagsRawValue` 字段；两者都有时以原始字段为准。鼠标按键和没有名字的按键只写原始字段。 |
| `prompts` | `{ id, title, promptText, useSystemInstructions }` 数组。和 `modes` 一样按 `id` 合并。 |
| `dictionary` | `{ "vocabulary": ["Yap"], "replacements": { "yep": "Yap" } }`。合并进现有词典。 |
| `general` | 和导出文件里的 `generalSettings` 相同：全局快捷键、开机启动、录音条样式、保留时长、粘贴和自动学习设置。 |
| `customModels` | 自定义转写模型的定义，和导出文件里的 `customCloudModels` 相同，按 `id` 合并。永远不写 `apiKey`；从另一台 Mac 同步来的模型会在「模型」页标注 **需要填 API key**，直到你在这台 Mac 上填好。 |
| `customProviders` | 自定义润色服务商：`{ id, name, baseURL, models, selectedModel }`，按 `id` 合并。永远不写 key；从另一台 Mac 同步来的服务商会在「模型」页标注 **需要填 API key**，直到你在这台 Mac 上填好。 |
| `modified` | `{ "modes": { "<id>": "<ISO 8601 时间>" }, "prompts": {…}, "vocabulary": { "<词>": … }, "replacements": { "<原文>": … } }`：每个条目最后一次修改的时间。由 Yap 写入，不需要手动编辑。 |
| `deleted` | 结构同上：已删除条目的删除记录。如果某个条目的删除时间晚于它的 `modified` 时间（或者它没有修改时间），这个条目会被删掉（文件里和应用里都删）。超过 90 天的删除记录会被清理。 |

先应用 v2 的各段，再在上面应用 v1 字段，所以 `enhancement.prompt` 和 `defaultMode` 会覆盖 `modes` 里的同项设置。空数组和空对象视为没写。

### 把设置写回文件

**把当前设置写入配置文件** 会把应用当前的设置存成一个 v2 文件，旧文件保留为 `config.json.bak`。写出的文件再读回来，设置不会有任何变化。

- `keys` 只保留文件里原本就有的 `env:NAME` 引用。明文 key 永远不会写出，所以它会从文件里消失；钥匙串里仍然有。
- `defaultMode` 和 `enhancement.enabled` 不再写出，因为 `modes` 里已经包含了。`transcription` 和 `enhancement` 只在和模式一致时保留。

打开 **保持配置文件同步**（默认关闭），任何设置改动后大约 2 秒会自动做一次写回。

### 在几台 Mac 之间同步

1. 在每台 Mac 上登录 Yap Cloud（见上文）。
2. 打开 **通过 Yap Cloud 同步**。第一次登录后，Yap 也会问你一次要不要开启。

之后 Yap 会在启动时、切回 Yap 时、Mac 从睡眠唤醒时以及每 15 分钟拉取一次同步的设置，本地改动在几秒后推送上去。拉取时如果云端没有新内容，什么都不会改。如果两台 Mac 同时改了设置，Yap 会按条目合并：每台 Mac 改过的模式、提示词、快捷键和词典条目都会保留。如果还是合并不了，这一段会显示冲突，并给出 **使用云端版本** 和 **保留这台 Mac 的设置** 两个选项；你选之前什么都不会被覆盖。如果是网络或服务端出错，会显示原因和 **重试**。

如果配置里的 `enhancement.prompt` 指向一个文件（比如 `prompt.md`），上传到云端的是文件内容，因为别的 Mac 上没有这个文件。拉取的那台 Mac 如果自己的配置也指向一个提示词文件，文本会写进那个文件（旧文件保留为 `prompt.md.bak`）；否则文本直接写进它的 config.json。

### 在新 Mac 上恢复设置

1. 在引导流程的第一屏点 **登录并恢复设置**，用同一个邮箱登录。
2. 看一眼摘要（模式、提示词、词典条目和快捷键各有多少），点 **恢复**。Yap 会应用这些设置、写入 config.json，并打开 **通过 Yap Cloud 同步**。
3. 照常授予权限、选择麦克风。如果恢复的设置里已经选好了转写模型，引导流程会跳过模型和练习这几步。
4. 如果设置里用到的某个服务商需要 API key、而这台 Mac 上还没有，会出现 key 那一步，并且已经选好了这个服务商。粘贴 key 就能继续。登录了 Yap Cloud 的话，Yap Cloud 本身不需要 key。

如果这个账户还没有同步过设置，窗口会直接说明，你只是完成了登录。

### 从 VoiceInk 迁移

如果这台 Mac 上运行过 VoiceInk，配置与同步里的 **从 VoiceInk 导入…** 会读取它的模式、提示词、词典、快捷键、通用设置以及自定义模型和服务商的定义，显示各有多少，你确认后再导入。id 相同的条目会替换 Yap 里的，其余的 Yap 设置保留。API key、许可证、历史记录和下载的模型都不会复制；导入的自定义模型和服务商会标注 **需要填 API key**，直到你填好。它只在你点击时运行；没装过 VoiceInk 的 Mac 上这个按钮是灰的。

### 删除记录

你删除一个模式、提示词、词典条目、自定义模型或自定义服务商时，Yap 会记下这次删除（在 `deleted` 里），让其他 Mac 也把它删掉，而不是再把它同步回来。如果另一台 Mac 在你删除之后又改了同一个条目，以那次修改为准，条目保留。删除记录保留 90 天后清理。

### API key 只留在各自的 Mac 上

API key 永远不会写进 config.json，也不会上传到 Yap Cloud。Yap 只从 `keys` 读取 key（`env:NAME`，或你自己写的明文）。自定义模型和自定义润色服务商同步时不带 key，会在「模型」页标注 **需要填 API key**，直到你在那台 Mac 上填好。Yap Cloud 的登录凭证也只留在它所属的那台 Mac 上。

### 推荐模型

当前选择（2026 年 9 月，11 段中英混说音频 / 82 个关键词）：转写用 `microsoft/mai-transcribe-2`（82 个里对 80 个，$0.10/小时），润色用 `deepseek/deepseek-v4.1-flash`（9/9 个用例，约 0.5 秒）。引导流程里的「自带 OpenRouter Key」选项用你自己的 OpenRouter key 应用这套配置，费用直接付给 OpenRouter。修改 `VoiceInk/Resources/RecommendedPrompt.md` 后请重新跑 `setup/bench.py`。

## 发布

发布流程和 CI 的说明面向维护者，只有英文版：见 [README.md 的 Releasing 一节](README.md#releasing)。
