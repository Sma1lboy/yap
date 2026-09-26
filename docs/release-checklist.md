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
- [ ] VoiceOver pass on a real Mac (#69): sidebar, Home, Modes, Dictionary, Models, Audio, Settings, the Yap Cloud page (Models › Cloud › Yap Cloud), onboarding.
- [ ] Light and dark mode: Home, the Yap Cloud page, Settings, onboarding, recorder, notifications, menu bar icon.
- [ ] Languages: switch the app to 简体中文, Deutsch and Français and skim onboarding, the Yap Cloud page and Settings for English leftovers or clipped text.
- [ ] Update path: install the previous release, update in-app through Sparkle, settings and permissions survive.
- [ ] Release notes: `docs/releases/X.Y.Z.md` is final and matches what ships.

### Window chrome (1.2.0: traffic lights in the sidebar, no title bar)

Run `make mock` (fake data, offline, its own settings; everything is removed when it quits). `make ui-snapshots` renders the layout but can't check what follows, which needs a real window and a mouse.

- [ ] Traffic lights: with the window in front, close/minimize/zoom sit at the sidebar's top-left, in color, not overlapping "Home"; hover shows their ×/−/+ glyphs; each works.
- [ ] No title bar strip: the page (Home's brand header, Modes, Models, the Yap Cloud page) starts right at the window's top edge; there's no empty band above it on the right.
- [ ] Drag from the sidebar: drag the empty space next to the traffic lights (above "Home"): the window moves; clicking there selects nothing.
- [ ] Drag from the page: drag the top ~16pt of Home, Modes, Models and the Yap Cloud page: the window moves; the header's buttons (Models' gear, Modes' +) still click and don't drag.
- [ ] Double-click the top of the sidebar and of a page: the window zooms (System Settings › Desktop & Dock › "Double-click a window's title bar to": set it to Minimize, repeat, the window minimizes; set it to Do Nothing, nothing happens).
- [ ] Full screen (green button or ⌃⌘F): the traffic lights hide and "Home" moves up to the top (no 28pt gap); moving the pointer to the top edge shows the menu bar without covering the first sidebar item; leaving full screen restores the gap under the traffic lights.
- [ ] Narrowest window: drag the window to its minimum width (900pt): sidebar items and traffic lights don't overlap, the page header isn't clipped.
- [ ] Onboarding window: Settings › Reset Onboarding (or a fresh `make mock` with onboarding not completed): traffic lights sit top-left over the onboarding background with no title bar strip, and dragging the top 28pt moves the window.

