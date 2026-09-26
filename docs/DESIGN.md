# Yap 视觉规则

这份文件是 Yap 视觉 token 的唯一来源。app（SwiftUI）、网页（官网、paygate 页面、dashboard）、邮件和 Stripe 后台都用这里的值，不另写一套：

- 下面 `tokens` 代码块里的值由 `scripts/design-tokens.py` 生成两份文件：`VoiceInk/DesignSystem/Theme/DesignTokens.generated.swift`（AppTheme 从它取值）和 `design/web/tokens.css`（`site/tokens.css` 是同一份）。这些文件不手改。
- 改 token：改这里 → `make design-tokens` → 提交三份文件。`make design-check` 会检查生成文件是否过期，以及 app 代码里有没有绕开 token 的写法。
- 邮件只能用行内样式，没法引用 CSS 变量，所以直接写这里的十六进制值（浅色那一列），`design-check` 也会检查。

## 禁止

在 `VoiceInk/DesignSystem/Theme/` 以外：

- 直接写颜色：`Color.red`、`Color(red:…)`、`Color(nsColor: .systemOrange)`、`.foregroundStyle(.orange)`、`Color.accentColor`。用 `AppTheme.*`。
- 直接写字号：`.font(.system(size: 12))`。用 `AppTheme.font(.footnote, .medium)`。
- 直接写圆角：`cornerRadius: 8`。用 `AppTheme.Radius.*`。
- 直接写间距：`.padding(10)`、`spacing: 6`。用 `AppTheme.Spacing.*`。
- 用系统的 `.borderedProminent`：它在黄底上画白字。主按钮用 `AppActionButton(kind: .primary)`。

例外：这一行确实不是界面样式，在行尾写 `// design-exempt: <原因>`，检查会跳过它。现有的例外只有这几类：

- 图标字形按所在容器缩放（`size * 0.58` 这种）。
- 布局偏移，不是间距（例如 onboarding 底部给按钮让出的 100pt）。
- 录音器和通知浮窗：它们浮在桌面上，不管系统是浅色还是深色都保持深色 HUD。
- Home 统计图的数据系列颜色（`AppTheme.Data`），只用在图表里。

网页同理：只用 `tokens.css` 里的变量，不在页面里写十六进制值（邮件除外，见上）。

## 颜色从哪来

颜色的出处是鸭子图标 `design/logo.svg`：

| logo 里的颜色 | 用途 |
|---|---|
| 鸭子头 `#FFD84D` | 强调色（浅色） |
| 呆毛 `#F7C83A` | 强调色（深色）、按下 |
| 眼睛 `#2A2320` | 黄底上的文字 |
| 底座 `#34343A → #202024` | 中性色的色相：偏冷的石墨色 |
| 嘴 `#FF9A3C` | 只留在 logo 里，不进界面 |

三组颜色分开用：

- **强调色（黄）**只当填充色：主按钮、选中项、品牌标记。每屏最多一个黄色主按钮。白字压在黄底上对比度只有 1.38，所以黄底上的字一律用 `on-accent`（墨色，对比度 11.2）。浅色模式下黄色不能当文字，链接和焦点环用墨色；深色模式下黄色当文字对比度有 12.4，链接和焦点环用黄色。
- **中性色**来自底座的石墨色，浅色背景是冷灰，不是暖米色。浅色靠白卡片放在灰底上分层，深色靠卡片比背景亮来分层，不靠阴影；所以深色不是浅色的反色，两列是分开定的。
- **语义色**只在需要用户确认结果或介入时出现，不当装饰。警告用橙色，刻意避开品牌黄。“信息”不单独给颜色（`sunken` 作底、`text` 作字、配图标）。钱进账（充值、赠额）是正常情况，用正文色，不用绿色；绿色留给“做成了”的一次性确认（充值到账、连接测试通过）。

## Token

```tokens
# 颜色：名字 浅色 深色 理由
color.bg            #F3F3F5  #1B1B1F  窗口和页面背景。浅色是底座色相的冷灰；深色比底座再暗一级，卡片才能往上提亮。
color.surface       #FFFFFF  #26262B  卡片、输入框、次按钮。
color.sunken        #EAEAED  #151518  凹下去的区域：代码框、分段控件底、信息横幅。
color.border        #DCDCE1  #37373E  卡片和控件的 1px 描边。
color.text          #1F1F23  #F2F2F4  正文。对比度 14.8 / 15.4。
color.text-2        #5E5E66  #A8A8B0  说明文字、次要数值。对比度 5.8 / 6.4。
color.text-3        #6F6F77  #8E8E96  时间戳、单位。按最低 4.5 定，不再用 secondary 乘透明度。
color.accent        #FFD84D  #F7C83A  鸭子黄，只做填充。
color.accent-press  #F7C83A  #E9B92C  主按钮按下。
color.on-accent     #2A2320  #2A2320  黄底上的文字，取鸭子眼睛的颜色。
color.accent-subtle #FFF5CC  #3A3322  选中行、“推荐”标签底。深色是带黄味的石墨，不是低透明度的黄。
color.link          #1F1F23  #FFD84D  链接。浅色用正文色加下划线。
color.focus         #2A2320  #FFD84D  键盘焦点环。
color.success       #1A7340  #6FD39A  “做成了”的确认文字和图标。
color.success-bg    #E6F4EA  #17301F  成功提示的底。
color.warning       #9A4A0B  #F4B070  余额偏低、草稿、快到上限。橙色，避开品牌黄。
color.warning-bg    #FDF1E4  #3A2818  警告横幅的底。
color.danger        #B42318  #FF8A80  出错、会丢数据的操作的文字和图标。
color.danger-bg     #FDEDEC  #3D1E1D  错误横幅的底。
color.danger-fill   #C62828  #E5484D  危险按钮的底。
color.on-danger     #FFFFFF  #FFFFFF  危险按钮上的字。

# 字号：名字 app(pt) 网页(px) 理由
font.micro     10  11  徽标里的字。只用于徽标。
font.caption   11  12  时间戳、次要标注。
font.footnote  12  13  卡片下的说明、字段报错、小按钮。
font.body      13  16  正文。13 是 macOS 的正文字号；网页和邮件要长时间阅读，用 16。
font.callout   14  16  列表项标题、侧边栏。
font.headline  16  18  卡片标题、分组标题。
font.title3    18  22  面板标题。
font.title     22  28  页面标题。
font.display   28  40  余额这种单独的大数字；网页首屏标题。

# 圆角：名字 值 理由
radius.sm      6    输入框、徽标、小色块。
radius.control 10   按钮、分段控件里的选项。比卡片小，放在卡片里的按钮不会比卡片更圆。
radius.card    12   卡片。
radius.panel   16   大容器：侧边面板、onboarding 的大卡片。
radius.pill    999  胶囊：标签、分段控件外框、搜索框。

# 间距：名字 值 理由
space.half 2   图标和紧贴的文字、描边内缩。
space.1    4   同一组里的行内间距。
space.2    8   控件之间。
space.3    12  卡片之间、卡片内的行距。
space.4    16  卡片内边距。
space.5    20  面板内边距。
space.6    24  分组之间。
space.8    32  页面区块之间。
space.12   48  大留白（onboarding、首屏）。
space.16   64  页面顶部和底部的留白。
```

字重只用三档：400 regular、500 medium、600 semibold。700 只用于官网首屏标题。

## 其他规则

- **字体**：系统字族。app 用 SF / 苹方；网页和邮件用 `-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", "Helvetica Neue", sans-serif`，等宽用 `ui-monospace, "SF Mono", Menlo, monospace`。这是有意的选择：Yap 是 Mac 应用，网页和 app 显示同一套字体，不加载外部字体（外部字体 CDN 在审阅页和不少邮件客户端里会被拦掉）。
- **层次**：卡片用 1px `border`，不加阴影。只有真正浮起来的东西（sheet、弹出菜单）有阴影；深色模式的阴影再加一圈 6% 的白描边，否则看不出边界。
- **金额**：余额和充值金额保留 2 位小数；单次扣费保留 4 位，不到 $0.0001 的写 “<$0.0001”；负号用 U+2212（−）；数字一律等宽（`.monospacedDigit()` / `font-variant-numeric: tabular-nums`）。收入和支出都用正文色。
- **按钮**：主按钮是黄底墨字，每屏最多一个；次按钮是 `surface` 底加描边；危险按钮只给会丢数据的操作（删除），登出不算。
- **横幅**：信息用中性色；警告、错误都要带一个能解决问题的动作。
- **空状态**：左对齐，一个线条图标，一句话说明为什么是空的，再给一个动作。不居中，不放插画。
- **对齐**：内容左对齐。只有单个图标加一句话的小块（例如录音器）才居中。

## 各载体怎么落地

| | 颜色 | 字号 | 深色 |
|---|---|---|---|
| app | `AppTheme.*`（取自 `DesignTokens.generated.swift`，按系统外观自动切换） | `AppTheme.font(.body)` 用 app 列 | 跟随系统 |
| 网页 | `var(--bg)` 等（`design/web/tokens.css`） | `var(--font-body)` 用网页列 | 跟随系统（`prefers-color-scheme`），可用 `data-theme` 强制 |
| 邮件 | 浅色列的十六进制值，写在行内样式里 | 网页列 | 不做深色：固定浅色；黄色只做色块、不做文字，客户端强制反色时也能读 |
| Stripe 后台 | Brand color `#FFD84D`，Accent color `#26262B`，Icon 用 `design/logo-1024.png` | 保持 Stripe 默认 | 由 Stripe 决定 |
