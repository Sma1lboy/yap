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

The script installs the app with Homebrew (or downloads the latest release), copies `setup/config.example.json` to `~/.config/yap/config.json` and the recommended prompt (`VoiceInk/Resources/RecommendedPrompt.md`, also bundled in the app) to `~/.config/yap/prompt.md` if they are not there yet, and opens Yap. Grant Microphone and Accessibility, pick a hotkey, and skip the provider steps if the config file already has your key.

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
| `enhancement` | Cleanup provider/model for modes that have enhancement on. `prompt` is a file next to the config (or an absolute path) or the prompt text itself; `"recommended"` uses the prompt bundled with the app. It becomes the default mode's prompt. |
| `defaultMode` | Which extra context the default mode sends to the model. All off keeps dictation fast and private. |

Schema v2 (`"version": 2`) adds whole-settings sections. They use the same JSON shapes as Settings → Backup → Export, so an exported file's sections can be pasted in. A file without `version` is v1 and reads exactly as before.

| Field (v2) | Meaning |
|---|---|
| `version` | `2`. Omitted means v1. A higher number (file from a newer Yap) still loads; Settings → Config File notes that unknown fields were ignored. |
| `modes` | Array of modes, same objects as `modeConfigs` in an export. Merged by `id`: a mode in the file replaces the app's mode with the same id; modes only in the app stay. |
| `modeShortcuts` | `{ "<mode id>": <shortcut> }`, same as the export's `modeShortcuts`. Ids not in `modes` are ignored. A shortcut (here and in `general`) can be written as `{ "shortcut": "cmd+shift+space" }`: modifiers `cmd` `shift` `opt` `ctrl` `fn`, keys by US-layout name (`a`, `5`, `/`, `space`, `return`, `f13`, `left`…), or one modifier key alone like `right-opt` or `fn`. Yap writes both this and the raw `kind`/`keyCode`/`modifierFlagsRawValue` fields; the raw fields win when both are present. Mouse buttons and keys without a name are written as raw fields only. |
| `prompts` | Array of `{ id, title, promptText, useSystemInstructions }`. Merged by `id` like `modes`. |
| `dictionary` | `{ "vocabulary": ["Yap"], "replacements": { "yep": "Yap" } }`. Merged into the existing dictionary. |
| `general` | Same object as the export's `generalSettings`: global shortcuts, launch at login, recorder style, retention, paste and auto-learn settings. |
| `modified` | `{ "modes": { "<id>": "<ISO 8601 time>" }, "prompts": {…}, "vocabulary": { "<word>": … }, "replacements": { "<source>": … } }`: when each entry last changed. Written by Yap; you don't need to edit it. |
| `deleted` | Same shape: tombstones for deleted entries. An entry is removed (from the file and from the app) when its tombstone is newer than its `modified` time, or it has none. Tombstones older than 90 days are dropped. |

v2 sections apply first, then the v1 fields on top, so `enhancement.prompt` and `defaultMode` win over the same settings inside `modes`. Empty arrays and objects count as unset. API keys are only ever read from `keys` (`env:NAME` or literal); custom model definitions are not part of the config because they can carry keys.

Settings → Config File → Write Current Settings to Config goes the other way: it writes the app's current settings as a v2 file. Keys keep only the `env:NAME` references already in the file; a literal key is never written, so it disappears from the file (the keychain still has it). `defaultMode` and `enhancement.enabled` are dropped because `modes` carries them, and `transcription` / `enhancement` stay only while they match the modes. Reading the written file back changes nothing. The previous file is kept as `config.json.bak`. "Keep Config File in Sync" (off by default) does the same about 2 s after any settings change.

"Sync via Yap Cloud" (needs a Yap Cloud sign-in) stores the same v2 file in your account. At launch Yap pulls it: if the cloud has a newer version and this Mac changed nothing since the last sync, the cloud copy is applied and written to config.json. Local changes are pushed with the last synced version as `If-Match`. If another Mac pushed first, the two copies are merged by id (modes, prompts, shortcuts, dictionary entries; each Mac's edits since the last sync win for what it changed) and pushed once more. If that fails too, Settings → Config File shows the conflict with "Use Cloud Version" / "Keep This Mac's Settings"; nothing is overwritten on its own. The last synced version is stored in UserDefaults (`configCloudSyncedVersion`). An `enhancement.prompt` that names a file (`"prompt.md"`) is sent to the cloud as the file's text, since other Macs don't have the file; a Mac that pulls it gets the text inline in its config.json. Deleting an entry writes a tombstone, so it stays deleted on the other Macs unless one of them edited it after the delete.

On a new Mac, onboarding's first screen has "Sign In and Restore Settings". After signing in it shows what the account has stored (modes, prompts, dictionary entries, shortcuts). Restore applies it, writes config.json and turns on sync. If the restored modes include a default mode with a transcription model, onboarding then skips the model, AI key and practice steps; the permission and microphone steps still run. API keys aren't synced, so a provider that needs one asks for it on first use.

Current picks (Sept 2026, 11 code-switched clips / 82 key terms): transcription `microsoft/mai-transcribe-2` (80/82, $0.10/h), cleanup `deepseek/deepseek-v4.1-flash` (9/9 cases, ~0.5 s). Onboarding's "Recommended" option applies exactly this setup with one OpenRouter key. Re-run `setup/bench.py` after editing `VoiceInk/Resources/RecommendedPrompt.md`.

## Releasing

Push a tag `vX.Y.Z`. CI (`.github/workflows/release.yml`) builds on macOS 26, signs with the "Yap Self-Signed" certificate, publishes `Yap.zip` to GitHub Releases, then commits the new `appcast.xml` item (Sparkle EdDSA-signed) and the `Casks/yap.rb` version in one commit to `main`. Build numbers are `1000 + run number`. CI also builds every push to `main` and once a week, so caches stay warm in `main`'s scope: the whisper.cpp framework, the compiled Swift packages (mlx, FluidAudio, TranscribeCpp — the stable local-model modules), and Xcode 26's content-hashed compilation cache for the app's own sources (a fresh checkout doesn't force a full recompile). A release takes about 3–4 minutes; changing `Package.resolved` triggers one full rebuild (~14 minutes).

Because every release is signed with the same certificate, macOS keeps the Microphone and Accessibility permissions across updates. The app is not notarized; Homebrew and the install script remove the quarantine flag.

Secrets used by CI: `YAP_SIGNING_P12`, `YAP_SIGNING_PASSWORD`, `SPARKLE_ED_PRIVATE_KEY`.

---

