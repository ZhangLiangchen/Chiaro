/*
 * This file is part of Chiaro.
 *
 * Chiaro is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Foundation
import Metal
import os

private struct OpticalCorrectionUniforms {
    var width: UInt32
    var height: UInt32
    var lutWidth: UInt32
    var lutHeight: UInt32
    var vignettingStrength: Float
    var applyGeometry: UInt32
    var applyVignetting: UInt32
    var pad0: UInt32 = 0
}

public enum OpticsPipelineError: Error, Sendable, CustomStringConvertible {
    case metalDeviceUnavailable
    case lutTextureAllocationFailed
    case outputTextureAllocationFailed
    case commandEncodingFailed
    case gpuExecutionFailed(String)

    public var description: String {
        switch self {
        case .metalDeviceUnavailable:
            return "Metal device is unavailable for optical correction."
        case .lutTextureAllocationFailed:
            return "Failed to allocate 256x192 optical correction LUT textures."
        case .outputTextureAllocationFailed:
            return "Failed to allocate RGBA16F optical correction output texture."
        case .commandEncodingFailed:
            return "Failed to create Metal command buffer or compute encoder for optics."
        case let .gpuExecutionFailed(msg):
            return "Metal optical_correction_kernel failed: \(msg)"
        }
    }
}

public final class OpticsPipelineEngine: OpticalCorrectionStage, @unchecked Sendable {
    public static let lutWidth = 256
    public static let lutHeight = 192
    private static let maxCachedLUTEntries = 8

    private struct LUTCacheKey: Hashable, Sendable {
        let source: ResolvedOpticsSource
        let width: Int
        let height: Int
        let distortion: Bool
        let autoScale: Bool
        let tca: Bool
        let vignetting: Bool
        let embeddedPayload: EmbeddedSonyOpticsPayload?
        let cameraMatched: String?
        let lensMatched: String?
        let focalLengthMM: Double?
        let apertureFNumber: Double?
        let cropFactor: Double
        let lensfunDatabaseGeneration: UInt64
    }

    private struct CachedLUTEntry: @unchecked Sendable {
        let key: LUTCacheKey
        let warpTexture: any MTLTexture
        let vigTexture: any MTLTexture
        let resolution: OpticsResolutionInfo
    }

    public let device: any MTLDevice
    private let shaderLibrary: MetalShaderLibrary
    private let lensfunProvider: LensfunOpticsProvider
    private let lutCacheLock = OSAllocatedUnfairLock<[CachedLUTEntry]>(initialState: [])

    public init(
        device: (any MTLDevice)? = nil,
        shaderLibrary: MetalShaderLibrary? = nil,
        lensfunProvider: LensfunOpticsProvider = .shared
    ) throws {
        guard let dev = device ?? shaderLibrary?.device ?? MTLCreateSystemDefaultDevice() else {
            throw OpticsPipelineError.metalDeviceUnavailable
        }
        self.device = dev
        self.shaderLibrary = try shaderLibrary ?? MetalShaderLibrary(device: dev, prewarmAllKernels: true)
        self.lensfunProvider = lensfunProvider
    }

    /// Synchronous, zero-GPU-allocation optics routing helper shared by `OpticsPipelineEngine`,
    /// `MetalPipelineEngine`, and `chiaro-cli` (`job_decoded` NDJSON).
    public static func resolveOpticsInfo(
        frame: DecodedRAWFrame,
        params: OpticalCorrectionParameters,
        provider: LensfunOpticsProvider = .shared
    ) -> OpticsResolutionInfo {
        guard params.enabled, params.distortion || params.tca || params.vignetting else {
            return .none
        }

        let embeddedInfo: OpticsResolutionInfo? = {
            guard let payload = frame.embeddedSonyOptics, payload.hasAnyCorrection else {
                return nil
            }
            let dist = params.distortion && payload.hasDistortion
            let tca = params.tca && payload.hasTCA
            let vig = params.vignetting && payload.hasVignetting && params.vignettingStrength > 0.0
            guard dist || tca || (params.vignetting && payload.hasVignetting) else {
                return nil
            }
            return OpticsResolutionInfo(
                source: .embeddedARW,
                lensMatched: frame.lensModel,
                cameraMatched: frame.exif.model,
                distortionApplied: dist,
                tcaApplied: tca,
                vignettingApplied: vig
            )
        }()

        func resolveLensfun() -> OpticsResolutionInfo? {
            let crop = frame.cropFactor ?? 1.0
            guard let match = provider.resolveMatch(
                make: frame.exif.make,
                model: frame.exif.model,
                lensMake: frame.exif.lensMake,
                lensModel: frame.exif.lensModel,
                cropFactor: crop,
                params: params
            ) else {
                return nil
            }
            let dist = params.distortion && match.hasDistortion
            let tca = params.tca && match.hasTCA
            let vig = params.vignetting && match.hasVignetting && params.vignettingStrength > 0.0
            guard dist || tca || (params.vignetting && match.hasVignetting) else {
                return nil
            }
            return OpticsResolutionInfo(
                source: .lensfun,
                lensMatched: match.lensMatched,
                cameraMatched: match.cameraMatched,
                distortionApplied: dist,
                tcaApplied: tca,
                vignettingApplied: vig
            )
        }

        switch params.source {
        case .embedded:
            return embeddedInfo ?? .none
        case .lensfun:
            return resolveLensfun() ?? .none
        case .auto:
            return embeddedInfo ?? resolveLensfun() ?? .none
        }
    }

    public func clearLUTCache() {
        lutCacheLock.withLock { $0.removeAll() }
    }

    public func resolveOptics(
        frame: DecodedRAWFrame,
        params: OpticalCorrectionParameters
    ) -> OpticsResolutionInfo {
        Self.resolveOpticsInfo(frame: frame, params: params, provider: lensfunProvider)
    }

    public func applyCorrection(
        inputTexture: any MTLTexture,
        frame: DecodedRAWFrame,
        params: OpticalCorrectionParameters,
        commandQueue: any MTLCommandQueue
    ) async throws -> (texture: any MTLTexture, resolution: OpticsResolutionInfo) {
        let resolution = resolveOptics(frame: frame, params: params)
        guard params.enabled, resolution.source != .none else {
            return (inputTexture, .none)
        }

        let effectiveVigStrength: Float = params.vignetting
            ? Float(min(max(params.vignettingStrength, 0.0), 1.0))
            : 0.0
        let anyGeometry = resolution.distortionApplied || resolution.tcaApplied
        let anyVignetting = resolution.vignettingApplied && effectiveVigStrength > 1e-6

        guard anyGeometry || anyVignetting else {
            return (inputTexture, resolution)
        }

        let width = inputTexture.width
        let height = inputTexture.height
        guard width > 0, height > 0 else {
            return (inputTexture, .none)
        }
        if resolution.source == .lensfun && (width <= 1 || height <= 1) {
            return (inputTexture, .none)
        }

        let entry = try obtainOrBuildLUT(
            frame: frame,
            params: params,
            resolution: resolution,
            width: width,
            height: height
        )

        let outputTexture = try dispatchOpticalCorrectionSync(
            inputTexture: inputTexture,
            entry: entry,
            width: width,
            height: height,
            vignettingStrength: effectiveVigStrength,
            anyGeometry: anyGeometry,
            anyVignetting: anyVignetting,
            commandQueue: commandQueue
        )

        return (outputTexture, resolution)
    }

    private func dispatchOpticalCorrectionSync(
        inputTexture: any MTLTexture,
        entry: CachedLUTEntry,
        width: Int,
        height: Int,
        vignettingStrength: Float,
        anyGeometry: Bool,
        anyVignetting: Bool,
        commandQueue: any MTLCommandQueue
    ) throws -> any MTLTexture {
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        outDesc.storageMode = .private
        outDesc.usage = [.shaderRead, .shaderWrite]
        guard let outputTexture = device.makeTexture(descriptor: outDesc) else {
            throw OpticsPipelineError.outputTextureAllocationFailed
        }

        let pso = try shaderLibrary.computePipelineState(for: "optical_correction_kernel")
        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw OpticsPipelineError.commandEncodingFailed
        }

        var uniforms = OpticalCorrectionUniforms(
            width: UInt32(width),
            height: UInt32(height),
            lutWidth: UInt32(Self.lutWidth),
            lutHeight: UInt32(Self.lutHeight),
            vignettingStrength: vignettingStrength,
            applyGeometry: anyGeometry ? 1 : 0,
            applyVignetting: anyVignetting ? 1 : 0
        )

        enc.setComputePipelineState(pso)
        enc.setTexture(inputTexture, index: 0)
        enc.setTexture(entry.warpTexture, index: 1)
        enc.setTexture(entry.vigTexture, index: 2)
        enc.setTexture(outputTexture, index: 3)
        enc.setBytes(&uniforms, length: MemoryLayout<OpticalCorrectionUniforms>.stride, index: 0)

        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()

        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error {
            throw OpticsPipelineError.gpuExecutionFailed(String(describing: err))
        }
        return outputTexture
    }

    private func obtainOrBuildLUT(
        frame: DecodedRAWFrame,
        params: OpticalCorrectionParameters,
        resolution: OpticsResolutionInfo,
        width: Int,
        height: Int
    ) throws -> CachedLUTEntry {
        let crop = frame.cropFactor ?? 1.0
        let dbGeneration: UInt64 = (resolution.source == .lensfun) ? lensfunProvider.databaseGeneration : 0
        let cacheKey = LUTCacheKey(
            source: resolution.source,
            width: width,
            height: height,
            distortion: params.distortion,
            autoScale: params.autoScale,
            tca: params.tca,
            vignetting: params.vignetting,
            embeddedPayload: resolution.source == .embeddedARW ? frame.embeddedSonyOptics : nil,
            cameraMatched: resolution.cameraMatched,
            lensMatched: resolution.lensMatched,
            focalLengthMM: resolution.source == .lensfun ? frame.focalLengthMM : nil,
            apertureFNumber: resolution.source == .lensfun ? frame.apertureFNumber : nil,
            cropFactor: resolution.source == .lensfun ? crop : 1.0,
            lensfunDatabaseGeneration: dbGeneration
        )

        if let hit = lutCacheLock.withLock({ entries -> CachedLUTEntry? in
            guard let idx = entries.firstIndex(where: { $0.key == cacheKey }) else {
                return nil
            }
            let item = entries.remove(at: idx)
            entries.append(item)
            return item
        }) {
            return hit
        }

        let lutData: OpticsLUTData
        switch resolution.source {
        case .embeddedARW:
            guard let payload = frame.embeddedSonyOptics else {
                throw OpticsPipelineError.lutTextureAllocationFailed
            }
            lutData = EmbeddedSonyOpticsEvaluator.computeLUT(
                payload: payload,
                width: width,
                height: height,
                lutWidth: Self.lutWidth,
                lutHeight: Self.lutHeight,
                distortion: params.distortion,
                autoScale: params.autoScale,
                tca: params.tca,
                vignetting: params.vignetting
            )
        case .lensfun:
            guard let computed = lensfunProvider.computeLUT(
                make: frame.exif.make,
                model: frame.exif.model,
                lensMake: frame.exif.lensMake,
                lensModel: frame.exif.lensModel,
                focalLengthMM: frame.focalLengthMM,
                apertureFNumber: frame.apertureFNumber,
                cropFactor: crop,
                width: width,
                height: height,
                lutWidth: Self.lutWidth,
                lutHeight: Self.lutHeight,
                params: params
            ) else {
                throw OpticsPipelineError.lutTextureAllocationFailed
            }
            lutData = computed.lut
        case .none:
            throw OpticsPipelineError.lutTextureAllocationFailed
        }

        let warpDesc = MTLTextureDescriptor()
        warpDesc.textureType = .type2DArray
        warpDesc.pixelFormat = .rg32Float
        warpDesc.width = lutData.lutWidth
        warpDesc.height = lutData.lutHeight
        warpDesc.arrayLength = 3
        warpDesc.storageMode = .shared
        warpDesc.usage = .shaderRead

        let vigDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float,
            width: lutData.lutWidth,
            height: lutData.lutHeight,
            mipmapped: false
        )
        vigDesc.storageMode = .shared
        vigDesc.usage = .shaderRead

        guard let warpTex = device.makeTexture(descriptor: warpDesc),
              let vigTex = device.makeTexture(descriptor: vigDesc) else {
            throw OpticsPipelineError.lutTextureAllocationFailed
        }

        let sliceFloats = lutData.lutWidth * lutData.lutHeight * 2
        let warpBytesPerRow = lutData.lutWidth * 2 * MemoryLayout<Float>.stride
        let region = MTLRegionMake2D(0, 0, lutData.lutWidth, lutData.lutHeight)
        lutData.warpRGBUV.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            let sliceBytes = sliceFloats * MemoryLayout<Float>.stride
            for slice in 0..<3 {
                warpTex.replace(
                    region: region,
                    mipmapLevel: 0,
                    slice: slice,
                    withBytes: base.advanced(by: slice * sliceBytes),
                    bytesPerRow: warpBytesPerRow,
                    bytesPerImage: sliceBytes
                )
            }
        }

        let vigBytesPerRow = lutData.lutWidth * MemoryLayout<Float16>.stride
        lutData.vignettingGain.withUnsafeBytes { raw in
            vigTex.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: vigBytesPerRow
            )
        }

        let created = CachedLUTEntry(
            key: cacheKey,
            warpTexture: warpTex,
            vigTexture: vigTex,
            resolution: resolution
        )
        lutCacheLock.withLock { entries in
            if let existingIdx = entries.firstIndex(where: { $0.key == cacheKey }) {
                entries.remove(at: existingIdx)
            }
            entries.append(created)
            while entries.count > Self.maxCachedLUTEntries {
                entries.removeFirst()
            }
        }
        return created
    }
}
