#!/bin/bash
# make lifecycle-check MODEL=<ggml-*.bin> MODEL2=<another ggml-*.bin> [SUITES="whisper residency tcpp fluid"]:
# cancelling, releasing and quitting with local models in use (LifecycleCheck.swift). The Debug app re-identified as
# me.sma1lboy.yap.mock as a fresh install (scripts/meeting-check-common.sh), one launch per suite:
# - whisper: MODEL; speech detection a piece at a time against one whisper.cpp call; cancel a request waiting for its
#   turn, one decoding, one in speech detection (the ~22 min clip), one waiting for its load, a dictation and an audio
#   import; whatever comes next must come out as alone, and each cancel must stop within 2 s. A dictation queued
#   behind speech detection says what it waits for. Then the live preview's final text, alone and with a request for
#   MODEL2 in the middle of the recording, and the long clip alone again (against the start: the Mac slowing down).
# - residency: MODEL; "Keep model loaded" Always / 5 s / After each against a live-preview final, an import, a
#   meeting, the wake prewarm and a cancelled request; a memory-pressure warning during a meeting.
# - tcpp: transcribe.cpp SenseVoice Small (TCPP_MODEL, default /tmp/yap-test-models/SenseVoiceSmall-Q8_0.gguf, from
#   the catalog's URL; checked against its size and SHA-256); - fluid: FluidAudio Nemotron Multilingual, downloaded
#   once by the app itself into FLUID_DIR (default /tmp/yap-test-models/fluidaudio, never the shared FluidAudio
#   folder; VAD off, since FluidAudio's VAD has no folder setting). Both: the clip in Chinese and an English one alone
#   and together, a release during a decode, cancelling, then Quit through NSApplication.terminate during a
#   transcription.
# Speaker models for the meetings are downloaded once into SPEAKER_CACHE (default /tmp/yap-speaker-models, shared with
# isolation-check) and copied in for later runs. Results stay in $OUT (default /tmp/yap-lifecycle-check).
set -euo pipefail

APP_DIR="$1"
MODEL="${2:?usage: lifecycle-check.sh <app dir> <ggml-*.bin> <another ggml-*.bin>}"
MODEL2="${3:?usage: lifecycle-check.sh <app dir> <ggml-*.bin> <another ggml-*.bin>}"
SUITES="${SUITES:-whisper residency tcpp fluid}"
TCPP_MODEL="${TCPP_MODEL:-/tmp/yap-test-models/SenseVoiceSmall-Q8_0.gguf}"
FLUID_DIR="${FLUID_DIR:-/tmp/yap-test-models/fluidaudio}"
SPEAKER_CACHE="${SPEAKER_CACHE:-/tmp/yap-speaker-models}"
NOTES=""
OUT="${OUT:-/tmp/yap-lifecycle-check}"
WORK="$OUT/work"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
mkdir -p "$OUT"
source "$(dirname "$0")/meeting-check-common.sh"

# The clips: Chinese (the mode's language), English, all the Chinese ones as one 65 s file, and that file LONG_REPEAT
# times over (default 20, ~22 min) for the backends that get through 65 s in well under a second.
say -v Samantha -r 200 -o "$WORK/clips/english.aiff" \
	"Please move the release review to Thursday afternoon and send the updated checklist to the whole team."
afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/clips/english.aiff" "$WORK/clips/english.wav"
python3 - "$WORK" "${LONG_REPEAT:-20}" <<'PY'
import glob, sys, wave
work = sys.argv[1]
def frames(name):
    with wave.open(f"{work}/clips/{name}.wav") as w:
        return w.readframes(w.getnframes())
silence = lambda seconds: b"\0\0" * int(16000 * seconds)
names = ["bug", "deploy", "email", "frontend", "infra", "meeting", "ml", "perf", "product", "security", "standup"]
with wave.open(f"{work}/long.wav", "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(b"".join(frames(n) for n in names))
with wave.open(f"{work}/longer.wav", "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(b"".join(frames(n) for n in names) * int(sys.argv[2]))
mic, system = b"", b""
for me_clip, other_clip in [("deploy", "standup"), ("bug", "infra"), ("perf", "ml"), ("meeting", "product")]:
    a, b = frames(me_clip), frames(other_clip)
    mic += a + silence(1) + silence(len(b) / 32000) + silence(1)
    system += silence(len(a) / 32000) + silence(1) + b + silence(1)
for name, data in [("mic", mic), ("system", system)]:
    with wave.open(f"{work}/{name}.wav", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(data)
PY
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

# prepare <model name> <language>: a fresh mock install whose mode uses that model.
prepare() {
	cleanup
	mkdir -p "$SUPPORT/WhisperModels"
	for file in "$MODEL" "$MODEL2"; do cp -c "$file" "$SUPPORT/WhisperModels/" 2>/dev/null || cp "$file" "$SUPPORT/WhisperModels/"; done
	restore_speaker_models
	defaults write "$ID" hasCompletedOnboardingV2 -bool true
	defaults write "$ID" lastLaunchedVersion "$version"
	defaults write "$ID" ModelKeepLoadedSeconds -int 0
	cat >"$WORK/config/yap/config.json" <<EOF
{ "modes": [ { "id": "0FF11E00-0000-4000-8000-000000000003", "name": "Lifecycle check", "isDefault": true,
    "selectedTranscriptionModelName": "$1", "selectedLanguage": "$2", "isAIEnhancementEnabled": false,
    "useClipboardContext": false, "useSelectedTextContext": false, "useScreenCapture": false } ] }
EOF
}

# launch <output> <app arguments…>: runs the app until it exits; prints its exit status.
launch() {
	local out="$1"
	shift
	touch "$out.started"
	local status=0
	XDG_CONFIG_HOME="$WORK/config" "$APP/Contents/MacOS/VoiceInk Dev" --dictate-file "$WORK/clips/security.wav" "$@" \
		--meeting-speaker-wait 0 >"$out" 2>"$out.err" || status=$?
	save_speaker_models "$out.err"
	echo "$status"
}
files=("$WORK/long.wav" "$WORK/clips/english.wav" "$WORK/mic.wav" "$WORK/system.wav")
backend_files=("$WORK/longer.wav" "$WORK/clips/english.wav" "$WORK/mic.wav" "$WORK/system.wav")

# machine_state <file>: what else the Mac was doing (written before and after each suite next to its output).
machine_state() {
	{
		date '+%F %T'
		git -C "$ROOT" rev-parse HEAD
		uptime
		pmset -g therm
		sysctl vm.swapusage
		vm_stat
		top -l 1 -n 12 -o cpu -stats pid,command,cpu,threads,state
	} >"$1" 2>&1
}

failed=0
for suite in $SUITES; do
	out="$OUT/$suite.txt"
	machine_state "$out.before"
	case "$suite" in
	whisper | residency)
		prepare "$(basename "$MODEL" .bin)" zh
		defaults write "$ID" PrewarmModelOnWake -bool true
		extra=()
		[ "$suite" = whisper ] && extra=("$WORK/longer.wav")
		status=$(launch "$out" --lifecycle-check "$suite" "${files[@]}" ${extra[@]+"${extra[@]}"})
		;;
	tcpp)
		size=$(stat -f %z "$TCPP_MODEL")
		sum=$(shasum -a 256 "$TCPP_MODEL" | cut -d' ' -f1)
		[ "$size" = 252684608 ] && [ "$sum" = 6c759ee4c9748c9b3f7a5a60ca74f0f7e685fb9d45d1378fce7cfd62f59adf29 ] \
			|| { echo "FAIL: $TCPP_MODEL isn't the catalog's SenseVoice Small ($size bytes, $sum)"; failed=1; continue; }
		prepare sensevoice-small zh
		mkdir -p "$SUPPORT/TranscribeCpp/sensevoice-small"
		cp -c "$TCPP_MODEL" "$SUPPORT/TranscribeCpp/sensevoice-small/"
		echo "$sum" >"$SUPPORT/TranscribeCpp/sensevoice-small/.SenseVoiceSmall-Q8_0.gguf.sha256"
		status=$(launch "$out" --lifecycle-check backend "${backend_files[@]}")
		;;
	fluid)
		prepare nemotron-multilingual-0.6b zh-CN
		defaults write "$ID" IsVADEnabled -bool false
		mkdir -p "$FLUID_DIR"
		if [ ! -f "$FLUID_DIR/.downloaded" ]; then
			avail=$(df -k / | awk 'NR==2 { print int($4 / 1048576) }')
			[ "$avail" -ge 17 ] || { echo "FAIL: only ${avail} GB free; not downloading Nemotron (~0.7 GB)"; failed=1; continue; }
			status=$(launch "$OUT/fluid-download.txt" --fluidaudio-models "$FLUID_DIR" \
				--lifecycle-check download nemotron-multilingual-0.6b)
			grep -q '"event":"downloaded"' "$OUT/fluid-download.txt" || { echo "FAIL: Nemotron download"; tail -3 "$OUT/fluid-download.txt"; failed=1; continue; }
			touch "$FLUID_DIR/.downloaded"
			prepare nemotron-multilingual-0.6b zh-CN
			defaults write "$ID" IsVADEnabled -bool false
		fi
		du -sh "$FLUID_DIR" | sed 's/^/fluid models: /'
		status=$(launch "$out" --fluidaudio-models "$FLUID_DIR" --lifecycle-check backend "${backend_files[@]}")
		;;
	*) echo "unknown suite $suite"; failed=1; continue ;;
	esac
	machine_state "$out.after"
	echo "$suite: $(speaker_models_source "$out.err")"
	crash=$(find "$REPORTS" -name 'VoiceInk Dev-*.ips' -newer "$out.started" 2>/dev/null | head -1 || true)
	[ -n "$crash" ] && cp "$crash" "$OUT/"
	python3 "$(dirname "$0")/lifecycle-check.py" "$suite" "$out" "$status" "${crash:-}" || failed=1
done
exit $failed
