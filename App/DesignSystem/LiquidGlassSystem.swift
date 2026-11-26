import AppKit
import Metal
import SwiftUI

public enum LiquidGlassSystem {
    public static let neutralCanvasHex: String = "#111214"
    public static let neutralCanvasRed: Double = 0.067
    public static let neutralCanvasGreen: Double = 0.071
    public static let neutralCanvasBlue: Double = 0.078

    public static let neutralCanvasColor = Color(
        .sRGB,
        red: neutralCanvasRed,
        green: neutralCanvasGreen,
        blue: neutralCanvasBlue,
        opacity: 1.0
    )

    public static let neutralCanvasNSColor = NSColor(
        srgbRed: CGFloat(neutralCanvasRed),
        green: CGFloat(neutralCanvasGreen),
        blue: CGFloat(neutralCanvasBlue),
        alpha: 1.0
    )

    /// Linear sRGB equivalent of #111214 (`sRGB 17/255, 18/255, 20/255`) for `rgba16Float` MTKView clearColor.
    public static let neutralCanvasClearColor = MTLClearColor(
        red: 0.005605,
        green: 0.006049,
        blue: 0.006995,
        alpha: 1.0
    )

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
