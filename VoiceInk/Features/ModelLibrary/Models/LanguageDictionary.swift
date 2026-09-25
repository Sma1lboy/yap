import Foundation

enum TranscriptionLanguageSupport {
    static func languages(for model: any TranscriptionModel, realtimeEnabled: Bool? = nil) -> [String: String] {
        model.supportedLanguages
    }

    static func validLanguageOrFallback(
        _ language: String?, for model: any TranscriptionModel, realtimeEnabled: Bool? = nil
    ) -> String {
        let languages = languages(for: model, realtimeEnabled: realtimeEnabled)

        if let language, languages[language] != nil {
            return language
        }

        if languages["auto"] != nil {
            return "auto"
        }

        if languages["en-US"] != nil {
            return "en-US"
        }

        if languages["en"] != nil {
            return "en"
        }

        return languages.keys.sorted { lhs, rhs in
            languages[lhs, default: lhs] < languages[rhs, default: rhs]
        }.first ?? "en"
    }

}

enum LanguageDictionary {
    static func forProvider(isMultilingual: Bool, provider: ModelProvider = .custom) -> [String: String] {
        if !isMultilingual {
            return ["en": "English"]
        }

        if let cloudProvider = CloudProviderRegistry.provider(for: provider) {
            guard let codes = cloudProvider.languageCodes else {
                return all
            }
            return forCodes(codes, includesAutoDetect: cloudProvider.includesAutoDetect)
        }

        return all
    }

    static func forCodes(_ codes: [String], includesAutoDetect: Bool = false) -> [String: String] {
        var filtered = all.filter { codes.contains($0.key) }
        if includesAutoDetect { filtered["auto"] = "Auto-detect" }
        return filtered
    }

    static let all: [String: String] = [
        "auto": "Auto-detect",
        "af": "Afrikaans",
        "af-ZA": "Afrikaans (South Africa)",
        "sq": "Albanian",
        "am": "Amharic",
        "am-ET": "Amharic (Ethiopia)",
        "ar": "Arabic",
        "ar-DZ": "Arabic (Algeria)",
        "ar-TD": "Arabic (Chad)",
        "ar-EG": "Arabic (Egypt)",
        "ar-IR": "Arabic (Iran)",
        "ar-IQ": "Arabic (Iraq)",
        "ar-JO": "Arabic (Jordan)",
        "ar-KW": "Arabic (Kuwait)",
        "ar-LB": "Arabic (Lebanon)",
        "ar-MA": "Arabic (Morocco)",
        "ar-PS": "Arabic (Palestine)",
        "ar-QA": "Arabic (Qatar)",
        "ar-SA": "Arabic (Saudi Arabia)",
        "ar-SD": "Arabic (Sudan)",
        "ar-SY": "Arabic (Syria)",
        "ar-TN": "Arabic (Tunisia)",
        "ar-AE": "Arabic (United Arab Emirates)",
        "rup-BG": "Aromanian (Bulgaria)",
        "hy": "Armenian",
        "hy-AM": "Armenian (Armenia)",
        "as": "Assamese",
        "as-IN": "Assamese (India)",
        "en_au": "Australian English",
        "az": "Azerbaijani",
        "az-AZ": "Azerbaijani (Azerbaijan)",
        "ba": "Bashkir",
        "eu": "Basque",
        "be": "Belarusian",
        "be-BY": "Belarusian (Belarus)",
        "bn": "Bengali",
        "bn-BD": "Bengali (Bangladesh)",
        "bn-IN": "Bengali (India)",
        "bs": "Bosnian",
        "bs-BA": "Bosnian (Bosnia and Herzegovina)",
        "br": "Breton",
        "en_uk": "British English",
        "bg": "Bulgarian",
        "bg-BG": "Bulgarian (Bulgaria)",
        "my-MM": "Burmese (Myanmar)",
        "yue": "Cantonese",
        "yue-Hant-HK": "Cantonese (Traditional, Hong Kong)",
        "ca": "Catalan",
        "ca-ES": "Catalan (Spain)",
        "ceb": "Cebuano",
        "zh": "Chinese",
        "zh-HK": "Chinese (Cantonese, Hong Kong)",
        "zh-CN": "Chinese (Simplified)",
        "zh-Hans": "Chinese (Simplified script)",
        "zh-Hant": "Chinese (Traditional script)",
        "zh-TW": "Chinese (Traditional, Taiwan)",
        "hr": "Croatian",
        "hr-HR": "Croatian (Croatia)",
        "cs": "Czech",
        "cs-CZ": "Czech (Czechia)",
        "da": "Danish",
        "da-DK": "Danish (Denmark)",
        "nl": "Dutch",
        "nl-NL": "Dutch (Netherlands)",
        "en": "English",
        "en-AU": "English (Australia)",
        "en-CA": "English (Canada)",
        "en-IN": "English (India)",
        "en-IE": "English (Ireland)",
        "en-NZ": "English (New Zealand)",
        "en-GB": "English (United Kingdom)",
        "en-US": "English (United States)",
        "et": "Estonian",
        "et-EE": "Estonian (Estonia)",
        "fo": "Faroese",
        "fa-IR": "Farsi (Iran)",
        "fil": "Filipino",
        "fil-PH": "Filipino (Philippines)",
        "fi": "Finnish",
        "fi-FI": "Finnish (Finland)",
        "nl-BE": "Flemish (Belgium)",
        "fr": "French",
        "fr-CA": "French (Canada)",
        "fr-FR": "French (France)",
        "gl": "Galician",
        "gl-ES": "Galician (Spain)",
        "ka": "Georgian",
        "ka-GE": "Georgian (Georgia)",
        "de": "German",
        "de-DE": "German (Germany)",
        "de-CH": "German (Switzerland)",
        "el": "Greek",
        "el-GR": "Greek (Greece)",
        "gu": "Gujarati",
        "gu-IN": "Gujarati (India)",
        "ht": "Haitian Creole",
        "ha": "Hausa",
        "ha-NG": "Hausa (Nigeria)",
        "haw": "Hawaiian",
        "he": "Hebrew",
        "he-IL": "Hebrew (Israel)",
        "hi": "Hindi",
        "hi-IN": "Hindi (India)",
        "hu": "Hungarian",
        "hu-HU": "Hungarian (Hungary)",
        "is": "Icelandic",
        "is-IS": "Icelandic (Iceland)",
        "ig": "Igbo",
        "id": "Indonesian",
        "id-ID": "Indonesian (Indonesia)",
        "ga": "Irish",
        "it": "Italian",
        "it-IT": "Italian (Italy)",
        "ja": "Japanese",
        "ja-JP": "Japanese (Japan)",
        "jw": "Javanese",
        "jv-ID": "Javanese (Indonesia)",
        "kea-CV": "Kabuverdianu (Cape Verde)",
        "kn": "Kannada",
        "kn-IN": "Kannada (India)",
        "kk": "Kazakh",
        "kk-KZ": "Kazakh (Kazakhstan)",
        "km": "Khmer",
        "km-KH": "Khmer (Cambodia)",
        "ko": "Korean",
        "ko-KR": "Korean (South Korea)",
        "ku": "Kurdish",
        "ky": "Kyrgyz",
        "ky-KG": "Kyrgyz (Kyrgyzstan)",
        "lo": "Lao",
        "la": "Latin",
        "lv": "Latvian",
        "lv-LV": "Latvian (Latvia)",
        "ln": "Lingala",
        "ln-CD": "Lingala (Congo)",
        "lt": "Lithuanian",
        "lt-LT": "Lithuanian (Lithuania)",
        "lb": "Luxembourgish",
        "mk": "Macedonian",
        "mk-MK": "Macedonian (North Macedonia)",
        "mg": "Malagasy",
        "ms": "Malay",
        "ms-MY": "Malay (Malaysia)",
        "ml": "Malayalam",
        "ml-IN": "Malayalam (India)",
        "mt": "Maltese",
        "mt-MT": "Maltese (Malta)",
        "cmn-Hans-CN": "Mandarin Chinese (Simplified)",
        "mi": "Maori",
        "mr": "Marathi",
        "mr-IN": "Marathi (India)",
        "mn": "Mongolian",
        "mn-MN": "Mongolian (Mongolia)",
        "my": "Myanmar",
        "ne": "Nepali",
        "ne-NP": "Nepali (Nepal)",
        "no": "Norwegian",
        "nb-NO": "Norwegian Bokmål (Norway)",
        "nn": "Norwegian Nynorsk",
        "oc": "Occitan",
        "or": "Odia",
        "or-IN": "Odia (India)",
        "ps": "Pashto",
        "fa": "Persian",
        "pl": "Polish",
        "pl-PL": "Polish (Poland)",
        "pt": "Portuguese",
        "pt-BR": "Portuguese (Brazil)",
        "pt-PT": "Portuguese (Portugal)",
        "pa": "Punjabi",
        "pa-Guru-IN": "Punjabi (Gurmukhi script)",
        "pa-IN": "Punjabi (India)",
        "ro": "Romanian",
        "ro-RO": "Romanian (Romania)",
        "ru": "Russian",
        "ru-RU": "Russian (Russia)",
        "sa": "Sanskrit",
        "sr": "Serbian",
        "sr-RS": "Serbian (Serbia)",
        "sn": "Shona",
        "sd": "Sindhi",
        "sd-Arab-IN": "Sindhi (Arabic script)",
        "si": "Sinhala",
        "sk": "Slovak",
        "sk-SK": "Slovak (Slovakia)",
        "sl": "Slovenian",
        "sl-SI": "Slovenian (Slovenia)",
        "so": "Somali",
        "es": "Spanish",
        "es-419": "Spanish (Latin America)",
        "es-US": "Spanish (United States)",
        "su": "Sundanese",
        "sw": "Swahili",
        "sw-KE": "Swahili (Kenya)",
        "sv": "Swedish",
        "sv-SE": "Swedish (Sweden)",
        "de_ch": "Swiss German",
        "tl": "Tagalog",
        "tg": "Tajik",
        "tg-TJ": "Tajik (Tajikistan)",
        "ta": "Tamil",
        "tt": "Tatar",
        "te": "Telugu",
        "te-IN": "Telugu (India)",
        "th": "Thai",
        "th-TH": "Thai (Thailand)",
        "bo": "Tibetan",
        "tr": "Turkish",
        "tr-TR": "Turkish (Turkey)",
        "tk": "Turkmen",
        "uk": "Ukrainian",
        "uk-UA": "Ukrainian (Ukraine)",
        "ur": "Urdu",
        "en_us": "US English",
        "uz": "Uzbek",
        "uz-UZ": "Uzbek (Uzbekistan)",
        "vi": "Vietnamese",
        "vi-VN": "Vietnamese (Vietnam)",
        "cy": "Welsh",
        "wo": "Wolof",
        "xh": "Xhosa",
        "yi": "Yiddish",
        "yo": "Yoruba",
        "zu": "Zulu",
    ]
}
