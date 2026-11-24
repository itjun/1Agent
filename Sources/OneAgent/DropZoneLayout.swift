import CoreGraphics
import Foundation

/// What a file dropped on a terminal does, picked by where it is released.
enum DropZone: Equatable, CaseIterable {
    case insertPath
    case openInPlace
    case splitLeft
    case splitRight
    case newTab
    /// Upload to the remote host in an SSH terminal; copy into the shell's folder in a local one.
    case transfer

    func title(remote: Bool) -> String {
        switch self {
        case .insertPath: return String(localized: "Insert Path")
        case .openInPlace: return String(localized: "Open in Place")
        case .splitLeft: return String(localized: "Split Left")
        case .splitRight: return String(localized: "Split Right")
        case .newTab: return String(localized: "New Tab")
        case .transfer: return remote ? String(localized: "Upload to Host") : String(localized: "Copy Here")
        }
    }
}

/// Circles over a terminal pane, in a top-left origin space: a large center circle split into
/// Insert Path (upper half) and Open in Place (lower half), and half circles on the four edges.
enum DropZoneLayout {
    /// Center circle radius as a share of the shorter pane side.
    static let centerRadiusShare: CGFloat = 0.27
    /// Edge circles relative to the center circle.
    static let edgeRadiusShare: CGFloat = 0.72
    static let labelFontSize: CGFloat = 11
    static let labelPaddingX: CGFloat = 8
    static let labelPaddingY: CGFloat = 3
    static let restingFillAlpha: CGFloat = 0.08
    static let activeFillAlpha: CGFloat = 0.26
    static let strokeAlpha: CGFloat = 0.35
    /// Points along each arc when the circles are turned into paths.
    static let arcSegments = 72

    struct Circle: Equatable {
        var center: CGPoint
        var radius: CGFloat

        func contains(_ point: CGPoint) -> Bool {
            hypot(point.x - center.x, point.y - center.y) <= radius
        }

        func gap(to point: CGPoint) -> CGFloat {
            hypot(point.x - center.x, point.y - center.y) - radius
        }
    }

    static func centerCircle(in size: CGSize) -> Circle {
        Circle(center: CGPoint(x: size.width / 2, y: size.height / 2), radius: min(size.width, size.height) * centerRadiusShare)
    }

    /// The edge circle of `zone`, nil for the two center halves.
    static func edgeCircle(_ zone: DropZone, in size: CGSize) -> Circle? {
        let radius = centerCircle(in: size).radius * edgeRadiusShare
        switch zone {
        case .splitLeft: return Circle(center: CGPoint(x: 0, y: size.height / 2), radius: radius)
        case .splitRight: return Circle(center: CGPoint(x: size.width, y: size.height / 2), radius: radius)
        case .newTab: return Circle(center: CGPoint(x: size.width / 2, y: 0), radius: radius)
        case .transfer: return Circle(center: CGPoint(x: size.width / 2, y: size.height), radius: radius)
        case .insertPath, .openInPlace: return nil
        }
    }

    static func zones(transfer: Bool) -> [DropZone] {
        DropZone.allCases.filter { transfer || $0 != .transfer }
    }

    /// Inside a circle wins; anywhere else goes to the nearest circle, so every release does something.
    static func zone(at point: CGPoint, in size: CGSize, transfer: Bool) -> DropZone {
        let center = centerCircle(in: size)
        if center.contains(point) {
            return point.y < center.center.y ? .insertPath : .openInPlace
        }
        var best: (zone: DropZone, gap: CGFloat) = (point.y < center.center.y ? .insertPath : .openInPlace, center.gap(to: point))
        for zone in zones(transfer: transfer) {
            guard let circle = edgeCircle(zone, in: size) else { continue }
            if circle.contains(point) {
                return zone
            }
            let gap = circle.gap(to: point)
            if gap < best.gap {
                best = (zone, gap)
            }
        }
        return best.zone
    }

    /// Outline of a zone as points: a half disc for the center halves, a full circle for the edges
    /// (the pane clips what falls outside).
    static func outline(of zone: DropZone, in size: CGSize) -> [CGPoint] {
        if let circle = edgeCircle(zone, in: size) {
            return arc(circle, from: 0, to: 2 * .pi)
        }
        let center = centerCircle(in: size)
        // Angles grow clockwise on screen because y points down: π…2π is the upper half.
        if zone == .insertPath {
            return arc(center, from: .pi, to: 2 * .pi)
        }
        return arc(center, from: 0, to: .pi)
    }

    /// Where the label of a zone sits: the middle of the part that is on screen.
    static func labelCenter(of zone: DropZone, in size: CGSize) -> CGPoint {
        let center = centerCircle(in: size)
        switch zone {
        case .insertPath: return CGPoint(x: center.center.x, y: center.center.y - center.radius / 2)
        case .openInPlace: return CGPoint(x: center.center.x, y: center.center.y + center.radius / 2)
        default:
            guard let circle = edgeCircle(zone, in: size) else { return center.center }
            let inset = circle.radius / 2
            switch zone {
            case .splitLeft: return CGPoint(x: inset, y: circle.center.y)
            case .splitRight: return CGPoint(x: size.width - inset, y: circle.center.y)
            case .newTab: return CGPoint(x: circle.center.x, y: inset)
            default: return CGPoint(x: circle.center.x, y: size.height - inset)
            }
        }
    }

    private static func arc(_ circle: Circle, from start: CGFloat, to end: CGFloat) -> [CGPoint] {
        var points: [CGPoint] = []
        for step in 0 ... arcSegments {
            let angle = start + (end - start) * CGFloat(step) / CGFloat(arcSegments)
            points.append(CGPoint(
                x: circle.center.x + circle.radius * cos(angle),
                y: circle.center.y + circle.radius * sin(angle)
            ))
        }
        return points
    }
}
