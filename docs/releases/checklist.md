# Release checklist

Run before pushing a `vX.Y.Z` tag. One line per check; note failures in the release PR/issue.

- [ ] `make cloud-smoke` passes against production paygate (`YAP_CLOUD_SMOKE_TOKEN` set; the script prints how to get one).
- [ ] `make local` builds, and `~/Downloads/Yap.app` launches on a clean macOS user account (a separate test user, so your own settings stay intact).
- [ ] Onboarding, Yap Cloud path: new email, code sign-in, $1 credit shown, first practice dictation pastes text, 6 screens with one microphone.
- [ ] Onboarding, Your OpenRouter Key path: paste a key, Continue verifies it, first practice dictation pastes text.
- [ ] Onboarding, Set It Up Later: finishing leaves a Dictation mode and Right Option; pressing it explains what to set up.
- [ ] Onboarding on a second Mac: "Sign In and Restore Settings" restores modes/prompts/dictionary/shortcuts and turns on sync.
- [ ] Account top-up (only once the production Stripe keys are configured): Add Funds opens Checkout, paying returns to Yap, balance updates, receipt link opens.
- [ ] Account: monthly cap save/clear, This Month card, Signed-in Devices list and remote sign-out, Sign Out confirmation.
- [ ] Yap Cloud errors: at $0 recording is blocked with Add Funds; offline shows the unavailable banner and recovers when back online.
- [ ] Config & Sync: edit a mode on Mac A, it appears on Mac B; delete one, it stays deleted; Version History lists and restores a version.
- [ ] Permissions: revoke Microphone and Accessibility in System Settings; recording and pasting show the right message with Open Settings.
- [ ] VoiceOver pass on a real Mac (#69): sidebar, Home, Modes, Dictionary, Models, Audio, Settings, Account, onboarding.
- [ ] Light and dark mode: Home, Account, Settings, onboarding, recorder, notifications, menu bar icon.
- [ ] Languages: switch the app to 简体中文, Deutsch and Français and skim onboarding, Account and Settings for English leftovers or clipped text.
- [ ] Update path: install the previous release, update in-app through Sparkle, settings and permissions survive.
- [ ] Release notes: `docs/releases/X.Y.Z.md` is final and matches what ships.
