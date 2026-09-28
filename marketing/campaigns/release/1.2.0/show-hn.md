<!-- Hacker News. Title ≤ 80 chars, no superlatives (HN guidelines). Post URL = the GitHub repo, so the first
<!-- 第一人称是按 Jackson 的口吻起草的，发之前改成你自己的话。 -->     comment carries the text. Post from Jackson's account; stay in the thread for the first hours. -->

**Title:** Show HN: Yap – Open-source Mac dictation for mixed Chinese and English

**URL:** https://github.com/Sma1lboy/yap

**First comment:**

Hi HN, I made Yap, a fork of VoiceInk (GPL-3.0, credit to Beingpax in the README). Hold a key, talk, let go, and the text is pasted into whatever app has focus.

I switch between Chinese and English inside a sentence all day ("OAuth refresh token 现在存在 Local Storage 里"). Dictation tools I tried either want one language per session, write the English words phonetically in Chinese characters, or translate half the sentence. 1.2.0 fixes that in Whisper's decoding path: each language stretch of a recording is detected and decoded in its own language, and recordings over 30 s are split at silences found by VAD.

Two things I wanted to be checkable rather than claimed:

- Accuracy on code-switched speech. setup/asr has 11 clips with 82 English terms and names embedded in Chinese sentences. microsoft/mai-transcribe-2 (the recommended cloud setup) gets 59/82; the local default, Whisper Large v3 Turbo q5 (547 MB, 0.9 GB peak memory), gets 45/82, and 54/82 when the terms are in Yap's dictionary, which is passed to whisper as its initial prompt. That beats moving up to Large v3 (47/82). The clips are synthetic (macOS `say`), so treat the numbers as relative; one of the two voices mangles English and costs every engine about half its terms. `python3 setup/asr/bench.py score` reproduces the table.

- Offline. `make offline-check` runs a dictation through the real pipeline under a sandbox profile that denies all IP traffic, then runs a second one with the network allowed while polling the app's sockets with lsof every 0.2 s. With a local model and cleanup off, no connection opens. Cleanup (LLM rewrite) is off in the offline setup because the small local model I tested translated English terms into Chinese.

Other bits: settings live in ~/.config/yap/config.json with a JSON Schema; corrections you make after a paste can become dictionary rules (read through Accessibility, no key logging), and in manual mode each one waits for your approval. You can bring your own OpenRouter or other provider key, or use a hosted option I run (optional).

Honest caveats: builds are signed with a self-signed certificate but not notarized, so the zip needs one "Open Anyway" (Homebrew avoids it). macOS 15+ only. No real-speech benchmark yet; I'd like recordings from people who code-switch, and bug reports with transcripts that went wrong.
