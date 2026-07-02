import SwiftUI

/// Live luma histogram with a marker at the diffuse-highlight percentile and
/// a tick at the clip point.
struct HistogramView: View {
    let histogram: Histogram?

    var body: some View {
        Canvas { context, size in
            guard let histogram, histogram.total > 0 else { return }
            let bins = histogram.bins
            let peak = max(bins.max() ?? 1, 1)
            let barWidth = size.width / 256

            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for i in 0..<256 {
                // Log scale keeps shadow detail visible next to big peaks.
                let h = log(Double(bins[i]) + 1) / log(Double(peak) + 1)
                path.addLine(to: CGPoint(x: Double(i) * barWidth,
                                         y: size.height * (1 - h)))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(.white.opacity(0.85)))

            // Clip point tick.
            let clipX = Tuning.clipValue / 255 * size.width
            context.stroke(
                Path { p in
                    p.move(to: CGPoint(x: clipX, y: 0))
                    p.addLine(to: CGPoint(x: clipX, y: size.height))
                },
                with: .color(.red.opacity(0.8)),
                lineWidth: 1
            )

            // Diffuse-highlight percentile marker.
            let pv = histogram.value(atPercentile: Tuning.highlightPercentile)
            let pX = pv / 255 * size.width
            context.stroke(
                Path { p in
                    p.move(to: CGPoint(x: pX, y: 0))
                    p.addLine(to: CGPoint(x: pX, y: size.height))
                },
                with: .color(.yellow),
                lineWidth: 1.5
            )
        }
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
