import AppKit
import Observation
import SwiftUI

enum FleetMeshAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
@Observable
final class FleetMeshAppearanceStore {
    static let shared = FleetMeshAppearanceStore()
    static let defaultsKey = "dev.starkpat.devicesync.appearance"

    private(set) var selection: FleetMeshAppearance
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.defaultsKey)
            .flatMap(FleetMeshAppearance.init(rawValue:))
            ?? .system
    }

    func select(_ appearance: FleetMeshAppearance) {
        guard selection != appearance else { return }
        selection = appearance
        defaults.set(appearance.rawValue, forKey: Self.defaultsKey)
        apply()
    }

    func apply(to window: NSWindow? = nil) {
        let resolved = selection.appKitAppearance
        window?.appearance = resolved
        window?.contentView?.appearance = resolved

        // `NSApp` is still nil when Swift Testing constructs this store before
        // the application lifecycle begins. Persisting a selection must remain
        // safe in that launch-order window; the app delegate applies it once
        // AppKit is ready.
        guard let application = NSApp else { return }
        application.appearance = resolved
        for appWindow in application.windows {
            appWindow.appearance = resolved
            appWindow.contentView?.appearance = resolved
        }
    }
}

enum DSTheme {
    static let ink = adaptive(
        light: (0.08, 0.11, 0.17, 1),
        dark: (0.92, 0.95, 0.99, 1)
    )
    static let inkSoft = adaptive(
        light: (0.31, 0.36, 0.44, 1),
        dark: (0.70, 0.75, 0.82, 1)
    )
    static let inkMuted = adaptive(
        light: (0.49, 0.53, 0.60, 1),
        dark: (0.52, 0.58, 0.67, 1)
    )
    static let canvas = adaptive(
        light: (0.955, 0.965, 0.98, 1),
        dark: (0.025, 0.043, 0.070, 1)
    )
    static let card = adaptive(
        light: (1, 1, 1, 0.92),
        dark: (0.055, 0.082, 0.125, 0.94)
    )
    static let line = adaptive(
        light: (0.85, 0.87, 0.91, 1),
        dark: (0.15, 0.20, 0.29, 1)
    )
    static let blue = adaptive(
        light: (0.18, 0.48, 0.94, 1),
        dark: (0.34, 0.60, 1.0, 1)
    )
    static let cyan = adaptive(
        light: (0.08, 0.70, 0.84, 1),
        dark: (0.20, 0.86, 0.94, 1)
    )
    static let green = adaptive(
        light: (0.10, 0.66, 0.43, 1),
        dark: (0.20, 0.83, 0.60, 1)
    )
    static let orange = adaptive(
        light: (0.94, 0.50, 0.12, 1),
        dark: (0.98, 0.66, 0.25, 1)
    )
    static let red = adaptive(
        light: (0.88, 0.23, 0.25, 1),
        dark: (0.98, 0.43, 0.52, 1)
    )
    static let purple = adaptive(
        light: (0.52, 0.31, 0.90, 1),
        dark: (0.68, 0.55, 0.98, 1)
    )

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
    static let auroraFieldGradient = LinearGradient(
        colors: [
            Color(red: 0.03, green: 0.25, blue: 0.28),
            Color(red: 0.02, green: 0.16, blue: 0.30),
            Color(red: 0.17, green: 0.10, blue: 0.34),
        ],
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
        case .notApplicable: inkMuted
        }
    }

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let values = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark
                : light
            return NSColor(
                srgbRed: values.0,
                green: values.1,
                blue: values.2,
                alpha: values.3
            )
        })
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
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }
}

extension View {
    func deviceCard() -> some View { modifier(CardModifier()) }
}
