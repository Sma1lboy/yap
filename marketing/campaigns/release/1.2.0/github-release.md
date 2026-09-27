<!-- GitHub Release body for v1.2.0. The full notes stay in docs/releases/1.2.0.md (bundled in the app);
     this is the top of the release page. Paste above the full notes, or use alone with the link. -->

Yap is an open-source (GPL-3.0) dictation app for macOS, forked from [VoiceInk](https://github.com/Beingpax/VoiceInk). Hold Right Option, talk in English, Chinese or both in one sentence, and let go: the text is pasted into the app you're in.

**What 1.2.0 changes**

- **Mixed Chinese and English.** Whisper decodes each language stretch in its own language, so a recording that starts in English no longer comes out with its Chinese half translated. Dictations over 30 seconds are split at pauses and no sentence goes missing.
- **Fully offline by default on the Local option.** Onboarding now downloads Whisper Large v3 Turbo (Quantized, 547 MB), which handles Chinese; Parakeet, English-only, is no longer the default. With a local model and cleanup off, a dictation opens no network connection. Check it yourself: `make offline-check MODEL=…` runs a dictation with all IP traffic denied.
- **Numbers you can rerun.** `setup/asr/` has 11 code-switched clips with 82 English terms and names. On that set: 59/82 for the recommended cloud model, 54/82 for the local default with the terms in your dictionary ([docs/dictation-accuracy.md](https://github.com/Sma1lboy/yap/blob/main/docs/dictation-accuracy.md); the clips are synthetic `say` voices).
- **Three ways to run it, side by side in onboarding:** a local model, your own OpenRouter or other provider key, or Yap Cloud if you'd rather not get a key. First dictation on the third screen.
- **Settings in `~/.config/yap/config.json`**, with readable shortcuts like `"cmd+shift+space"`; optional sync across Macs.
- **Clearer failures.** A failed transcription keeps the recording and offers Retry; if Yap can't paste, the text stays on your clipboard and Yap says how to fix it.

Full notes, in English and Chinese: [docs/releases/1.2.0.md](https://github.com/Sma1lboy/yap/blob/main/docs/releases/1.2.0.md).

**Install**

```bash
brew tap sma1lboy/yap https://github.com/Sma1lboy/yap
brew install --cask sma1lboy/yap/yap
```

Or download `Yap.zip` below. Releases are signed but not notarized; the zip needs one "Open Anyway" in System Settings › Privacy & Security the first time ([details](https://yap.sma1lboy.me/#unverified-developer)). Homebrew skips that step. Requires macOS 15.

---

Yap 是开源（GPL-3.0）的 macOS 听写 app，fork 自 VoiceInk。1.2.0：中英混说按语言分段转写，不再把一半翻译成另一种语言；「本地」选项改为下载支持中文的 Whisper Large v3 Turbo（量化版，547 MB），用本地模型、关掉润色时一次听写不联网，`make offline-check` 可以自己验证。完整中文说明见 [docs/releases/1.2.0.md](https://github.com/Sma1lboy/yap/blob/main/docs/releases/1.2.0.md) 的后半部分。
