<p align="center"><img src="design/logo-1024.png" width="160" alt="Yap duck icon"></p>

<h1 align="center">Yap</h1>

<p align="center">按住快捷键说话，中英混着说也行，松开就是整理好的文字。</p>

Yap is a fork of [VoiceInk](https://github.com/Beingpax/VoiceInk) by Prakash Joshi Pax, distributed under the same GPL-3.0 license. All credit for the app goes to the original author — if you want the official, notarized, auto-updating build, [buy VoiceInk](https://tryvoiceink.com/).

What this fork changes:

- Its own identity: app name, bundle ID `me.sma1lboy.yap`, Application Support folder and keychain namespace, so it installs next to VoiceInk without sharing data. Upstream announcements, GitHub-star prompts, the Pro/licensing screen and the upstream change log are gone.
- A calmer UI: monochrome sidebar, a Home screen that shows the default mode and recent transcripts, SF Symbols instead of emoji.
- Onboarding lets you skip the transcription and AI provider steps ("Set It Up Later") and configure everything from a JSON file instead.
- Its own update channel: CI signs every release with a stable self-signed certificate, publishes it, and updates both the Sparkle appcast (in-app updates) and the Homebrew cask.
- A duck icon (`design/logo.svg`).
- `setup/`: a tuned setup for Chinese–English code-switched dictation through OpenRouter, plus the benchmark scripts used to pick the models.

## Install

```bash
git clone https://github.com/Sma1lboy/yap && cd yap
./setup/install.sh
```

The script installs the app with Homebrew (or downloads the latest release), copies `setup/config.example.json` and `setup/prompt.md` to `~/.config/yap/` if they are not there yet, and opens Yap. Grant Microphone and Accessibility, pick a hotkey, and skip the provider steps if the config file already has your key.

Just the app: `brew tap sma1lboy/yap https://github.com/Sma1lboy/yap && brew install --cask sma1lboy/yap/yap`. After that, Yap updates itself (Check for Updates… in the app menu) or with `brew upgrade --cask yap`.

## Config file

Yap reads `~/.config/yap/config.json` (or `$XDG_CONFIG_HOME/yap/config.json`) at every launch. Fields that are present override the in-app settings; missing or empty fields are left alone. Settings → Config File shows what was applied and has Open / Show in Finder / Reload.

```json
{
  "keys": { "openrouter": "env:OPENROUTER_API_KEY" },
  "transcription": { "provider": "openrouter", "model": "microsoft/mai-transcribe-2" },
  "enhancement": { "enabled": true, "provider": "openrouter", "model": "deepseek/deepseek-v4.1-flash", "prompt": "prompt.md" },
  "defaultMode": { "screenContext": false, "clipboardContext": false, "selectedTextContext": false }
}
```

| Field | Meaning |
|---|---|
| `keys.<provider>` | API key, stored in the keychain. `env:NAME` reads the variable from the environment, then from `~/.env` (apps opened from the Dock don't see your shell environment). |
| `transcription` | Speech-to-text provider and model, applied to every mode. |
| `enhancement` | Cleanup provider/model for modes that have enhancement on. `prompt` is a file next to the config (or an absolute path) or the prompt text itself; it becomes the default mode's prompt. |
| `defaultMode` | Which extra context the default mode sends to the model. All off keeps dictation fast and private. |

Current picks (Sept 2026, 11 code-switched clips / 82 key terms): transcription `microsoft/mai-transcribe-2` (80/82, $0.10/h), cleanup `deepseek/deepseek-v4.1-flash` (9/9 cases, ~0.5 s). Re-run `setup/bench.py` after editing the prompt.

## Releasing

Push a tag `vX.Y.Z`. CI (`.github/workflows/release.yml`) builds on macOS 26, signs with the "Yap Self-Signed" certificate, publishes `Yap.zip` to GitHub Releases, then commits the new `appcast.xml` item (Sparkle EdDSA-signed) and the `Casks/yap.rb` version in one commit to `main`. Build numbers are `1000 + run number`.

Because every release is signed with the same certificate, macOS keeps the Microphone and Accessibility permissions across updates. The app is not notarized; Homebrew and the install script remove the quarantine flag.

Secrets used by CI: `YAP_SIGNING_P12`, `YAP_SIGNING_PASSWORD`, `SPARKLE_ED_PRIVATE_KEY`.

---

