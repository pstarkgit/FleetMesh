import Observation

enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case fleet = "Fleet"
    case doctor = "Doctor"
    case bootstrap = "Bootstrap"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .fleet: "macbook.and.iphone"
        case .doctor: "stethoscope"
        case .bootstrap: "sparkles.rectangle.stack"
        case .settings: "gearshape"
        }
    }
}

@MainActor
@Observable
final class AppNavigation {
    var section: AppSection

    init(section: AppSection = .fleet) {
        self.section = section
    }

    func open(_ section: AppSection) {
        self.section = section
    }
}
