import SwiftUI

enum FleetMeshMarkGeometry {
    static func links(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 100
        let origin = CGPoint(
            x: rect.midX - 50 * scale,
            y: rect.midY - 50 * scale
        )
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var links = Path()
        links.move(to: point(20, 25))
        links.addLine(to: point(42, 50))
        links.addLine(to: point(19, 76))
        links.move(to: point(80, 25))
        links.addLine(to: point(58, 50))
        links.addLine(to: point(81, 76))
        links.move(to: point(42, 50))
        links.addLine(to: point(58, 50))
        return links
    }

    static func nodes(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 100
        let origin = CGPoint(
            x: rect.midX - 50 * scale,
            y: rect.midY - 50 * scale
        )
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var nodes = Path()
        let outerRadius = 7.5 * scale
        let innerRadius = 8.5 * scale
        for (center, radius) in [
            (point(20, 25), outerRadius),
            (point(19, 76), outerRadius),
            (point(42, 50), innerRadius),
            (point(80, 25), outerRadius),
            (point(81, 76), outerRadius),
            (point(58, 50), innerRadius),
        ] {
            nodes.addEllipse(in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        nodes.addRoundedRect(
            in: CGRect(
                x: point(46, 44).x,
                y: point(46, 44).y,
                width: 8 * scale,
                height: 12 * scale
            ),
            cornerSize: CGSize(width: 2.5 * scale, height: 2.5 * scale)
        )
        return nodes
    }
}

/// Two local machine clusters connected through one explicit authority bridge.
///
/// The packaged icon is rendered from `Resources/FleetMeshMark.svg`; this
/// SwiftUI form uses the same geometry and Aurora knockout treatment inside the
/// full app and menu-bar command center.
struct FleetMeshMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 100
            let rect = CGRect(origin: .zero, size: size)
            context.stroke(
                FleetMeshMarkGeometry.links(in: rect),
                with: .color(.black.opacity(0.90)),
                style: StrokeStyle(
                    lineWidth: 6.7 * scale,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            context.fill(
                FleetMeshMarkGeometry.nodes(in: rect),
                with: .color(.black.opacity(0.90))
            )
        }
        .accessibilityHidden(true)
    }
}
