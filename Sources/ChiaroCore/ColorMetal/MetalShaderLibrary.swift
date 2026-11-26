import Foundation
import Metal
import os

public enum MetalShaderLibraryError: Error, Sendable, CustomStringConvertible {
    case metalDeviceUnavailable
    case shaderSourceNotFound
    case shaderSourceUnreadable(URL)
    case kernelNotFound(String)
    case pipelineCompilationFailed(kernel: String, underlying: String)

    public var description: String {
        switch self {
        case .metalDeviceUnavailable:
            return "No Metal device available on host"
        case .shaderSourceNotFound:
            return "Shaders.metal not found in PresetLoader.resourceBundle"
        case let .shaderSourceUnreadable(url):
            return "Failed to read Shaders.metal at \(url.path)"
        case let .kernelNotFound(name):
            return "Metal function '\(name)' not found in MTLLibrary"
        case let .pipelineCompilationFailed(kernel, underlying):
            return "Failed to compile MTLComputePipelineState for '\(kernel)': \(underlying)"
        }
    }
}

/// Loads `Shaders.metal` from `PresetLoader.resourceBundle` at runtime (compatible with CLT-only macOS hosts)
/// using `MTLCompileOptions` with `.safe` math mode and `.precise` floating-point functions, and caches
/// compiled `MTLComputePipelineState` objects for all M3 kernels.
public final class MetalShaderLibrary: @unchecked Sendable {
    public static let allComputeKernelNames: [String] = [
        "hdr_passthrough_kernel",
        "demosaic_bayer_malvar_5x5_kernel",
        "opposed_inpaint_reduce_kernel",
        "opposed_inpaint_finalize_kernel",
        "opposed_inpaint_apply_kernel",
        "highlight_blend_kernel",
        "rebuild_seed_kernel",
        "rebuild_pull_kernel",
        "rebuild_push_kernel",
        "rebuild_apply_kernel",
        "unpack_rgb16u_to_rgba16f_kernel",
        "unpack_rgb16f_to_rgba16f_kernel",
        "camera_to_rec2020_lut_kernel",
        "profiled_denoise_gat_opponent_kernel",
        "profiled_denoise_atrous_h_kernel",
        "profiled_denoise_atrous_v_detail_kernel",
        "profiled_denoise_shrink_accum_kernel",
        "profiled_denoise_igat_rgb_kernel",
        "optical_correction_kernel",
        "scene_grading_kernel",
        "clarity_bilateral_h_kernel",
        "clarity_bilateral_v_apply_kernel",
        "optical_sharpness_init_kernel",
        "optical_sharpness_diffuse_step_kernel",
        "optical_sharpness_apply_kernel",
        "orient_crop_resize_kernel",
        "dual_branch_tonemap_gamut_kernel",
        "linear_to_srgb_oetf_quantize_kernel",
        "srgb_eotf_to_linear_kernel",
        "downsample_linear_antihalo_2x_kernel",
        "gainmap_log_ratio_kernel",
        "gainmap_minmax_reduce_kernel",
        "gainmap_histogram_kernel",
        "gainmap_quantize_dither_kernel",
        "hlg_p3_to_bt2020_420x10_kernel",
        "edr_preview_compute",
        "dual_zone_histogram_kernel",
    ]

    private struct PipelineBox: @unchecked Sendable {
        let pso: any MTLComputePipelineState
    }

    public let device: any MTLDevice
    public let library: any MTLLibrary
    private let cache: OSAllocatedUnfairLock<[String: PipelineBox]>

    public init(device: any MTLDevice, prewarmAllKernels: Bool = true) throws {
        self.device = device
        self.library = try Self.loadLibrary(device: device)
        self.cache = OSAllocatedUnfairLock(initialState: [:])

        if prewarmAllKernels {
            for name in Self.allComputeKernelNames {
                _ = try computePipelineState(for: name)
            }
        }
    }

    /// Exposed publicly so `ChiaroApp` (M6) can reuse the exact same compiled `MTLLibrary`
    /// for `edr_preview_vertex` / `edr_preview_fragment` without importing `MetalKit` in `ChiaroCore`.
    public static func loadLibrary(device: any MTLDevice) throws -> any MTLLibrary {
        let bundle = PresetLoader.resourceBundle

        if let metallibURL = bundle.url(forResource: "default", withExtension: "metallib"),
           let compiled = try? device.makeLibrary(URL: metallibURL) {
            return compiled
        }

        let metalURL = bundle.url(forResource: "Shaders", withExtension: "metal", subdirectory: "ColorMetal")
            ?? bundle.url(forResource: "Shaders", withExtension: "metal")

        guard let shaderURL = metalURL else {
            throw MetalShaderLibraryError.shaderSourceNotFound
        }

        guard let source = try? String(contentsOf: shaderURL, encoding: .utf8), !source.isEmpty else {
            throw MetalShaderLibraryError.shaderSourceUnreadable(shaderURL)
        }

        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        return try device.makeLibrary(source: source, options: options)
    }

    public func computePipelineState(for kernelName: String) throws -> any MTLComputePipelineState {
        if let existing = cache.withLock({ $0[kernelName] }) {
            return existing.pso
        }

        guard let fn = library.makeFunction(name: kernelName) else {
            throw MetalShaderLibraryError.kernelNotFound(kernelName)
        }

        let pso: any MTLComputePipelineState
        do {
            pso = try device.makeComputePipelineState(function: fn)
        } catch {
            throw MetalShaderLibraryError.pipelineCompilationFailed(
                kernel: kernelName,
                underlying: String(describing: error)
            )
        }

        let box = PipelineBox(pso: pso)
        return cache.withLock { map in
            if let raced = map[kernelName] {
                return raced.pso
            }
            map[kernelName] = box
            return pso
        }
    }
}
