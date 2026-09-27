import SwiftUI
import UIKit

struct Chip: View {
    var icon: String?
    let text: String
    var highlighted = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
            Text(text).font(.subheadline.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(highlighted ? Theme.accent.opacity(0.25) : Theme.chip, in: Capsule())
        .foregroundStyle(highlighted ? Theme.accent : .white)
    }
}

/// A value picker you can tap through or drag sideways, like a dial.
struct StepDial: View {
    let title: String
    let values: [Double]
    let format: (Double) -> String
    @Binding var value: Double
    var enabled = true
    var highlight = false

    @State private var dragSteps = 0

    private var index: Int {
        guard !values.isEmpty else { return 0 }
        let positive = value > 0 && values.allSatisfy { $0 > 0 }
        func dist(_ v: Double) -> Double { positive ? abs(log2(v / value)) : abs(v - value) }
        var best = 0
        for i in values.indices where dist(values[i]) < dist(values[best]) { best = i }
        return best
    }

    var body: some View {
        HStack(spacing: 2) {
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 26, height: 40) }
                .disabled(!enabled || index == 0)
            VStack(spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(Theme.dim)
                Text(format(value))
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(enabled ? (highlight ? Theme.accent : .white) : Theme.dim)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(minWidth: 64)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { g in
                        guard enabled else { return }
                        let s = Int((g.translation.width / 22).rounded(.towardZero))
                        if s != dragSteps { step(s - dragSteps); dragSteps = s }
                    }
                    .onEnded { _ in dragSteps = 0 }
            )
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 26, height: 40) }
                .disabled(!enabled || index >= values.count - 1)
        }
        .padding(.vertical, 2)
        .background(Theme.chip.opacity(enabled ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 10))
        .opacity(enabled ? 1 : 0.6)
    }

    private func step(_ d: Int) {
        guard !values.isEmpty else { return }
        let i = max(0, min(values.count - 1, index + d))
        if values[i] != value {
            value = values[i]
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}

/// Vertical slider with snapping, used on the locked frame.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let format: (Double) -> String

    var body: some View {
        VStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(Theme.dim)
            GeometryReader { geo in
                let h = geo.size.height
                let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .top) {
                    Capsule().fill(Color.white.opacity(0.15)).frame(width: 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 26, height: 26)
                        .offset(y: CGFloat(1 - t) * (h - 26))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { g in
                        let frac = 1 - Double(max(0, min(h, g.location.y)) / max(1, h))
                        var v = range.lowerBound + frac * (range.upperBound - range.lowerBound)
                        v = (v / step).rounded() * step
                        v = min(range.upperBound, max(range.lowerBound, v))
                        if abs(v - value) > step / 10 {
                            value = v
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                )
            }
            Text(format(value))
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(width: 54)
    }
}

/// Match-needle for manual mode: how far the settings sit from the meter.
struct MeterNeedle: View {
    let stops: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let clamped = max(-3, min(3, stops))
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(-3...3, id: \.self) { i in
                        Rectangle().fill(i == 0 ? Theme.accent : Color.white.opacity(0.4))
                            .frame(width: i == 0 ? 2 : 1, height: i == 0 ? 12 : 8)
                            .frame(maxWidth: .infinity)
                    }
                }
                Triangle()
                    .fill(abs(stops) < 1.0 / 6 ? Color.green : (abs(stops) > 3 ? Color.red : Color.white))
                    .frame(width: 10, height: 8)
                    .offset(x: CGFloat((clamped + 3) / 6) * (w - w / 7) + w / 14 - 5, y: 12)
            }
        }
        .frame(height: 24)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
