import CoreGraphics
import CoreVideo
import Foundation
@testable import ChiaroCore
import ImageIO
import Metal
import simd
import Testing
import UniformTypeIdentifiers

// MARK: - Test Helpers

private func requireMetalDevice() throws -> any MTLDevice {
    try #require(MTLCreateSystemDefaultDevice(), "Metal GPU device must be available on macOS host")
}

private func makeSharedRGBA16FTexture(
    device: any MTLDevice,
    width: Int,
    height: Int,
    pixels: [Float] // 4 floats per pixel
) throws -> SendableMTLTexture {
    precondition(pixels.count == width * height * 4)
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: width,
        height: height,
        mipmapped: false
    )
    desc.storageMode = .shared
    desc.usage = [.shaderRead, .shaderWrite]
    let tex = try #require(device.makeTexture(descriptor: desc))
    var halfPixels = [Float16](repeating: 0, count: pixels.count)
    for i in 0..<pixels.count {
        halfPixels[i] = Float16(pixels[i])
    }
    halfPixels.withUnsafeBytes { ptr in
        if let base = ptr.baseAddress {
            tex.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: width * 4 * MemoryLayout<Float16>.stride
            )
        }
    }
    return SendableMTLTexture(tex)
}

private func readRGBA16FPixels(
    device: any MTLDevice,
    commandQueue: any MTLCommandQueue,
    texture: SendableMTLTexture
) throws -> [Float] {
    let w = texture.texture.width
    let h = texture.texture.height
    let count = w * h * 4
    let byteCount = count * MemoryLayout<Float16>.stride

    let rawData: [Float16]
    if texture.texture.storageMode == .private {
        let stagingDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: w,
            height: h,
            mipmapped: false
        )
        stagingDesc.storageMode = .shared
        stagingDesc.usage = .shaderRead
        let staging = try #require(device.makeTexture(descriptor: stagingDesc))
        let cb = try #require(commandQueue.makeCommandBuffer())
        let blit = try #require(cb.makeBlitCommandEncoder())
        blit.copy(
            from: texture.texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: w, height: h, depth: 1),
            to: staging,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var arr = [Float16](repeating: 0, count: count)
        arr.withUnsafeMutableBytes { ptr in
            if let base = ptr.baseAddress {
                staging.getBytes(base, bytesPerRow: w * 4 * MemoryLayout<Float16>.stride, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            }
        }
        rawData = arr
    } else {
        var arr = [Float16](repeating: 0, count: count)
        arr.withUnsafeMutableBytes { ptr in
            if let base = ptr.baseAddress {
                texture.texture.getBytes(base, bytesPerRow: w * 4 * MemoryLayout<Float16>.stride, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            }
        }
        rawData = arr
    }
    _ = byteCount
    return rawData.map(Float.init)
}

private func makeLinearRGB16FData(pixelsRGB: [Float]) -> Data {
    var halfs = [Float16](repeating: 0, count: pixelsRGB.count)
    for i in 0..<pixelsRGB.count {
        halfs[i] = Float16(pixelsRGB[i])
    }
    return halfs.withUnsafeBytes { Data($0) }
}

private func encodeJPEGData(from cgImage: CGImage, quality: Double) throws -> Data {
    let mutable = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(mutable, UTType.jpeg.identifier as CFString, 1, nil))
    let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
    return mutable as Data
}

private func decodeISOGainMapPixel(
    sdrLin: SIMD3<Double>,
    gmBuffer: GainMapBuffer,
    metadata: GainMapMetadata,
    px: Int,
    py: Int,
    weightW: Double
) -> SIMD3<Double> {
    let gx = min(px * gmBuffer.width / max(1, gmBuffer.width), gmBuffer.width - 1)
    let gy = min(py * gmBuffer.height / max(1, gmBuffer.height), gmBuffer.height - 1)
    return decodeISOGainMapAtGMCoord(sdrLin: sdrLin, gmBuffer: gmBuffer, metadata: metadata, gx: gx, gy: gy, weightW: weightW)
}

private func decodeISOGainMapAtGMCoord(
    sdrLin: SIMD3<Double>,
    gmBuffer: GainMapBuffer,
    metadata: GainMapMetadata,
    gx: Int,
    gy: Int,
    weightW: Double
) -> SIMD3<Double> {
    let k = metadata.baseOffset.first ?? GainMapMetadata.symmetricOffset
    let enc: SIMD3<Double>
    switch gmBuffer.channels {
    case .mono1ch:
        let v = Double(gmBuffer.data[gy * gmBuffer.bytesPerRow + gx]) / 255.0
        enc = SIMD3<Double>(repeating: v)
    case .rgb3ch:
        let off = gy * gmBuffer.bytesPerRow + gx * 4
        // BGRA8 layout: [B, G, R, A]
        let b = Double(gmBuffer.data[off + 0]) / 255.0
        let g = Double(gmBuffer.data[off + 1]) / 255.0
        let r = Double(gmBuffer.data[off + 2]) / 255.0
        enc = SIMD3<Double>(r, g, b)
    }

    var out = SIMD3<Double>(repeating: 0)
    for c in 0..<3 {
        let idx = min(c, metadata.gainMapMin.count - 1)
        let gMin = metadata.gainMapMin[idx]
        let gMax = metadata.gainMapMax[idx]
        let gam = metadata.gamma[min(c, metadata.gamma.count - 1)]
        let logGain = gMin + (gMax - gMin) * pow(enc[c], 1.0 / gam)
        out[c] = (sdrLin[c] + k) * exp2(weightW * logGain) - k
    }
    return out
}

// MARK: - 1. Runtime Shader Compilation

extension ChiaroSerializedSuites {

@Suite("ColorMetalAndGainMapTests", .serialized)
struct ColorMetalAndGainMapTests {

@Test
func testRuntimeShaderCompilationFromBundle() throws {
    let dev = try requireMetalDevice()
    let lib = try MetalShaderLibrary(device: dev, prewarmAllKernels: true)
    let names = Set(lib.library.functionNames)

    #expect(names.contains("hdr_passthrough_kernel"))
    #expect(names.contains("edr_preview_vertex"))
    #expect(names.contains("edr_preview_fragment"))

    for kernelName in MetalShaderLibrary.allComputeKernelNames {
        #expect(names.contains(kernelName), "Missing compute kernel \(kernelName)")
        _ = try lib.computePipelineState(for: kernelName)
    }
}

// MARK: - 2. Matrix & OKLab Numerical Invariants

@Test
func testMatrixAndOKLabNumericalInvariants() {
    let white = SIMD3<Double>(1.0, 1.0, 1.0)
    let p3To2020 = ColorTransforms.displayP3ToRec2020 * white
    let r2020ToP3 = ColorTransforms.rec2020ToDisplayP3 * white
    let d50To2020 = ColorTransforms.xyzD50ToRec2020D65 * ColorTransforms.xyzD50
    let agxRT = ColorTransforms.agxOutset2020 * ColorTransforms.agxInset2020
    let okWhite = ColorTransforms.linearRec2020ToOKLab(white)

    for c in 0..<3 {
        #expect(abs(p3To2020[c] - 1.0) < 1e-5)
        #expect(abs(r2020ToP3[c] - 1.0) < 1e-5)
        #expect(abs(d50To2020[c] - 1.0) < 1e-5)
    }

    let cols = [agxRT.columns.0, agxRT.columns.1, agxRT.columns.2]
    for c in 0..<3 {
        for r in 0..<3 {
            let expected = (r == c) ? 1.0 : 0.0
            #expect(abs(cols[c][r] - expected) < 1e-6)
        }
    }

    #expect(abs(okWhite.x - 1.0) < 1e-5)
    #expect(abs(okWhite.y) < 1e-5)
    #expect(abs(okWhite.z) < 1e-5)
}

// MARK: - 3. MTLHeapTexturePool Reuse, Eviction & Concurrency

@Test
func testMTLHeapTexturePoolReuseAlignmentAndConcurrency() async throws {
    let dev = try requireMetalDevice()
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 256, height: 256, mipmapped: false)
    desc.storageMode = .private
    desc.usage = [.shaderRead, .shaderWrite]
    let sa = dev.heapTextureSizeAndAlign(descriptor: desc)
    #expect(sa.size > 0)

    // Budget enough for ~2 heaps of 256x256 rgba16Float
    let pool = MTLHeapTexturePool(device: dev, maxPoolBytes: max(4 * 1024 * 1024, sa.size * 5))

    try {
        let t1 = try pool.acquire(width: 256, height: 256, pixelFormat: .rgba16Float)
        #expect(t1.texture.storageMode == .private)
        #expect(t1.texture.pixelFormat == .rgba16Float)
        #expect(pool.stats.activeCount == 1)
    }()
    #expect(pool.stats.activeCount == 0)
    #expect(pool.stats.freeCount == 1)

    try {
        let t2 = try pool.acquire(width: 256, height: 256, pixelFormat: .rgba16Float)
        #expect(pool.stats.reusedCount >= 1)
        #expect(t2.texture.width == 256)
    }()

    // Allocate a different bucket to trigger eviction when approaching maxPoolBytes
    for dim in [300, 320, 340, 360] {
        autoreleasepool {
            _ = try? pool.acquire(width: dim, height: dim, pixelFormat: .rgba16Float)
        }
    }
    pool.evictIdle()

    // Concurrent Swift 6 stress test
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<32 {
            group.addTask {
                for _ in 0..<10 {
                    let tex = try pool.acquire(width: 128, height: 128, pixelFormat: .rgba16Float)
                    #expect(tex.texture.width == 128)
                }
            }
        }
        try await group.waitForAll()
    }
    #expect(pool.stats.activeCount == 0)
}

// MARK: - 4. ISO/IEC 21496-1 Roundtrip Midtone Error & CIEDE2000

@Test
func testISO21496RoundTripMidtoneErrorAndDeltaE00() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    let w = 64, h = 64
    var rgb = [Float](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        for x in 0..<w {
            let idx = (y * w + x) * 3
            if y < h / 2 {
                // Midtone & skin-tone patches <= P (0.80) in Linear Rec.2020
                let v = 0.08 + 0.55 * Float(x) / Float(w - 1)
                rgb[idx + 0] = v
                rgb[idx + 1] = v * 0.78
                rgb[idx + 2] = v * 0.58
            } else {
                // HDR highlight gradient up to +2.5 EV (5.66)
                let t = Float(x) / Float(w - 1)
                let v = 0.85 + 4.8 * t
                rgb[idx + 0] = v
                rgb[idx + 1] = v * 0.92
                rgb[idx + 2] = v * 0.80
            }
        }
    }

    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/synthetic_iso.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16F(width: w, height: h, colorSpace: .linearRec2020, data: makeLinearRGB16FData(pixelsRGB: rgb)),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )

    let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    let params = EffectiveDevelopParams.resolve(preset: preset)

    for channels in [GainMapChannels.mono1ch, GainMapChannels.rgb3ch] {
        for res in [GainMapResolution.full, GainMapResolution.half] {
            for gam in [0.5, 1.0, 2.0] {
                for cs in [BaseColorSpace.displayP3, BaseColorSpace.srgb] {
                    let spec = RenderOutputSpec(
                        targetBitDepth: .bit10,
                        baseColorSpace: cs,
                        gainMapChannels: channels,
                        gainMapResolution: res,
                        gainMapGamma: gam,
                        lockLegacyAppleGainMapBounds: false
                    )
                    let rendered = try await engine.render(frame: frame, params: params, outputSpec: spec)
                    #expect(rendered.gainMap.metadata.useBaseColorSpace == true)
                    #expect(rendered.gainMap.metadata.baseOffset.first == GainMapMetadata.symmetricOffset)

                    let sdrTex = try #require(rendered.sdrLinearTexture)
                    let hdrTex = try #require(rendered.hdrLinearTexture)
                    let sdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: sdrTex)
                    let hdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: hdrTex)

                    // Check midtones (top half): W = 0 equals SDR base, W = 1 recovers SDR==HDR within < 0.5% and dE00 < 0.5
                    var maxMidRelErr = 0.0
                    var maxDE00 = 0.0
                    var worstInfo = ""
                    for y in 2..<(h / 2 - 2) {
                        for x in 2..<(w - 2) {
                            let off = (y * w + x) * 4
                            let s = SIMD3<Double>(Double(sdrPx[off]), Double(sdrPx[off + 1]), Double(sdrPx[off + 2]))
                            let hd = SIMD3<Double>(Double(hdrPx[off]), Double(hdrPx[off + 1]), Double(hdrPx[off + 2]))
                            let gx = min(res == .half ? x / 2 : x, rendered.gainMap.buffer.width - 1)
                            let gy = min(res == .half ? y / 2 : y, rendered.gainMap.buffer.height - 1)

                            let decW0 = decodeISOGainMapAtGMCoord(sdrLin: s, gmBuffer: rendered.gainMap.buffer, metadata: rendered.gainMap.metadata, gx: gx, gy: gy, weightW: 0.0)
                            #expect(simd_distance(decW0, s) < 1e-5)

                            let decW1 = decodeISOGainMapAtGMCoord(sdrLin: s, gmBuffer: rendered.gainMap.buffer, metadata: rendered.gainMap.metadata, gx: gx, gy: gy, weightW: 1.0)
                            for c in 0..<3 {
                                let rel = abs(decW1[c] - hd[c]) / max(hd[c], 0.01)
                                if rel > maxMidRelErr {
                                    maxMidRelErr = rel
                                    worstInfo = "at (\(x),\(y)) c=\(c) s=\(s[c]) hd=\(hd[c]) dec=\(decW1[c]) min=\(rendered.gainMap.metadata.gainMapMin) max=\(rendered.gainMap.metadata.gainMapMax)"
                                }
                            }
                            let lab1 = cs == .srgb ? ColorTransforms.linearSRGBToCIELab(hd) : ColorTransforms.linearDisplayP3ToCIELab(hd)
                            let lab2 = cs == .srgb ? ColorTransforms.linearSRGBToCIELab(decW1) : ColorTransforms.linearDisplayP3ToCIELab(decW1)
                            maxDE00 = max(maxDE00, ColorTransforms.ciede2000(lab1: lab1, lab2: lab2))
                        }
                    }
                    #expect(maxMidRelErr < 0.005, "Midtone error \(maxMidRelErr) >= 0.5% for \(channels) \(res) gam=\(gam) \(worstInfo)")
                    #expect(maxDE00 < 0.5, "Midtone CIEDE2000 \(maxDE00) >= 0.5 for \(channels) \(res) gam=\(gam)")

                    // Verify highlight headroom recovery at W = 1 for .full resolution
                    if res == .full && channels == .rgb3ch && gam == 1.0 {
                        let y = h - 4, x = w - 4
                        let off = (y * w + x) * 4
                        let s = SIMD3<Double>(Double(sdrPx[off]), Double(sdrPx[off + 1]), Double(sdrPx[off + 2]))
                        let hd = SIMD3<Double>(Double(hdrPx[off]), Double(hdrPx[off + 1]), Double(hdrPx[off + 2]))
                        let dec = decodeISOGainMapAtGMCoord(sdrLin: s, gmBuffer: rendered.gainMap.buffer, metadata: rendered.gainMap.metadata, gx: x, gy: y, weightW: 1.0)
                        let rel = abs(dec.x - hd.x) / max(hd.x, 1.0)
                        #expect(rel < 0.03)
                    }
                }
            }
        }
    }
}

// MARK: - 5. All 8 EXIF Orientations Upright Bake

@Test
func testAllEightEXIFOrientationsUprightBake() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    // Target upright image: 32 x 24 (multiple of 4)
    // Quadrants in upright coordinates:
    // TL = Red (2.0, 0.05, 0.05), TR = Green (0.05, 2.0, 0.05),
    // BL = Blue (0.05, 0.05, 2.0), BR = Yellow (2.0, 2.0, 0.05)
    let upW = 32, upH = 24
    func uprightColor(ux: Int, uy: Int) -> (Float, Float, Float) {
        let right = ux >= upW / 2
        let bottom = uy >= upH / 2
        switch (right, bottom) {
        case (false, false): return (2.0, 0.05, 0.05)
        case (true, false):  return (0.05, 2.0, 0.05)
        case (false, true):  return (0.05, 0.05, 2.0)
        case (true, true):   return (2.0, 2.0, 0.05)
        }
    }

    let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    let params = EffectiveDevelopParams.resolve(preset: preset)
    let spec = RenderOutputSpec(targetBitDepth: .bit8, baseColorSpace: .displayP3, gainMapChannels: .rgb3ch, gainMapResolution: .half)

    for orient in 1...8 {
        let srcW = orient >= 5 ? upH : upW
        let srcH = orient >= 5 ? upW : upH
        var srcRGB = [Float](repeating: 0, count: srcW * srcH * 3)

        // Place uprightColor(ux, uy) at the source coordinate corresponding to (ux, uy)
        for uy in 0..<upH {
            for ux in 0..<upW {
                let (sx, sy): (Int, Int)
                switch orient {
                case 2: (sx, sy) = (srcW - 1 - ux, uy)
                case 3: (sx, sy) = (srcW - 1 - ux, srcH - 1 - uy)
                case 4: (sx, sy) = (ux, srcH - 1 - uy)
                case 5: (sx, sy) = (uy, ux)
                case 6: (sx, sy) = (uy, srcH - 1 - ux)
                case 7: (sx, sy) = (srcW - 1 - uy, srcH - 1 - ux)
                case 8: (sx, sy) = (srcW - 1 - uy, ux)
                default: (sx, sy) = (ux, uy)
                }
                let c = uprightColor(ux: ux, uy: uy)
                let idx = (sy * srcW + sx) * 3
                srcRGB[idx + 0] = c.0
                srcRGB[idx + 1] = c.1
                srcRGB[idx + 2] = c.2
            }
        }

        let frame = DecodedRAWFrame(
            sourceURL: URL(fileURLWithPath: "/tmp/orient_\(orient).arw"),
            backendUsed: .libraw,
            payload: .linearRGB16F(width: srcW, height: srcH, colorSpace: .linearRec2020, data: makeLinearRGB16FData(pixelsRGB: srcRGB)),
            visibleCrop: SensorCropRect(x: 0, y: 0, width: srcW, height: srcH),
            orientation: orient,
            colorMatrices: CameraColorMatrices(),
            isLosslessMS: false,
            exif: WhitelistedExif(orientation: orient)
        )

        let rendered = try await engine.render(frame: frame, params: params, outputSpec: spec)
        #expect(rendered.exif.orientation == 1)
        #expect(rendered.width == upW)
        #expect(rendered.height == upH)
        #expect(rendered.sdrCGImage.width == upW)
        #expect(rendered.sdrCGImage.height == upH)
        #expect(rendered.gainMap.buffer.width == upW / 2)
        #expect(rendered.gainMap.buffer.height == upH / 2)

        // Verify HDR linear texture quadrants match upright TL=R, TR=G, BL=B, BR=Y
        let hdrTex = try #require(rendered.hdrLinearTexture)
        let hdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: hdrTex)
        func sampleHDR(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * upW + x) * 4
            return SIMD3<Float>(hdrPx[i], hdrPx[i + 1], hdrPx[i + 2])
        }
        let tl = sampleHDR(4, 4)
        let tr = sampleHDR(upW - 5, 4)
        let bl = sampleHDR(4, upH - 5)
        let br = sampleHDR(upW - 5, upH - 5)

        #expect(tl.x > tl.y * 2 && tl.x > tl.z * 2, "Orient \(orient) TL should be Red, got \(tl)")
        #expect(tr.y > tr.x * 2 && tr.y > tr.z * 2, "Orient \(orient) TR should be Green, got \(tr)")
        #expect(bl.z > bl.x * 2 && bl.z > bl.y * 2, "Orient \(orient) BL should be Blue, got \(bl)")
        #expect(br.x > br.z * 2 && br.y > br.z * 2, "Orient \(orient) BR should be Yellow, got \(br)")

        // Verify GainMap buffer quadrants match (TL R > B, TR G > R, BL B > R)
        let gm = rendered.gainMap.buffer
        func sampleGM(_ gx: Int, _ gy: Int) -> (UInt8, UInt8, UInt8) {
            let off = gy * gm.bytesPerRow + gx * 4 // BGRA
            return (gm.data[off + 2], gm.data[off + 1], gm.data[off + 0])
        }
        let gmTL = sampleGM(2, 2)
        let gmTR = sampleGM(gm.width - 3, 2)
        let gmBL = sampleGM(2, gm.height - 3)
        #expect(gmTL.0 > gmTL.2)
        #expect(gmTR.1 > gmTR.0)
        #expect(gmBL.2 > gmBL.0)
    }
}

// MARK: - 6. OKLab Hue Preservation on Out-of-Gamut Sony Blue & Primaries

@Test
func testOKLabHuePreservationOutOfGamutSonyBlue() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    let testColors: [SIMD3<Double>] = [
        SIMD3<Double>(0.02, 0.08, 1.50), // Sony stage/neon deep blue
        SIMD3<Double>(0.00, 0.00, 2.50), // Pure Rec.2020 blue
        SIMD3<Double>(3.00, 0.00, 0.00), // Pure Rec.2020 red
        SIMD3<Double>(0.00, 0.90, 0.00), // Pure Rec.2020 green
    ]

    let w = 16, h = 16
    var rgb = [Float](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        let color = testColors[min(y / 4, testColors.count - 1)]
        for x in 0..<w {
            let i = (y * w + x) * 3
            rgb[i + 0] = Float(color.x)
            rgb[i + 1] = Float(color.y)
            rgb[i + 2] = Float(color.z)
        }
    }

    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/oog_blue.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16F(width: w, height: h, colorSpace: .linearRec2020, data: makeLinearRGB16FData(pixelsRGB: rgb)),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )

    let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    let params = EffectiveDevelopParams.resolve(preset: preset)
    let spec = RenderOutputSpec(baseColorSpace: .displayP3)
    let rendered = try await engine.render(frame: frame, params: params, outputSpec: spec)

    let sdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.sdrLinearTexture))
    let hdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.hdrLinearTexture))

    // Verify all pixels finite & non-negative, SDR <= 1.0
    for i in stride(from: 0, to: sdrPx.count, by: 4) {
        for c in 0..<3 {
            #expect(sdrPx[i + c].isFinite && sdrPx[i + c] >= 0.0 && sdrPx[i + c] <= 1.0001)
            #expect(hdrPx[i + c].isFinite && hdrPx[i + c] >= 0.0)
        }
    }

    // Check OKLab hue preservation on Sony deep blue row (y = 2)
    let off = (2 * w + 8) * 4
    let outP3 = SIMD3<Double>(Double(hdrPx[off]), Double(hdrPx[off + 1]), Double(hdrPx[off + 2]))
    let labIn = ColorTransforms.linearRec2020ToOKLab(testColors[0])
    let labOut = ColorTransforms.linearDisplayP3ToOKLab(outP3)
    let hIn = atan2(labIn.z, labIn.y) * 180.0 / .pi
    let hOut = atan2(labOut.z, labOut.y) * 180.0 / .pi
    var diff = abs(hOut - hIn)
    if diff > 180.0 { diff = 360.0 - diff }
    #expect(diff < 2.0, "OKLab hue drift \(diff)° >= 2.0°")
}

// MARK: - 7. Opposed Inpaint Highlight Recovery (> 1.0) & RAW Calibration

@Test
func testOpposedInpaintHighlightRecoveryAboveOne() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    let w = 32, h = 32
    var bayer = [UInt16](repeating: 512, count: w * h)
    // RGGB CFA: whiteLevel = 15360, blackLevel = 512
    // Outer ring: bright boundary where R & B unclipped, G near clip (14500)
    // Inner 8x8 core: G clipped at 15360, R=13000, B=12500 with WB [2.5, 1.0, 1.6, 1.0]
    for y in 0..<h {
        for x in 0..<w {
            let isCore = (x >= 12 && x < 20 && y >= 12 && y < 20)
            let isR = (y & 1 == 0) && (x & 1 == 0)
            let isB = (y & 1 == 1) && (x & 1 == 1)
            let val: UInt16
            if isCore {
                val = isR ? 10000 : (isB ? 14500 : 15360)
            } else {
                val = isR ? 9000 : (isB ? 13000 : 14200)
            }
            bayer[y * w + x] = val
        }
    }

    let bayerData = bayer.withUnsafeBytes { Data($0) }
    // Realistic sRGB/Camera-like cam_xyz (XYZ_D65 -> CamRaw)
    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/bayer_opposed.arw"),
        backendUsed: .libraw,
        payload: .rawBayer(width: w, height: h, bitsPerSample: 14, cfa: .rggb, data: bayerData),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(
            camXYZ: [
                +3.2404542, -1.5371385, -0.4985314,
                -0.9692660, +1.8760108, +0.0415560,
                +0.0556434, -0.2040259, +1.0572252,
            ],
            forwardMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            wbMultipliers: [2.5, 1.0, 1.6, 1.0],
            asShotWBApplied: false
        ),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )

    let cal = RAWLevelCalibration(blackLevel: [512, 512, 512, 512], whiteLevel: 15360)
    let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)

    for mode in [HighlightReconstructionMode.opposedInpaint, .blend, .rebuild] {
        let delta = PerPhotoDelta(highlightReconstructionOverride: mode)
        let params = EffectiveDevelopParams.resolve(preset: preset, delta: delta)
        let rendered = try await engine.render(
            frame: frame,
            params: params,
            outputSpec: RenderOutputSpec(),
            rawCalibration: cal
        )
        let hdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.hdrLinearTexture))
        let off = (16 * w + 16) * 4
        let r = hdrPx[off + 0], g = hdrPx[off + 1], b = hdrPx[off + 2]
        let peak = max(r, max(g, b))
        #expect(peak > 1.0, "Mode \(mode) failed to preserve HDR highlight headroom > 1.0 (got \(peak))")
        if mode == .opposedInpaint {
            // Green must be recovered above 1.0 so highlight does not turn magenta (R,B >> G)
            #expect(g > 1.0, "Opposed inpaint failed to recover clipped green > 1.0 (got \(g))")
        }
    }
}

// MARK: - 8. Midtone Lock Across All Three Tone Mappers

@Test
func testMidtoneLockAcrossAllThreeToneMappers() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    let w = 16, h = 16
    var rgb = [Float](repeating: 0, count: w * h * 3)
    for i in stride(from: 0, to: rgb.count, by: 3) {
        rgb[i + 0] = 0.40
        rgb[i + 1] = 0.30
        rgb[i + 2] = 0.20
    }

    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/midtone_lock.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16F(width: w, height: h, colorSpace: .linearRec2020, data: makeLinearRGB16FData(pixelsRGB: rgb)),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )

    let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    for mapper in SDRToneMapper.allCases {
        var modPreset = preset
        modPreset.sdrToneMapper = mapper
        let params = EffectiveDevelopParams.resolve(preset: modPreset)
        let rendered = try await engine.render(frame: frame, params: params, outputSpec: RenderOutputSpec())
        let sdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.sdrLinearTexture))
        let hdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.hdrLinearTexture))
        for c in 0..<3 {
            #expect(abs(sdrPx[c] - hdrPx[c]) < 1e-4, "ToneMapper \(mapper) broke midtone lock: sdr=\(sdrPx[c]) hdr=\(hdrPx[c])")
        }
    }
}

// MARK: - 9. Flat SDR Zero-Gain Stability

@Test
func testFlatSDRZeroGainStability() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    let w = 32, h = 32
    var rgb = [Float](repeating: 0, count: w * h * 3)
    for i in stride(from: 0, to: rgb.count, by: 3) {
        rgb[i + 0] = 0.35
        rgb[i + 1] = 0.35
        rgb[i + 2] = 0.35
    }

    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/flat_sdr.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16F(width: w, height: h, colorSpace: .linearRec2020, data: makeLinearRGB16FData(pixelsRGB: rgb)),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )

    let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    let params = EffectiveDevelopParams.resolve(preset: preset)

    // Check 3ch BGRA8 (B=G=R=0, A=255)
    let rendered3 = try await engine.render(frame: frame, params: params, outputSpec: RenderOutputSpec(gainMapChannels: .rgb3ch))
    #expect(rendered3.gainMap.metadata.gainMapMin.allSatisfy { $0 == 0.0 })
    #expect(rendered3.gainMap.metadata.gainMapMax.allSatisfy { $0 == 0.0 })
    let d3 = rendered3.gainMap.buffer.data
    for i in stride(from: 0, to: d3.count, by: 4) {
        #expect(d3[i + 0] == 0 && d3[i + 1] == 0 && d3[i + 2] == 0 && d3[i + 3] == 255)
    }

    // Check 1ch L008 (all bytes == 0)
    let rendered1 = try await engine.render(frame: frame, params: params, outputSpec: RenderOutputSpec(gainMapChannels: .mono1ch))
    #expect(rendered1.gainMap.metadata.gainMapMin.allSatisfy { $0 == 0.0 })
    #expect(rendered1.gainMap.metadata.gainMapMax.allSatisfy { $0 == 0.0 })
    #expect(rendered1.gainMap.buffer.data.allSatisfy { $0 == 0 })
}

// MARK: - 10. Hot-Pixel 0.01% / 99.99% Quantile Rejection

@Test
func testHotPixelQuantileRejection() throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    let w = 200, h = 200
    var sdrPx = [Float](repeating: 0, count: w * h * 4)
    var hdrPx = [Float](repeating: 0, count: w * h * 4)
    let k = Float(GainMapMetadata.symmetricOffset)

    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            let t = Float(x) / Float(w - 1)
            let sVal: Float = 0.5
            let targetG = 2.0 * t // [0, +2] EV
            var hVal = (sVal + k) * exp2(targetG) - k

            // 2 extreme hot/cold outlier pixels out of 40,000
            if x == 10 && y == 10 {
                hVal = (sVal + k) * exp2(6.0) - k
            } else if x == 20 && y == 20 {
                hVal = 0.0
            }
            sdrPx[i + 0] = sVal; sdrPx[i + 1] = sVal; sdrPx[i + 2] = sVal; sdrPx[i + 3] = 1.0
            hdrPx[i + 0] = hVal; hdrPx[i + 1] = hVal; hdrPx[i + 2] = hVal; hdrPx[i + 3] = 1.0
        }
    }

    let sdrTex = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: sdrPx)
    let hdrTex = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: hdrPx)
    let res = try engine.gainMapSynthesizer.synthesize(
        commandQueue: engine.commandQueue,
        sdrLinearTexture: sdrTex,
        hdrLinearTexture: hdrTex,
        baseColorSpace: .displayP3,
        targetHeadroom: .maxSupported,
        midtoneAnchorP: 0.80,
        gamma: 1.0,
        channels: .mono1ch,
        resolution: .full,
        lockLegacyBounds: false,
        deadzoneScale: 0.0
    )

    #expect(res.metadata.gainMapMax[0] <= 2.05)
    #expect(res.metadata.gainMapMin[0] >= -0.05)
}

// MARK: - 11. Blue-Noise TPDF Dithering Reduces Gradient Banding

@Test
func testDitheringReducesGradientBanding() throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    let w = 256, h = 64
    var sdrPx = [Float](repeating: 0, count: w * h * 4)
    var hdrPx = [Float](repeating: 0, count: w * h * 4)
    let k = Float(GainMapMetadata.symmetricOffset)

    var idealEnc = [Double](repeating: 0, count: w)
    for x in 0..<w {
        let g = (x == w - 1) ? 2.5 : (0.04 * Double(x) / Double(w - 1)) // shallow ~4-code ramp + max anchor
        let sVal: Float = 0.5
        let hVal = (sVal + k) * exp2(Float(g)) - k
        idealEnc[x] = g / 2.5
        for y in 0..<h {
            let i = (y * w + x) * 4
            sdrPx[i + 0] = sVal; sdrPx[i + 1] = sVal; sdrPx[i + 2] = sVal; sdrPx[i + 3] = 1.0
            hdrPx[i + 0] = hVal; hdrPx[i + 1] = hVal; hdrPx[i + 2] = hVal; hdrPx[i + 3] = 1.0
        }
    }

    let sdrTex = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: sdrPx)
    let hdrTex = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: hdrPx)

    let dithered = try engine.gainMapSynthesizer.synthesize(
        commandQueue: engine.commandQueue,
        sdrLinearTexture: sdrTex,
        hdrLinearTexture: hdrTex,
        baseColorSpace: .displayP3,
        targetHeadroom: .defaultHDR,
        midtoneAnchorP: 0.80,
        gamma: 1.0,
        channels: .mono1ch,
        resolution: .full,
        lockLegacyBounds: false,
        deadzoneScale: 0.0,
        enableDither: true
    )

    let undithered = try engine.gainMapSynthesizer.synthesize(
        commandQueue: engine.commandQueue,
        sdrLinearTexture: sdrTex,
        hdrLinearTexture: hdrTex,
        baseColorSpace: .displayP3,
        targetHeadroom: .defaultHDR,
        midtoneAnchorP: 0.80,
        gamma: 1.0,
        channels: .mono1ch,
        resolution: .full,
        lockLegacyBounds: false,
        deadzoneScale: 0.0,
        enableDither: false
    )

    func rowAveragedRMSE(_ gm: GainMapBuffer) -> Double {
        var sq = 0.0
        let span = w - 2
        for x in 1..<(w - 1) {
            var sum = 0.0
            for y in 0..<h {
                sum += Double(gm.data[y * gm.bytesPerRow + x]) / 255.0
            }
            let mean = sum / Double(h)
            let err = mean - idealEnc[x]
            sq += err * err
        }
        return sqrt(sq / Double(span))
    }

    let rmsDither = rowAveragedRMSE(dithered.buffer)
    let rmsNoDither = rowAveragedRMSE(undithered.buffer)
    #expect(rmsDither < rmsNoDither, "Dithered RMSE (\(rmsDither)) should be strictly lower than undithered (\(rmsNoDither))")
}

// MARK: - 12. Closed-Loop SDR JPEG Compensation

@Test
func testClosedLoopSDRCompensationReducesJPEGError() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    let w = 64, h = 64
    var rgb = [Float](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 3
            let u = Float(x) / Float(w - 1)
            let v = Float(y) / Float(h - 1)
            rgb[i + 0] = 0.1 + 3.5 * u
            rgb[i + 1] = 0.1 + 2.5 * v
            rgb[i + 2] = 0.2 + 1.5 * u * v
        }
    }

    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/closed_loop.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16F(width: w, height: h, colorSpace: .linearRec2020, data: makeLinearRGB16FData(pixelsRGB: rgb)),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )

    let preset = try PresetLoader.loadBuiltIn(id: .xiaohongshuJPG)
    var modPreset = preset
    modPreset.maxLongEdge = nil
    modPreset.cropAspect = .original
    let params = EffectiveDevelopParams.resolve(preset: modPreset)
    let spec = RenderOutputSpec(
        targetBitDepth: .bit8,
        baseColorSpace: .displayP3,
        gainMapChannels: .mono1ch,
        gainMapResolution: .full,
        gainMapGamma: 1.0
    )

    let rendered = try await engine.render(frame: frame, params: params, outputSpec: spec)
    let hdrTex = try #require(rendered.hdrLinearTexture)
    let hdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: hdrTex)

    // Compress SDR CGImage at heavy JPEG quantization (Q = 0.45) to introduce noticeable SDR drift
    let jpegData = try encodeJPEGData(from: rendered.sdrCGImage, quality: 0.45)
    let compensated = try await engine.recomputeGainMapCompensated(
        hdrTexture: hdrTex,
        compressedSDRJPEGData: jpegData,
        metadata: rendered.gainMap.metadata,
        gamma: 1.0,
        channels: .mono1ch,
        resolution: .full
    )

    // Decode compressed JPEG back to linear P3 for fair ISO 21496-1 reconstruction error comparison
    let src = try #require(CGImageSourceCreateWithData(jpegData as CFData, nil))
    let decodedCG = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    var jpegRGBA = [UInt8](repeating: 0, count: w * h * 4)
    let cs = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let ctx = try #require(CGContext(data: &jpegRGBA, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    ctx.draw(decodedCG, in: CGRect(x: 0, y: 0, width: w, height: h))

    func srgbEOTF(_ u: UInt8) -> Double {
        let c = Double(u) / 255.0
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    func meanLumaError(_ gmResult: GainMapResult) -> Double {
        var errSum = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let off = (y * w + x) * 4
                let bHat = SIMD3<Double>(srgbEOTF(jpegRGBA[off]), srgbEOTF(jpegRGBA[off + 1]), srgbEOTF(jpegRGBA[off + 2]))
                let hd = SIMD3<Double>(Double(hdrPx[off]), Double(hdrPx[off + 1]), Double(hdrPx[off + 2]))
                let rec = decodeISOGainMapPixel(sdrLin: bHat, gmBuffer: gmResult.buffer, metadata: gmResult.metadata, px: x, py: y, weightW: 1.0)
                let yTarget = simd_dot(hd, ColorTransforms.displayP3Luma)
                let yRec = simd_dot(rec, ColorTransforms.displayP3Luma)
                errSum += abs(yRec - yTarget)
            }
        }
        return errSum / Double(w * h)
    }

    let errUncomp = meanLumaError(rendered.gainMap)
    let errComp = meanLumaError(compensated)
    #expect(errComp < errUncomp, "Compensated error \(errComp) should be < uncompensated error \(errUncomp)")
}

// MARK: - 13. HLG OETF 75% Diffuse White Anchor & 'x420' Bit Layout

@Test
func testHLGOETFDiffuseWhite75PercentAndX420BitLayout() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    let w = 16, h = 16
    var pixels = [Float](repeating: 0, count: w * h * 4)
    // 4 vertical stripes of width 4: Black(0), MidGray(0.18), DiffuseWhite(1.0), Peak(+2.5 EV = 5.656854)
    let stripeValues: [Float] = [0.0, 0.18, 1.0, 5.656854]
    for y in 0..<h {
        for x in 0..<w {
            let v = stripeValues[x / 4]
            let i = (y * w + x) * 4
            pixels[i + 0] = v
            pixels[i + 1] = v
            pixels[i + 2] = v
            pixels[i + 3] = 1.0
        }
    }

    let hdrTex = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: pixels)
    let sendablePB = try await engine.generateHLGPixelBuffer(
        from: hdrTex,
        targetDimensions: PixelDimensions(width: w, height: h)
    )
    let pb = sendablePB.buffer
    #expect(CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    #expect(CVPixelBufferGetWidth(pb) == w)
    #expect(CVPixelBufferGetHeight(pb) == h)

    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

    let yBase = try #require(CVPixelBufferGetBaseAddressOfPlane(pb, 0)).assumingMemoryBound(to: UInt16.self)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0) / MemoryLayout<UInt16>.stride

    let uvBase = try #require(CVPixelBufferGetBaseAddressOfPlane(pb, 1)).assumingMemoryBound(to: UInt16.self)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1) / MemoryLayout<UInt16>.stride

    func yCode(_ x: Int, _ y: Int) -> Int {
        Int((yBase[y * yStride + x] >> 6) & 0x3FF)
    }
    func uvCodes(_ x: Int, _ y: Int) -> (Int, Int) {
        let idx = (y / 2) * uvStride + (x / 2) * 2
        return (Int((uvBase[idx] >> 6) & 0x3FF), Int((uvBase[idx + 1] >> 6) & 0x3FF))
    }

    let yBlack = yCode(1, 8)
    let yMid = yCode(5, 8)
    let yWhite = yCode(9, 8)
    let yPeak = yCode(13, 8)
    let (cbWhite, crWhite) = uvCodes(9, 8)

    #expect(yBlack == 64)
    #expect(yMid > yBlack && yMid < yWhite)
    #expect((719...723).contains(yWhite), "1.0 diffuse white Y_10 should be 721 (75% HLG), got \(yWhite)")
    #expect((511...513).contains(cbWhite) && (511...513).contains(crWhite))
    #expect((880...940).contains(yPeak), "+2.5 EV peak Y_10 should be in 880...940, got \(yPeak)")
}

// MARK: - 14. EDR Preview Modes & Dual-Zone Histogram

@Test
func testEDRPreviewModesAndDualZoneHistogram() throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    let w = 64, h = 64
    var sdrPx = [Float](repeating: 0, count: w * h * 4)
    var hdrPx = [Float](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            if x < w / 2 {
                // Left half: SDR 0.50 (Y = 0.5 <= 1.0)
                sdrPx[i] = 0.5; sdrPx[i + 1] = 0.5; sdrPx[i + 2] = 0.5; sdrPx[i + 3] = 1.0
                hdrPx[i] = 0.5; hdrPx[i + 1] = 0.5; hdrPx[i + 2] = 0.5; hdrPx[i + 3] = 1.0
            } else {
                // Right half: HDR 4.0 (Y = 4.0 > 1.0)
                sdrPx[i] = 0.92; sdrPx[i + 1] = 0.92; sdrPx[i + 2] = 0.92; sdrPx[i + 3] = 1.0
                hdrPx[i] = 4.0; hdrPx[i + 1] = 4.0; hdrPx[i + 2] = 4.0; hdrPx[i + 3] = 1.0
            }
        }
    }

    let sdrTex = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: sdrPx)
    let hdrTex = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: hdrPx)
    let gmResult = try engine.gainMapSynthesizer.synthesize(
        commandQueue: engine.commandQueue,
        sdrLinearTexture: sdrTex,
        hdrLinearTexture: hdrTex,
        baseColorSpace: .displayP3,
        targetHeadroom: .x4,
        midtoneAnchorP: 0.80,
        gamma: 1.0,
        channels: .mono1ch,
        resolution: .full,
        lockLegacyBounds: false
    )

    // Upload gain map to .r8Unorm texture
    let gmDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
    gmDesc.storageMode = .shared
    gmDesc.usage = .shaderRead
    let gmMetalTex = try #require(dev.makeTexture(descriptor: gmDesc))
    gmResult.buffer.data.withUnsafeBytes { ptr in
        if let base = ptr.baseAddress {
            gmMetalTex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base, bytesPerRow: gmResult.buffer.bytesPerRow)
        }
    }
    let gmSendable = SendableMTLTexture(gmMetalTex)
    let outTex = try engine.texturePool.acquire(width: w, height: h, pixelFormat: .rgba16Float)

    // Test 1x vs 4x headroom
    let u1x = EDRPreviewUniforms(mode: .standardEDR, metadata: gmResult.metadata, isMonoGainMap: true, displayHeadroom: .sdr)
    try engine.edrPreviewPipeline.evaluateCompute(commandQueue: engine.commandQueue, sdrLinearTexture: sdrTex, gainMapTexture: gmSendable, outputTexture: outTex, uniforms: u1x)
    let px1x = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: outTex)
    #expect(abs(px1x[(32 * w + 48) * 4] - 0.92) < 0.02)

    let u4x = EDRPreviewUniforms(mode: .standardEDR, metadata: gmResult.metadata, isMonoGainMap: true, displayHeadroom: .x4)
    try engine.edrPreviewPipeline.evaluateCompute(commandQueue: engine.commandQueue, sdrLinearTexture: sdrTex, gainMapTexture: gmSendable, outputTexture: outTex, uniforms: u4x)
    let px4x = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: outTex)
    #expect(abs(px4x[(32 * w + 48) * 4] - 4.0) < 0.08)

    // SDR exposure scale mode (1 / 4.0 = 0.25 -> peak 4.0 scales to ~1.0)
    let uScale = EDRPreviewUniforms(mode: .standardEDR, sdrExposureScaleEnabled: true, metadata: gmResult.metadata, isMonoGainMap: true, displayHeadroom: .x4)
    try engine.edrPreviewPipeline.evaluateCompute(commandQueue: engine.commandQueue, sdrLinearTexture: sdrTex, gainMapTexture: gmSendable, outputTexture: outTex, uniforms: uScale)
    let pxScale = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: outTex)
    #expect(abs(pxScale[(32 * w + 48) * 4] - 1.0) < 0.03)

    // Split screen (splitPosition = 0.25 -> right of 0.25 at x=48 shows HDR, left at x=8 shows SDR)
    let uSplit = EDRPreviewUniforms(mode: .splitScreenSwipe, metadata: gmResult.metadata, isMonoGainMap: true, displayHeadroom: .x4, splitPosition: 0.75)
    try engine.edrPreviewPipeline.evaluateCompute(commandQueue: engine.commandQueue, sdrLinearTexture: sdrTex, gainMapTexture: gmSendable, outputTexture: outTex, uniforms: uSplit)
    let pxSplit = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: outTex)
    #expect(pxSplit[(32 * w + 40) * 4] < 1.0) // x=40 < 48 (0.75 * 64) -> SDR
    #expect(pxSplit[(32 * w + 56) * 4] > 3.5) // x=56 > 48 -> HDR

    // False color heatmap & Gain Map direct view
    for mode in [EDRPreviewMode.falseColorHeatmap, .gainMapDirectView] {
        let uMode = EDRPreviewUniforms(mode: mode, metadata: gmResult.metadata, isMonoGainMap: true, displayHeadroom: .x4)
        try engine.edrPreviewPipeline.evaluateCompute(commandQueue: engine.commandQueue, sdrLinearTexture: sdrTex, gainMapTexture: gmSendable, outputTexture: outTex, uniforms: uMode)
        let pxMode = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: outTex)
        #expect(pxMode.allSatisfy { $0.isFinite && $0 >= 0.0 })
    }

    // Dual-zone histogram: 50% SDR (< 128) and 50% HDR (>= 128)
    let bins = try engine.edrPreviewPipeline.computeDualZoneHistogram(
        commandQueue: engine.commandQueue,
        sdrLinearTexture: sdrTex,
        gainMapTexture: gmSendable,
        uniforms: u4x
    )
    #expect(bins.count == 256)
    let sdrCount = bins[0..<128].reduce(0, +)
    let hdrCount = bins[128..<256].reduce(0, +)
    #expect(sdrCount == UInt32(w * h / 2))
    #expect(hdrCount == UInt32(w * h / 2))
}

// MARK: - 15. Anti-Halo 1/2 Downsample, Legacy Bounds Lock & Crop/4-Aligned Geometry

@Test
func testAntiHaloHalfResLegacyBoundsLockAndCropAlignment() throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    // Sharp dark-to-bright edge where B == H -> 1/2 linear downsample must produce identical B_down == H_down and G == 0
    let w = 32, h = 32
    var px = [Float](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let v: Float = (x < w / 2) ? 0.02 : 0.78
            let i = (y * w + x) * 4
            px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 1.0
        }
    }
    let texA = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: px)
    let texB = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: px)
    let symRes = try engine.gainMapSynthesizer.synthesize(
        commandQueue: engine.commandQueue,
        sdrLinearTexture: texA,
        hdrLinearTexture: texB,
        baseColorSpace: .displayP3,
        targetHeadroom: .defaultHDR,
        midtoneAnchorP: 0.80,
        gamma: 1.0,
        channels: .mono1ch,
        resolution: .half,
        lockLegacyBounds: false
    )
    #expect(symRes.buffer.width == 16 && symRes.buffer.height == 16)
    #expect(symRes.buffer.data.allSatisfy { $0 == 0 })

    // Legacy Apple bounds lock: gainMapMin == [0.0], gainMapMax == [targetHeadroom.log2Value]
    var hdrPx = px
    hdrPx[0] = 3.0; hdrPx[1] = 3.0; hdrPx[2] = 3.0
    let hdrTex = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: hdrPx)
    let legacyRes = try engine.gainMapSynthesizer.synthesize(
        commandQueue: engine.commandQueue,
        sdrLinearTexture: texA,
        hdrLinearTexture: hdrTex,
        baseColorSpace: .displayP3,
        targetHeadroom: .defaultHDR,
        midtoneAnchorP: 0.80,
        gamma: 1.0,
        channels: .mono1ch,
        resolution: .half,
        lockLegacyBounds: true
    )
    #expect(legacyRes.metadata.gainMapMin == [0.0])
    #expect(legacyRes.metadata.gainMapMax == [HeadroomStops.defaultHDR.log2Value])

    // Geometry: 7008x4672 Rotate 270 CW (8), 3:4 aspect, maxLongEdge = 2048 -> 1536x2048 (multiples of 4)
    let geom = ColorTransforms.computeOutputGeometry(
        srcWidth: 7008,
        srcHeight: 4672,
        orientation: 8,
        cropAspect: .ratio3x4,
        cropOffset: .centered,
        maxLongEdge: 2048,
        gainMapResolution: .half,
        gainMapChannels: .rgb3ch
    )
    #expect(geom.uprightWidth == 4672 && geom.uprightHeight == 7008)
    #expect(geom.outWidth == 1536 && geom.outHeight == 2048)
    #expect(geom.outWidth % 4 == 0 && geom.outHeight % 4 == 0)
}

// MARK: - 16. DCP Skips ProfileToneCurve & .cube LUT Log Shaper Roundtrip

@Test
func testDCPLoadingSkipsToneCurveAndCubeLUTLogShaperRoundtrip() async throws {
    // Build a minimal valid little-endian TIFF/DCP binary in memory with ForwardMatrix1 + ProfileToneCurve
    var tiff = Data()
    func appendU16(_ v: UInt16) {
        var le = v.littleEndian
        tiff.append(Data(bytes: &le, count: 2))
    }
    func appendU32(_ v: UInt32) {
        var le = v.littleEndian
        tiff.append(Data(bytes: &le, count: 4))
    }
    func appendI32(_ v: Int32) {
        var le = v.littleEndian
        tiff.append(Data(bytes: &le, count: 4))
    }

    // Header: II, 42, IFD offset = 8
    tiff.append(contentsOf: [0x49, 0x49])
    appendU16(42)
    appendU32(8)

    // 3 IFD entries: CalibrationIlluminant1 (0xC65A), ProfileToneCurve (0xC6FC), ForwardMatrix1 (0xC714)
    let entryCount: UInt16 = 3
    appendU16(entryCount)
    let extraOffset = UInt32(8 + 2 + Int(entryCount) * 12 + 4)

    // Entry 1: CalibrationIlluminant1 = 21 (D65)
    appendU16(0xC65A); appendU16(3); appendU32(1); appendU16(21); appendU16(0)
    // Entry 2: ProfileToneCurve (FLOAT[4]) -> must be skipped!
    let curveOffset = extraOffset
    appendU16(0xC6FC); appendU16(11); appendU32(4); appendU32(curveOffset)
    // Entry 3: ForwardMatrix1 (SRATIONAL[9]) -> D50 diagonal scaling
    let fmOffset = curveOffset + 16
    appendU16(0xC714); appendU16(10); appendU32(9); appendU32(fmOffset)
    // Next IFD = 0
    appendU32(0)

    // ProfileToneCurve floats (zeros)
    for _ in 0..<4 { appendU32(0) }
    // ForwardMatrix1: diag(0.9642, 1.0, 0.8249)
    let fmVals: [Int32] = [9642, 10000, 0, 1, 0, 1,  0, 1, 10000, 10000, 0, 1,  0, 1, 0, 1, 8249, 10000]
    for v in fmVals { appendI32(v) }

    let dcp = try DCPProfile(data: tiff)
    #expect(dcp.illuminant1Kelvin == 6500.0)
    #expect(dcp.forwardMatrix1 != nil)

    // Identity 17^3 .cube LUT through Log Shaper [-10 EV, +6 EV]
    let n = 17
    var cubeText = "TITLE \"IdentityLogShaper\"\nLUT_3D_SIZE \(n)\n"
    for b in 0..<n {
        for g in 0..<n {
            for r in 0..<n {
                let rf = Float(r) / Float(n - 1)
                let gf = Float(g) / Float(n - 1)
                let bf = Float(b) / Float(n - 1)
                cubeText += String(format: "%.6f %.6f %.6f\n", rf, gf, bf)
            }
        }
    }
    let lutURL = FileManager.default.temporaryDirectory.appendingPathComponent("identity_test_\(UUID().uuidString).cube")
    defer { try? FileManager.default.removeItem(at: lutURL) }
    try cubeText.write(to: lutURL, atomically: true, encoding: .utf8)

    let parsedLUT = try CubeLUT(contentsOf: lutURL)
    #expect(parsedLUT.dimension == .threeD(n))

    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)
    let w = 16, h = 16
    var rgb = [Float](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        let v: Float = y < 8 ? 0.25 : 4.0
        for x in 0..<w {
            let i = (y * w + x) * 3
            rgb[i] = v; rgb[i + 1] = v; rgb[i + 2] = v
        }
    }

    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/lut_test.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16F(width: w, height: h, colorSpace: .linearRec2020, data: makeLinearRGB16FData(pixelsRGB: rgb)),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )
    var modPreset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    modPreset.developDefaults.cubeLUTPath = lutURL.path
    let params = EffectiveDevelopParams.resolve(preset: modPreset)
    let rendered = try await engine.render(frame: frame, params: params, outputSpec: RenderOutputSpec())
    let hdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.hdrLinearTexture))

    let mid = hdrPx[(2 * w + 8) * 4]
    let hi = hdrPx[(12 * w + 8) * 4]
    #expect(abs(mid - 0.25) / 0.25 < 0.02)
    #expect(hi > 2.5, "Identity 3D LUT in Log Shaper must preserve HDR highlights > 1.0, got \(hi)")
}

// MARK: - 17. linearRGB16U dmax Compensation, Custom WB, Grading & 1D CubeLUT

@Test
func testLinearRGB16UDmaxCompensationCustomWBAnd1DLUT() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    let w = 16, h = 16
    // Simulate LibRaw PROXY_RGB16 / LINEAR_RGB16 where highlight=1 attenuated mid-gray by G/dmax (wb = [2.5, 1.0, 1.6, 1.0])
    let wbR = 2.5, wbG = 1.0, wbB = 1.6
    let dmax = max(wbR, wbG, wbB)
    let attenuated = UInt16((0.18 * (wbG / dmax) * 65535.0).rounded())
    var rgb16 = [UInt16](repeating: attenuated, count: w * h * 3)
    for i in 0..<(w * h * 3) { rgb16[i] = attenuated }
    let payloadData = rgb16.withUnsafeBytes { Data($0) }

    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/proxy_dmax.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16U(width: w, height: h, colorSpace: .linearRec2020, data: payloadData),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(wbMultipliers: [wbR, wbG, wbB, wbG], asShotWBApplied: false),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )

    // 1D identity LUT
    let lut1DText = "LUT_1D_SIZE 4\n0.0 0.0 0.0\n0.333333 0.333333 0.333333\n0.666667 0.666667 0.666667\n1.0 1.0 1.0\n"
    let lut1DURL = FileManager.default.temporaryDirectory.appendingPathComponent("id1d_\(UUID().uuidString).cube")
    defer { try? FileManager.default.removeItem(at: lut1DURL) }
    try lut1DText.write(to: lut1DURL, atomically: true, encoding: .utf8)

    var preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    preset.developDefaults.cubeLUTPath = lut1DURL.path
    preset.developDefaults.cameraProfile = .creativeLook("VV")
    let params = EffectiveDevelopParams.resolve(preset: preset)
    let rendered = try await engine.render(frame: frame, params: params, outputSpec: RenderOutputSpec())
    let sdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.sdrLinearTexture))

    // dmax compensation must restore 0.18 mid-gray (not 0.18 / 2.5 = 0.072)
    let mid = sdrPx[(8 * w + 8) * 4]
    #expect(abs(mid - 0.18) < 0.02, "Expected ~0.18 after LibRaw dmax compensation, got \(mid)")

    // Also verify custom WB + shadowRecovery + blackPoint + vibrance executes cleanly without NaN
    let delta = PerPhotoDelta(
        shadowRecoveryOverride: 35.0,
        blackPointOverride: 10.0,
        vibranceOverride: 25.0,
        whiteBalanceOverride: .custom(temperatureKelvin: 4200.0, tint: 12.0)
    )
    let customParams = EffectiveDevelopParams.resolve(preset: preset, delta: delta)
    let customRendered = try await engine.render(frame: frame, params: customParams, outputSpec: RenderOutputSpec())
    let customPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(customRendered.hdrLinearTexture))
    #expect(customPx.allSatisfy { $0.isFinite && $0 >= 0.0 })
}

// MARK: - 18. Regression: Multi-Megapixel Opposed Inpaint (No Int32 Overflow)

@Test
func testOpposedInpaintMultiMegapixelNoInt32Overflow() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    // 2048 x 2048 = 4,194,304 pixels (> Int32.max when summed at 4096x fixed point with opp > +0.5)
    let w = 2048, h = 2048
    var bayer = [UInt16](repeating: 512, count: w * h)
    bayer.withUnsafeMutableBufferPointer { buf in
        for y in 0..<h {
            let isOddY = (y & 1) == 1
            let rowOff = y * w
            let inCoreY = (y >= h / 2 - 32 && y < h / 2 + 32)
            for x in 0..<w {
                let isOddX = (x & 1) == 1
                let inCore = inCoreY && (x >= w / 2 - 32 && x < w / 2 + 32)
                if !isOddY && !isOddX {
                    // Red site: bright unclipped surround (14000 -> ~1.75 after 2.0 WB), clipped core (15360)
                    buf[rowOff + x] = inCore ? 15360 : 14000
                } else {
                    // Green / Blue sites: 8000 surround (~0.50), 12000 core (~0.77)
                    buf[rowOff + x] = inCore ? 12000 : 8000
                }
            }
        }
    }

    let bayerData = bayer.withUnsafeBytes { Data($0) }
    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/bayer_4mp_overflow.arw"),
        backendUsed: .libraw,
        payload: .rawBayer(width: w, height: h, bitsPerSample: 14, cfa: .rggb, data: bayerData),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(
            camXYZ: [
                +3.2404542, -1.5371385, -0.4985314,
                -0.9692660, +1.8760108, +0.0415560,
                +0.0556434, -0.2040259, +1.0572252,
            ],
            forwardMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            wbMultipliers: [2.0, 1.0, 1.0, 1.0],
            asShotWBApplied: false
        ),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )

    let cal = RAWLevelCalibration(blackLevel: [512, 512, 512, 512], whiteLevel: 15360)
    let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    let params = EffectiveDevelopParams.resolve(preset: preset, delta: PerPhotoDelta(highlightReconstructionOverride: .opposedInpaint))
    let rendered = try await engine.render(
        frame: frame,
        params: params,
        outputSpec: RenderOutputSpec(targetBitDepth: .bit8, gainMapResolution: .half),
        rawCalibration: cal
    )

    let hdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.hdrLinearTexture))
    let centerOff = ((h / 2) * w + (w / 2)) * 4
    let r = hdrPx[centerOff + 0]
    let g = hdrPx[centerOff + 1]
    let b = hdrPx[centerOff + 2]
    #expect(r.isFinite && g.isFinite && b.isFinite)
    // Interior of 64x64 clipped-R core relies on globalChroma.r (+0.5 clamped), so R must stay > G & B (no sign flip)
    #expect(r > g + 0.15 && r > b + 0.15, "Opposed inpaint overflowed or flipped globalChroma sign: R=\(r) G=\(g) B=\(b)")
}

// MARK: - 19. Regression: OKLab Soft Gamut Map Boundary Continuity

@Test
func testOKLabSoftGamutMapBoundaryContinuity() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    // 128-step smooth saturated red-orange gradient in Rec.2020 crossing the Display P3 gamut boundary
    // Kept at low/mid luminance (norm <= 0.80) under .openDRT so tone mapper does not compress before OKLab.
    let w = 128, h = 4
    var rgb = [Float](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        for x in 0..<w {
            let t = Float(x) / Float(w - 1) // 0 = inside P3, 1 = deep outside P3 in Rec.2020
            let r: Float = 0.35 + 0.55 * t
            let g: Float = 0.25 * (1.0 - t)
            let b: Float = 0.25 * (1.0 - t)
            let i = (y * w + x) * 3
            rgb[i + 0] = r
            rgb[i + 1] = g
            rgb[i + 2] = b
        }
    }

    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/oklab_continuity.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16F(width: w, height: h, colorSpace: .linearRec2020, data: makeLinearRGB16FData(pixelsRGB: rgb)),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )

    var preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    preset.sdrToneMapper = .openDRT
    let params = EffectiveDevelopParams.resolve(preset: preset)

    for cs in [BaseColorSpace.displayP3, BaseColorSpace.srgb] {
        let rendered = try await engine.render(
            frame: frame,
            params: params,
            outputSpec: RenderOutputSpec(baseColorSpace: cs)
        )
        let sdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.sdrLinearTexture))

        var chromas = [Double]()
        for x in 0..<w {
            let off = (2 * w + x) * 4
            let p = SIMD3<Double>(Double(sdrPx[off]), Double(sdrPx[off + 1]), Double(sdrPx[off + 2]))
            let lab = (cs == .srgb) ? ColorTransforms.linearSRGBToOKLab(p) : ColorTransforms.linearDisplayP3ToOKLab(p)
            chromas.append(hypot(lab.y, lab.z))
        }

        var maxStepDrop = 0.0
        var maxStepJump = 0.0
        var dropIdx = -1
        for x in 1..<w {
            let delta = chromas[x] - chromas[x - 1]
            if delta < 0 && -delta > maxStepDrop {
                maxStepDrop = -delta
                dropIdx = x
            }
            maxStepJump = max(maxStepJump, abs(delta))
        }
        // Previously had a -7.5% (~0.022 OKLab C) discontinuity right at the gamut boundary
        #expect(maxStepDrop < 0.002, "Chroma dropped discontinuously across \(cs) gamut boundary at idx=\(dropIdx) (t=\(Double(dropIdx)/Double(w-1))): drop=\(maxStepDrop), prev=\(dropIdx > 0 ? chromas[dropIdx-1] : 0), cur=\(dropIdx > 0 ? chromas[dropIdx] : 0)")
        #expect(maxStepJump < 0.008, "Chroma jumped too sharply across \(cs) gamut boundary: jump=\(maxStepJump)")
        #expect(chromas.last! > chromas.first!)
    }
}

// MARK: - 20. Regression: DCP Huge HueSatMapDims Throws & Periodic Hue Wrap

@Test
func testDCPHugeHueSatDimsThrowsAndPeriodicHueWrap() async throws {
    // 1) Crafted TIFF/DCP with ProfileHueSatMapDims (0xC6F9) = [10_000_000, 10_000_000, 10_000_000]
    var tiff = Data()
    func appendU16(_ v: UInt16) {
        var le = v.littleEndian
        tiff.append(Data(bytes: &le, count: 2))
    }
    func appendU32(_ v: UInt32) {
        var le = v.littleEndian
        tiff.append(Data(bytes: &le, count: 4))
    }

    tiff.append(contentsOf: [0x49, 0x49])
    appendU16(42)
    appendU32(8)
    appendU16(1) // 1 IFD entry
    let dimsOffset = UInt32(8 + 2 + 12 + 4)
    appendU16(0xC6F9); appendU16(4); appendU32(3); appendU32(dimsOffset)
    appendU32(0) // next IFD
    appendU32(10_000_000); appendU32(10_000_000); appendU32(10_000_000)

    #expect(throws: DCPProfileError.self) {
        _ = try DCPProfile(data: tiff)
    }

    // 2) Periodic hue wrap across 0°/360° red seam in apply_hsv_table
    // HueDivs = 6 (0°, 60°, 120°, 180°, 240°, 300°); hueIdx=0 has +20° shift, hueIdx=5 has -20° shift -> wrap must interpolate smoothly through 0°!
    // Actually if hueIdx=0 and hueIdx=5 both have +24° shift while others have 0°, hue=358° and hue=2° must both get ~+24° shift!
    let hDivs = 6, sDivs = 2, vDivs = 2
    var tableFloats = [Float](repeating: 0, count: hDivs * sDivs * vDivs * 4)
    for v in 0..<vDivs {
        for h in 0..<hDivs {
            let hueShift: Float = (h == 0 || h == hDivs - 1) ? 24.0 : 0.0
            for s in 0..<sDivs {
                let idx = ((v * hDivs * sDivs) + h * sDivs + s) * 4
                tableFloats[idx + 0] = hueShift
                tableFloats[idx + 1] = 1.0
                tableFloats[idx + 2] = 1.0
                tableFloats[idx + 3] = 0.0
            }
        }
    }
    let hsvTable = HSVTable3D(hueDivs: hDivs, satDivs: sDivs, valDivs: vDivs, rgbaFloats: tableFloats)
    let dcp = DCPProfile(lookTable: hsvTable)
    let dcpData: Data = {
        var d = Data()
        func u16(_ v: UInt16) { var le = v.littleEndian; d.append(Data(bytes: &le, count: 2)) }
        func u32(_ v: UInt32) { var le = v.littleEndian; d.append(Data(bytes: &le, count: 4)) }
        func f32(_ v: Float) { u32(v.bitPattern) }
        d.append(contentsOf: [0x49, 0x49]); u16(42); u32(8)
        u16(2)
        let dimsOff = UInt32(8 + 2 + 2 * 12 + 4)
        let dataOff = dimsOff + 12
        u16(0xC725); u16(4); u32(3); u32(dimsOff)
        u16(0xC726); u16(11); u32(UInt32(hDivs * sDivs * vDivs * 3)); u32(dataOff)
        u32(0)
        u32(UInt32(hDivs)); u32(UInt32(sDivs)); u32(UInt32(vDivs))
        for i in 0..<(hDivs * sDivs * vDivs) {
            f32(tableFloats[i * 4 + 0])
            f32(tableFloats[i * 4 + 1])
            f32(tableFloats[i * 4 + 2])
        }
        return d
    }()
    let dcpURL = FileManager.default.temporaryDirectory.appendingPathComponent("wrap_test_\(UUID().uuidString).dcp")
    defer { try? FileManager.default.removeItem(at: dcpURL) }
    try dcpData.write(to: dcpURL)
    _ = dcp

    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)
    // Two pixels: hue=2° (R=0.5, G=0.055, B=0.04) and hue=358° (R=0.5, G=0.04, B=0.055)
    let w = 4, h = 4
    var rgb = [Float](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 3
            rgb[i + 0] = 0.50
            if x < w / 2 {
                rgb[i + 1] = 0.055; rgb[i + 2] = 0.040 // +2°
            } else {
                rgb[i + 1] = 0.040; rgb[i + 2] = 0.055 // 358° (-2°)
            }
        }
    }
    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/hue_wrap.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16F(width: w, height: h, colorSpace: .linearRec2020, data: makeLinearRGB16FData(pixelsRGB: rgb)),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )
    var preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    preset.developDefaults.cameraProfile = .dcp(path: dcpURL.path)
    let rendered = try await engine.render(frame: frame, params: EffectiveDevelopParams.resolve(preset: preset), outputSpec: RenderOutputSpec())
    let sdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.sdrLinearTexture))
    let gPlus = sdrPx[(2 * w + 1) * 4 + 1]
    let gMinus = sdrPx[(2 * w + 3) * 4 + 1]
    // Both 358° and 2° should shift +24° toward orange-yellow (high G, small gap across seam)
    #expect(gPlus > 0.15 && gMinus > 0.15, "Hue wrap failed across 0°/360° seam: gPlus=\(gPlus), gMinus=\(gMinus)")
    #expect(abs(gPlus - gMinus) < 0.04, "Seam discontinuity across 0°/360°: gPlus=\(gPlus), gMinus=\(gMinus)")
}

// MARK: - 21. Regression: .linearRGB16U Clipped-G Highlight Recovery (No Magenta Clipping)

@Test
func testLinearRGB16UCameraNativeClippedGHighlightRecovery() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    let w = 32, h = 32
    let wbR = 1.85, wbG = 1.0, wbB = 2.14
    let dmax = max(wbR, wbG, wbB)

    // Simulate LibRaw PROXY_RGB16 (cameraNative, highlight=1 scale_colors() scaled by wb/dmax & clamped to 65535)
    // Neutral white scene where sensor G clips first (1.0 -> 1.0/2.14) while R and B remain unclipped:
    // Surround (neutral 0.85): after WB [1.85, 1.0, 2.14], camera RGB is [0.85, 0.85, 0.85] -> raw_sensor = [0.85/1.85, 0.85, 0.85/2.14]
    // Center 8x8 core (neutral 1.75): sensor G clips at 1.00 (cam G = 1.00 after dmax), while cam R = 1.75 & cam B = 1.75 are unclipped!
    var rgb16 = [UInt16](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        for x in 0..<w {
            let inCore = (x >= 12 && x < 20 && y >= 12 && y < 20)
            let sR = inCore ? (1.75 / wbR) : (0.85 / wbR)
            let sG = inCore ? 1.00 : 0.85
            let sB = inCore ? (1.75 / wbB) : (0.85 / wbB)
            let i = (y * w + x) * 3
            rgb16[i + 0] = UInt16(min(max((sR * (wbR / dmax) * 65535.0).rounded(), 0.0), 65535.0))
            rgb16[i + 1] = UInt16(min(max((sG * (wbG / dmax) * 65535.0).rounded(), 0.0), 65535.0))
            rgb16[i + 2] = UInt16(min(max((sB * (wbB / dmax) * 65535.0).rounded(), 0.0), 65535.0))
        }
    }
    let payloadData = rgb16.withUnsafeBytes { Data($0) }

    // Use standard sRGB/Rec709-like camXYZ (D65 -> camera) so neutral [1,1,1] camera maps to neutral Rec.2020
    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/proxy_clipped_g.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16U(width: w, height: h, colorSpace: .cameraNative, data: payloadData),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(
            camXYZ: [
                +3.2404542, -1.5371385, -0.4985314,
                -0.9692660, +1.8760108, +0.0415560,
                +0.0556434, -0.2040259, +1.0572252,
            ],
            forwardMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            wbMultipliers: [wbR, wbG, wbB, wbG],
            asShotWBApplied: false
        ),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )

    let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    let params = EffectiveDevelopParams.resolve(preset: preset)
    let rendered = try await engine.render(frame: frame, params: params, outputSpec: RenderOutputSpec())
    let hdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.hdrLinearTexture))

    let off = (16 * w + 16) * 4
    let r = hdrPx[off + 0], g = hdrPx[off + 1], b = hdrPx[off + 2]
    #expect(g > 1.35, "Clipped G must be reconstructed above 1.35 (not clamped at ~1.0), got G=\(g)")
    #expect(r <= g * 1.25 && b <= g * 1.25, "Highlight turned magenta: R=\(r) G=\(g) B=\(b)")

    // Also verify .linearRec2020 with !isLosslessMS && !asShotWBApplied reconstructs clipped G without magenta clipping
    let cam2020 = ColorTransforms.buildCameraToRec2020Matrix(
        matrices: frame.colorMatrices,
        dcp: nil,
        sceneKelvin: ColorTransforms.estimateSceneKelvin(matrices: frame.colorMatrices)
    )
    var rgb2020_16 = [UInt16](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        for x in 0..<w {
            let inCore = (x >= 12 && x < 20 && y >= 12 && y < 20)
            let sR = inCore ? (1.75 / wbR) : (0.85 / wbR)
            let sG = inCore ? 1.00 : 0.85
            let sB = inCore ? (1.75 / wbB) : (0.85 / wbB)
            let camPre = SIMD3<Double>(sR * (wbR / dmax), sG * (wbG / dmax), sB * (wbB / dmax))
            let rec = cam2020 * camPre
            let i = (y * w + x) * 3
            rgb2020_16[i + 0] = UInt16(min(max((rec.x * 65535.0).rounded(), 0.0), 65535.0))
            rgb2020_16[i + 1] = UInt16(min(max((rec.y * 65535.0).rounded(), 0.0), 65535.0))
            rgb2020_16[i + 2] = UInt16(min(max((rec.z * 65535.0).rounded(), 0.0), 65535.0))
        }
    }
    let frame2020 = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/proxy_clipped_g_2020.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16U(width: w, height: h, colorSpace: .linearRec2020, data: rgb2020_16.withUnsafeBytes { Data($0) }),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: frame.colorMatrices,
        isLosslessMS: false,
        exif: WhitelistedExif()
    )
    let rendered2020 = try await engine.render(frame: frame2020, params: params, outputSpec: RenderOutputSpec())
    let hdrPx2020 = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered2020.hdrLinearTexture))
    let r2 = hdrPx2020[off + 0], g2 = hdrPx2020[off + 1], b2 = hdrPx2020[off + 2]
    #expect(g2 > 1.35, "linearRec2020 clipped G must be reconstructed > 1.35, got G=\(g2)")
    #expect(r2 <= g2 * 1.25 && b2 <= g2 * 1.25, "linearRec2020 highlight turned magenta: R=\(r2) G=\(g2) B=\(b2)")
}

// MARK: - 22. Regression: GainMapSynthesizer Negative-Gain Zero-Anchor & lockLegacyBounds .rgb3ch

@Test
func testGainMapZeroAnchorExtremeGammaAndLegacyBoundsRGB3ch() throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)
    let k = Float(GainMapMetadata.symmetricOffset)

    // 1) Negative gain [-1.5, +2.0] with exact G = 0.0 midtone row at gamma = 0.25 and 4.0
    let w = 64, h = 64
    var sdrPx = [Float](repeating: 0, count: w * h * 4)
    var hdrPx = [Float](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        let targetG: Float
        if y < 20 {
            targetG = -1.5 * Float(20 - y) / 20.0
        } else if y < 44 {
            targetG = 0.0
        } else {
            targetG = 2.0 * Float(y - 43) / 20.0
        }
        let sVal: Float = 0.45
        let hVal = (sVal + k) * exp2(targetG) - k
        for x in 0..<w {
            let i = (y * w + x) * 4
            sdrPx[i + 0] = sVal; sdrPx[i + 1] = sVal; sdrPx[i + 2] = sVal; sdrPx[i + 3] = 1.0
            hdrPx[i + 0] = hVal; hdrPx[i + 1] = hVal; hdrPx[i + 2] = hVal; hdrPx[i + 3] = 1.0
        }
    }
    let sdrTex = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: sdrPx)
    let hdrTex = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: hdrPx)

    for gam in [0.25, 4.0] {
        let res = try engine.gainMapSynthesizer.synthesize(
            commandQueue: engine.commandQueue,
            sdrLinearTexture: sdrTex,
            hdrLinearTexture: hdrTex,
            baseColorSpace: .displayP3,
            targetHeadroom: .x4,
            midtoneAnchorP: 0.80,
            gamma: gam,
            channels: .mono1ch,
            resolution: .full,
            lockLegacyBounds: false,
            deadzoneScale: 0.0,
            enableDither: true
        )
        var maxZeroRelErr = 0.0
        for x in 0..<w {
            let dec = decodeISOGainMapAtGMCoord(
                sdrLin: SIMD3<Double>(0.45, 0.45, 0.45),
                gmBuffer: res.buffer,
                metadata: res.metadata,
                gx: x,
                gy: 32,
                weightW: 1.0
            )
            maxZeroRelErr = max(maxZeroRelErr, abs(dec.x - 0.45) / 0.45)
        }
        #expect(maxZeroRelErr < 0.005, "Zero-anchor midtone error \(maxZeroRelErr) >= 0.5% at gamma=\(gam)")
    }

    // Non-finite gamma (.nan / .infinity) passed directly must sanitize to 1.0 and preserve valid gain map bytes
    for badGamma in [Double.nan, Double.infinity, -Double.infinity] {
        let sanitized = try engine.gainMapSynthesizer.synthesize(
            commandQueue: engine.commandQueue,
            sdrLinearTexture: sdrTex,
            hdrLinearTexture: hdrTex,
            baseColorSpace: .displayP3,
            targetHeadroom: .x4,
            midtoneAnchorP: 0.80,
            gamma: badGamma,
            channels: .mono1ch,
            resolution: .full,
            lockLegacyBounds: false,
            deadzoneScale: 0.0,
            enableDither: true
        )
        #expect(sanitized.metadata.gamma == [1.0], "Non-finite gamma \(badGamma) must sanitize to 1.0, got \(sanitized.metadata.gamma)")
        #expect(sanitized.metadata.gainMapMin.allSatisfy(\.isFinite) && sanitized.metadata.gainMapMax.allSatisfy(\.isFinite))
        #expect(sanitized.buffer.data[(63 * w + 32)] > 200, "Non-finite gamma corrupted gain map payload")
    }

    // 2) lockLegacyBounds = true + .rgb3ch with R=0 gain and B=+2.5 EV gain
    let lw = 32, lh = 32
    var lSdr = [Float](repeating: 0, count: lw * lh * 4)
    var lHdr = [Float](repeating: 0, count: lw * lh * 4)
    for i in stride(from: 0, to: lw * lh * 4, by: 4) {
        lSdr[i + 0] = 0.2; lSdr[i + 1] = 0.2; lSdr[i + 2] = 0.5; lSdr[i + 3] = 1.0
        lHdr[i + 0] = 0.2; lHdr[i + 1] = 0.2; lHdr[i + 2] = 2.8; lHdr[i + 3] = 1.0
    }
    let lSdrTex = try makeSharedRGBA16FTexture(device: dev, width: lw, height: lh, pixels: lSdr)
    let lHdrTex = try makeSharedRGBA16FTexture(device: dev, width: lw, height: lh, pixels: lHdr)
    let legacy3 = try engine.gainMapSynthesizer.synthesize(
        commandQueue: engine.commandQueue,
        sdrLinearTexture: lSdrTex,
        hdrLinearTexture: lHdrTex,
        baseColorSpace: .displayP3,
        targetHeadroom: .defaultHDR,
        midtoneAnchorP: 0.80,
        gamma: 1.0,
        channels: .rgb3ch,
        resolution: .full,
        lockLegacyBounds: true
    )
    #expect(legacy3.metadata.gainMapMax == [2.5, 2.5, 2.5])
    // BGRA8 byte 0 is Blue channel
    #expect(legacy3.buffer.data[0] > 200, "Blue HDR gain was lost in lockLegacyBounds .rgb3ch: byte=\(legacy3.buffer.data[0])")
}

// MARK: - 23. Regression: Out-of-Range .cube LUT, NaN Domain & Pure Black Preservation

@Test
func testCubeLUTOutOfRangeHighlightNaNDomainAndPureBlack() async throws {
    // 1) DOMAIN_MIN NaN & inverted domain must throw
    #expect(throws: CubeLUTError.self) {
        _ = try CubeLUT(parsing: "LUT_1D_SIZE 2\nDOMAIN_MIN NaN 0 0\n0 0 0\n1 1 1\n")
    }
    #expect(throws: CubeLUTError.self) {
        _ = try CubeLUT(parsing: "LUT_1D_SIZE 2\nDOMAIN_MIN 1 0 0\nDOMAIN_MAX 0 1 1\n0 0 0\n1 1 1\n")
    }

    // 2) 3D LUT with out-of-range corner (1,1,1) = (2.0, 2.0, 2.0) at +6 EV (64.0) must NOT black out,
    //    and (0,0,0) corner = (0,0,0) must preserve exact (0,0,0) black!
    let cubeText = """
    LUT_3D_SIZE 2
    0.0 0.0 0.0
    2.0 0.0 0.0
    0.0 2.0 0.0
    2.0 2.0 0.0
    0.0 0.0 2.0
    2.0 0.0 2.0
    0.0 2.0 2.0
    2.0 2.0 2.0
    """
    let lutURL = FileManager.default.temporaryDirectory.appendingPathComponent("oor_lut_\(UUID().uuidString).cube")
    defer { try? FileManager.default.removeItem(at: lutURL) }
    try cubeText.write(to: lutURL, atomically: true, encoding: .utf8)

    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)
    let w = 16, h = 16
    var rgb = [Float](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        let v: Float = (y < h / 2) ? 0.0 : 64.0
        for x in 0..<w {
            let i = (y * w + x) * 3
            rgb[i + 0] = v; rgb[i + 1] = v; rgb[i + 2] = v
        }
    }
    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/oor_lut.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16F(width: w, height: h, colorSpace: .linearRec2020, data: makeLinearRGB16FData(pixelsRGB: rgb)),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )
    var preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    preset.developDefaults.cubeLUTPath = lutURL.path
    let rendered = try await engine.render(frame: frame, params: EffectiveDevelopParams.resolve(preset: preset), outputSpec: RenderOutputSpec())
    let hdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.hdrLinearTexture))
    let sdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.sdrLinearTexture))

    let blackVal = hdrPx[(2 * w + 8) * 4]
    let hiHDR = hdrPx[(12 * w + 8) * 4]
    let hiSDR = sdrPx[(12 * w + 8) * 4]
    #expect(blackVal == 0.0, "Pure black (0,0,0) must stay 0.0 through non-lifting LUT, got \(blackVal)")
    #expect(hiHDR.isFinite && hiHDR > 4.0, "Out-of-range .cube corner at +6 EV must stay bright HDR, got \(hiHDR)")
    #expect(hiSDR.isFinite && hiSDR > 0.85, "Out-of-range .cube corner at +6 EV must stay bright SDR, got \(hiSDR)")
}

// MARK: - 24. Regression: computeOutputGeometry maxLongEdge Cap, estimateAsShotSceneXYZ & HLG +Inf

@Test
func testGeometryMaxLongEdgeCapAsShotXYZAndHLGInfGuard() async throws {
    // 1) maxLongEdge = 2050 with .half + .rgb3ch must stay <= 2050 (2048) and 4-aligned across all aspects/orientations
    for orient in 1...8 {
        for aspect in AspectRatio.allCases {
            let geom = ColorTransforms.computeOutputGeometry(
                srcWidth: 7008,
                srcHeight: 4672,
                orientation: orient,
                cropAspect: aspect,
                cropOffset: .centered,
                maxLongEdge: 2050,
                gainMapResolution: .half,
                gainMapChannels: .rgb3ch
            )
            #expect(max(geom.outWidth, geom.outHeight) <= 2050, "Exceeded maxLongEdge=2050: \(geom.outWidth)x\(geom.outHeight)")
            #expect(geom.outWidth % 4 == 0 && geom.outHeight % 4 == 0)
        }
    }
    let origGeom = ColorTransforms.computeOutputGeometry(
        srcWidth: 7008,
        srcHeight: 4672,
        orientation: 1,
        cropAspect: .original,
        cropOffset: .centered,
        maxLongEdge: 2050,
        gainMapResolution: .half,
        gainMapChannels: .rgb3ch
    )
    #expect(origGeom.outWidth == 2048)

    // 2) estimateAsShotSceneXYZ with asShotWBApplied == true & uniform [1,1,1,1] returns xyzD65
    let xyz = ColorTransforms.estimateAsShotSceneXYZ(
        matrices: CameraColorMatrices(
            camXYZ: [
                +3.2404542, -1.5371385, -0.4985314,
                -0.9692660, +1.8760108, +0.0415560,
                +0.0556434, -0.2040259, +1.0572252,
            ],
            forwardMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            wbMultipliers: [1, 1, 1, 1],
            asShotWBApplied: true
        )
    )
    #expect(simd_distance(xyz, ColorTransforms.xyzD65) < 1e-6)

    // 3) HLG +Inf guard must clamp to peak white (Y_10 = 940), never NaN -> 64 black
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)
    let w = 8, h = 8
    var infPixels = [Float](repeating: 0, count: w * h * 4)
    for i in stride(from: 0, to: infPixels.count, by: 4) {
        infPixels[i + 0] = Float.infinity
        infPixels[i + 1] = Float.infinity
        infPixels[i + 2] = Float.infinity
        infPixels[i + 3] = 1.0
    }
    let infTex = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: infPixels)
    let pb = try await engine.generateHLGPixelBuffer(from: infTex, targetDimensions: PixelDimensions(width: w, height: h)).buffer
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let yBase = try #require(CVPixelBufferGetBaseAddressOfPlane(pb, 0)).assumingMemoryBound(to: UInt16.self)
    let yCode = Int((yBase[0] >> 6) & 0x3FF)
    #expect(yCode == 940, "HLG +Inf input should clamp to peak white 940, got \(yCode)")
}

// MARK: - 25. Regression: .linearRGB16U .linearRec2020 Clamped-White Highlight Recovery (No Magenta)

@Test
func testLinearRGB16ULinearRec2020ClampedWhiteHighlightRecovery() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    let w = 48, h = 48
    let wbR = 1890.0 / 1024.0
    let wbG = 1.0
    let wbB = 2189.0 / 1024.0
    let dmax = max(wbR, max(wbG, wbB))

    // Sony-like camXYZ where clipped sensor white (camPre = (wbR/dmax, wbG/dmax, 1.0))
    // pushes Rec.2020 B > 1.0 so LibRaw's uint16 output_color=8 clamps B to 65535 (1.0),
    // distorting cam2020.inverse * rawNorm below the unadjusted 0.97 threshold.
    let matrices = CameraColorMatrices(
        camXYZ: [
            +0.85, -0.22, -0.08,
            -0.40, +1.25, +0.18,
            -0.05, +0.15, +0.68,
        ],
        forwardMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
        wbMultipliers: [wbR, wbG, wbB, wbG],
        asShotWBApplied: false
    )
    let sceneKelvin = ColorTransforms.estimateSceneKelvin(matrices: matrices)
    let cam2020 = ColorTransforms.buildCameraToRec2020Matrix(
        matrices: matrices,
        dcp: nil,
        sceneKelvin: sceneKelvin
    )

    let clippedWhitePre = SIMD3<Double>(wbR / dmax, wbG / dmax, wbB / dmax)
    let recWhiteUnclamped = cam2020 * clippedWhitePre
    #expect(recWhiteUnclamped.z > 1.02, "Test geometry must saturate Rec.2020 uint16 channel: \(recWhiteUnclamped)")
    let recWhiteClamped = simd_clamp(recWhiteUnclamped, SIMD3<Double>(repeating: 0.0), SIMD3<Double>(repeating: 1.0))
    let invertedClamped = cam2020.inverse * recWhiteClamped
    #expect(invertedClamped.z < 0.97 * (wbB / dmax), "Clamped Rec.2020 must distort camNorm.b below 0.97 threshold")

    var rgb2020_16 = [UInt16](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        for x in 0..<w {
            let inWhiteCore = (x >= 16 && x < 32 && y >= 16 && y < 32)
            let inWarmPatch = (x >= 4 && x < 12 && y >= 4 && y < 12)
            let camPre: SIMD3<Double>
            if inWhiteCore {
                // Fully clipped sensor white (R=1, G=1, B=1)
                camPre = clippedWhitePre
            } else if inWarmPatch {
                // Unclipped B & G warm highlight (only R clipped; after WB R=1.85 > G=0.72 > B=0.35)
                camPre = SIMD3<Double>(wbR / dmax, 0.72 * (wbG / dmax), 0.35 * (wbG / dmax))
            } else {
                // Unclipped neutral-warm surround
                camPre = SIMD3<Double>(0.55 / dmax, 0.50 / dmax, 0.45 / dmax)
            }
            let rec = cam2020 * camPre
            let i = (y * w + x) * 3
            rgb2020_16[i + 0] = UInt16(min(max((rec.x * 65535.0).rounded(), 0.0), 65535.0))
            rgb2020_16[i + 1] = UInt16(min(max((rec.y * 65535.0).rounded(), 0.0), 65535.0))
            rgb2020_16[i + 2] = UInt16(min(max((rec.z * 65535.0).rounded(), 0.0), 65535.0))
        }
    }

    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/rec2020_clamped_white.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16U(width: w, height: h, colorSpace: .linearRec2020, data: rgb2020_16.withUnsafeBytes { Data($0) }),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: matrices,
        isLosslessMS: false,
        exif: WhitelistedExif()
    )

    let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    for mode in [HighlightReconstructionMode.opposedInpaint, .rebuild] {
        let params = EffectiveDevelopParams.resolve(
            preset: preset,
            delta: PerPhotoDelta(highlightReconstructionOverride: mode)
        )
        let rendered = try await engine.render(frame: frame, params: params, outputSpec: RenderOutputSpec())
        let hdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.hdrLinearTexture))

        // Clipped white core must reconstruct neutral white (not magenta)
        let whiteOff = (24 * w + 24) * 4
        let rw = hdrPx[whiteOff + 0], gw = hdrPx[whiteOff + 1], bw = hdrPx[whiteOff + 2]
        #expect(rw.isFinite && gw.isFinite && bw.isFinite)
        #expect(gw > 1.10, "[\(mode)] Clipped white core G must not dip below 1.10: R=\(rw) G=\(gw) B=\(bw)")
        #expect(rw <= gw * 1.15 && bw <= gw * 1.15, "[\(mode)] Clipped white core turned magenta: R=\(rw) G=\(gw) B=\(bw)")

        // Warm highlight with unclipped B/G must keep warm hue (R > G > B)
        let warmOff = (8 * w + 8) * 4
        let rWarm = hdrPx[warmOff + 0], gWarm = hdrPx[warmOff + 1], bWarm = hdrPx[warmOff + 2]
        #expect(rWarm > gWarm && gWarm > bWarm, "[\(mode)] Warm highlight hue corrupted: R=\(rWarm) G=\(gWarm) B=\(bWarm)")
    }
}

// MARK: - 26. Regression: OKLab Soft Gamut Map Saturated Blue OOG Ramp (No Outer-Lobe Jump)

@Test
func testOKLabSoftGamutMapBlueOOGRampNoOuterLobeJump() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    // 1) Exact 256-step Rec2020_Blue_to_OOG ramp: (0.25*(1-t), 0.25*(1-t), 0.35+0.55*t), .openDRT, P=0.95
    let w = 256, h = 4
    var rgb = [Float](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        for x in 0..<w {
            let t = Float(x) / Float(w - 1)
            let i = (y * w + x) * 3
            rgb[i + 0] = 0.25 * (1.0 - t)
            rgb[i + 1] = 0.25 * (1.0 - t)
            rgb[i + 2] = 0.35 + 0.55 * t
        }
    }
    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/rec2020_blue_oog.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16F(width: w, height: h, colorSpace: .linearRec2020, data: makeLinearRGB16FData(pixelsRGB: rgb)),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )

    var preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    preset.sdrToneMapper = .openDRT
    preset.midtoneAnchorP = 0.95
    let params = EffectiveDevelopParams.resolve(preset: preset)

    for cs in [BaseColorSpace.displayP3, BaseColorSpace.srgb] {
        let rendered = try await engine.render(
            frame: frame,
            params: params,
            outputSpec: RenderOutputSpec(baseColorSpace: cs)
        )
        let sdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.sdrLinearTexture))
        let hdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.hdrLinearTexture))

        // For x >= 199, R=0 bounds both SDR and HDR (before x=199, SDR's tMax<=1.0 ceiling bounds B earlier than HDR)
        var maxOuterBranchDiff = 0.0
        for (branch, px) in [("SDR", sdrPx), ("HDR", hdrPx)] {
            var maxRGBStep = 0.0
            var maxCDrop = 0.0
            var prevC = 0.0
            var prevRGB = SIMD3<Double>.zero
            for x in 0..<w {
                let off = (2 * w + x) * 4
                let p = SIMD3<Double>(Double(px[off]), Double(px[off + 1]), Double(px[off + 2]))
                #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite)
                #expect(min(p.x, min(p.y, p.z)) >= -1e-4)

                if cs == .displayP3 || x >= 199 {
                    let sdrP = SIMD3<Double>(Double(sdrPx[off]), Double(sdrPx[off + 1]), Double(sdrPx[off + 2]))
                    let hdrP = SIMD3<Double>(Double(hdrPx[off]), Double(hdrPx[off + 1]), Double(hdrPx[off + 2]))
                    maxOuterBranchDiff = max(maxOuterBranchDiff, max(abs(hdrP.x - sdrP.x), max(abs(hdrP.y - sdrP.y), abs(hdrP.z - sdrP.z))))
                }

                let lab = (cs == .srgb) ? ColorTransforms.linearSRGBToOKLab(p) : ColorTransforms.linearDisplayP3ToOKLab(p)
                let c = hypot(lab.y, lab.z)
                if x > 0 {
                    let rgbStep = max(abs(p.x - prevRGB.x), max(abs(p.y - prevRGB.y), abs(p.z - prevRGB.z)))
                    maxRGBStep = max(maxRGBStep, rgbStep)
                    if c < prevC {
                        maxCDrop = max(maxCDrop, prevC - c)
                    }
                }
                prevC = c
                prevRGB = p
            }

            if cs == .displayP3 {
                #expect(maxRGBStep < 0.016, "[\(cs) \(branch)] Unexpected RGB step \(maxRGBStep)")
                #expect(maxCDrop < 0.0035, "[\(cs) \(branch)] Unexpected OKLab C drop \(maxCDrop)")
            } else {
                // Before the fix, HDR jumped to the outer lobe at x=199->200 (0.059 RGB / 0.01267 C drop)
                #expect(maxRGBStep < 0.038, "[\(cs) \(branch)] Outer-lobe RGB jump detected: \(maxRGBStep)")
                #expect(maxCDrop < 0.008, "[\(cs) \(branch)] Outer-lobe OKLab C drop detected: \(maxCDrop)")
                let b199 = Double(px[(2 * w + 199) * 4 + 2])
                #expect(b199 < 0.85, "[\(cs) \(branch)] Pixel x=199 escaped to outer lobe (B=\(b199))")
            }
        }
        #expect(maxOuterBranchDiff < 5e-4, "[\(cs)] HDR diverged from SDR on R=0-bounded blue ramp: \(maxOuterBranchDiff)")
    }

    // 2) Constant-(L, h) blue gamut sweep in sRGB and Display P3: cBound is constant, so C must be strictly non-decreasing (maxCDrop < 0.002)
    let cw = 128, ch = 4
    var constHueRGB = [Float](repeating: 0, count: cw * ch * 3)
    // Pure constant-OKLab-(L=0.45, h=blue) ray from neutral gray (0.091) out past Rec.2020 blue
    for y in 0..<ch {
        for x in 0..<cw {
            let t = Float(x) / Float(cw - 1)
            let lab = SIMD3<Double>(0.48, -0.04 * Double(t), -0.32 * Double(t))
            let lmsC = ColorTransforms.oklabToLMSCbrt * lab
            let lms = lmsC * lmsC * lmsC
            let rec = ColorTransforms.lmsToRec2020 * lms
            let i = (y * cw + x) * 3
            constHueRGB[i + 0] = Float(max(rec.x, 0.0))
            constHueRGB[i + 1] = Float(max(rec.y, 0.0))
            constHueRGB[i + 2] = Float(max(rec.z, 0.0))
        }
    }
    let constFrame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/oklab_const_blue.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16F(width: cw, height: ch, colorSpace: .linearRec2020, data: makeLinearRGB16FData(pixelsRGB: constHueRGB)),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: cw, height: ch),
        orientation: 1,
        colorMatrices: CameraColorMatrices(),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )
    for cs in [BaseColorSpace.displayP3, BaseColorSpace.srgb] {
        let rendered = try await engine.render(frame: constFrame, params: params, outputSpec: RenderOutputSpec(baseColorSpace: cs))
        let hdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.hdrLinearTexture))
        var maxCDrop = 0.0
        var prevC = 0.0
        for x in 0..<cw {
            let off = (2 * cw + x) * 4
            let p = SIMD3<Double>(Double(hdrPx[off]), Double(hdrPx[off + 1]), Double(hdrPx[off + 2]))
            let lab = (cs == .srgb) ? ColorTransforms.linearSRGBToOKLab(p) : ColorTransforms.linearDisplayP3ToOKLab(p)
            let c = hypot(lab.y, lab.z)
            if x > 0 && c < prevC {
                maxCDrop = max(maxCDrop, prevC - c)
            }
            prevC = c
        }
        #expect(maxCDrop < 0.002, "[\(cs)] Constant-hue blue ray dropped chroma by \(maxCDrop)")
    }
}

// MARK: - 27. Regression: .linearRGB16U .linearRec2020 Unclamped Warm/Saturated Highlights Match .cameraNative

@Test
func testLinearRGB16ULinearRec2020UnclampedHighlightsMatchCameraNative() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)
    let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)

    // Real Sony ILCE-7CM2 camXYZ matrix
    let sonyCamXYZ: [Double] = [
        0.746000, -0.236500, -0.058800,
        -0.568700, 1.344200, 0.247400,
        -0.062400, 0.115600, 0.658400,
    ]

    struct Profile {
        let name: String
        let wb: [Double]
        let surroundSens: SIMD3<Double>
        // (label, xRange, yRange, cSens, checkWarmHue, isClampedWhite)
        let patches: [(String, Range<Int>, Range<Int>, SIMD3<Double>, Bool, Bool)]
    }

    let profiles: [Profile] = [
        Profile(
            name: "DSC02543_WB",
            wb: [2017.0 / 1024.0, 1.0, 2020.0 / 1024.0, 1.0],
            surroundSens: SIMD3<Double>(0.40, 0.72, 0.35),
            patches: [
                ("warmLantern1", 6..<16, 6..<16, SIMD3<Double>(0.950, 0.600, 0.090), true, false),
                ("warmLantern2", 26..<36, 6..<16, SIMD3<Double>(0.947, 0.596, 0.094), true, false),
                ("gClippedOnly", 46..<56, 6..<16, SIMD3<Double>(0.979, 1.000, 0.385), false, false),
                ("clampedWhite", 26..<36, 36..<46, SIMD3<Double>(1.000, 1.000, 1.000), false, true),
            ]
        ),
        Profile(
            name: "DSC02540_WB",
            wb: [1949.0 / 1024.0, 1.0, 2051.0 / 1024.0, 1.0],
            surroundSens: SIMD3<Double>(0.70, 0.55, 0.70),
            patches: [
                ("rgClippedBUnclipped", 6..<16, 6..<16, SIMD3<Double>(1.000, 1.000, 0.901), false, false),
                ("clampedWhite", 36..<46, 36..<46, SIMD3<Double>(1.000, 1.000, 1.000), false, true),
            ]
        ),
    ]

    let w = 64, h = 64
    for profile in profiles {
        let dmax = max(profile.wb[0], max(profile.wb[1], profile.wb[2]))
        let wbNorm = SIMD3<Double>(profile.wb[0] / dmax, profile.wb[1] / dmax, profile.wb[2] / dmax)
        let matrices = CameraColorMatrices(
            camXYZ: sonyCamXYZ,
            forwardMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            wbMultipliers: profile.wb,
            asShotWBApplied: false
        )
        let sceneKelvin = ColorTransforms.estimateSceneKelvin(matrices: matrices)
        let cam2020 = ColorTransforms.buildCameraToRec2020Matrix(
            matrices: matrices,
            dcp: nil,
            sceneKelvin: sceneKelvin
        )

        // Verify test geometry preconditions
        for (label, _, _, cSens, _, isClampedWhite) in profile.patches {
            let camPre = cSens * wbNorm
            let rec = cam2020 * camPre
            let maxRaw = max(rec.x, max(rec.y, rec.z))
            if isClampedWhite {
                #expect(rec.z > 1.05, "[\(profile.name)/\(label)] Clamped white must saturate Rec.2020 B > 1.05: \(rec)")
                let clamped = simd_clamp(rec, SIMD3<Double>(repeating: 0.0), SIMD3<Double>(repeating: 1.0))
                let inv = cam2020.inverse * clamped
                #expect(inv.z < 0.97 * wbNorm.z, "[\(profile.name)/\(label)] Clamped white must distort inv.z < 0.97*wbNorm.z")
            } else {
                #expect(maxRaw >= 0.95 && maxRaw < 0.999, "[\(profile.name)/\(label)] Expected unclamped maxRaw in [0.95, 0.999), got \(maxRaw)")
            }
        }

        var cam16 = [UInt16](repeating: 0, count: w * h * 3)
        var rec2020_16 = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                var cSens = profile.surroundSens
                for (_, xr, yr, pSens, _, _) in profile.patches where xr.contains(x) && yr.contains(y) {
                    cSens = pSens
                    break
                }
                let camPre = cSens * wbNorm
                let rec = cam2020 * camPre
                let i = (y * w + x) * 3
                cam16[i + 0] = UInt16(min(max((camPre.x * 65535.0).rounded(), 0.0), 65535.0))
                cam16[i + 1] = UInt16(min(max((camPre.y * 65535.0).rounded(), 0.0), 65535.0))
                cam16[i + 2] = UInt16(min(max((camPre.z * 65535.0).rounded(), 0.0), 65535.0))
                rec2020_16[i + 0] = UInt16(min(max((rec.x * 65535.0).rounded(), 0.0), 65535.0))
                rec2020_16[i + 1] = UInt16(min(max((rec.y * 65535.0).rounded(), 0.0), 65535.0))
                rec2020_16[i + 2] = UInt16(min(max((rec.z * 65535.0).rounded(), 0.0), 65535.0))
            }
        }

        let frameCam = DecodedRAWFrame(
            sourceURL: URL(fileURLWithPath: "/tmp/\(profile.name)_cam.arw"),
            backendUsed: .libraw,
            payload: .linearRGB16U(width: w, height: h, colorSpace: .cameraNative, data: cam16.withUnsafeBytes { Data($0) }),
            visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
            orientation: 1,
            colorMatrices: matrices,
            isLosslessMS: false,
            exif: WhitelistedExif()
        )
        let frame2020 = DecodedRAWFrame(
            sourceURL: URL(fileURLWithPath: "/tmp/\(profile.name)_2020.arw"),
            backendUsed: .libraw,
            payload: .linearRGB16U(width: w, height: h, colorSpace: .linearRec2020, data: rec2020_16.withUnsafeBytes { Data($0) }),
            visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
            orientation: 1,
            colorMatrices: matrices,
            isLosslessMS: false,
            exif: WhitelistedExif()
        )

        for mode in [HighlightReconstructionMode.opposedInpaint, .blend, .rebuild] {
            let params = EffectiveDevelopParams.resolve(
                preset: preset,
                delta: PerPhotoDelta(highlightReconstructionOverride: mode)
            )
            let renCam = try await engine.render(frame: frameCam, params: params, outputSpec: RenderOutputSpec())
            let ren2020 = try await engine.render(frame: frame2020, params: params, outputSpec: RenderOutputSpec())
            let pxCam = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(renCam.hdrLinearTexture))
            let px2020 = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(ren2020.hdrLinearTexture))

            for (label, xr, yr, _, checkWarmHue, isClampedWhite) in profile.patches {
                let cx = (xr.lowerBound + xr.upperBound) / 2
                let cy = (yr.lowerBound + yr.upperBound) / 2
                let off = (cy * w + cx) * 4
                let rC = pxCam[off + 0], gC = pxCam[off + 1], bC = pxCam[off + 2]
                let r2 = px2020[off + 0], g2 = px2020[off + 1], b2 = px2020[off + 2]
                #expect(r2.isFinite && g2.isFinite && b2.isFinite)

                if isClampedWhite {
                    #expect(g2 > 1.10, "[\(profile.name)/\(mode)/\(label)] Clamped white G < 1.10: (\(r2), \(g2), \(b2))")
                    #expect(r2 <= g2 * 1.15 && b2 <= g2 * 1.15, "[\(profile.name)/\(mode)/\(label)] Clamped white turned magenta: (\(r2), \(g2), \(b2))")
                    #expect(abs(r2 - g2) <= 0.05 && abs(b2 - g2) <= 0.05, "[\(profile.name)/\(mode)/\(label)] Clamped white not neutral: (\(r2), \(g2), \(b2))")
                } else {
                    let maxDiff = max(abs(r2 - rC), max(abs(g2 - gC), abs(b2 - bC)))
                    #expect(maxDiff < 0.02, "[\(profile.name)/\(mode)/\(label)] Rec2020 diverged from CameraNative by \(maxDiff): 2020=(\(r2), \(g2), \(b2)) vs cam=(\(rC), \(gC), \(bC))")
                    if checkWarmHue {
                        #expect(r2 > g2 * 1.5 && g2 > b2 * 1.5, "[\(profile.name)/\(mode)/\(label)] Warm lantern bleached toward neutral: (\(r2), \(g2), \(b2))")
                    }
                }
            }
        }
    }
}

// MARK: - 28. Regression: GainMapSynthesizer & Compensated Non-Finite Headroom/Gamma/Offset + JSON Encoding

@Test
func testGainMapNonFiniteHeadroomGammaOffsetAndJSONEncoding() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)
    let encoder = JSONEncoder()

    let w = 32, h = 32
    var sdrPx = [Float](repeating: 0, count: w * h * 4)
    var hdrPx = [Float](repeating: 0, count: w * h * 4)
    var rawRGB = [Float](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        for x in 0..<w {
            let t = Float(x) / Float(w - 1)
            let sVal: Float = 0.25 + 0.50 * t
            let hVal: Float = 0.25 + 3.50 * t
            let i4 = (y * w + x) * 4
            sdrPx[i4 + 0] = sVal; sdrPx[i4 + 1] = sVal; sdrPx[i4 + 2] = sVal; sdrPx[i4 + 3] = 1.0
            hdrPx[i4 + 0] = hVal; hdrPx[i4 + 1] = hVal; hdrPx[i4 + 2] = hVal; hdrPx[i4 + 3] = 1.0
            let i3 = (y * w + x) * 3
            rawRGB[i3 + 0] = hVal; rawRGB[i3 + 1] = hVal * 0.9; rawRGB[i3 + 2] = hVal * 0.8
        }
    }
    let sdrTex = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: sdrPx)
    let hdrTex = try makeSharedRGBA16FTexture(device: dev, width: w, height: h, pixels: hdrPx)

    let badGammas: [Double] = [.nan, .infinity, -.infinity, 0.0, -1.0]
    let badHeadroomStops: [Double] = [2.5, .nan, .infinity, -.infinity, -1.0]

    func assertValidMetadata(
        _ m: GainMapMetadata,
        expectedChannels: GainMapChannels,
        expectedGamma: Double,
        expectedBaseStops: Double,
        expectedAltStops: Double,
        expectedOffset: Double = GainMapMetadata.symmetricOffset,
        context: String
    ) throws {
        let chCount = (expectedChannels == .mono1ch) ? 1 : 3
        #expect(m.gainMapMin.count == chCount, "\(context): gainMapMin count")
        #expect(m.gainMapMax.count == chCount, "\(context): gainMapMax count")
        #expect(m.gamma.count == chCount, "\(context): gamma count")
        #expect(m.baseOffset.count == chCount, "\(context): baseOffset count")
        #expect(m.altOffset.count == chCount, "\(context): altOffset count")

        #expect(m.gainMapMin.allSatisfy { $0.isFinite }, "\(context): non-finite gainMapMin \(m.gainMapMin)")
        #expect(m.gainMapMax.allSatisfy { $0.isFinite }, "\(context): non-finite gainMapMax \(m.gainMapMax)")
        for c in 0..<chCount {
            #expect(m.gainMapMin[c] <= m.gainMapMax[c], "\(context): gainMapMin > gainMapMax at ch \(c)")
            #expect(m.gamma[c] == expectedGamma, "\(context): expected gamma \(expectedGamma), got \(m.gamma[c])")
            #expect(m.baseOffset[c].isFinite && m.baseOffset[c] > 0.0, "\(context): invalid baseOffset \(m.baseOffset)")
            #expect(m.altOffset[c].isFinite && m.altOffset[c] > 0.0, "\(context): invalid altOffset \(m.altOffset)")
            #expect(abs(m.baseOffset[c] - expectedOffset) < 1e-12, "\(context): unexpected baseOffset \(m.baseOffset[c])")
            #expect(abs(m.altOffset[c] - expectedOffset) < 1e-12, "\(context): unexpected altOffset \(m.altOffset[c])")
        }
        #expect(m.baseHeadroom.log2Value.isFinite && m.baseHeadroom.log2Value == expectedBaseStops, "\(context): baseHeadroom \(m.baseHeadroom)")
        #expect(m.alternateHeadroom.log2Value.isFinite && m.alternateHeadroom.log2Value >= 0.0, "\(context): non-finite/negative altHeadroom \(m.alternateHeadroom)")
        #expect(m.alternateHeadroom == HeadroomStops(log2Value: expectedAltStops), "\(context): expected altHeadroom \(expectedAltStops), got \(m.alternateHeadroom.log2Value)")

        let jsonData = try encoder.encode(m)
        #expect(!jsonData.isEmpty, "\(context): JSONEncoder produced empty data")
    }

    // 1) Direct GainMapSynthesizer.synthesize matrix: (1ch, 3ch) x (lockLegacyBounds false/true) x 5 bad gammas x 5 headroom values
    for channels in [GainMapChannels.mono1ch, .rgb3ch] {
        for lockLegacy in [false, true] {
            for rawGamma in badGammas {
                let expectedGamma = rawGamma.isFinite ? min(max(rawGamma, 0.25), 4.0) : 1.0
                for rawStops in badHeadroomStops {
                    let safeTarget = HeadroomStops(log2Value: rawStops.isFinite ? max(rawStops, 0.0) : 0.0)
                    let res = try engine.gainMapSynthesizer.synthesize(
                        commandQueue: engine.commandQueue,
                        sdrLinearTexture: sdrTex,
                        hdrLinearTexture: hdrTex,
                        baseColorSpace: .displayP3,
                        targetHeadroom: HeadroomStops(log2Value: rawStops),
                        midtoneAnchorP: 0.80,
                        gamma: rawGamma,
                        channels: channels,
                        resolution: .full,
                        lockLegacyBounds: lockLegacy,
                        deadzoneScale: 0.0
                    )
                    try assertValidMetadata(
                        res.metadata,
                        expectedChannels: channels,
                        expectedGamma: expectedGamma,
                        expectedBaseStops: 0.0,
                        expectedAltStops: safeTarget.log2Value,
                        context: "synthesize(ch=\(channels), legacy=\(lockLegacy), g=\(rawGamma), h=\(rawStops))"
                    )
                    if lockLegacy {
                        let expectedMax = safeTarget.log2Value > 1e-5 ? safeTarget.log2Value : 0.0
                        #expect(res.metadata.gainMapMin.allSatisfy { $0 == 0.0 })
                        #expect(res.metadata.gainMapMax.allSatisfy { $0 == expectedMax })
                    }
                }
            }
        }
    }

    // 2) Poisoned kOffset, midtoneAnchorP, and deadzoneScale in synthesize
    for badVal in [Double.nan, .infinity, -.infinity, -1.0, 0.0] {
        let expectedK = (badVal.isFinite && badVal >= 0.0) ? min(max(badVal, 1e-6), 10.0) : GainMapMetadata.symmetricOffset
        let res = try engine.gainMapSynthesizer.synthesize(
            commandQueue: engine.commandQueue,
            sdrLinearTexture: sdrTex,
            hdrLinearTexture: hdrTex,
            baseColorSpace: .displayP3,
            targetHeadroom: .defaultHDR,
            midtoneAnchorP: badVal,
            gamma: 1.0,
            channels: .rgb3ch,
            resolution: .full,
            lockLegacyBounds: false,
            kOffset: badVal,
            deadzoneScale: badVal
        )
        try assertValidMetadata(
            res.metadata,
            expectedChannels: .rgb3ch,
            expectedGamma: 1.0,
            expectedBaseStops: 0.0,
            expectedAltStops: HeadroomStops.defaultHDR.log2Value,
            expectedOffset: expectedK,
            context: "synthesize_poisoned_params(\(badVal))"
        )
    }

    // 3) recomputeGainMapCompensated (1ch & 3ch) with poisoned gamma, alternateHeadroom, baseHeadroom, and baseOffset
    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/nonfinite_recomp.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16F(width: w, height: h, colorSpace: .linearRec2020, data: makeLinearRGB16FData(pixelsRGB: rawRGB)),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )
    let preset = try PresetLoader.loadBuiltIn(id: .xiaohongshuJPG)
    var modPreset = preset
    modPreset.maxLongEdge = nil
    modPreset.cropAspect = .original
    let rendered = try await engine.render(
        frame: frame,
        params: EffectiveDevelopParams.resolve(preset: modPreset),
        outputSpec: RenderOutputSpec(targetBitDepth: .bit8, baseColorSpace: .displayP3, gainMapChannels: .mono1ch, gainMapResolution: .full)
    )
    let renHdrTex = try #require(rendered.hdrLinearTexture)
    let jpegData = try encodeJPEGData(from: rendered.sdrCGImage, quality: 0.70)

    for channels in [GainMapChannels.mono1ch, .rgb3ch] {
        for rawGamma in badGammas {
            let expectedGamma = rawGamma.isFinite ? min(max(rawGamma, 0.25), 4.0) : 1.0
            for rawStops in badHeadroomStops {
                let expectedAltStops = rawStops.isFinite ? max(rawStops, 0.0) : 0.0
                var poisonedMeta = rendered.gainMap.metadata
                poisonedMeta.baseHeadroom = HeadroomStops(log2Value: rawStops == 2.5 ? 0.0 : rawStops)
                poisonedMeta.alternateHeadroom = HeadroomStops(log2Value: rawStops)
                poisonedMeta.baseOffset = [rawStops]

                let expectedBaseStops = poisonedMeta.baseHeadroom.log2Value.isFinite ? max(poisonedMeta.baseHeadroom.log2Value, 0.0) : 0.0
                let expectedK = (rawStops.isFinite && rawStops >= 0.0) ? min(max(rawStops, 1e-6), 10.0) : GainMapMetadata.symmetricOffset

                let comp = try await engine.recomputeGainMapCompensated(
                    hdrTexture: renHdrTex,
                    compressedSDRJPEGData: jpegData,
                    metadata: poisonedMeta,
                    gamma: rawGamma,
                    channels: channels,
                    resolution: .full
                )
                try assertValidMetadata(
                    comp.metadata,
                    expectedChannels: channels,
                    expectedGamma: expectedGamma,
                    expectedBaseStops: expectedBaseStops,
                    expectedAltStops: expectedAltStops,
                    expectedOffset: expectedK,
                    context: "recomputeGainMapCompensated(ch=\(channels), g=\(rawGamma), h=\(rawStops))"
                )
            }
        }
    }
}

// MARK: - 29. Regression: Unit-WB twoCh_RG_1.00_unitWB & Method B2 Demosaic Overshoot (camNorm[k] > ceilCam[k])

@Test
func testLinearRGB16UUnitWBAndMethodB2DemosaicOvershoot() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)
    let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)

    // Real Sony ILCE-7CM2 camXYZ matrix
    let sonyCamXYZ: [Double] = [
        0.746000, -0.236500, -0.058800,
        -0.568700, 1.344200, 0.247400,
        -0.062400, 0.115600, 0.658400,
    ]
    let w = 48, h = 48

    // Part 1: twoCh_RG_1.00_unitWB (wb=[1,1,1,1], cSens=(1.0, 1.0, 0.35))
    do {
        let unitMatrices = CameraColorMatrices(
            camXYZ: sonyCamXYZ,
            forwardMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            wbMultipliers: [1.0, 1.0, 1.0, 1.0],
            asShotWBApplied: false
        )
        let sceneKelvin = ColorTransforms.estimateSceneKelvin(matrices: unitMatrices)
        let cam2020 = ColorTransforms.buildCameraToRec2020Matrix(matrices: unitMatrices, dcp: nil, sceneKelvin: sceneKelvin)
        let coreSens = SIMD3<Double>(1.0, 1.0, 0.35)
        let recRaw = cam2020 * coreSens
        #expect(recRaw.x > 1.05 && recRaw.y > 1.05 && recRaw.z < 0.5, "Precondition: twoCh_RG_1.00_unitWB must clip Rec2020 R & G")

        var cam16 = [UInt16](repeating: 0, count: w * h * 3)
        var rec2020_16 = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let inCore = (x >= 16 && x < 32 && y >= 16 && y < 32)
                let cSens = inCore ? coreSens : SIMD3<Double>(0.70, 0.70, 0.35)
                let rec = cam2020 * cSens
                let i = (y * w + x) * 3
                cam16[i + 0] = UInt16(min(max((cSens.x * 65535.0).rounded(), 0.0), 65535.0))
                cam16[i + 1] = UInt16(min(max((cSens.y * 65535.0).rounded(), 0.0), 65535.0))
                cam16[i + 2] = UInt16(min(max((cSens.z * 65535.0).rounded(), 0.0), 65535.0))
                rec2020_16[i + 0] = UInt16(min(max((rec.x * 65535.0).rounded(), 0.0), 65535.0))
                rec2020_16[i + 1] = UInt16(min(max((rec.y * 65535.0).rounded(), 0.0), 65535.0))
                rec2020_16[i + 2] = UInt16(min(max((rec.z * 65535.0).rounded(), 0.0), 65535.0))
            }
        }

        let frameCam = DecodedRAWFrame(
            sourceURL: URL(fileURLWithPath: "/tmp/unit_wb_cam.arw"),
            backendUsed: .libraw,
            payload: .linearRGB16U(width: w, height: h, colorSpace: .cameraNative, data: cam16.withUnsafeBytes { Data($0) }),
            visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
            orientation: 1,
            colorMatrices: unitMatrices,
            isLosslessMS: false,
            exif: WhitelistedExif()
        )
        let frame2020 = DecodedRAWFrame(
            sourceURL: URL(fileURLWithPath: "/tmp/unit_wb_2020.arw"),
            backendUsed: .libraw,
            payload: .linearRGB16U(width: w, height: h, colorSpace: .linearRec2020, data: rec2020_16.withUnsafeBytes { Data($0) }),
            visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
            orientation: 1,
            colorMatrices: unitMatrices,
            isLosslessMS: false,
            exif: WhitelistedExif()
        )

        for mode in [HighlightReconstructionMode.opposedInpaint, .blend, .rebuild] {
            let params = EffectiveDevelopParams.resolve(preset: preset, delta: PerPhotoDelta(highlightReconstructionOverride: mode))
            let renCam = try await engine.render(frame: frameCam, params: params, outputSpec: RenderOutputSpec())
            let ren2020 = try await engine.render(frame: frame2020, params: params, outputSpec: RenderOutputSpec())
            let pxCam = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(renCam.hdrLinearTexture))
            let px2020 = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(ren2020.hdrLinearTexture))

            let off = (24 * w + 24) * 4
            let maxDiff = max(abs(px2020[off] - pxCam[off]), max(abs(px2020[off + 1] - pxCam[off + 1]), abs(px2020[off + 2] - pxCam[off + 2])))
            #expect(maxDiff < 0.02, "[twoCh_RG_1.00_unitWB/\(mode)] Rec2020 diverged from CameraNative by \(maxDiff): 2020=(\(px2020[off]), \(px2020[off+1]), \(px2020[off+2])) vs cam=(\(pxCam[off]), \(pxCam[off+1]), \(pxCam[off+2]))")
        }
    }

    // Part 2: camNorm[k] > ceilCam[k] demosaic overshoot (DSC02540.ARW full-res (1251, 3604) geometry:
    // raw2020 = (56812, 21726, 65535) gives camNorm.x > ceilCam.x while raw2020.b == 65535 and camNorm.z < 0.985)
    do {
        let wb = [1949.0 / 1024.0, 1.0, 2051.0 / 1024.0, 1.0]
        let dmax = max(wb[0], max(wb[1], wb[2]))
        let ceilCam = SIMD3<Double>(wb[0] / dmax, wb[1] / dmax, wb[2] / dmax)
        let matrices = CameraColorMatrices(
            camXYZ: sonyCamXYZ,
            forwardMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            wbMultipliers: wb,
            asShotWBApplied: false
        )
        let sceneKelvin = ColorTransforms.estimateSceneKelvin(matrices: matrices)
        let cam2020 = ColorTransforms.buildCameraToRec2020Matrix(matrices: matrices, dcp: nil, sceneKelvin: sceneKelvin)
        let preMat = cam2020.inverse

        let overshootRaw2020: (UInt16, UInt16, UInt16) = (56812, 21726, 65535)
        let refRawCam: (UInt16, UInt16, UInt16) = (63176, 32719, 65535)
        let rawNorm = SIMD3<Double>(Double(overshootRaw2020.0) / 65535.0, Double(overshootRaw2020.1) / 65535.0, Double(overshootRaw2020.2) / 65535.0)
        let camNorm = preMat * rawNorm
        #expect(camNorm.x > ceilCam.x, "Precondition: demosaic overshoot must push camNorm.x > ceilCam.x (\(camNorm.x) > \(ceilCam.x))")
        #expect(camNorm.z < 0.985 * ceilCam.z, "Precondition: camNorm.z must start below 0.985*ceilCam.z (\(camNorm.z))")

        var cam16 = [UInt16](repeating: 0, count: w * h * 3)
        var rec2020_16 = [UInt16](repeating: 0, count: w * h * 3)
        let surroundCamPre = SIMD3<Double>(0.55 / dmax, 0.55 / dmax, 0.55 / dmax)
        let surroundRec = cam2020 * surroundCamPre
        for y in 0..<h {
            for x in 0..<w {
                let inCore = (x >= 16 && x < 32 && y >= 16 && y < 32)
                let i = (y * w + x) * 3
                if inCore {
                    cam16[i + 0] = refRawCam.0; cam16[i + 1] = refRawCam.1; cam16[i + 2] = refRawCam.2
                    rec2020_16[i + 0] = overshootRaw2020.0; rec2020_16[i + 1] = overshootRaw2020.1; rec2020_16[i + 2] = overshootRaw2020.2
                } else {
                    cam16[i + 0] = UInt16((surroundCamPre.x * 65535.0).rounded())
                    cam16[i + 1] = UInt16((surroundCamPre.y * 65535.0).rounded())
                    cam16[i + 2] = UInt16((surroundCamPre.z * 65535.0).rounded())
                    rec2020_16[i + 0] = UInt16((surroundRec.x * 65535.0).rounded())
                    rec2020_16[i + 1] = UInt16((surroundRec.y * 65535.0).rounded())
                    rec2020_16[i + 2] = UInt16((surroundRec.z * 65535.0).rounded())
                }
            }
        }

        let frameCam = DecodedRAWFrame(
            sourceURL: URL(fileURLWithPath: "/tmp/overshoot_cam.arw"),
            backendUsed: .libraw,
            payload: .linearRGB16U(width: w, height: h, colorSpace: .cameraNative, data: cam16.withUnsafeBytes { Data($0) }),
            visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
            orientation: 1,
            colorMatrices: matrices,
            isLosslessMS: false,
            exif: WhitelistedExif()
        )
        let frame2020 = DecodedRAWFrame(
            sourceURL: URL(fileURLWithPath: "/tmp/overshoot_2020.arw"),
            backendUsed: .libraw,
            payload: .linearRGB16U(width: w, height: h, colorSpace: .linearRec2020, data: rec2020_16.withUnsafeBytes { Data($0) }),
            visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
            orientation: 1,
            colorMatrices: matrices,
            isLosslessMS: false,
            exif: WhitelistedExif()
        )

        for mode in [HighlightReconstructionMode.opposedInpaint, .blend, .rebuild] {
            let params = EffectiveDevelopParams.resolve(preset: preset, delta: PerPhotoDelta(highlightReconstructionOverride: mode))
            let renCam = try await engine.render(frame: frameCam, params: params, outputSpec: RenderOutputSpec())
            let ren2020 = try await engine.render(frame: frame2020, params: params, outputSpec: RenderOutputSpec())
            let pxCam = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(renCam.hdrLinearTexture))
            let px2020 = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(ren2020.hdrLinearTexture))

            let off = (24 * w + 24) * 4
            let r2 = px2020[off + 0], g2 = px2020[off + 1], b2 = px2020[off + 2]
            let rC = pxCam[off + 0], gC = pxCam[off + 1], bC = pxCam[off + 2]
            let maxDiff = max(abs(r2 - rC), max(abs(g2 - gC), abs(b2 - bC)))
            #expect(g2 > 1.10 && r2 <= g2 * 1.15 && b2 <= g2 * 1.15, "[overshoot/\(mode)] Clipped pixel turned magenta instead of neutral white: (\(r2), \(g2), \(b2))")
            #expect(maxDiff < 0.05, "[overshoot/\(mode)] Method B2 stalled on camNorm.x > ceilCam.x: 2020=(\(r2), \(g2), \(b2)) vs cam=(\(rC), \(gC), \(bC))")
        }
    }
}

// MARK: - 30. Regression: .neutralRational 0 EV Rec.2020 Blue Sweep Continuity & Ceiling (<= 1.001)

@Test
func testNeutralRationalZeroEVRec2020BlueSweepContinuityAndCeiling() async throws {
    let dev = try requireMetalDevice()
    let engine = try MetalPipelineEngine(device: dev)

    let w = 64, h = 4
    var rgb = [Float](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        for x in 0..<w {
            let t = Float(x) / Float(w - 1)
            let blue = 0.2 + 16.0 * t // 0.2 .. 16.2; Y = 0.0593 * B crosses P = 0.80 around B = 13.49
            let i = (y * w + x) * 3
            rgb[i + 0] = 0.0
            rgb[i + 1] = 0.0
            rgb[i + 2] = blue
        }
    }

    let frame = DecodedRAWFrame(
        sourceURL: URL(fileURLWithPath: "/tmp/neutral_rational_0ev_blue.arw"),
        backendUsed: .libraw,
        payload: .linearRGB16F(width: w, height: h, colorSpace: .linearRec2020, data: makeLinearRGB16FData(pixelsRGB: rgb)),
        visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
        orientation: 1,
        colorMatrices: CameraColorMatrices(),
        isLosslessMS: false,
        exif: WhitelistedExif()
    )

    var preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
    preset.sdrToneMapper = .neutralRational
    preset.midtoneAnchorP = 0.80
    preset.targetHeadroomStops = 0.0
    let params = EffectiveDevelopParams.resolve(preset: preset)

    for cs in [BaseColorSpace.displayP3, BaseColorSpace.srgb] {
        let rendered = try await engine.render(
            frame: frame,
            params: params,
            outputSpec: RenderOutputSpec(baseColorSpace: cs)
        )
        let sdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.sdrLinearTexture))
        let hdrPx = try readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(rendered.hdrLinearTexture))

        var maxStep = 0.0
        var maxStepIdx = -1
        var maxHDRVal = 0.0
        var maxBranchDiff = 0.0
        var prevHDR = SIMD3<Double>.zero

        for x in 0..<w {
            let off = (2 * w + x) * 4
            let s = SIMD3<Double>(Double(sdrPx[off]), Double(sdrPx[off + 1]), Double(sdrPx[off + 2]))
            let hd = SIMD3<Double>(Double(hdrPx[off]), Double(hdrPx[off + 1]), Double(hdrPx[off + 2]))
            #expect(s.x.isFinite && s.y.isFinite && s.z.isFinite)
            #expect(hd.x.isFinite && hd.y.isFinite && hd.z.isFinite)
            #expect(min(hd.x, min(hd.y, hd.z)) >= -1e-4)

            maxHDRVal = max(maxHDRVal, max(hd.x, max(hd.y, hd.z)))
            maxBranchDiff = max(maxBranchDiff, max(abs(hd.x - s.x), max(abs(hd.y - s.y), abs(hd.z - s.z))))

            if x > 0 {
                let step = max(abs(hd.x - prevHDR.x), max(abs(hd.y - prevHDR.y), abs(hd.z - prevHDR.z)))
                if step > maxStep {
                    maxStep = step
                    maxStepIdx = x
                }
            }
            prevHDR = hd
        }

        #expect(maxHDRVal <= 1.001, "[\(cs)] 0 EV .neutralRational leaked HDR output > 1.001: \(maxHDRVal)")
        #expect(maxBranchDiff <= 1e-3, "[\(cs)] 0 EV hdrOut diverged from sdrOut by \(maxBranchDiff)")
        #expect(maxStep < 0.30, "[\(cs)] .neutralRational 0 EV Rec2020 Blue discontinuity at x=\(maxStepIdx): step=\(maxStep)")
    }
}

}

}



