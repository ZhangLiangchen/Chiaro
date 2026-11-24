import Foundation
import ChiaroCore
import Metal

public enum EDRPreviewShaderSupport {
    public static func makeRenderPipelineState(
        device: any MTLDevice,
        sharedShaderLibrary: MetalShaderLibrary? = nil,
        pixelFormat: MTLPixelFormat = .rgba16Float
    ) throws -> any MTLRenderPipelineState {
        let library = try (sharedShaderLibrary?.library ?? MetalShaderLibrary.loadLibrary(device: device))
        guard let vFunc = library.makeFunction(name: "edr_preview_vertex"),
              let fFunc = library.makeFunction(name: "edr_preview_fragment") else {
            throw MetalShaderLibraryError.kernelNotFound("edr_preview_vertex / edr_preview_fragment")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "ChiaroEDRPreviewPSO"
        desc.vertexFunction = vFunc
        desc.fragmentFunction = fFunc
        desc.colorAttachments[0].pixelFormat = pixelFormat
        return try device.makeRenderPipelineState(descriptor: desc)
    }
}
