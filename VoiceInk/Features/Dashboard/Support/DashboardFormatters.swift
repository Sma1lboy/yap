import Foundation

enum Formatters {
    static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func formattedNumber(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func formattedCompactNumber(_ value: Int) -> String {
        guard value >= 1000 else {
            return "\(value)"
        }

        var divisor: Double = value >= 1_000_000 ? 1_000_000 : 1000
        var suffix = value >= 1_000_000 ? "M" : "K"
        let compactValue = Double(value) / divisor
        var roundedValue = (compactValue * 10).rounded() / 10

        if suffix == "K", roundedValue >= 1000 {
            divisor = 1_000_000
            suffix = "M"
            roundedValue = ((Double(value) / divisor) * 10).rounded() / 10
        }

        if roundedValue.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(roundedValue))\(suffix)"
        }

        return String(format: "%.1f%@", roundedValue, suffix)
    }

    static func formattedAxisValue(_ value: Int) -> String {
        value >= 1000 ? formattedCompactNumber(value) : "\(value)"
    }

    static func localizedHourFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter
    }

    /// "3 hr, 5 min", "3小时5分钟", "3 Std., 5 Min.": in the app's language, like the text around it, never a bare
    /// "5m" or "5分". Under a minute it's seconds ("27 sec"), so a few short dictations don't read as none.
    static func formattedCompactHoursAndMinutes(_ interval: TimeInterval) -> String {
        let hours = max(0, Int((interval / 60).rounded())) / 60
        if hours >= 1000 {
            return "\(formattedCompactNumber(hours)) h"
        }
        return durationFormatter(.short, for: interval).string(from: displayed(interval)) ?? "\(hours) h"
    }

    /// The same, written out for VoiceOver: "3 hours, 5 minutes".
    static func spokenHoursAndMinutes(_ interval: TimeInterval) -> String {
        durationFormatter(.full, for: interval).string(from: displayed(interval)) ?? formattedCompactHoursAndMinutes(interval)
    }

    /// Whole minutes, or whole seconds between 1 and 59; nothing at all reads "0 min".
    private static func displayed(_ interval: TimeInterval) -> TimeInterval {
        let interval = max(0, interval)
        return inSeconds(interval) ? interval.rounded() : (interval / 60).rounded() * 60
    }

    private static func inSeconds(_ interval: TimeInterval) -> Bool { (1..<60).contains(interval.rounded()) }

    private static func durationFormatter(_ style: DateComponentsFormatter.UnitsStyle, for interval: TimeInterval)
        -> DateComponentsFormatter
    {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = style
        formatter.allowedUnits = inSeconds(max(0, interval)) ? [.second] : [.hour, .minute]
        var calendar = Calendar.current
        calendar.locale = TranscriptionLanguageSupport.appLocale
        formatter.calendar = calendar
        return formatter
    }

    static func formattedSavedTime(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int((interval / 60).rounded()))
        let hours = totalMinutes / 60

        guard hours >= 1000 else {
            return formattedCompactHoursAndMinutes(interval)
        }

        return "\(formattedCompactNumber(hours)) \(String(localized: "hours"))"
    }

    static func roundedChartMaximum(for value: Int) -> Int {
        guard value > 0 else {
            return 1000
        }

        let target = Double(value) * 1.12
        let magnitude = pow(10, floor(log10(target)))
        let normalized = target / magnitude
        let step: Double

        switch normalized {
        case ...1:
            step = 1
        case ...2:
            step = 2
        case ...5:
            step = 5
        default:
            step = 10
        }

        return Int(step * magnitude)
    }

    static func formattedDuration(
        _ interval: TimeInterval, style: DateComponentsFormatter.UnitsStyle, fallback: String = "-"
    ) -> String {
        guard interval > 0 else { return fallback }
        let formatter = DateComponentsFormatter()
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = style
        formatter.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: interval) ?? fallback
    }

    static func formattedPreciseDuration(_ interval: TimeInterval, fallback: String = "-") -> String {
        guard interval > 0 else {
            return fallback
        }

        let roundedTenths = Int((interval * 10).rounded())

        if roundedTenths < 600 {
            return String(format: "%.1f sec", Double(roundedTenths) / 10)
        }

        if roundedTenths < 36_000 {
            let minutes = roundedTenths / 600
            let seconds = Double(roundedTenths % 600) / 10
            return "\(minutes)m \(String(format: "%.1f", seconds))s"
        }

        let totalMinutes = roundedTenths / 600
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours)h \(minutes)m"
    }
}
