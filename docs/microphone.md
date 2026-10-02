# Which microphone Yap records from

Settings › Audio › Audio Input sets it. Dictation and a meeting's "Me" channel both use it (`AudioDeviceManager.resolveCurrentRecordingDevice`).

| Microphone Mode | What's used |
|---|---|
| Selected Microphone › System Default | The Mac's current default input, whatever it is (a virtual input too). Yap never changes the system default. |
| Selected Microphone › a device | That device, found by its UID, or by its model UID when the UID changed (it's then saved under the new UID). |
| Priority Order | The first device in the list that's connected. |

## When the chosen microphone isn't there

Yap falls back on its own only to an input with a physical transport. Core Audio's transport type decides:

- built-in, USB, Bluetooth, Thunderbolt, PCI, FireWire, HDMI, DisplayPort, Continuity (iPhone): allowed;
- virtual (BlackHole, Loopback, a meeting app's own device), aggregate and auto-aggregate (Yap's private system-audio tap during a meeting is one), unknown, or no answer: never.

The order among the allowed ones is unchanged: the built-in microphone first, or last when the lid is closed (it hears nothing then and isn't used). A virtual or aggregate input is still in the Microphone menu and the priority list, and once the user picks it, it's used like any other.

- **The fallback isn't a choice.** It's never saved. When the chosen device comes back, recording uses it again without being set again. Switching Microphone Mode to Selected Microphone with nothing chosen yet also only falls back (it used to save the first device in Core Audio's list, which could be a virtual input).
- **Nothing allowed is left.** Recording doesn't start. The notification says why and opens Audio Settings: "Your microphone isn't connected, and Yap doesn't switch to a virtual or aggregate input you haven't chosen. Choose a microphone in Audio Settings." With the lid closed and only the internal microphone left, it says to open the lid or connect an external microphone instead.
- **During a recording.** When the device in use goes away, the recording switches to the same fallback ("Switched to: …"), or stops getting audio and shows the same notification. A failed switch says so; it's never reported as switched.

Audio Settings says this under the microphone menu.

## Checked

`make mic-fallback-check` (no model, mock identity under the mock lock):

1. **Matrix.** `AudioDeviceManager(fixture:)` gets fixture devices in place of Core Audio's: MacBook Pro Microphone (built-in, internal), USB Microphone, BlackHole 2ch (virtual), "Yap system audio" (aggregate), a device without a transport, and AirPods. Each case lists them in an order that puts the unchosen input first, saves a mode and devices as the app does, and checks what's selected, what a recording would use, what stays saved, and what a recording gets when its device goes away.
2. **Smoke.** Lists this Mac's real input devices with their transport and whether Yap would fall back to each, then reports what the app would record from. Read only: nothing is recorded, and no setting outside the mock identity changes.

Before the change (2026-10-02, the same matrix), 9 of 19 cases picked an input nobody chose:
- BlackHole: with the lid closed next to a USB microphone, when nothing else was left, and mid-recording instead of AirPods;
- the aggregate;
- the unknown-transport device ahead of a USB microphone.

After the change, all 19 cases pass. On this Mac (one built-in microphone, `'bltn'`) the smoke picks the MacBook Pro Microphone both as the system default and as the fallback.

## Not covered

- **Not tried with real hardware:** no virtual driver is installed here, so BlackHole and Loopback were never seen by the real enumeration. Also untried: plugging devices in and out, closing the lid, and a meeting's tap aggregate showing up in Yap's own device list.
- **Transport only, not names.** A virtual driver that reports a physical transport is treated as physical.
- **Inputs that don't report a transport aren't fallbacks.** That includes real ones, which have to be chosen once.
- **A meeting that can't find a microphone** shows its own message ("No microphone is available for the meeting recording.").
