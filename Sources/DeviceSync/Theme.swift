import SwiftUI

enum DSTheme {
    static let ink = Color(red: 0.08, green: 0.11, blue: 0.17)
    static let inkSoft = Color(red: 0.31, green: 0.36, blue: 0.44)
    static let inkMuted = Color(red: 0.49, green: 0.53, blue: 0.60)
    static let canvas = Color(red: 0.955, green: 0.965, blue: 0.98)
    static let card = Color.white.opacity(0.92)
    static let line = Color(red: 0.85, green: 0.87, blue: 0.91)
    static let blue = Color(red: 0.18, green: 0.48, blue: 0.94)
    static let cyan = Color(red: 0.08, green: 0.70, blue: 0.84)
    static let green = Color(red: 0.10, green: 0.66, blue: 0.43)
    static let orange = Color(red: 0.94, green: 0.50, blue: 0.12)
    static let red = Color(red: 0.88, green: 0.23, blue: 0.25)
    static let purple = Color(red: 0.52, green: 0.31, blue: 0.90)

    // Shared Aurora family identity, byte-for-byte with AuthBar, Stow, and
    // Murmur's Aurora canvas. Operational colors above remain semantic; these
    // three stops are reserved for FleetMesh brand surfaces.
    static let auroraEmerald = Color(red: 0.063, green: 0.725, blue: 0.506) // #10B981
    static let auroraCyan = Color(red: 0.133, green: 0.827, blue: 0.933) // #22D3EE
    static let auroraIndigo = Color(red: 0.545, green: 0.361, blue: 0.965) // #8B5CF6
    static let auroraGradient = LinearGradient(
        colors: [auroraEmerald, auroraCyan, auroraIndigo],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func color(for verdict: FleetVerdict) -> Color {
        switch verdict {
        case .aligned: green
        case .attention: orange
        case .critical: red
        case .unknown: inkMuted
        }
    }

    static func color(for drift: DriftState) -> Color {
        switch drift {
        case .aligned: green
        case .different: orange
        case .missing: red
        case .unknown: inkMuted
        case .localChanges: purple
        case .notManaged: blue
        }
    }
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(DSTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(DSTheme.line, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.035), radius: 10, y: 4)
    }
}

extension View {
    func deviceCard() -> some View { modifier(CardModifier()) }
}
