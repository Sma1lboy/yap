# Yap

Yap is a fork of [VoiceInk](https://github.com/Beingpax/VoiceInk) by Prakash Joshi Pax, distributed under the same GPL-3.0 license. All credit for the app goes to the original author — if you want the official, notarized, auto-updating build, [buy VoiceInk](https://tryvoiceink.com/).

What this fork changes:

- App name and bundle ID (`me.sma1lboy.yap`) so it installs next to VoiceInk.
- A GitHub Actions workflow that builds an ad-hoc-signed `LOCAL_BUILD` on every `v*` tag, so no local Xcode is needed.
- `setup/`: a tuned setup for Chinese–English code-switched dictation through OpenRouter (transcription `microsoft/mai-transcribe-2`, cleanup `deepseek/deepseek-v4.1-flash`), the cleanup prompt, and the benchmark scripts used to pick them.

Install on a new Mac:

```bash
git clone https://github.com/Sma1lboy/yap && cd yap
OPENROUTER_API_KEY=sk-or-... ./setup/install.sh
```

macOS permissions (microphone, accessibility) and the hotkey still have to be granted by hand on each machine.

---

