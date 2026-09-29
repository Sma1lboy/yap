import SwiftUI

private struct ReduceMotionOverrideKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Forces the recorder into its Reduce Motion look (ui-snapshots renders it; the system setting is read-only).
    var reduceMotionOverride: Bool {
        get { self[ReduceMotionOverrideKey.self] }
        set { self[ReduceMotionOverrideKey.self] = newValue }
    }
}

/// `@ReducedMotion private var reduceMotion`: the system's Reduce Motion setting, or the override above.
@propertyWrapper
struct ReducedMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.reduceMotionOverride) private var forced
    var wrappedValue: Bool { system || forced }
}

/// Bars follow the audio level; the sine wave is skipped when Reduce Motion is on, so the height depends on the level only.
enum VisualizerMotion {
    static func wave(time: Double, phase: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 1.0 : sin(time * 8 + phase) * 0.5 + 0.5
    }

    #if DEBUG
        static func selfCheck() {
            assert(wave(time: 0, phase: 0, reduceMotion: true) == wave(time: 3.7, phase: 1.2, reduceMotion: true))
            assert(wave(time: 0, phase: 0, reduceMotion: false) != wave(time: 0.3, phase: 0, reduceMotion: false))
        }
    #endif
}

struct AudioVisualizer: View {
    let audioMeterProvider: () -> AudioMeter
    let color: Color
    let isActive: Bool

    private let barCount = 15
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let minHeight: CGFloat = 4
    private let maxHeight: CGFloat = 28

    @ReducedMotion private var reduceMotion
    private let phases: [Double]

    init(audioMeterProvider: @escaping () -> AudioMeter, color: Color, isActive: Bool) {
        self.audioMeterProvider = audioMeterProvider
        self.color = color
        self.isActive = isActive
        self.phases = (0..<barCount).map { Double($0) * 0.4 }
    }

    var body: some View {
        // Reduce Motion: no travelling wave, just the level, refreshed 4 times a second.
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : 0.016)) { context in
            let audioMeter = audioMeterProvider()

            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(color.opacity(0.85))
                        .frame(
                            width: barWidth,
                            height: barHeight(
                                for: index,
                                at: context.date,
                                audioMeter: audioMeter,
                                reduceMotion: reduceMotion
                            )
                        )
                }
            }
        }
    }

    private func barHeight(for index: Int, at date: Date, audioMeter: AudioMeter, reduceMotion: Bool) -> CGFloat {
        guard isActive else { return minHeight }

        let time = date.timeIntervalSince1970
        let amplitude = max(0, min(1, pow(audioMeter.averagePower, 0.7)))  // boosted for visibility
        let wave = VisualizerMotion.wave(time: time, phase: phases[index], reduceMotion: reduceMotion)
        let centerDistance = abs(Double(index) - Double(barCount) / 2) / Double(barCount / 2)
        let centerBoost = 1.0 - (centerDistance * 0.4)

        return max(minHeight, minHeight + CGFloat(amplitude * wave * centerBoost) * (maxHeight - minHeight))
    }
}

// Flat bars shown when the recorder is idle (no audio input)
struct StaticVisualizer: View {
    private let barCount = 15
    private let barWidth: CGFloat = 3
    private let barHeight: CGFloat = 4
    private let barSpacing: CGFloat = 2
    let color: Color

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { _ in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color.opacity(0.5))
                    .frame(width: barWidth, height: barHeight)
            }
        }
    }
}

// MARK: - Processing Status Display

struct ProcessingStatusDisplay: View {
    enum Mode {
        case transcribing
        case enhancing
    }

    let mode: Mode
    let color: Color

    private var label: LocalizedStringKey {
        switch mode {
        case .transcribing: return "Transcribing"
        case .enhancing: return "Enhancing"
        }
    }

    private var animationSpeed: Double {
        switch mode {
        case .transcribing: return 0.18
        case .enhancing: return 0.22
        }
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.x1) {
            Text(label)
                .foregroundColor(color)
                .font(AppTheme.font(.caption, .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            ProgressAnimation(color: color, animationSpeed: animationSpeed)
        }
        .frame(height: 28)  // matches AudioVisualizer maxHeight to prevent layout shift
    }
}
