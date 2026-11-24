import SwiftUI
import KarvCore

enum KarvTheme {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.043)       // #09090B
    static let surface = Color(red: 0.067, green: 0.067, blue: 0.078)          // #111114
    static let surfaceElevated = Color(red: 0.094, green: 0.094, blue: 0.110)  // #18181C
    static let hairline = Color.white.opacity(0.08)
    static let hairlineStrong = Color.white.opacity(0.14)
    static let textPrimary = Color(red: 0.980, green: 0.980, blue: 0.984)      // #FAFAFB
    static let textSecondary = Color(red: 0.631, green: 0.631, blue: 0.667)    // #A1A1AA
    static let textTertiary = Color(red: 0.443, green: 0.443, blue: 0.478)     // #71717A
}

struct KarvCardModifier: ViewModifier {
    var glowColor: Color? = nil
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(KarvTheme.surface)

                    if let glowColor {
                        RadialGradient(
                            colors: [glowColor.opacity(0.16), glowColor.opacity(0.03), .clear],
                            center: .topLeading,
                            startRadius: 4,
                            endRadius: 210
                        )
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                (glowColor ?? .white).opacity(glowColor == nil ? 0.10 : 0.24),
                                KarvTheme.hairline,
                                Color.white.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
    }
}

extension View {
    func karvCard(glow: Color? = nil, cornerRadius: CGFloat = 20) -> some View {
        modifier(KarvCardModifier(glowColor: glow, cornerRadius: cornerRadius))
    }
}

struct ProviderBadge: View {
    let provider: AIProvider
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(provider.accentColor.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(provider.accentColor.opacity(0.32), lineWidth: 1)
                )

            Image(systemName: provider.symbolName)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(provider.accentColor)
        }
        .frame(width: size, height: size)
    }
}

struct PrecisionMeterBar: View {
    let progress: Double
    let accent: Color
    let secondaryAccent: Color
    let warningThreshold: Double
    var height: CGFloat = 7

    private var activeGradient: LinearGradient {
        if progress >= 0.90 {
            return LinearGradient(
                colors: [Color(red: 0.957, green: 0.247, blue: 0.369), Color(red: 0.984, green: 0.443, blue: 0.522)],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else if progress >= warningThreshold {
            return LinearGradient(
                colors: [Color(red: 0.961, green: 0.620, blue: 0.043), Color(red: 0.984, green: 0.749, blue: 0.141)],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            return LinearGradient(
                colors: [accent, secondaryAccent],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(progress, 0.02), 1.0)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.07))

                Capsule(style: .continuous)
                    .fill(activeGradient)
                    .frame(width: max(height, proxy.size.width * clamped))
                    .shadow(color: accent.opacity(0.35), radius: 6, x: 0, y: 0)
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: progress)
    }
}

struct MiniSparkline: View {
    let points: [UsageHistoryPoint]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let values = points.map(\.usedPercent)
            if values.count >= 2 {
                let width = proxy.size.width
                let height = proxy.size.height
                let step = width / CGFloat(values.count - 1)

                Path { path in
                    for (index, val) in values.enumerated() {
                        let x = CGFloat(index) * step
                        let y = height - (CGFloat(val) * (height - 4)) - 2
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(
                    color.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }
}
