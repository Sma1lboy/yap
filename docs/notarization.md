# Notarization: where Yap stands and what switching would take

Research only; nothing here has been changed. The decision is Jackson's.

## Today

- Every release is signed in CI with a self-signed certificate, "Yap Self-Signed" (`.github/workflows/release.yml`: build ad-hoc, then `codesign --force --deep --preserve-metadata=entitlements,runtime --sign "Yap Self-Signed"`). The installed app's designated requirement is `identifier "me.sma1lboy.yap" and certificate root = H"9e41dec1…"`. Because every release has the same certificate, macOS keeps Microphone and Accessibility permissions across updates.
- The app is **not notarized**. What users see depends on how they install:
  - **Homebrew** (`Casks/yap.rb`) and **`setup/install.sh`** remove the quarantine flag, so Gatekeeper never checks the app. The cask does it in `postflight` with `xattr -dr com.apple.quarantine`.
  - **Downloading `Yap.zip` in a browser** (GitHub Releases) keeps quarantine. On first open macOS refuses ("Apple could not verify 'Yap' is free of malware…"). Since macOS 15, Control-click → Open no longer bypasses this: the user has to go to System Settings → Privacy & Security → Open Anyway and confirm with a password.
  - **Sparkle updates** are unaffected (verified with the EdDSA key in `SUPublicEDKey`; Sparkle installs without quarantine).
- Homebrew no longer wants to help bypass Gatekeeper: the official cask tap disables casks that fail Gatekeeper from 2026-09-01, and `--no-quarantine` is deprecated ([discussion #6482](https://github.com/orgs/Homebrew/discussions/6482), [Homebrew 5.0](https://workbrew.com/blog/homebrew-5-0-0)). Yap is in its own tap (`sma1lboy/yap`), so it isn't removed, but it can't move to the official tap unsigned. Its `postflight` quarantine removal goes against that direction and could stop working in a future Homebrew.

## What switching to Developer ID + notarization needs

1. **Apple Developer Program**, individual: US$99 a year. Enrollment needs an Apple Account with two-factor authentication and identity verification, usually a day or two.
2. **A "Developer ID Application" certificate**, created in the developer account (Certificates → +, or Xcode → Settings → Accounts → Manage Certificates). Export it with its private key as `.p12`. Only the Account Holder can create Developer ID certificates.
3. **Signing changes in CI**, still no Xcode-managed signing:
   - Import the Developer ID `.p12` instead of the self-signed one. Drop the steps that trust the self-signed certificate in the System keychain; they aren't needed for an Apple-issued certificate.
   - Sign the nested code inside-out rather than with `--deep` (Sparkle's `Autoupdate`, `Updater.app`, `Downloader.xpc`, `Installer.xpc`, `VoiceInkRefineXPC.xpc`, `whisper.framework`, `CTranscribe.framework`, `MediaRemoteAdapter.framework`, then `Yap.app`: the full list in today's bundle), each with `--options runtime --timestamp` and its own entitlements. Notarization requires hardened runtime and a secure timestamp on every executable, and no `get-task-allow`.
   - The current entitlements are compatible with notarization; `com.apple.security.cs.disable-library-validation` is an allowed hardened-runtime exception.
4. **Notarize and staple** after signing: `xcrun notarytool submit Yap.zip --key AuthKey.p8 --key-id … --issuer … --wait`, then `xcrun stapler staple Yap.app`, then zip again. This adds a few minutes to a release, mostly waiting for Apple.
5. **CI secrets**:
   - replace `YAP_SIGNING_P12` / `YAP_SIGNING_PASSWORD` with the Developer ID `.p12` and its password (e.g. `DEVELOPER_ID_P12`, `DEVELOPER_ID_PASSWORD`);
   - add an App Store Connect API key for notarytool (`NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`), created under Users and Access → Integrations → App Store Connect API. An Apple ID + app-specific password + team id also works but is weaker.
   - `SPARKLE_ED_PRIVATE_KEY` stays the same.
6. **Afterwards**: `install.sh` and the cask can stop removing quarantine, the README's "not notarized" paragraph goes, and a browser download opens with the normal "downloaded from the internet" prompt.

## Impact on existing users

- **Updates keep working through Sparkle.** Sparkle allows an update to change *either* the Apple code-signing certificate *or* the EdDSA key, not both ([Sparkle docs](https://sparkle-project.org/documentation/)). Keep the EdDSA key and change only the certificate, and 1.x users update in-app as usual. Never rotate both in one release.
- **Microphone and Accessibility have to be granted again, once.** macOS stores these permissions (TCC) against the app's designated requirement. It changes from "certificate root = the self-signed certificate" to Apple's Developer ID requirement (anchor apple generic + team id), so the old grants no longer match:
  - Microphone asks again on the next recording.
  - Accessibility still *looks* on in System Settings but doesn't work until the old entry is removed or toggled and Yap is allowed again.
  - Screen recording is the same, if used.
  - The update's release notes, and ideally a one-time in-app hint, should say so.
- **Keychain items ask once.** Release builds keep API keys and the Yap Cloud token in the login keychain, with access tied to the app's signature. After the switch macOS asks "Yap wants to use your confidential information stored in … in your keychain" once per item; "Always Allow" ends it. Settings, modes and history are in UserDefaults and files and aren't affected.
- **After that, it stays stable.** A Developer ID requirement is tied to the team id, not to one certificate, so renewing the certificate (every 5 years) doesn't reset permissions again. The self-signed setup can't offer that if its certificate ever has to be replaced.
- **Optional, later:** with a paid team, the non-`LOCAL_BUILD` configuration (data-protection keychain, iCloud dictionary sync) becomes possible. It needs provisioning profiles, and it's a separate decision.

## Recommendation for the decision

The cost is small (US$99 a year plus about half a day of CI work and a test update from a self-signed build to a Developer ID build). What it buys:
- Browser downloads open normally.
- A path into the official Homebrew tap.
- Future-proofing against quarantine removal being blocked.

The one-time cost to users is re-granting Microphone and Accessibility, and a keychain prompt. The least painful time to do it is the release that already asks users to do something, or before the user base grows.

To verify before switching, on a spare Mac or user account: install the current self-signed release, grant permissions, update through Sparkle to a Developer-ID-signed test build served from a test appcast, and note exactly which prompts appear.
