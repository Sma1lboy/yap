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
