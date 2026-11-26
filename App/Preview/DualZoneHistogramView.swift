import AppKit
import ChiaroAppCore
import ChiaroCore
import SwiftUI

struct DualZoneHistogramView: View {
    @Environment(\.colorScheme) private var colorScheme

    let bins: [UInt32]
    let displayHeadroom: LinearHeadroom
    var language: ResolvedLanguage = .zhHans

    private var zeroEVColor: Color {
        colorScheme == .dark ? Color.cyan.opacity(0.85) : Color.blue.opacity(0.78)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(ChiaroStrings.histogramTitle(language))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                let simStops = displayHeadroom.toStops().log2Value
                Text(ChiaroStrings.histogramSimLimit(mult: displayHeadroom.multiplier, ev: simStops, lang: language))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
            }

            Canvas { context, size in
                guard size.width > 4, size.height > 4 else { return }

                let midX = size.width * 0.5
                context.fill(
                    Path(CGRect(x: 0, y: 0, width: midX, height: size.height)),
                    with: .color(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.035))
                )
                context.fill(
                    Path(CGRect(x: midX, y: 0, width: size.width - midX, height: size.height)),
                    with: .color(Color.orange.opacity(colorScheme == .dark ? 0.10 : 0.12))
                )

                let safeBins = bins.count == 256 ? bins : Array(repeating: UInt32(0), count: 256)
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

                let sdrBarColor = colorScheme == .dark
                    ? Color.white.opacity(0.75)
                    : Color.primary.opacity(0.65)
                context.fill(sdrPath, with: .color(sdrBarColor))
                context.fill(hdrPath, with: .color(Color.orange.opacity(0.9)))

                var zeroEVLine = Path()
                zeroEVLine.move(to: CGPoint(x: midX, y: 0))
                zeroEVLine.addLine(to: CGPoint(x: midX, y: size.height))
                context.stroke(zeroEVLine, with: .color(zeroEVColor), lineWidth: 1.5)

                let simEV = min(max(displayHeadroom.toStops().log2Value, 0.0), 4.0)
                let simX = midX + CGFloat(simEV / 4.0) * (size.width - midX)
                var simLine = Path()
                simLine.move(to: CGPoint(x: simX, y: 0))
                simLine.addLine(to: CGPoint(x: simX, y: size.height))
                let simLineColor = colorScheme == .dark
                    ? Color.yellow.opacity(0.85)
                    : Color.orange.opacity(0.9)
                context.stroke(
                    simLine,
                    with: .color(simLineColor),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
            }
            .frame(height: 68)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            )

            HStack {
                Text("-6 EV")
                Spacer()
                Text("-3 EV")
                Spacer()
                Text(ChiaroStrings.histogramZeroEV(language))
                    .foregroundStyle(zeroEVColor)
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
