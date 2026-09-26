# 视觉审计（2026-09-25）

对照 `docs/DESIGN.md` 扫的全 app 绕开 token 的地方。清单由 `scripts/design-tokens.py --check` 产出：这次改动之前是 1895 处，改完是 0 处。以后 `make build` 会先跑 `make design-check`，新写的硬编码会直接让构建失败，所以这份文件只记录这一轮找到了什么、怎么处理的，以及还剩哪些。

## 按类别

| 类别 | 改之前 | 怎么处理 |
|---|---|---|
| 字号 `.system(size:)` | 566 | 映射到 9 档字号（`AppTheme.font(.caption, .medium)` 等）。8–10→micro，11→caption，12/12.5→footnote，13/13.5→body，14→callout，15–17→headline，18→title3，20–24→title，28→display；bold/heavy 统一成 semibold。10 处是图标字形按容器尺寸缩放（`size * 0.58`），标了 `design-exempt`。 |
| 圆角 `cornerRadius:` | 175 | 2–7→small(6)，8–11→control(10)，12–14→card(12)，16–18→panel(16)，22→pill。`AppActionButton` 的 9/15 改为 control/pill。原来的 `Radius.control` 是 14，比卡片的 12 还大，现在是 10。 |
| 间距 `.padding(n)` / `spacing: n` | 512 + 624 | 就近取 4 的倍数档（2、4、8、12、16、20、24、32、48），落在两档正中间时取大的：6→8，10→12，14→16。27 处 ≥50 的值是布局偏移（例如 onboarding 底部给按钮让出的 100），标了 `design-exempt`。 |
| 直接写颜色 | 14 | 见下表。 |
| `.borderedProminent` | 4 | 系统样式在黄底上画白字，改成 `AppActionButton(kind: .primary)`。按回车触发的默认按钮（6 个）加 `.buttonStyle(.appAction(.primary))`，因为系统强调色是“多彩”时 macOS 会用 app 的黄色画默认按钮，文字却是白色。 |

改动最集中的文件：`OnboardingTranscriptionSetupCard.swift`（102 处）、`HistoryView.swift`（70）、`ModeViewComponents.swift`（58）、`CustomProviderManagementView.swift`（58）、`AIProviderVerificationCard.swift`（53）、`ProviderDetailPanel.swift`（51）。

## 直接写的颜色

| 位置 | 原来 | 现在 |
|---|---|---|
| `ModeViewComponents.swift:359/365` “不可用”胶囊 | `Color.red.opacity(0.8)` 底 + 白字 | `Status.errorFill` 底 + `Status.error` 字 |
| `TriggerTemplateRow.swift:45`、`TriggerPickerPopover.swift:322` | `Color.accentColor` 当文字色 | `Accent.text`（浅色墨色，深色黄色） |
| `AutoLearnFailurePanel.swift:27` | `.orange` | `Status.warning` |
| `ShortcutPreviewView.swift:32` 按键帽 | `Color(white: 0.2)` / `.white` | `Surface.control` |
| `VoiceInkRefineModelCardView.swift:32/35` “New”徽标 | 黑字 + 肉色 `Color(red: 0.96…)` | `Text.primary` + `Accent.fillSubtle` |
| `AppNotificationView.swift`、`RecorderComponents.swift` | 固定深色 | 保留，标 `design-exempt`：这两个浮窗浮在桌面上，不管系统外观都是深色 HUD（DESIGN.md 的例外清单） |

## 同一个概念在不同页面长得不一样

1. **余额**有三种写法：Home 顶部卡片（“Yap Cloud balance / $4.21”，13 号字，低余额时有 Add Funds 按钮）、菜单栏（“Yap Cloud balance: $4.21”，一行菜单项）、Account（表单里的一行，和“邮箱”一样大）。按 DESIGN.md，余额应该是 display 字号的等宽数字。这次没改 Account 的布局，见“还剩”。
2. **收入金额**：Account 最近记录里的“+$5.00”“+$1.00”是绿色，Home 和别处没有这种写法。已改成正文色，负号改用 U+2212。
3. **注册赠额**：onboarding 的“新用户注册送 $1 额度”是绿色的粗字，Account 里是普通说明文字。已改成浅黄底的标签（和 round 1 板子上的“推荐”标签一样）。
4. **主按钮**：模型目录每一行都是一个蓝色（现在是黄色）实心“下载”按钮，一屏十几个主按钮；别的页面的行内操作是次按钮。已改成次按钮（surface 底 + 描边），取消下载不再用红底（取消不丢数据）。
5. **链接**：设置、Account、onboarding 里的链接是系统蓝，有的有下划线、有的没有。设置和 Account 的 `Link` 已改成 `appLinkStyle()`（墨色/黄色 + 下划线）；onboarding 里“继续即表示同意…”那句用的是 AttributedString 链接，还是系统蓝。
6. **卡片下的说明文字**：Account 和设置用的是 macOS grouped Form，分组下面的说明被右对齐；自己画的页面（Home、Modes、Models）是左对齐。
7. **圆角**：同样是卡片，Home 统计块是 16–17，Models 是 12，Mode 编辑器是 18，onboarding 是 12 和 16 混用。已统一成 card(12) / panel(16) 两档。
8. **录音红点**：录音按钮用的是语义色 `Status.error`，深色外观下是偏粉的 #FF8A80。已改成 `Action.destructiveFill`。

## 还剩（没在这一轮做）

- **Account 页的布局**：round 1 板子上画的“余额放页首、刷新和登出分开、说明文字左对齐”需要把 Account 从 grouped Form 改成自己排的页面，改动比 token 替换大得多，建议单独做一轮。
- **onboarding 模型页的四个标签**：“Your OpenRouter Key”在英文下折成两行（中文不折），间距加大后更明显。
- **onboarding 同意条款那句**里的链接还是系统蓝（见上面第 5 条）。
- **系统控件**：开关、分段控件、进度条会用 app 的强调色（`AccentColor` 已设成鸭子黄），但只在用户把系统强调色设成“多彩”（macOS 默认）时生效；用户选了别的系统强调色，这些原生控件会跟着系统走。这是 macOS 的行为，不打算绕开。
