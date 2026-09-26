import SwiftUI

struct DashboardPeakHoursCard: View {
    let summary: DashboardPeakHoursSummary
    var isLocked = false

    private var maxHourlyWords: Int {
        max(summary.hourlyActivity.map(\.wordCount).max() ?? 0, 1)
    }

    private var canShowPattern: Bool {
        !isLocked && summary.hasData
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x4) {
                header

                DashboardPeakHoursHistogram(
                    points: summary.hourlyActivity,
                    maxWords: maxHourlyWords,
                    peakStartHour: summary.startHour,
                    hasData: canShowPattern
                )
            }
            .blur(radius: isLocked ? 2 : 0)
            .opacity(isLocked ? 0.42 : 1)

            if isLocked {
                lockedOverlay
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(AppTheme.Spacing.x5)
        .frame(maxWidth: .infinity, minHeight: 196, maxHeight: 196, alignment: .topLeading)
        .background(DashboardInsightCardBackground(cornerRadius: AppTheme.Radius.panel))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Peak dictation hours")
        .accessibilityValue(accessibilityValue)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x3) {
            Text("Peak Dictation Hours")
                .font(AppTheme.font(.title3, .semibold, design: .rounded))
                .foregroundStyle(AppTheme.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.84)

            Spacer(minLength: 0)

            HStack(spacing: AppTheme.Spacing.x1) {
                Image(systemName: "clock")
                    .font(AppTheme.font(.footnote, .semibold))
                    .foregroundStyle(AppTheme.Text.secondary.opacity(0.78))

                Text(canShowPattern ? windowText : "--")
                    .font(AppTheme.font(.body, .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
        }
    }

    private var windowText: String {
        formattedHourRange(from: summary.startHour, to: summary.endHour)
    }

    private var accessibilityValue: String {
        if isLocked {
            return String(localized: "Continue using Yap to unlock peak hours.")
        }

        guard summary.hasData else {
            return String(localized: "No hourly pattern yet.")
        }

        return windowText
    }

    private var lockedOverlay: some View {
        VStack(spacing: AppTheme.Spacing.x2) {
            Image(systemName: "lock.fill")
                .font(AppTheme.font(.headline, .semibold))
                .foregroundStyle(AppTheme.Accent.text)
                .frame(width: 34, height: 34)
                .background(AppTheme.Accent.fill)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))

            Text("Continue using Yap to unlock peak hours.")
                .font(AppTheme.font(.body, .semibold))
                .foregroundStyle(AppTheme.Text.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 260)
        }
        .padding(.horizontal, AppTheme.Spacing.x5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func formattedHourRange(from startHour: Int, to endHour: Int) -> String {
        String(
            format: String(localized: "%@ to %@"),
            formattedHour(startHour),
            formattedHour(endHour)
        )
    }

    private func formattedHour(_ hour: Int) -> String {
        "\(displayHour(hour)) \(hourSuffix(hour))"
    }

    private func displayHour(_ hour: Int) -> Int {
        let hour = ((hour % 24) + 24) % 24
        return hour % 12 == 0 ? 12 : hour % 12
    }

    private func hourSuffix(_ hour: Int) -> String {
        let hour = ((hour % 24) + 24) % 24
        return hour < 12 ? "AM" : "PM"
    }
}

private struct DashboardPeakHoursHistogram: View {
    private let peakTint = AppTheme.Accent.text
    private let peakTintSoft = AppTheme.Accent.primary.opacity(0.46)

    let points: [DashboardHourlyActivityPoint]
    let maxWords: Int
    let peakStartHour: Int
    let hasData: Bool

    var body: some View {
        VStack(spacing: AppTheme.Spacing.x2) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    baseline
                        .frame(width: geometry.size.width)
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 1)

                    HStack(alignment: .bottom, spacing: AppTheme.Spacing.x1) {
                        ForEach(points) { point in
                            ZStack(alignment: .bottom) {
                                Capsule(style: .continuous)
                                    .fill(AppTheme.Border.subtle.opacity(hasData ? 0.13 : 0.08))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                                Capsule(style: .continuous)
                                    .fill(barStyle(for: point))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: barHeight(for: point, in: geometry.size))
                                    .shadow(
                                        color: isPeakHour(point.hour) && hasData ? peakTint.opacity(0.22) : Color.clear,
                                        radius: 5,
                                        y: 1
                                    )
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(height: 104)

            HStack {
                axisLabel("12 AM")
                Spacer(minLength: 0)
                axisLabel("6 AM")
                Spacer(minLength: 0)
                axisLabel("12 PM")
                Spacer(minLength: 0)
                axisLabel("6 PM")
                Spacer(minLength: 0)
                axisLabel("12 AM")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hourly dictation activity")
    }

    private var baseline: some View {
        Rectangle()
            .fill(AppTheme.Border.subtle.opacity(0.55))
            .frame(height: 1)
    }

    private func barStyle(for point: DashboardHourlyActivityPoint) -> AnyShapeStyle {
        let opacity = barOpacity(for: point)

        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    peakTintSoft.opacity(opacity),
                    peakTint.opacity(opacity * 0.94),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func barHeight(for point: DashboardHourlyActivityPoint, in size: CGSize) -> CGFloat {
        guard hasData, maxWords > 0, point.wordCount > 0 else {
            return 3
        }

        let availableHeight = max(size.height - 10, 1)
        return max(4, availableHeight * (0.40 + (emphasizedActivity(for: point) * 0.60)))
    }

    private func axisLabel(_ label: LocalizedStringKey) -> some View {
        Text(label)
            .font(AppTheme.font(.micro, .semibold))
            .foregroundStyle(AppTheme.Text.secondary)
            .lineLimit(1)
    }

    private func isPeakHour(_ hour: Int) -> Bool {
        let hour = normalizedHour(hour)
        let firstHour = normalizedHour(peakStartHour)
        let secondHour = normalizedHour(firstHour + 1)
        return hour == firstHour || hour == secondHour
    }

    private func barOpacity(for point: DashboardHourlyActivityPoint) -> CGFloat {
        guard hasData else {
            return 0.10
        }

        guard point.wordCount > 0, maxWords > 0 else {
            return 0.10
        }

        let normalized = emphasizedActivity(for: point)
        let peakBoost: CGFloat = isPeakHour(point.hour) ? 0.16 : 0

        return min(0.92, 0.22 + (normalized * 0.50) + peakBoost)
    }

    private func emphasizedActivity(for point: DashboardHourlyActivityPoint) -> CGFloat {
        CGFloat(pow(Double(relativeActivity(for: point)), 0.82))
    }

    private func relativeActivity(for point: DashboardHourlyActivityPoint) -> CGFloat {
        let wordScore = relativeScore(
            value: CGFloat(point.wordCount),
            values: points.map { CGFloat($0.wordCount) }
        )

        let activeDayScore = relativeScore(
            value: CGFloat(point.activeDayCount),
            values: points.map { CGFloat($0.activeDayCount) }
        )
        let audioDurationScore = relativeScore(
            value: CGFloat(point.audioDuration),
            values: points.map { CGFloat($0.audioDuration) }
        )

        return (wordScore * 0.64) + (activeDayScore * 0.20) + (audioDurationScore * 0.16)
    }

    private func relativeScore(value: CGFloat, values: [CGFloat]) -> CGFloat {
        let activeValues = values.filter { $0 > 0 }
        guard
            value > 0,
            let minValue = activeValues.min(),
            let maxValue = activeValues.max()
        else {
            return 0
        }

        guard maxValue > minValue else {
            return 0.5
        }

        return min(max((value - minValue) / (maxValue - minValue), 0), 1)
    }

    private func normalizedHour(_ hour: Int) -> Int {
        ((hour % 24) + 24) % 24
    }
}
