# Dictation backlog: assessed, not built

Upstream feature requests we read against our code. Each entry: what exists in Yap today, what the request would add, cost, and a verdict. Nothing here is implemented. (Upstream issues are only read. Never comment on them; see CLAUDE.md.)

## #910 Accessibility (AX) text as context, OCR as fallback

**Today.** Enhancement context has three optional sources per mode: selected text (`SelectedTextService` via SelectedTextKit; tries AX first, then the Copy menu item, then AppleScript), clipboard, and screen text (`ScreenCaptureService`: a ScreenCaptureKit screenshot of the focused window run through Vision OCR, under a timeout). Screen text needs the Screen Recording permission and sends whatever is visible on screen.

**The request.** Read the focused element through AX instead: app and window title, the text around the caret (`AXValue` + `AXSelectedTextRange`), maybe nearby labels. Bound it to ~3,000 characters, and fall back to OCR when AX exposes nothing (canvas UIs, images, PDFs, remote desktops).

**Assessment.**
- AX gives exact text: names, code identifiers and Chinese come back as typed, not as OCR guesses. It needs only the Accessibility permission Yap already requires for pasting, not Screen Recording. It runs in milliseconds instead of a capture plus an OCR pass.
- "Text around the caret" is the useful part for dictation: it is what the user is continuing. The window title adds little. The whole AX tree would be noise and a privacy problem.
- AX coverage varies. Native AppKit/SwiftUI text views work. Chrome and Electron apps expose a text tree only after `AXEnhancedUserInterface` / `AXManualAccessibility` is set on the app, which has side effects (slower in some apps). Terminals and custom-drawn editors expose little. So the OCR fallback stays.
- Cost: about 1–2 days. That covers a bounded caret-context reader (~150 lines next to `SelectedTextService`), wiring it as another `RecordingContextSnapshot` field and prompt block, the fallback rule, and checking it by hand in ~10 common apps (Notes, Mail, Slack, Chrome, VS Code, Cursor, Xcode, WeChat, Terminal, Notion). No UI beyond renaming the existing screen-context toggle.

**Verdict: worth doing, second priority.** Most accuracy per day of any context work, and it removes a permission and screen-content upload for the apps where it works. Do it after real-speech numbers exist from `setup/asr/recordings/`, so its effect on enhancement can be measured rather than guessed.

## #905 Left vs right Command / Option in shortcuts

**Today.** A single modifier pressed alone can already be side-specific: Right ⌘, Right ⌥, Right ⌃ and the left ones (`Shortcut.modifierOnly` with the physical key code; `left-cmd` / `right-cmd` in `config.json`). A combination is side-agnostic: ⌘⌥ or ⌥ + key matches either side, because `Shortcut` stores `NSEvent.ModifierFlags`, which have no left/right bits.

**The request.** Let a combination require one side, e.g. right ⌘ + right ⌥, so the left-hand ⌘⌥[ in an IDE stops triggering dictation.

**Assessment.**
- The reporter's case is partly served today: a single right-side modifier as the trigger avoids the clash.
- For side-specific combinations, the event tap would read the device-dependent bits in `CGEventFlags` (`NX_DEVICELCMDKEYMASK` / `NX_DEVICERCMDKEYMASK` and friends). `Shortcut` would need a side mask, stored in the Codable model and the config string (`right-cmd+right-opt`). The recorder would keep which physical keys were down, and the display and conflict checks would learn about it. Old shortcuts decode as side-agnostic, so no migration.
- Cost: about 1 day plus the recorder UI and a selfCheck for the matching rules.

**Verdict: low priority.** Useful but narrow: it matters only to people who trigger with a modifier combination rather than a single modifier or a key. Revisit if our own users ask. A cheaper step first: mention in the shortcut help that a single right-side modifier avoids clashes.

## #858 Hardware push-to-talk key and physical mode switch

**Today.** Everything the device needs exists if it presents itself as a keyboard (HID). Push to Talk: the recording shortcut in hold mode records while the key is down. Per-mode shortcuts (`ModeShortcutManager`) start recording in a specific mode, so a three-position switch that sends three different key codes (e.g. F17/F18/F19) selects Dictation / Rewrite / etc. explicitly. App Intents (`ToggleMiniRecorderIntent`, `DismissMiniRecorderIntent`) cover Shortcuts.app automation.

**The request.** A vendor (ReAI, AI-Board-01) offers key down/up and mode events through its own Rust crate or a local HTTP/WebSocket endpoint, plus its own audio stream, and asks whether the project wants an integration.

**Assessment.**
- A vendor-specific endpoint means a new always-on local listener, its security surface (any local process could start recordings), and code tied to one product's protocol, all for one device.
- Taking audio from the device is already possible: it's a microphone like any other in Audio Settings.
- If a missing capability shows up, the general fix beats a vendor one: an App Intent that starts or stops recording in a named mode (and so works from Shortcuts, Stream Deck, Raycast and hardware) is ~half a day.

**Verdict: don't build the integration.** Document that a hardware key works as a hold-to-talk shortcut and that per-mode shortcuts act as a mode switch. Add a "start recording in mode X" App Intent only when a user needs something that keys can't do.
