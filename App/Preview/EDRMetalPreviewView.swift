import AppKit
import CoreGraphics
import ChiaroAppCore
import ChiaroCore
import Metal
import MetalKit
import SwiftUI

@MainActor
final class EDRMTKView: MTKView {
    var onScreenMaxEDRChanged: ((Double) -> Void)?
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installObservers()
        reportScreenEDR()
    }

    private func installObservers() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)

        if let window {
            observedWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScreenNotification(_:)),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenNotification(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenNotification(_ notification: Notification) {
        reportScreenEDR()
    }

    func reportScreenEDR() {
        let value = Double(
            window?.screen?.maximumExtendedDynamicRangeColorComponentValue
                ?? NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue
                ?? 1.0
        )
        onScreenMaxEDRChanged?(max(1.0, value))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

struct EDRMetalPreviewView: NSViewRepresentable {
    var renderedFrame: RenderedFrame?
    var sharedShaderLibrary: MetalShaderLibrary?
    var previewMode: EDRPreviewMode
    var displayHeadroom: LinearHeadroom
    var sdrExposureScaleEnabled: Bool
    var splitPosition: Float
    var baseColorSpace: BaseColorSpace
    var isInteracting: Bool
    var onScreenMaxEDRChanged: @MainActor (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScreenMaxEDRChanged: onScreenMaxEDRChanged)
    }

    func makeNSView(context: Context) -> EDRMTKView {
        let view = EDRMTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = Self.targetColorSpace(for: baseColorSpace)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1.0)
        view.delegate = context.coordinator
        view.onScreenMaxEDRChanged = onScreenMaxEDRChanged

        if let metalLayer = view.layer as? CAMetalLayer {
            // Keep wantsExtendedDynamicRangeContent permanently true to avoid WindowServer flashes
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = Self.targetColorSpace(for: baseColorSpace)
        }

        context.coordinator.configurePipelineIfNeeded(sharedShaderLibrary: sharedShaderLibrary)
        return view
    }

    func updateNSView(_ nsView: EDRMTKView, context: Context) {
        nsView.onScreenMaxEDRChanged = onScreenMaxEDRChanged
        let targetCS = Self.targetColorSpace(for: renderedFrame?.baseColorSpace ?? baseColorSpace)
        if nsView.colorspace !== targetCS {
            nsView.colorspace = targetCS
        }
        if let metalLayer = nsView.layer as? CAMetalLayer {
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = targetCS
        }

        context.coordinator.configurePipelineIfNeeded(sharedShaderLibrary: sharedShaderLibrary)
        context.coordinator.updateState(
            renderedFrame: renderedFrame,
            previewMode: previewMode,
            displayHeadroom: displayHeadroom,
            sdrExposureScaleEnabled: sdrExposureScaleEnabled,
            splitPosition: splitPosition
        )

        if isInteracting {
            nsView.isPaused = false
            nsView.enableSetNeedsDisplay = false
        } else {
            nsView.isPaused = true
            nsView.enableSetNeedsDisplay = true
            nsView.setNeedsDisplay(nsView.bounds)
        }
    }

    private static func targetColorSpace(for base: BaseColorSpace) -> CGColorSpace? {
        switch base {
        case .srgb:
            return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        case .displayP3:
            return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        }
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let device: (any MTLDevice)?
        private let commandQueue: (any MTLCommandQueue)?
        private var pipelineState: (any MTLRenderPipelineState)?
        private var currentFrame: RenderedFrame?
        private var lastUploadedGainMap: GainMapBuffer?
        private var gainMapTexture: (any MTLTexture)?
        private var uniforms: EDRPreviewUniforms?
        var onScreenMaxEDRChanged: @MainActor (Double) -> Void

        init(onScreenMaxEDRChanged: @escaping @MainActor (Double) -> Void) {
            let dev = MTLCreateSystemDefaultDevice()
            self.device = dev
            self.commandQueue = dev?.makeCommandQueue()
            self.onScreenMaxEDRChanged = onScreenMaxEDRChanged
            super.init()
        }

        func configurePipelineIfNeeded(sharedShaderLibrary: MetalShaderLibrary? = nil) {
            guard pipelineState == nil else { return }
            let targetDevice = sharedShaderLibrary?.device ?? device
            guard let targetDevice else { return }
            do {
                pipelineState = try EDRPreviewShaderSupport.makeRenderPipelineState(
                    device: targetDevice,
                    sharedShaderLibrary: sharedShaderLibrary,
                    pixelFormat: .rgba16Float
                )
            } catch {
                pipelineState = nil
            }
        }

        func updateState(
            renderedFrame: RenderedFrame?,
            previewMode: EDRPreviewMode,
            displayHeadroom: LinearHeadroom,
            sdrExposureScaleEnabled: Bool,
            splitPosition: Float
        ) {
            self.currentFrame = renderedFrame
            guard let frame = renderedFrame else {
                self.uniforms = nil
                self.gainMapTexture = nil
                self.lastUploadedGainMap = nil
                return
            }

            if lastUploadedGainMap != frame.gainMap.buffer {
                uploadGainMapIfNeeded(frame.gainMap.buffer)
                lastUploadedGainMap = frame.gainMap.buffer
            }

            self.uniforms = EDRPreviewUniforms(
                mode: previewMode,
                sdrExposureScaleEnabled: sdrExposureScaleEnabled,
                metadata: frame.gainMap.metadata,
                isMonoGainMap: frame.gainMap.buffer.channels == .mono1ch,
                isSRGBBase: frame.baseColorSpace == .srgb,
                displayHeadroom: displayHeadroom,
                splitPosition: splitPosition
            )
        }

        private func uploadGainMapIfNeeded(_ gm: GainMapBuffer) {
            guard let device else { return }
            let pixelFormat: MTLPixelFormat = (gm.channels == .mono1ch) ? .r8Unorm : .bgra8Unorm
            let width = max(1, gm.width)
            let height = max(1, gm.height)

            // Always allocate a fresh MTLTexture when GainMapBuffer changes so any in-flight GPU
            // command buffer retaining the previous texture via addCompletedHandler never races
            // with CPU tex.replace(...) writes.
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else {
                gainMapTexture = nil
                return
            }
            gm.data.withUnsafeBytes { rawPtr in
                guard let base = rawPtr.baseAddress else { return }
                tex.replace(
                    region: MTLRegionMake2D(0, 0, gm.width, gm.height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: gm.bytesPerRow
                )
            }
            gainMapTexture = tex
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            configurePipelineIfNeeded()
            guard let commandQueue,
                  let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor,
                  let cb = commandQueue.makeCommandBuffer() else {
                return
            }

            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1.0)

            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else {
                return
            }

            let retainedTextures: [SendableMTLTexture]
            if let pso = pipelineState,
               let frame = currentFrame,
               let sdrWrapper = frame.sdrLinearTexture,
               let gmTex = gainMapTexture,
               var u = uniforms {
                let dw = max(Double(view.drawableSize.width), 1.0)
                let dh = max(Double(view.drawableSize.height), 1.0)
                let imgAspect = Double(max(1, frame.width)) / Double(max(1, frame.height))
                let viewAspect = dw / dh

                let vpW: Double
                let vpH: Double
                if viewAspect > imgAspect {
                    vpH = dh
                    vpW = dh * imgAspect
                } else {
                    vpW = dw
                    vpH = dw / imgAspect
                }
                let vpX = (dw - vpW) * 0.5
                let vpY = (dh - vpH) * 0.5
                enc.setViewport(MTLViewport(
                    originX: vpX,
                    originY: vpY,
                    width: vpW,
                    height: vpH,
                    znear: 0.0,
                    zfar: 1.0
                ))

                enc.setRenderPipelineState(pso)
                enc.setFragmentTexture(sdrWrapper.texture, index: 0)
                enc.setFragmentTexture(gmTex, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<EDRPreviewUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                retainedTextures = [sdrWrapper, SendableMTLTexture(gmTex)]
            } else {
                retainedTextures = []
            }

            enc.endEncoding()
            cb.addCompletedHandler { _ in
                _ = retainedTextures
            }
            cb.present(drawable)
            cb.commit()
        }
    }
}
