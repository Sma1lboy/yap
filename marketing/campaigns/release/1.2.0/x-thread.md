<!-- X thread, English. 6 posts, each under 280 characters (counted with the link as 23).
     Attach: 1 = 30 s demo video (marketing/visuals/demo-30s.md); 3 = home-en light screenshot; 4 = offline-check terminal output. -->

**1/**
Yap 1.2.0 is out: open-source dictation for Mac that handles Chinese and English in the same sentence.

Offline, on the local model, raw output:
"OAuth Refresh Token现在存在Local Storage里,有XSS风险,改成HTTP-only的Cookie"

github.com/Sma1lboy/yap

**2/**
Most dictation makes you pick one language. Speak both and you get the English words spelled out in Chinese characters, or half the sentence translated.

1.2.0 decodes each language stretch of a recording in its own language.

**3/**
We don't say "most accurate". We publish the test: 11 code-switched clips, 82 English terms and names, in the repo.

Recommended cloud model: 59/82
Local Whisper Turbo + your dictionary: 54/82

Rerun it: python3 setup/asr/bench.py score

**4/**
The Local option runs fully offline. That's checkable:

make offline-check

runs a dictation with all IP traffic denied (it must still return text), then logs the app's sockets during a second one. Zero connections on the default local model.

**5/**
Fix a word Yap got wrong and it can learn the fix: it reads the edited field through Accessibility (no keylogger), queues the correction, and in manual mode nothing enters your dictionary until you approve it.

**6/**
GPL-3.0, a fork of VoiceInk by Beingpax (credit stays in the README). Local model, your own API key, or an optional hosted service.

brew install --cask sma1lboy/yap/yap (after brew tap sma1lboy/yap https://github.com/Sma1lboy/yap)

yap.sma1lboy.me
