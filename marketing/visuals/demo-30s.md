# 30 秒演示视频分镜

目标：不配旁白也看得懂三件事——中英混说转对、断网也能用、开源。用在 X 第 1 条、即刻、官网演示区旁边、Show HN 帖子里的链接。

## 怎么拍，不碰 Jackson 的真机

- app 画面：`make mock` 起一个独立身份的 app（`me.sma1lboy.yap.mock`，假数据，断网，退出即删）。录音那一步不对着麦克风说：用 `--dictate-file setup/asr/clips/security.m4a` 把测试音频喂进真实管线（`make offline-check` 就是这么做的），转写结果是真跑出来的。
- 打字目标（编辑器窗口）、浮窗、终端输出：用 HyperFrames 按 app 截图和真实输出重建成动画，不录屏 Jackson 的桌面，不用合成点击去驱动 app。
- 转写文字只用真跑出来的结果，不手写一段"理想输出"。下面分镜里的字就是 `docs/local-models.md` 记录的那次离线输出。
- 1920×1080，30 fps；浅色为主，第 5 镜切一次深色（跟随系统的卖点）。字体系统字族。无背景音乐或只用很轻的 BGM；字幕中英双语。

## 分镜

| # | 时间 | 画面 | 屏上字（英 / 中） | 声音 |
|---|---|---|---|---|
| 1 | 0–3 s | 空的编辑器窗口，光标在闪。右下角键帽「右 ⌥」按下 | Hold a key. Talk. / 按住快捷键，说话。 | 按键声 |
| 2 | 3–9 s | 录音浮窗（`recorder-mini`）出现，波形在动；字幕逐词出现说的话："OAuth refresh token 现在存在 Local Storage 里，有 XSS 风险……" | 字幕即原话 | `security.m4a` 原声（合成语音，屏上角标 "test clip, macOS say"） |
| 3 | 9–13 s | 松开按键，浮窗收起，文字一次性粘贴进编辑器 | Let go. It's pasted. / 松开，粘贴。 | 轻"咔" |
| 4 | 13–19 s | 画面右上角出现一个 Wi-Fi 关闭的系统图标；左侧叠一块终端：`make offline-check` 的两段输出逐行出现，最后一行 "no network connection was opened during the dictation" 高亮 | Offline on a local model. Checked by a script. / 本地模型，断网可用，脚本可验证。 | 静 |
| 5 | 19–25 s | 切深色。测试结果表：mai-transcribe-2 **59/82**，本地 + 词典 **54/82** 两行放大，其余淡出 | 11 clips, 82 English terms, in the repo. / 11 段音频、82 个英文术语，都在仓库里。 | 静 |
| 6 | 25–30 s | 鸭子图标 + "Yap"，下面 `github.com/Sma1lboy/yap` 和 `brew install --cask sma1lboy/yap/yap` | Open source. GPL-3.0. / 开源，GPL-3.0。 | 结束音 |

## 注意

- 第 3 镜粘贴的是润色关闭时的原始输出，包括末尾转错的"效应"（原话是"就行"类的词，模型转错了）。二选一：保留（最诚实，屏上标 "raw output, cleanup off"），或者只截到"改成 HTTP-only 的 Cookie"为止。不要手改成正确的字。
- 不出现价格、余额、Yap Cloud 充值界面。
- 做法：`/hyperframes` → `product-launch-video` 路线，素材用 `/tmp/yap-ui/snapshots` 的图和上面的文字。
