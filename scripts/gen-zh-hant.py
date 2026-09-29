#!/usr/bin/env python3
"""Fill zh-Hant in the .xcstrings catalogs from zh-Hans: ICU Hans-Hant (through `swift`), then Taiwan UI terms.

Only adds zh-Hant entries that are missing (or every one with --all); hand-fixed entries stay.
Run from the repo root: python3 scripts/gen-zh-hant.py [--all]. scripts/check-i18n.py verifies the result.
"""
import json, re, subprocess, sys, tempfile, os

FILES = ["VoiceInk/Localizable.xcstrings", "VoiceInk/InfoPlist.xcstrings"]

# Applied to the ICU output. Mainland word -> Taiwan word (ICU already turned the characters into Hant).
TERMS = {
    "設置": "設定", "文件夾": "資料夾", "文件": "檔案", "屏幕": "螢幕", "網絡": "網路", "消息": "訊息", "信息": "資訊",
    "軟件": "軟體", "默認": "預設", "視頻": "影片", "音頻": "音訊", "服務器": "伺服器", "登錄": "登入", "注銷": "登出",
    "數據庫": "資料庫", "數據": "資料", "內存": "記憶體", "剪貼板": "剪貼簿", "打印": "列印", "保存": "儲存", "存儲": "儲存",
    "帳戶": "帳號", "賬戶": "帳號", "賬號": "帳號", "詞典": "字典", "應用程序": "應用程式", "程序": "程式", "用戶": "使用者",
    "質量": "品質", "支持": "支援", "兼容": "相容", "優化": "最佳化", "界面": "介面", "接口": "介面", "鼠標": "滑鼠",
    "硬盤": "硬碟", "磁盤": "磁碟", "通過": "透過", "運行": "執行", "鏈接": "連結", "郵箱": "信箱", "字符": "字元",
    "緩存": "快取", "調試": "除錯", "日誌": "記錄", "設備": "裝置", "導出": "匯出", "導入": "匯入", "快捷鍵": "快速鍵",
    "熱鍵": "快速鍵", "粘貼": "貼上", "拷貝": "複製", "搜索": "搜尋", "視圖": "檢視", "菜單": "選單", "窗口": "視窗",
    "光標": "游標", "文本": "文字", "高級": "進階", "常規": "一般", "內置": "內建", "令牌": "Token", "許可證": "授權", "提供商": "供應商", "雙擊": "按兩下", "全局": "全域",
    "實時": "即時", "恢復": "復原", "重置": "重設", "禁用": "停用", "激活": "啟用", "卸載": "解除安裝", "加載": "載入",
    "打開": "開啟", "充值": "儲值", "模塊": "模組", "文檔": "文件", "示例": "範例", "自定義": "自訂", "批量": "批次",
    "重啟": "重新啟動", "密鑰": "金鑰", "添加": "新增", "創建": "建立", "超時": "逾時", "配置": "設定", "替換": "取代",
    "轉寫": "轉錄", "錄制": "錄製", "啓": "啟", "連接": "連線", "刷新": "重新整理", "訪問": "存取", "響應": "回應",
    "性能": "效能", "模板": "範本", "檢測": "偵測", "智能": "智慧", "代碼": "程式碼", "匹配": "比對", "發送": "傳送",
    "獲取": "取得", "流式": "串流", "助手": "助理", "條目": "項目", "生成": "產生", "跳過": "略過",
    "圖標": "圖示", "程序塢": "Dock", "程式塢": "Dock", "檔案里": "檔案裡", "應用里": "應用裡", "這里": "這裡",
    "字段": "欄位", "自帶": "內建", "識別": "辨識", "當前": "目前", "服務商": "供應商",
}
PUNCT = {"“": "「", "”": "」"}

SWIFT = """import Foundation
let a = try! JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String]
let t = StringTransform(rawValue: "Hans-Hant")
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: a.map { $0.applyingTransform(t, reverse: false) ?? $0 }))
"""


def icu(strings):
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "t.swift")
        open(src, "w").write(SWIFT)
        r = subprocess.run(["swift", src], input=json.dumps(strings).encode(), capture_output=True, check=True)
    return json.loads(r.stdout)


def taiwan(s):
    for k in sorted(TERMS, key=len, reverse=True):
        s = s.replace(k, TERMS[k])
    s = re.sub(r"(?<![公英千萬])里(?!程)", "裡", s)  # ICU leaves the "inside" 里 as is
    for k, v in PUNCT.items():
        s = s.replace(k, v)
    return s


def units(loc):
    """Every stringUnit inside one localization (plain value or plural/device variations)."""
    if "stringUnit" in loc:
        yield loc["stringUnit"]
    for kind in loc.get("variations", {}).values():
        for v in kind.values():
            yield from units(v)


def main():
    force = "--all" in sys.argv
    for f in FILES:
        d = json.load(open(f))
        sorted_before = all(list(e.get("localizations", {})) == sorted(e.get("localizations", {})) for e in d["strings"].values())
        todo = []
        for entry in d["strings"].values():
            loc = entry.get("localizations", {})
            if "zh-Hans" not in loc or ("zh-Hant" in loc and not force):
                continue
            loc["zh-Hant"] = json.loads(json.dumps(loc["zh-Hans"]))
            todo += list(units(loc["zh-Hant"]))
        for u, v in zip(todo, icu([u["value"] for u in todo])):
            u["value"], u["state"] = taiwan(v), "translated"
        if sorted_before:  # Xcode keeps language codes sorted
            for entry in d["strings"].values():
                if "localizations" in entry:
                    entry["localizations"] = dict(sorted(entry["localizations"].items()))
        open(f, "w").write(json.dumps(d, ensure_ascii=False, indent=2, separators=(",", " : ")))
        print(f, "converted", len(todo), "strings")


main()
