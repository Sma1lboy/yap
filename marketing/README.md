# marketing/

Yap 的宣发材料，按 brand-studio 的目录约定（`marketing.studio.yaml` 声明所有路径，结构同 rove 仓库）。

| 路径 | 内容 |
|---|---|
| `positioning/positioning.md` | 一句话、三个卖点和证据、能用和不能用的说法。其他文案都从这里取句子和数字。 |
| `campaigns/release/1.2.0/` | 1.2.0 发布素材：GitHub Release、X thread、即刻、V2EX、小红书、Show HN。 |
| `site-proposal/` | 官网改版提案和 HTML 草稿。不是 `site/`：改 `site/` 并合进 main 会触发 GitHub Pages 部署。 |
| `visuals/` | 截图清单、30 秒演示分镜。 |
| `theme.md` | 给出图工具看的品牌 token，抄自 `docs/DESIGN.md`；两者不一致时以 DESIGN.md 为准。 |
| `portfolios/`、`../public/assets/accepted.yaml` | Jackson 接受过的素材登记。现在为空。 |
| `review/` | 发到 share server 的审阅页源文件（series `yap-launch`）。 |

规矩：外发文案只写 `docs/releases/<版本>.md` 里有的功能，数字只引用 `docs/` 里已入库的。不对上游 Beingpax/VoiceInk 做任何写操作。
