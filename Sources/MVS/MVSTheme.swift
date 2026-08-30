import SwiftUI

enum MVSTheme {
    static let canvas = Color(red: 0.953, green: 0.941, blue: 0.914)
    static let surface = Color(red: 1.0, green: 0.992, blue: 0.976)
    static let ink = Color(red: 0.090, green: 0.090, blue: 0.176)
    static let indigo = Color(red: 0.145, green: 0.141, blue: 0.349)
    static let indigoHover = Color(red: 0.204, green: 0.200, blue: 0.416)
    static let periwinkle = Color(red: 0.663, green: 0.706, blue: 0.827)
    static let paleSilver = Color(red: 0.788, green: 0.804, blue: 0.882)
    static let line = Color(red: 0.867, green: 0.851, blue: 0.882)
    static let gold = Color(red: 0.722, green: 0.608, blue: 0.353)
    static let cyan = Color(red: 0.431, green: 0.859, blue: 0.910)
    static let yellow = Color(red: 0.847, green: 0.675, blue: 0.208)
    static let lavender = Color(red: 0.604, green: 0.471, blue: 0.773)
    static let muted = Color(red: 0.412, green: 0.404, blue: 0.478)
    static let danger = Color(red: 0.650, green: 0.180, blue: 0.220)
    static let success = Color(red: 0.235, green: 0.475, blue: 0.380)
}

struct MVSPageBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(MVSTheme.ink)
            .background(MVSTheme.canvas.ignoresSafeArea())
    }
}

extension View {
    func mvsPage() -> some View {
        modifier(MVSPageBackground())
    }
}

struct MVSPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(configuration.isPressed ? MVSTheme.indigoHover : MVSTheme.indigo)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(MVSTheme.cyan.opacity(configuration.isPressed ? 0.55 : 0), lineWidth: 1)
            }
    }
}

struct MVSSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(MVSTheme.indigo)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(configuration.isPressed ? MVSTheme.paleSilver.opacity(0.5) : MVSTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(MVSTheme.line, lineWidth: 1)
            }
    }
}

struct MVSPageHeader: View {
    let title: String
    let eyebrow: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(MVSTheme.gold)
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(MVSTheme.ink)
            }
            Spacer()
            trailing
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MVSTheme.line)
                .frame(height: 1)
        }
    }
}

struct MVSEnergyCore: View {
    var active = false

    var body: some View {
        ZStack {
            Circle().fill(MVSTheme.indigo)
            Circle().stroke(MVSTheme.gold, lineWidth: 1.5)
            Circle()
                .fill(active ? MVSTheme.cyan : MVSTheme.periwinkle)
                .padding(4)
            Circle()
                .trim(from: 0, to: 0.5)
                .fill(MVSTheme.yellow)
                .rotationEffect(.degrees(90))
                .padding(6)
        }
        .frame(width: 16, height: 16)
        .shadow(color: active ? MVSTheme.cyan.opacity(0.35) : .clear, radius: 4)
    }
}

struct MVSStatusBadge: View {
    let status: JobStatus

    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.10))
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .queued: MVSTheme.muted
        case .running: MVSTheme.indigo
        case .completed: MVSTheme.success
        case .failed: MVSTheme.danger
        case .cancelled: MVSTheme.gold
        }
    }
}
