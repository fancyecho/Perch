import SwiftUI

/// The status page's colors and its two charts.
enum Palette {
    static let cpu = Color(red: 0.38, green: 0.56, blue: 1.00)
    static let memory = Color(red: 0.66, green: 0.48, blue: 1.00)
    static let gpu = Color(red: 0.20, green: 0.78, blue: 0.72)
    static let disk = Color(red: 1.00, green: 0.62, blue: 0.28)
    static let down = Color(red: 0.25, green: 0.70, blue: 1.00)
    static let up = Color(red: 1.00, green: 0.42, blue: 0.58)
    static let battery = Color(red: 0.30, green: 0.82, blue: 0.45)

    static func level(_ percent: Double) -> Color {
        percent >= 90 ? Color(red: 1, green: 0.36, blue: 0.36) : percent >= 70 ? Color(red: 1, green: 0.72, blue: 0.2) : .clear
    }
}

private func chartPoints(_ values: [Double], capacity: Int, maxValue: Double, in size: CGSize, inset: CGFloat) -> [CGPoint] {
    guard values.count > 1 else { return [] }
    let step = size.width / CGFloat(max(capacity - 1, 1))
    let startX = size.width - CGFloat(values.count - 1) * step
    let usable = size.height - inset
    return values.enumerated().map { i, v in
        CGPoint(x: startX + CGFloat(i) * step,
                y: size.height - usable * CGFloat(min(max(v / maxValue, 0), 1)))
    }
}

private func smoothLine(_ points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    for i in 1..<points.count {
        let prev = points[i - 1], cur = points[i]
        let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
        path.addQuadCurve(to: mid, control: prev)
    }
    path.addLine(to: points[points.count - 1])
    return path
}

private func closedArea(_ line: Path, points: [CGPoint], bottom: CGFloat) -> Path {
    var area = line
    area.addLine(to: CGPoint(x: points[points.count - 1].x, y: bottom))
    area.addLine(to: CGPoint(x: points[0].x, y: bottom))
    area.closeSubpath()
    return area
}

struct Sparkline: View {
    let values: [Double]
    var maxValue: Double? = nil
    let tint: Color
    var capacity = SystemMonitor.historyLength

    var body: some View {
        GeometryReader { geo in
            let top = max(maxValue ?? (values.max() ?? 1), 0.0001)
            let points = chartPoints(values, capacity: capacity, maxValue: top, in: geo.size, inset: 1.5)
            if points.count > 1 {
                let line = smoothLine(points)
                let area = closedArea(line, points: points, bottom: geo.size.height)
                ZStack {
                    area.fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    line.stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            } else {
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

/// Download above the midline, upload below.
struct MirrorChart: View {
    let top: [Double]
    let bottom: [Double]
    let topTint: Color
    let bottomTint: Color

    var body: some View {
        GeometryReader { geo in
            let half = CGSize(width: geo.size.width, height: geo.size.height / 2)
            let peak = max(top.max() ?? 0, bottom.max() ?? 0, 10_000)
            VStack(spacing: 0) {
                Sparkline(values: top, maxValue: peak, tint: topTint)
                    .frame(height: half.height)
                Sparkline(values: bottom, maxValue: peak, tint: bottomTint)
                    .frame(height: half.height)
                    .scaleEffect(x: 1, y: -1)
            }
            .overlay { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
        }
    }
}
