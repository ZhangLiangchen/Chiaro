import AppKit
import Foundation
import Metal
import SwiftUI

public enum LiquidGlassSystem {
    public static let adaptiveCanvasStyleIdentifier: String = "adaptive-liquid-glass"

    /// Resolves `NSColor.windowBackgroundColor` under the given appearance and converts
    /// sRGB channels to linear sRGB for `rgba16Float` `MTKView.clearColor`.
    /// Uses a safe Light/Dark neutral fallback so Light Mode never flashes black.
    public static func adaptiveCanvasClearColor(for appearance: NSAppearance?) -> MTLClearColor {
        let resolvedAppearance = appearance ?? NSAppearance.currentDrawing()
        let isDark = resolvedAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        var resolvedSRGB: NSColor?
        resolvedAppearance.performAsCurrentDrawingAppearance {
            resolvedSRGB = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
        }

        let srgbRed: Double
        let srgbGreen: Double
        let srgbBlue: Double
        if let color = resolvedSRGB, color.alphaComponent >= 0.5 {
            srgbRed = Double(color.redComponent)
            srgbGreen = Double(color.greenComponent)
            srgbBlue = Double(color.blueComponent)
        } else {
            let fallback: Double = isDark ? 0.12 : 0.95
            srgbRed = fallback
            srgbGreen = fallback
            srgbBlue = fallback
        }

        return MTLClearColor(
            red: sRGBToLinear(srgbRed),
            green: sRGBToLinear(srgbGreen),
            blue: sRGBToLinear(srgbBlue),
            alpha: 1.0
        )
    }

    private static func sRGBToLinear(_ channel: Double) -> Double {
        let clamped = min(max(channel, 0.0), 1.0)
        if clamped <= 0.04045 {
            return clamped / 12.92
        }
        return pow((clamped + 0.055) / 1.055, 2.4)
    }

    public static func isReduceTransparencyActive(_ envReduceTransparency: Bool) -> Bool {
        envReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || UserDefaults.standard.bool(forKey: "NSReduceTransparency")
    }
}

public struct ChiaroGlassContainer<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var envReduceTransparency
    private let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if !LiquidGlassSystem.isReduceTransparencyActive(envReduceTransparency),
           #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

private struct ChiaroGlassSurfaceModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var envReduceTransparency
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if LiquidGlassSystem.isReduceTransparencyActive(envReduceTransparency) {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(
                    shape
                        .stroke(Color.primary.opacity(0.22), lineWidth: 1)
                )
        } else if #available(macOS 26.0, *) {
            let base = tint.map { Glass.regular.tint($0) } ?? Glass.regular
            let configured = interactive ? base.interactive() : base
            content
                .glassEffect(configured, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.28),
                                    Color.white.opacity(0.06),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )
                .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
        }
    }
}

private struct ChiaroGlassButtonModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var envReduceTransparency
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if !LiquidGlassSystem.isReduceTransparencyActive(envReduceTransparency),
           #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

public extension View {
    func chiaroGlassSurface<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(ChiaroGlassSurfaceModifier(shape: shape, tint: tint, interactive: interactive))
    }

    func chiaroGlassSurface(
        cornerRadius: CGFloat = 12,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        chiaroGlassSurface(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint,
            interactive: interactive
        )
    }

    func chiaroGlassButtonStyle(prominent: Bool = false) -> some View {
        modifier(ChiaroGlassButtonModifier(prominent: prominent))
    }
}
