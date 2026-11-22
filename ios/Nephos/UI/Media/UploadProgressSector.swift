import SwiftUI

struct UploadProgressSector: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        let progress = fraction.isFinite ? min(1, max(0, fraction)) : 0
        guard progress > 0 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(
            center: center, radius: hypot(rect.width, rect.height) / 2,
            startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * progress), clockwise: false)
        path.closeSubpath()
        return path
    }
}
