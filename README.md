**English** | [简体中文](README.zh-CN.md)

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

## Yap Cloud

Yap Cloud is an optional account that pays for transcription and cleanup from a prepaid balance, so you don't need API keys from OpenRouter or other providers. It uses the same models as the "Your OpenRouter Key" setup.

**Sign up / sign in.** Open **Account** in the sidebar, enter your email, then the 6-digit code sent to it. There is no password. A new account gets $1 of credit, listed under **Recent Activity** as "Sign-up bonus". During onboarding you can pick **Use Yap Cloud (pay as you go)** on the model step instead.

<!-- 10% = paygate MARKUP; update here, README.zh-CN.md and site/index.html when it changes. -->
**What it costs.** Each transcription or cleanup request is charged the model provider's price plus 10%. **Account → Models & Pricing** lists the models; **This Month** shows what you spent this month and on which models, and **Recent Activity** lists every charge and top-up.

**Adding funds.** In **Account → Add Funds**, pick $5, $10 or $20, or Custom (a whole-dollar amount from $5 to $500), and click **Add Funds…**. Checkout opens in your browser; the balance updates when you come back to Yap. Below $1 Yap shows a low-balance warning; when the balance runs out, Yap Cloud requests stop and a notification takes you to Account.

**Monthly cap.** **Account → Monthly Cap** limits spending per calendar month: pick $5, $10, $20, a custom amount up to $10,000, or No Cap. Once this month's spending reaches the cap, Yap Cloud stops charging until next month or until you raise the cap. A cap of $0 blocks all Yap Cloud calls.

**Devices.** Every Mac you sign in on gets its own token (kept in that Mac's keychain, never synced). **Account → Signed-in Devices** lists them with when each was last used; **Remove** signs that Mac out so it stops charging your balance. It can sign in again with your email. **Sign Out** on the Account page signs out this Mac; modes that use Yap Cloud stop working until you sign in again or switch them to another provider.

## Config & Sync

All of Yap's settings can live in one file, `~/.config/yap/config.json` (or `$XDG_CONFIG_HOME/yap/config.json`), and can sync between your Macs through Yap Cloud. Everything below is under **Settings → Config & Sync**.

### The config file

Yap reads the file at every launch. Fields that are present override the in-app settings; missing or empty fields are left alone. **Open** creates the file from a template if it doesn't exist, **Show in Finder** reveals it, and **Reload** applies it again without restarting. The status line says which fields were applied and which were skipped (for example a key whose `env:` variable isn't set).

A minimal file (schema v1):

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

Schema v2 (`"version": 2`) describes all settings. It uses the same JSON shapes as **Settings → Backup → Export**, so sections of an exported file can be pasted in. A file without `version` is v1 and reads as before.

| Field (v2) | Meaning |
|---|---|
| `version` | `2`. Omitted means v1. A higher number (file from a newer Yap) still loads; Settings → Config & Sync notes that unknown fields were ignored. |
| `modes` | Array of modes, same objects as `modeConfigs` in an export. Merged by `id`: a mode in the file replaces the app's mode with the same id; modes only in the app stay. |
| `modeShortcuts` | `{ "<mode id>": <shortcut> }`, same as the export's `modeShortcuts`. Ids not in `modes` are ignored. A shortcut (here and in `general`) can be written as `{ "shortcut": "cmd+shift+space" }`: modifiers `cmd` `shift` `opt` `ctrl` `fn`, keys by US-layout name (`a`, `5`, `/`, `space`, `return`, `f13`, `left`…), or one modifier key alone like `right-opt` or `fn`. Yap writes both this and the raw `kind`/`keyCode`/`modifierFlagsRawValue` fields; the raw fields win when both are present. Mouse buttons and keys without a name are written as raw fields only. |
| `prompts` | Array of `{ id, title, promptText, useSystemInstructions }`. Merged by `id` like `modes`. |
| `dictionary` | `{ "vocabulary": ["Yap"], "replacements": { "yep": "Yap" } }`. Merged into the existing dictionary. |
| `general` | Same object as the export's `generalSettings`: global shortcuts, launch at login, recorder style, retention, paste and auto-learn settings. |
| `customModels` | Custom transcription model definitions, same objects as the export's `customCloudModels`, merged by `id`. `apiKey` is never written; a model synced from another Mac shows "API key needed" in Models until you add its key. |
| `customProviders` | Custom enhancement providers: `{ id, name, baseURL, models, selectedModel }`, merged by `id`. No key is ever written; a provider synced from another Mac shows "API key needed" in Models until you add its key. |
| `modified` | `{ "modes": { "<id>": "<ISO 8601 time>" }, "prompts": {…}, "vocabulary": { "<word>": … }, "replacements": { "<source>": … } }`: when each entry last changed. Written by Yap; you don't need to edit it. |
| `deleted` | Same shape: tombstones for deleted entries. An entry is removed (from the file and from the app) when its tombstone is newer than its `modified` time, or it has none. Tombstones older than 90 days are dropped. |

v2 sections apply first, then the v1 fields on top, so `enhancement.prompt` and `defaultMode` win over the same settings inside `modes`. Empty arrays and objects count as unset.

### Writing your settings to the file

**Write Current Settings to Config** saves the app's current settings as a v2 file. The previous file is kept as `config.json.bak`. Reading the written file back changes nothing.

- `keys` keeps only `env:NAME` references that were already in the file. A literal key is never written, so it disappears from the file; the keychain still has it.
- `defaultMode` and `enhancement.enabled` are dropped because `modes` carries them. `transcription` and `enhancement` stay only while they match the modes.

Turn on **Keep Config File in Sync** (off by default) to do this automatically about 2 seconds after any settings change.

### Syncing between Macs

1. Sign in to Yap Cloud on each Mac (see above).
2. Turn on **Sync via Yap Cloud**. Yap also offers this once, right after you first sign in.

From then on Yap pulls the synced settings at launch, when you switch back to Yap, when the Mac wakes from sleep and every 15 minutes, and pushes local changes a couple of seconds after you make them. A pull that finds nothing new changes nothing. If two Macs changed settings at the same time, Yap merges them by entry: each Mac keeps the modes, prompts, shortcuts and dictionary entries it changed. If they still can't be merged, the section shows the conflict with **Use Cloud Version** and **Keep This Mac's Settings**; nothing is overwritten until you choose. A network or server error shows its reason and **Retry** instead.

If your config's `enhancement.prompt` points to a file such as `prompt.md`, the cloud gets the file's text, because other Macs don't have that file. A Mac whose own config also points to a prompt file writes the text into that file (keeping the old one as `prompt.md.bak`); otherwise the text goes into its config.json.

### Setting up a new Mac

1. On the first onboarding screen, click **Sign In and Restore Settings** and sign in with the same email.
2. Check the summary (number of modes, prompts, dictionary entries and shortcuts) and click **Restore**. Yap applies the settings, writes config.json and turns on **Sync via Yap Cloud**.
3. Grant the permissions and pick a microphone as usual. If the restored settings already choose a transcription model, onboarding skips the model and practice steps.
4. If a provider in your settings needs an API key that this Mac doesn't have yet, the key step appears with that provider already selected. Paste the key to continue. Yap Cloud needs no key once you're signed in.

If the account hasn't synced any settings yet, the sheet says so and just leaves you signed in.

### Moving from VoiceInk

If VoiceInk has run on this Mac, **Import from VoiceInk…** in Config & Sync reads its modes, prompts, dictionary, shortcuts, general settings and custom model/provider definitions, shows how many of each it found, and imports them after you confirm. Entries with the same id replace Yap's; the rest of Yap's settings stay. API keys, the license, history and downloaded models are not copied; imported custom models and providers show **API key needed** until you add their keys. It only runs when you click it; on a Mac without VoiceInk the button is disabled.

### Deleted items

When you delete a mode, prompt, dictionary entry, custom model or custom provider, Yap records the deletion (in the `deleted` map) so the other Macs delete it too instead of bringing it back. If another Mac edited the same item after you deleted it, the edit wins and the item stays. Deletion records are kept for 90 days, then removed.

### API keys stay on each Mac

API keys are never written to config.json or sent to Yap Cloud. Yap only reads them from `keys` (as `env:NAME` or a literal you typed yourself). Custom models and custom enhancement providers sync without their keys and show **API key needed** in Models until you add the key on that Mac. The Yap Cloud sign-in token also stays on the Mac it belongs to.

### Recommended models

Current picks (Sept 2026, 11 code-switched clips / 82 key terms): transcription `microsoft/mai-transcribe-2` (80/82, $0.10/h), cleanup `deepseek/deepseek-v4.1-flash` (9/9 cases, ~0.5 s). Onboarding's "Your OpenRouter Key" option applies exactly this setup with your own OpenRouter key; usage is billed by OpenRouter. Re-run `setup/bench.py` after editing `VoiceInk/Resources/RecommendedPrompt.md`.

## Releasing

Before tagging, run `make cloud-smoke` (needs `YAP_CLOUD_SMOKE_TOKEN`; the command prints how to get one): it compiles the real Yap Cloud client against small stubs and checks it against live paygate — account, ledger paging, usage, models, config 409s, devices, the monthly cap (restored afterwards) and the 402s at a zero balance. It exits non-zero on any FAIL.

Push a tag `vX.Y.Z`. CI (`.github/workflows/release.yml`) builds on macOS 26, signs with the "Yap Self-Signed" certificate, publishes `Yap.zip` to GitHub Releases, then commits the new `appcast.xml` item (Sparkle EdDSA-signed) and the `Casks/yap.rb` version in one commit to `main`. Build numbers are `1000 + run number`. CI also builds every push to `main` and once a week, so caches stay warm in `main`'s scope: the whisper.cpp framework, the compiled Swift packages (mlx, FluidAudio, TranscribeCpp — the stable local-model modules), and Xcode 26's content-hashed compilation cache for the app's own sources (a fresh checkout doesn't force a full recompile). A release takes about 3–4 minutes; changing `Package.resolved` triggers one full rebuild (~14 minutes).

Because every release is signed with the same certificate, macOS keeps the Microphone and Accessibility permissions across updates. The app is not notarized; Homebrew and the install script remove the quarantine flag.

Secrets used by CI: `YAP_SIGNING_P12`, `YAP_SIGNING_PASSWORD`, `SPARKLE_ED_PRIVATE_KEY`.

---

