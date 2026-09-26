# design/web

Yap 网页和邮件的设计稿，都是可以直接用的静态 HTML/CSS。颜色、字号、圆角、间距全部来自 `docs/DESIGN.md`。

| 文件 | 用在哪 |
|---|---|
| `tokens.css` | 生成文件（`make design-tokens`），不手改。浅色和深色两套变量，跟随系统，`data-theme` 可以强制。 |
| `components.css` | 页面骨架、按钮、卡片、表单、表格、横幅、状态标签、金额、空状态。只用 `tokens.css` 的变量。 |
| `checkout-success.html` / `checkout-cancel.html` | paygate `GET /checkout/success`、`/checkout/cancel` |
| `legal.html` | paygate `GET /privacy`、`/terms`（正文沿用 `legal-pages.ts` 现在渲染的内容） |
| `dashboard.html` | 账户 dashboard 的设计参考：所有组件放在真实场景里，数字是假的 |
| `email-sign-in-code.html` | 登录验证码邮件（`auth.ts`） |
| `email-low-balance.html` | 余额不足 $1 的提醒邮件（`wallet.ts`） |

## 搬进 paygate 时

- **CSS 要内联。** paygate 的 CSP 是 `default-src 'none'; style-src 'unsafe-inline'`，外链的 `.css` 会被拦掉。把 `tokens.css` 和 `components.css` 的内容放进 `htmlPage()` 的 `<style>`，替换掉现在那段样式。
- **logo 是内联 SVG**（同样因为 CSP 不能引用图片文件），直接复制页面里的 `<svg class="logo">`。
- **占位符**用 `{{名字}}` 标出，每个文件开头的注释写了有哪些、从哪来。插进去的值照旧要 `escape()`。
- **邮件**：现在 `mail.ts` 只发 `text`。改成同时发 `html` 和 `text`，现有的纯文本内容留作 text 部分。邮件里的十六进制颜色只能取 `docs/DESIGN.md` 浅色那一列，`make design-check` 会检查。
- **改 token**：改 `docs/DESIGN.md`，跑 `make design-tokens`，再把新的 `tokens.css` 拷过去。不要在 paygate 里改颜色值。

## Stripe 付款页的品牌设置

Stripe 付款页（Checkout）上我们能改的只有下面几项，页面结构由 Stripe 决定。名称按 [Stripe 文档](https://docs.stripe.com/payments/checkout/customization/appearance?payment-ui=stripe-hosted)：Dashboard 里是 Settings › Branding › Checkout，API 里是创建 Checkout Session 时的 `branding_settings`。

| 设置 | Dashboard / `branding_settings` | 值 | 理由 |
|---|---|---|---|
| 图标 | Icon / `icon` | `design/web/stripe-icon.png`（512×512 PNG） | `design/logo.svg` 去掉圆角和阴影后铺满正方形：Stripe 会自己加圆角或裁成圆形，自带圆角的图再被裁一次，四角会露出底色。只传 icon 时，Stripe 也把它当 favicon。 |
| 按钮颜色 | Button color / `button_color` | `#FFD84D` | `color.accent` 的浅色值（鸭子头）。付款按钮是这一页唯一的主按钮，和 app、官网里黄色主按钮的用法一致。 |
| 背景色 | Background color / `background_color` | `#26262B` | `color.surface` 的深色值，和图标底座同一色系：深石墨底配黄色按钮和鸭子图标，就是 app 图标本身的配色。 |
| 名称 | Business name / `display_name` | `Yap Cloud` | 和 paygate 页面、邮件里的品牌名一致。 |
| 字体 | `font_family` | 不设（默认） | 可选字体里没有 SF，而且大多数不支持 `zh`，中文会退回系统字体；不设最接近 app。 |
| 形状 | `border_style` | `rounded` | 最接近 DESIGN.md 的 6px 输入框、10px 按钮圆角；不选 `pill` 和 `rectangular`。 |
| Logo | Logo / `logo` | 不设 | 没有横版 logo；不设时 Stripe 显示 Icon 加名称。 |

两种设法都可以：在 Dashboard 设一次（所有 Session 默认用它），或者 paygate 创建 Session 时传 `branding_settings`（没传的字段仍用 Dashboard 的值）。图标先上传成 Stripe File，再以 `icon[type]=file`、`icon[file]=<file id>` 传入。

设好后请在测试模式下打开一次付款页，确认两件事：付款按钮上的字是深色（Stripe 按按钮颜色自动选字色，黄底应该配深色字）；深色背景上的文字清楚。
