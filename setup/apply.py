# 把选好的模型和 prompt 写进 Yap 的偏好设置。Yap 必须先退出，否则它退出时会把旧值写回去。
# 前提：已走完首次引导（引导会生成默认的三个模式）。
# 用法: python3 apply.py   （改了 prompt.md 或下面的模型后重跑即可）
import hashlib, json, os, plistlib, subprocess, uuid

DOMAIN = os.environ.get("YAP_DOMAIN", "me.sma1lboy.yap")
STT = "microsoft/mai-transcribe-2"   # 11 条中英混说 80/82，结果稳定，$0.10/h；备选 openai/gpt-4o-mini-transcribe
LLM = "deepseek/deepseek-v4.1-flash"   # 9 条三轮全对，p50 0.5s；备选 openai/gpt-6-luna
PROMPT_ID = "A1B2C3D4-0000-4000-8000-00000000C0DE"
HERE = os.path.dirname(os.path.abspath(__file__))

def stt_key(slug):  # 与 OpenRouterProvider.stableID 相同的算法
    return "OpenRouter:" + str(uuid.UUID(bytes=hashlib.sha256(f"OpenRouter:{slug}".encode()).digest()[:16])).upper()

tmp = "/tmp/voiceink-prefs.plist"
subprocess.run(["defaults", "export", DOMAIN, tmp], check=True)
prefs = plistlib.load(open(tmp, "rb"))
if "modeConfigurationsV2" not in prefs:
    raise SystemExit("还没走完首次引导：先打开 Yap 完成授权和快捷键设置，再重跑")

prompts = [p for p in json.loads(prefs.get("customPrompts", b"[]")) if p["id"] != PROMPT_ID]
prompts.insert(0, {"id": PROMPT_ID, "title": "中英整理", "useSystemInstructions": False,
                   "promptText": open(os.path.join(HERE, "prompt.md")).read()})
prefs["customPrompts"] = json.dumps(prompts, ensure_ascii=False).encode()

modes = json.loads(prefs["modeConfigurationsV2"])
for m in modes:
    m["selectedTranscriptionModelName"] = stt_key(STT)
    if m.get("isAIEnhancementEnabled") or m.get("isDefault"):
        m["selectedAIProvider"], m["selectedAIModel"] = "OpenRouter", LLM
    if m.get("isDefault"):  # 默认的 Dictation 模式：润色开、上下文全关（省延迟、不读屏）
        m.update(isAIEnhancementEnabled=True, selectedPrompt=PROMPT_ID, isTextFormattingEnabled=False,
                 useScreenCapture=False, useClipboardContext=False, useSelectedTextContext=False)
prefs["modeConfigurationsV2"] = json.dumps(modes, ensure_ascii=False).encode()
prefs["CurrentTranscriptionModel"] = stt_key(STT)
prefs["OpenRouterSelectedModel"] = LLM

plistlib.dump(prefs, open(tmp, "wb"))
subprocess.run(["defaults", "import", DOMAIN, tmp], check=True)
print("ok:", STT, LLM, [(m["name"], m.get("selectedAIModel"), m.get("isAIEnhancementEnabled")) for m in modes])
