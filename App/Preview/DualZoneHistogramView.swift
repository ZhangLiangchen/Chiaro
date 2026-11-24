import ChiaroCore
import SwiftUI

struct DualZoneHistogramView: View {
    let bins: [UInt32]
    let displayHeadroom: LinearHeadroom

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("双区 HDR 直方图 (SDR [-6..0 EV] | HDR (0..+4 EV])")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                let simStops = displayHeadroom.toStops().log2Value
                Text(String(format: "模拟上限: %.1f× (+%.1f EV)", displayHeadroom.multiplier, simStops))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
            }

            Canvas { context, size in
                guard size.width > 4, size.height > 4 else { return }

                // Background zones: SDR (left) & HDR (right)
                let midX = size.width * 0.5
                context.fill(
                    Path(CGRect(x: 0, y: 0, width: midX, height: size.height)),
                    with: .color(Color.white.opacity(0.03))
                )
                context.fill(
                    Path(CGRect(x: midX, y: 0, width: size.width - midX, height: size.height)),
                    with: .color(Color.orange.opacity(0.08))
                )

                let safeBins = bins.count == 256 ? bins : Array(repeating: UInt32(0), count: 256)
                // Use log scaling with robust normalization so midtones & HDR highlights are both legible
                let maxVal = max(safeBins.max() ?? 1, 1)
                let logMax = log1p(Double(maxVal))

                let binWidth = size.width / 256.0
                var sdrPath = Path()
                var hdrPath = Path()

                sdrPath.move(to: CGPoint(x: 0, y: size.height))
                for i in 0..<128 {
                    let norm = log1p(Double(safeBins[i])) / max(logMax, 1e-6)
                    let barH = CGFloat(norm) * (size.height - 4)
                    let x = CGFloat(i) * binWidth
                    sdrPath.addLine(to: CGPoint(x: x, y: size.height - barH))
                    sdrPath.addLine(to: CGPoint(x: x + binWidth, y: size.height - barH))
                }
                sdrPath.addLine(to: CGPoint(x: midX, y: size.height))
                sdrPath.closeSubpath()

                hdrPath.move(to: CGPoint(x: midX, y: size.height))
                for i in 128..<256 {
                    let norm = log1p(Double(safeBins[i])) / max(logMax, 1e-6)
                    let barH = CGFloat(norm) * (size.height - 4)
                    let x = CGFloat(i) * binWidth
                    hdrPath.addLine(to: CGPoint(x: x, y: size.height - barH))
                    hdrPath.addLine(to: CGPoint(x: x + binWidth, y: size.height - barH))
                }
                hdrPath.addLine(to: CGPoint(x: size.width, y: size.height))
                hdrPath.closeSubpath()

                context.fill(sdrPath, with: .color(Color.white.opacity(0.75)))
                context.fill(hdrPath, with: .color(Color.orange.opacity(0.9)))

                // 0 EV Diffuse White boundary at bin 128
                var zeroEVLine = Path()
                zeroEVLine.move(to: CGPoint(x: midX, y: 0))
                zeroEVLine.addLine(to: CGPoint(x: midX, y: size.height))
                context.stroke(zeroEVLine, with: .color(.cyan.opacity(0.85)), lineWidth: 1.5)

                // Active simulated headroom marker inside HDR zone (0..+4 EV)
                let simEV = min(max(displayHeadroom.toStops().log2Value, 0.0), 4.0)
                let simX = midX + CGFloat(simEV / 4.0) * (size.width - midX)
                var simLine = Path()
                simLine.move(to: CGPoint(x: simX, y: 0))
                simLine.addLine(to: CGPoint(x: simX, y: size.height))
                context.stroke(
                    simLine,
                    with: .color(.yellow.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
            }
            .frame(height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )

            HStack {
                Text("-6 EV")
                Spacer()
                Text("-3 EV")
                Spacer()
                Text("0 EV 漫反射白")
                    .foregroundStyle(.cyan)
                Spacer()
                Text("+2 EV")
                Spacer()
                Text("+4 EV")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }
}
