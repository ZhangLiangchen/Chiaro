import Foundation
import Metal
import simd
import Testing
@testable import ChiaroCore

extension ChiaroSerializedSuites {

@Suite("DemosaicOpticsDenoiseTests", .serialized)
struct DemosaicOpticsDenoiseTests {
    private static func requireDevice() throws -> any MTLDevice {
        try #require(MTLCreateSystemDefaultDevice(), "Metal GPU device required")
    }

    private static func makeRGBA16FTexture(
        device: any MTLDevice,
        width: Int,
        height: Int,
        pixels: [Float] // 4 floats per pixel
    ) throws -> any MTLTexture {
        precondition(pixels.count == width * height * 4)
        let halfs = pixels.map { Float16($0).bitPattern }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.storageMode = .shared
        desc.usage = [.shaderRead, .shaderWrite]
        let tex = try #require(device.makeTexture(descriptor: desc))
        halfs.withUnsafeBytes { raw in
            tex.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * 8
            )
        }
        return tex
    }

    private static func readRGBA16FPixels(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        texture: any MTLTexture
    ) throws -> [Float] {
        let w = texture.width
        let h = texture.height
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: w,
            height: h,
            mipmapped: false
        )
        outDesc.storageMode = .shared
        outDesc.usage = [.shaderRead, .shaderWrite]
        let staging = try #require(device.makeTexture(descriptor: outDesc))
        let cb = try #require(commandQueue.makeCommandBuffer())
        let blit = try #require(cb.makeBlitCommandEncoder())
        blit.copy(
            from: texture,
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

        var halfs = [UInt16](repeating: 0, count: w * h * 4)
        halfs.withUnsafeMutableBytes { raw in
            staging.getBytes(
                raw.baseAddress!,
                bytesPerRow: w * 8,
                from: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0
            )
        }
        return halfs.map { Float(Float16(bitPattern: $0)) }
    }

    private static func computeChromaAndLumaStats(_ rgba: [Float]) -> (lumaMean: Double, lumaVar: Double, chromaVar: Double, maxChannel: Float, allFinite: Bool) {
        var lumas: [Double] = []
        var rgDiffs: [Double] = []
        var bgDiffs: [Double] = []
        lumas.reserveCapacity(rgba.count / 4)
        rgDiffs.reserveCapacity(rgba.count / 4)
        bgDiffs.reserveCapacity(rgba.count / 4)
        var maxCh: Float = 0
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let r = rgba[i + 0], g = rgba[i + 1], b = rgba[i + 2]
            guard r.isFinite && g.isFinite && b.isFinite else {
                return (0, 0, 0, 0, false)
            }
            maxCh = max(maxCh, max(r, max(g, b)))
            let y = 0.2627 * Double(r) + 0.6780 * Double(g) + 0.0593 * Double(b)
            lumas.append(y)
            rgDiffs.append(Double(r - g))
            bgDiffs.append(Double(b - g))
        }
        func variance(_ arr: [Double]) -> (Double, Double) {
            let m = arr.reduce(0, +) / Double(max(arr.count, 1))
            let v = arr.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(arr.count, 1))
            return (m, v)
        }
        let (lMean, lVar) = variance(lumas)
        let (_, rgVar) = variance(rgDiffs)
        let (_, bgVar) = variance(bgDiffs)
        return (lMean, lVar, rgVar + bgVar, maxCh, true)
    }

    // MARK: - 1. SensorNoiseProfileLoader & Log-ISO Interpolation

    @Test
    func testSensorNoiseProfileLoaderAndLogISOInterpolation() throws {
        let loader = SensorNoiseProfileLoader.shared
        let a7c2 = try #require(loader.profile(forMake: "SONY", model: "ILCE-7CM2"))
        let a7m4 = try #require(loader.profile(forMake: "Sony", model: "ILCE-7M4"))
        #expect(a7c2.profiles.count == 37)
        #expect(a7m4.profiles.count == 37)
        #expect(loader.profile(forMake: "SONY", model: "a7c ii")?.model == "ILCE-7CM2")
        #expect(loader.profile(forMake: "Canon", model: "EOS R5") == nil)
        #expect(loader.profileWithSonyFallback(forMake: "SONY", model: "ILCE-UNKNOWN")?.model == "ILCE-7CM2")

        let c12800 = try #require(a7c2.interpolatedParameters(forISO: 12800))
        #expect(c12800.a.x > 0 && c12800.a.y > 0 && c12800.a.z > 0)
        #expect(c12800.b.x >= 0 && c12800.b.y >= 0 && c12800.b.z >= 0)

        let c2500 = try #require(a7c2.interpolatedParameters(forISO: 2500))
        let c100 = try #require(a7c2.interpolatedParameters(forISO: 100))
        #expect(c2500.a.y > c100.a.y && c2500.a.y < c12800.a.y)

        // Upstream darktable ILCE-7CM2 has negative fitted b at ISO >= 51200; must clamp >= 0
        let c51200 = try #require(a7c2.interpolatedParameters(forISO: 51200))
        #expect(c51200.b.x >= 0 && c51200.b.y >= 0 && c51200.b.z >= 0)
    }

    // MARK: - 2. ProfiledWaveletDenoiseStage Variance Reduction & HDR Preservation

    @Test
    func testProfiledWaveletDenoiseStageVarianceReductionAndHDRPreservation() async throws {
        let dev = try Self.requireDevice()
        let queue = try #require(dev.makeCommandQueue())
        let stage = try ProfiledWaveletDenoiseStage(device: dev)
        let profile = try #require(SensorNoiseProfileLoader.shared.profile(forMake: "SONY", model: "ILCE-7CM2"))

        let w = 128, h = 128
        var pixels = [Float](repeating: 0, count: w * h * 4)
        var rng: UInt64 = 0x123456789ABCDEF0
        func nextGaussian() -> Float {
            func nextU() -> Double {
                rng ^= rng >> 12
                rng ^= rng << 25
                rng ^= rng >> 27
                let val = rng &* 0x2545F4914F6CDD1D
                return Double(val >> 11) / Double(1 << 53)
            }
            let u1 = max(nextU(), 1e-12)
            let u2 = nextU()
            return Float(sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2))
        }

        let coeffs = try #require(profile.interpolatedParameters(forISO: 12800))
        for y in 0..<h {
            for x in 0..<w {
                let isHDR = (x >= 96 && y >= 96)
                let base: Float = isHDR ? 2.4 : 0.14
                let stdR = Float(sqrt(coeffs.a.x * Double(base) + coeffs.b.x))
                let stdG = Float(sqrt(coeffs.a.y * Double(base) + coeffs.b.y))
                let stdB = Float(sqrt(coeffs.a.z * Double(base) + coeffs.b.z))
                let i = (y * w + x) * 4
                pixels[i + 0] = max(base + stdR * nextGaussian(), 0.0)
                pixels[i + 1] = max(base + stdG * nextGaussian(), 0.0)
                pixels[i + 2] = max(base + stdB * nextGaussian(), 0.0)
                pixels[i + 3] = 1.0
            }
        }

        let inputTex = try Self.makeRGBA16FTexture(device: dev, width: w, height: h, pixels: pixels)

        func cropFlatStats(from tex: any MTLTexture) throws -> (lumaMean: Double, lumaVar: Double, chromaVar: Double, maxHDR: Float, allFinite: Bool) {
            let out = try Self.readRGBA16FPixels(device: dev, commandQueue: queue, texture: tex)
            var flat: [Float] = []
            var maxHDR: Float = 0
            for y in 0..<h {
                for x in 0..<w {
                    let off = (y * w + x) * 4
                    let r = out[off], g = out[off + 1], b = out[off + 2]
                    if !r.isFinite || !g.isFinite || !b.isFinite {
                        return (0, 0, 0, 0, false)
                    }
                    if x >= 100 && x < 120 && y >= 100 && y < 120 {
                        maxHDR = max(maxHDR, max(r, max(g, b)))
                    } else if x >= 12 && x < 84 && y >= 12 && y < 84 {
                        flat.append(contentsOf: [r, g, b, 1.0])
                    }
                }
            }
            let st = Self.computeChromaAndLumaStats(flat)
            return (st.lumaMean, st.lumaVar, st.chromaVar, maxHDR, st.allFinite)
        }

        // Mode .off must return exact pass-through
        let offTex = try await stage.denoise(
            inputTexture: inputTex,
            iso: 12800,
            noiseProfile: profile,
            params: DenoiseParameters(mode: .off),
            commandQueue: queue
        )
        #expect(offTex === inputTex)
        let stOff = try cropFlatStats(from: offTex)

        // Default auto profiledWavelet
        let autoTex = try await stage.denoise(
            inputTexture: inputTex,
            iso: 12800,
            noiseProfile: profile,
            params: .default,
            commandQueue: queue
        )
        let stAuto = try cropFlatStats(from: autoTex)
        #expect(stAuto.allFinite)
        #expect(stAuto.chromaVar <= 0.75 * stOff.chromaVar, "Auto chromaVar \(stAuto.chromaVar) > 0.75 * \(stOff.chromaVar)")
        let lumaDelta = abs(stAuto.lumaMean - stOff.lumaMean) / max(stOff.lumaMean, 1e-6)
        #expect(lumaDelta < 0.05, "Luma mean shifted by \(lumaDelta * 100)%")
        #expect(stAuto.maxHDR > 1.5, "HDR > 1.0 clipped during profiled denoise: \(stAuto.maxHDR)")

        // Higher chromaStrength reduces chroma variance monotonically
        let texCh10 = try await stage.denoise(
            inputTexture: inputTex,
            iso: 12800,
            noiseProfile: profile,
            params: DenoiseParameters(mode: .profiledWavelet, luminanceStrength: 0, chromaStrength: 10),
            commandQueue: queue
        )
        let texCh100 = try await stage.denoise(
            inputTexture: inputTex,
            iso: 12800,
            noiseProfile: profile,
            params: DenoiseParameters(mode: .profiledWavelet, luminanceStrength: 0, chromaStrength: 100),
            commandQueue: queue
        )
        #expect(try cropFlatStats(from: texCh100).chromaVar < cropFlatStats(from: texCh10).chromaVar)

        // Higher luminanceStrength reduces luma variance monotonically
        let texLu5 = try await stage.denoise(
            inputTexture: inputTex,
            iso: 12800,
            noiseProfile: profile,
            params: DenoiseParameters(mode: .profiledWavelet, luminanceStrength: 5, chromaStrength: 0),
            commandQueue: queue
        )
        let texLu80 = try await stage.denoise(
            inputTexture: inputTex,
            iso: 12800,
            noiseProfile: profile,
            params: DenoiseParameters(mode: .profiledWavelet, luminanceStrength: 80, chromaStrength: 0),
            commandQueue: queue
        )
        #expect(try cropFlatStats(from: texLu80).lumaVar < cropFlatStats(from: texLu5).lumaVar)
    }

    // MARK: - 3. EmbeddedSonyOpticsEvaluator (16-node FF & 11-node APS-C)

    @Test
    func testEmbeddedSonyOpticsEvaluator16And11NodesAndAutoScale() throws {
        // Empirical DSC02532.ARW (FF nc=16 pincushion)
        let ffPayload = EmbeddedSonyOpticsPayload(
            distortionNodeCount: 16,
            distortionParams: [0, 0, 5, 14, 27, 43, 65, 92, 122, 158, 198, 244, 298, 359, 428, 501],
            caNodeCount: 16,
            caRedParams: Array(repeating: -256, count: 16),
            caBlueParams: Array(repeating: 256, count: 16),
            vignettingNodeCount: 16,
            vignettingParams: [0, 64, 160, 320, 512, 768, 1088, 1472, 1920, 2432, 3008, 3648, 4352, 5120, 5952, 6848]
        )
        let lutFF = EmbeddedSonyOpticsEvaluator.computeLUT(
            payload: ffPayload,
            width: 7008,
            height: 4672,
            distortion: true,
            autoScale: true,
            tca: true,
            vignetting: true
        )
        #expect(lutFF.warpRGBUV.allSatisfy { $0.isFinite })
        #expect(lutFF.vignettingGain.allSatisfy { !$0.isNaN && !$0.isInfinite && Float($0) >= 0.99 })
        // Corner vignetting lift must be > 1.0
        let cornerVigFF = Float(lutFF.vignettingGain[0])
        let centerVigFF = Float(lutFF.vignettingGain[(lutFF.lutHeight / 2) * lutFF.lutWidth + (lutFF.lutWidth / 2)])
        #expect(cornerVigFF > centerVigFF)
        #expect(cornerVigFF > 1.1)

        // Empirical DSC02556.ARW (APS-C nc=11)
        let apscPayload = EmbeddedSonyOpticsPayload(
            distortionNodeCount: 11,
            distortionParams: [-4, 0, 9, 23, 41, 65, 93, 128, 167, 212, 264],
            caNodeCount: 11,
            caRedParams: Array(repeating: -512, count: 11),
            caBlueParams: [-512, -512, -512, -512, -512, -544, -576, -608, -608, -640, -640],
            vignettingNodeCount: 11,
            vignettingParams: [0, 96, 256, 480, 736, 992, 1408, 2240, 3232, 4288, 5376],
            cropFactor: 1.5
        )
        let lutAPSC = EmbeddedSonyOpticsEvaluator.computeLUT(
            payload: apscPayload,
            width: 4608,
            height: 3072,
            distortion: true,
            autoScale: true,
            tca: true,
            vignetting: true
        )
        #expect(lutAPSC.warpRGBUV.allSatisfy { $0.isFinite })
        #expect(Float(lutAPSC.vignettingGain[0]) > 1.1)
    }

    // MARK: - 4. LensfunOpticsProvider Custom XML, Optics Routing & Catmull-Rom HDR

    @Test
    func testLensfunOpticsProviderCustomXMLRoutingAndCatmullRomHDR() async throws {
        let dev = try Self.requireDevice()
        let queue = try #require(dev.makeCommandQueue())

        let tmpUserDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chiaro-lensfun-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpUserDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpUserDir) }

        let customXML = """
        <lensdatabase version="1">
            <lens>
                <maker>Tamron</maker>
                <model>Tamron 25-200mm F/2.8-5.6 Di III VXD A075</model>
                <mount>Sony E</mount>
                <cropfactor>1.0</cropfactor>
                <calibration>
                    <distortion model="ptlens" focal="50" a="0.002" b="-0.01" c="0.004"/>
                    <tca model="poly3" focal="50" br="-0.0002" vr="1.0002" bb="0.0002" vb="0.9998"/>
                    <vignetting model="pa" focal="50" aperture="4.0" distance="10" k1="-0.3" k2="0.1" k3="0.0"/>
                </calibration>
            </lens>
        </lensdatabase>
        """
        let srcXML = tmpUserDir.appendingPathComponent("custom_a075.xml")
        let importDir = tmpUserDir.appendingPathComponent("user_db", isDirectory: true)
        try customXML.write(to: srcXML, atomically: true, encoding: .utf8)

        let provider = LensfunOpticsProvider(userDatabaseURL: importDir)
        try provider.importCustomXML(from: srcXML)
        let info = provider.databaseInfo()
        #expect(info.loadedPrimary)
        #expect(info.loadedUser)

        let embeddedPayload = EmbeddedSonyOpticsPayload(
            distortionNodeCount: 16,
            distortionParams: [0, 0, 5, 14, 27, 43, 65, 92, 122, 158, 198, 244, 298, 359, 428, 501],
            caNodeCount: 16,
            caRedParams: Array(repeating: -128, count: 16),
            caBlueParams: Array(repeating: 128, count: 16),
            vignettingNodeCount: 16,
            vignettingParams: [0, 64, 128, 256, 400, 600, 900, 1200, 1600, 2000, 2400, 2900, 3400, 4000, 4600, 5200]
        )

        let w = 96, h = 64
        var hdrPixels = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let isBright = (x >= 40 && x < 56 && y >= 24 && y < 40)
                let v: Float = isBright ? 2.6 : 0.30
                let i = (y * w + x) * 4
                hdrPixels[i + 0] = v
                hdrPixels[i + 1] = v
                hdrPixels[i + 2] = v
                hdrPixels[i + 3] = 1.0
            }
        }
        let inTex = try Self.makeRGBA16FTexture(device: dev, width: w, height: h, pixels: hdrPixels)

        let frame = DecodedRAWFrame(
            sourceURL: URL(fileURLWithPath: "/tmp/optics_routing.arw"),
            backendUsed: .libraw,
            payload: .linearRGB16F(width: w, height: h, colorSpace: .linearRec2020, data: Data(count: w * h * 8)),
            visibleCrop: SensorCropRect(x: 0, y: 0, width: w, height: h),
            orientation: 1,
            colorMatrices: CameraColorMatrices(),
            isLosslessMS: false,
            exif: WhitelistedExif(
                make: "SONY",
                model: "ILCE-7CM2",
                lensModel: "Tamron 25-200mm F/2.8-5.6 Di III VXD A075",
                focalLengthMM: 50.0,
                fNumber: 4.0
            ),
            embeddedSonyOptics: embeddedPayload,
            cropFactor: 1.0
        )

        let opticsEngine = try OpticsPipelineEngine(device: dev, lensfunProvider: provider)

        // Auto chooses embedded
        let autoInfo = opticsEngine.resolveOptics(frame: frame, params: .default)
        #expect(autoInfo.source == .embeddedARW)

        // Lensfun mode uses imported custom XML + Sony E FF fallback
        let lfParams = OpticalCorrectionParameters(source: .lensfun)
        let (lfTex, lfRes) = try await opticsEngine.applyCorrection(
            inputTexture: inTex,
            frame: frame,
            params: lfParams,
            commandQueue: queue
        )
        #expect(lfRes.source == .lensfun)
        #expect(lfRes.distortionApplied && lfRes.tcaApplied && lfRes.vignettingApplied)

        let lfOut = try Self.readRGBA16FPixels(device: dev, commandQueue: queue, texture: lfTex)
        #expect(lfOut.allSatisfy { $0.isFinite })
        let maxLF = lfOut.max() ?? 0
        #expect(maxLF > 1.5, "optical_correction_kernel clipped HDR highlight > 1.0: \(maxLF)")

        // Vignetting strength 0% vs 100% corner brightness check (using LUT cache!)
        let embFullParams = OpticalCorrectionParameters(source: .embedded, vignettingStrength: 1.0)
        let embZeroVigParams = OpticalCorrectionParameters(source: .embedded, vignettingStrength: 0.0)
        let (texVig100, _) = try await opticsEngine.applyCorrection(inputTexture: inTex, frame: frame, params: embFullParams, commandQueue: queue)
        let (texVig0, _) = try await opticsEngine.applyCorrection(inputTexture: inTex, frame: frame, params: embZeroVigParams, commandQueue: queue)
        let outVig100 = try Self.readRGBA16FPixels(device: dev, commandQueue: queue, texture: texVig100)
        let outVig0 = try Self.readRGBA16FPixels(device: dev, commandQueue: queue, texture: texVig0)
        #expect(outVig100[1] > outVig0[1], "100% vignetting correction must lift corner brightness above 0%")

        // Disabled optics returns pass-through
        let (offTex, offRes) = try await opticsEngine.applyCorrection(
            inputTexture: inTex,
            frame: frame,
            params: OpticalCorrectionParameters(enabled: false),
            commandQueue: queue
        )
        #expect(offRes.source == .none)
        #expect(offTex === inTex)
    }

    private static func computeHighPassShadowChromaNoise(
        _ rgba: [Float],
        width: Int,
        height: Int,
        normalizedBox: (minX: Double, minY: Double, maxX: Double, maxY: Double)? = nil
    ) -> (lumaMean: Double, highPassChromaVar: Double, maxChannel: Float, allFinite: Bool) {
        var sumLuma = 0.0
        var sumRG2 = 0.0
        var sumBG2 = 0.0
        var shadowCnt = 0
        var maxCh: Float = 0

        let xStart = max(2, normalizedBox.map { Int(Double(width) * $0.minX) } ?? 2)
        let xEnd = min(width - 2, normalizedBox.map { Int(Double(width) * $0.maxX) } ?? (width - 2))
        let yStart = max(2, normalizedBox.map { Int(Double(height) * $0.minY) } ?? 2)
        let yEnd = min(height - 2, normalizedBox.map { Int(Double(height) * $0.maxY) } ?? (height - 2))

        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let r = rgba[idx + 0], g = rgba[idx + 1], b = rgba[idx + 2]
                guard r.isFinite && g.isFinite && b.isFinite else {
                    return (0, 0, 0, false)
                }
                maxCh = max(maxCh, max(r, max(g, b)))
                let luma = 0.2627 * Double(r) + 0.6780 * Double(g) + 0.0593 * Double(b)
                sumLuma += luma
                guard luma >= 0.001 && luma <= 0.08, x >= xStart && x < xEnd && y >= yStart && y < yEnd else {
                    continue
                }
                var meanR = 0.0, meanG = 0.0, meanB = 0.0
                for dy in -2...2 {
                    for dx in -2...2 {
                        let nIdx = ((y + dy) * width + (x + dx)) * 4
                        meanR += Double(rgba[nIdx + 0])
                        meanG += Double(rgba[nIdx + 1])
                        meanB += Double(rgba[nIdx + 2])
                    }
                }
                meanR /= 25.0; meanG /= 25.0; meanB /= 25.0
                let hpRG = (Double(r) - Double(g)) - (meanR - meanG)
                let hpBG = (Double(b) - Double(g)) - (meanB - meanG)
                sumRG2 += hpRG * hpRG
                sumBG2 += hpBG * hpBG
                shadowCnt += 1
            }
        }
        let totalPx = max(width * height, 1)
        let hpVar = shadowCnt > 0 ? (sumRG2 + sumBG2) / Double(shadowCnt) : 0.0
        return (sumLuma / Double(totalPx), hpVar, maxCh, true)
    }

    // MARK: - 5. Real Sony A7C2 End-to-End Integration Tests (CHIARO_SAMPLE_DIR)

    @Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testRealA7C2EndToEndOpticsDenoiseAndIQEngines() async throws {
        let dir = TestFixtures.sampleDirectory
        let dsc2532 = dir.appendingPathComponent("DSC02532.ARW")
        let dsc2533 = dir.appendingPathComponent("DSC02533.ARW")
        let dsc2556 = dir.appendingPathComponent("DSC02556.ARW")
        try #require(FileManager.default.fileExists(atPath: dsc2532.path))
        try #require(FileManager.default.fileExists(atPath: dsc2533.path))
        try #require(FileManager.default.fileExists(atPath: dsc2556.path))

        let dev = try Self.requireDevice()
        let decoder = LibRawDecoder()
        let engine = try MetalPipelineEngine(device: dev)
        let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)

        // 1. DSC02532 (FF 16-node) & DSC02556 (APS-C 11-node) Optics routing
        let frame2532 = try await decoder.decodeProxy(url: dsc2532)
        let frame2556 = try await decoder.decodeProxy(url: dsc2556)
        let info2532 = OpticsPipelineEngine.resolveOpticsInfo(frame: frame2532, params: .default)
        let info2556 = OpticsPipelineEngine.resolveOpticsInfo(frame: frame2556, params: .default)
        #expect(info2532.source == .embeddedARW && info2532.distortionApplied && info2532.tcaApplied && info2532.vignettingApplied)
        #expect(info2556.source == .embeddedARW && info2556.distortionApplied && info2556.tcaApplied && info2556.vignettingApplied)

        // Render FF frame with vignettingStrength 1.0 vs 0.0 (same geometry, pure vignetting lift)
        var paramsOptOn = EffectiveDevelopParams.resolve(preset: preset)
        paramsOptOn.maxLongEdge = 1024
        var paramsOptVig0 = paramsOptOn
        paramsOptVig0.optics.vignettingStrength = 0.0
        let renOptOn = try await engine.render(frame: frame2532, params: paramsOptOn, outputSpec: RenderOutputSpec())
        let renOptVig0 = try await engine.render(frame: frame2532, params: paramsOptVig0, outputSpec: RenderOutputSpec())
        let hdrOptOn = try Self.readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(renOptOn.hdrLinearTexture).texture)
        let hdrOptVig0 = try Self.readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(renOptVig0.hdrLinearTexture).texture)
        #expect(hdrOptOn.allSatisfy { $0.isFinite })
        #expect((hdrOptOn.max() ?? 0) > 1.5)
        // Corner pixel must lift under vignetting compensation
        #expect(hdrOptOn[1] > hdrOptVig0[1])

        // 2. DSC02533 (ISO 12800 night scene): Profiled Denoise + Sigmoid + Clarity + Optical Sharpness + Opposed Inpaint
        let frame2533 = try await decoder.decodeFull(
            url: dsc2533,
            options: DecodeOptions(backend: .libraw, demosaicAlgorithm: .lmmse)
        )
        #expect(frame2533.demosaicUsed == .lmmse)
        #expect(frame2533.isoSpeed == 12800)

        var base2533 = EffectiveDevelopParams.resolve(preset: preset)
        base2533.maxLongEdge = 1024

        var pDenoiseOff = base2533
        pDenoiseOff.denoise.mode = .off
        let renOff = try await engine.render(frame: frame2533, params: pDenoiseOff, outputSpec: RenderOutputSpec())
        let renAuto = try await engine.render(frame: frame2533, params: base2533, outputSpec: RenderOutputSpec())

        let hdrOffTex = try #require(renOff.hdrLinearTexture).texture
        let hdrAutoTex = try #require(renAuto.hdrLinearTexture).texture
        let pxOff = try Self.readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: hdrOffTex)
        let pxAuto = try Self.readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: hdrAutoTex)
        let stOff = Self.computeHighPassShadowChromaNoise(pxOff, width: hdrOffTex.width, height: hdrOffTex.height)
        let stAuto = Self.computeHighPassShadowChromaNoise(pxAuto, width: hdrAutoTex.width, height: hdrAutoTex.height)

        let sdrOffTex = try #require(renOff.sdrLinearTexture).texture
        let sdrAutoTex = try #require(renAuto.sdrLinearTexture).texture
        let pxSdrOff = try Self.readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: sdrOffTex)
        let pxSdrAuto = try Self.readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: sdrAutoTex)
        func toSRGB(_ x: Float) -> Float {
            let c = min(max(x, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055
        }
        let srgbOff = pxSdrOff.map(toSRGB)
        let srgbAuto = pxSdrAuto.map(toSRGB)
        let stSrgbOff = Self.computeHighPassShadowChromaNoise(srgbOff, width: sdrOffTex.width, height: sdrOffTex.height)
        let stSrgbAuto = Self.computeHighPassShadowChromaNoise(srgbAuto, width: sdrAutoTex.width, height: sdrAutoTex.height)

        #expect(stAuto.allFinite && stAuto.maxChannel > 1.5)
        let lumaDelta = abs(stAuto.lumaMean - stOff.lumaMean) / max(stOff.lumaMean, 1e-6)
        #expect(lumaDelta < 0.05, "Luma mean shifted by \(lumaDelta * 100)%")
        #expect(stSrgbAuto.highPassChromaVar <= 0.75 * stSrgbOff.highPassChromaVar, "Real ISO 12800 1024px sRGB highPassChromaVar did not drop: auto=\(stSrgbAuto.highPassChromaVar) vs off=\(stSrgbOff.highPassChromaVar)")

        // Sigmoid + Clarity (+60) + Optical Sharpness (80) on DSC02533
        var pSigmoid = base2533
        pSigmoid.sdrToneMapper = .sigmoid
        pSigmoid.develop.clarity = 60
        pSigmoid.develop.opticalSharpness = 80
        let renSig = try await engine.render(frame: frame2533, params: pSigmoid, outputSpec: RenderOutputSpec())
        let sdrSig = try Self.readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(renSig.sdrLinearTexture).texture)
        let hdrSig = try Self.readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: try #require(renSig.hdrLinearTexture).texture)
        #expect(sdrSig.allSatisfy { $0.isFinite })
        #expect(hdrSig.allSatisfy { $0.isFinite })
        #expect((hdrSig.max() ?? 0) > 1.5)
    }

    // MARK: - 6. Remediation Tests (Tile Seams, 8GB Budget, 1:1 ISO 12800, Malformed XML, Optics Short-Circuit)

    private static func computeTileHighPassLumaAndChroma(
        _ rgba: [Float],
        width: Int,
        height: Int,
        x0: Int,
        y0: Int,
        tileW: Int,
        tileH: Int
    ) -> (meanY: Double, hpLumaVar: Double, hpChromaVar: Double, allFinite: Bool) {
        var sumY = 0.0
        var sumL2 = 0.0
        var sumRG2 = 0.0
        var sumBG2 = 0.0
        var count = 0
        let xStart = max(2, x0)
        let xEnd = min(width - 2, x0 + tileW)
        let yStart = max(2, y0)
        let yEnd = min(height - 2, y0 + tileH)

        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                let idx = (y * width + x) * 4
                let r = rgba[idx + 0], g = rgba[idx + 1], b = rgba[idx + 2]
                guard r.isFinite && g.isFinite && b.isFinite else {
                    return (0, 0, 0, false)
                }
                let yC = 0.2627 * Double(r) + 0.6780 * Double(g) + 0.0593 * Double(b)
                sumY += yC

                var mR = 0.0, mG = 0.0, mB = 0.0
                for dy in -2...2 {
                    for dx in -2...2 {
                        let n = ((y + dy) * width + (x + dx)) * 4
                        mR += Double(rgba[n + 0])
                        mG += Double(rgba[n + 1])
                        mB += Double(rgba[n + 2])
                    }
                }
                mR /= 25.0; mG /= 25.0; mB /= 25.0
                let mY = 0.2627 * mR + 0.6780 * mG + 0.0593 * mB
                let hpL = yC - mY
                let hpRG = (Double(r) - Double(g)) - (mR - mG)
                let hpBG = (Double(b) - Double(g)) - (mB - mG)
                sumL2 += hpL * hpL
                sumRG2 += hpRG * hpRG
                sumBG2 += hpBG * hpBG
                count += 1
            }
        }
        let n = Double(max(count, 1))
        return (sumY / n, sumL2 / n, (sumRG2 + sumBG2) / n, true)
    }

    @Test
    func testProfiledWaveletDenoiseTiledVsUntiledEquivalenceAcrossSeams() async throws {
        let dev = try Self.requireDevice()
        let queue = try #require(dev.makeCommandQueue())
        let stage = try ProfiledWaveletDenoiseStage(device: dev)
        let profile = try #require(SensorNoiseProfileLoader.shared.profile(forMake: "SONY", model: "ILCE-7CM2"))

        // 2048 x 1600 = 3,276,800 pixels (> 3_000_000 tiling threshold -> 3 strips with 2 interior seams)
        let w = 2048, h = 1600
        var pixels = [Float](repeating: 0, count: w * h * 4)
        var rng: UInt64 = 0xCAFEBABEDEADBEEF
        func nextF() -> Float {
            rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27
            let v = rng &* 0x2545F4914F6CDD1D
            return Float(Double(v >> 11) / Double(1 << 53)) - 0.5
        }
        for y in 0..<h {
            let base: Float = (y % 400 < 200) ? 0.12 : 0.45
            for x in 0..<w {
                let i = (y * w + x) * 4
                let edge: Float = (x % 256 < 128) ? 0.04 : 0.0
                pixels[i + 0] = max(base + edge + 0.03 * nextF(), 0.0)
                pixels[i + 1] = max(base + edge + 0.02 * nextF(), 0.0)
                pixels[i + 2] = max(base + edge + 0.03 * nextF(), 0.0)
                pixels[i + 3] = 1.0
            }
        }

        let inTex = try Self.makeRGBA16FTexture(device: dev, width: w, height: h, pixels: pixels)
        let tiledTex = try await stage.denoiseImpl(
            inputTexture: inTex,
            iso: 12800,
            noiseProfile: profile,
            params: .default,
            commandQueue: queue,
            forceUntiled: false
        )
        let untiledTex = try await stage.denoiseImpl(
            inputTexture: inTex,
            iso: 12800,
            noiseProfile: profile,
            params: .default,
            commandQueue: queue,
            forceUntiled: true
        )

        let tiledPx = try Self.readRGBA16FPixels(device: dev, commandQueue: queue, texture: tiledTex)
        let untiledPx = try Self.readRGBA16FPixels(device: dev, commandQueue: queue, texture: untiledTex)
        #expect(tiledPx.count == untiledPx.count)

        var maxDiff: Float = 0
        for i in 0..<tiledPx.count {
            let d = abs(tiledPx[i] - untiledPx[i])
            if d > maxDiff { maxDiff = d }
        }
        #expect(maxDiff == 0.0, "Tiled vs untiled ProfiledWaveletDenoiseStage differed across seams: maxDiff=\(maxDiff)")
    }

    @Test
    func testProfiledWaveletDenoiseLowISOSmoothnessAndPureBlackAdjacentToPlus6EV() async throws {
        let dev = try Self.requireDevice()
        let queue = try #require(dev.makeCommandQueue())
        let stage = try ProfiledWaveletDenoiseStage(device: dev)
        let profile = try #require(SensorNoiseProfileLoader.shared.profile(forMake: "SONY", model: "ILCE-7CM2"))

        // 1. Low-ISO (ISO 50 & ISO 100) gradient monotonicity & smoothness
        let w = 256, h = 64
        var ramp = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v: Float = 0.0005 + (0.45 - 0.0005) * Float(x) / Float(w - 1)
                let i = (y * w + x) * 4
                ramp[i + 0] = v; ramp[i + 1] = v; ramp[i + 2] = v; ramp[i + 3] = 1.0
            }
        }
        let rampTex = try Self.makeRGBA16FTexture(device: dev, width: w, height: h, pixels: ramp)
        for iso in [50, 100] {
            let outTex = try await stage.denoise(
                inputTexture: rampTex,
                iso: iso,
                noiseProfile: profile,
                params: .default,
                commandQueue: queue
            )
            let out = try Self.readRGBA16FPixels(device: dev, commandQueue: queue, texture: outTex)
            var nonMono = 0
            let row = h / 2
            for x in 1..<w {
                let prev = out[(row * w + (x - 1)) * 4 + 1]
                let cur = out[(row * w + x) * 4 + 1]
                if cur + 1e-6 < prev { nonMono += 1 }
            }
            #expect(nonMono == 0, "ISO \(iso) gradient ramp had \(nonMono) non-monotonic steps")
        }

        // 2. Pure-black (0,0,0) next to +6 EV (64.0) preservation
        let bw = 128, bh = 64
        var edgePx = [Float](repeating: 0, count: bw * bh * 4)
        for y in 0..<bh {
            for x in 0..<bw {
                let v: Float = (x >= bw / 2) ? 64.0 : 0.0
                let i = (y * bw + x) * 4
                edgePx[i + 0] = v; edgePx[i + 1] = v; edgePx[i + 2] = v; edgePx[i + 3] = 1.0
            }
        }
        let edgeTex = try Self.makeRGBA16FTexture(device: dev, width: bw, height: bh, pixels: edgePx)
        let denoisedEdge = try await stage.denoise(
            inputTexture: edgeTex,
            iso: 12800,
            noiseProfile: profile,
            params: DenoiseParameters(mode: .profiledWavelet, luminanceStrength: 80, chromaStrength: 100),
            commandQueue: queue
        )
        let outEdge = try Self.readRGBA16FPixels(device: dev, commandQueue: queue, texture: denoisedEdge)
        var maxBleed: Float = 0
        for y in 0..<bh {
            for x in 0..<(bw / 2) {
                let i = (y * bw + x) * 4
                maxBleed = max(maxBleed, max(outEdge[i], max(outEdge[i + 1], outEdge[i + 2])))
            }
        }
        #expect(maxBleed == 0.0, "Pure black (0,0,0) bled next to +6 EV: maxBleed=\(maxBleed)")
    }

    @Test
    func testLensfunMalformedXMLRejectionAndOpticsInfoShortCircuit() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chiaro-malformed-xml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let userDB = tmpDir.appendingPathComponent("user_db", isDirectory: true)
        let provider = LensfunOpticsProvider(userDatabaseURL: userDB)

        let brokenXML = tmpDir.appendingPathComponent("broken.xml")
        try "<lensdatabase><lens><maker>Broken</maker><unclosed".write(to: brokenXML, atomically: true, encoding: .utf8)

        #expect(throws: LensfunProviderError.self) {
            try provider.importCustomXML(from: brokenXML)
        }
        #expect(!FileManager.default.fileExists(atPath: userDB.appendingPathComponent("broken.xml").path))
        #expect(!provider.databaseInfo().loadedUser)

        // OpticsPipelineEngine.resolveOpticsInfo short-circuits to .none when all 3 sub-toggles are false
        let frame = DecodedRAWFrame(
            sourceURL: URL(fileURLWithPath: "/tmp/optics_shortcircuit.arw"),
            backendUsed: .libraw,
            payload: .linearRGB16F(width: 64, height: 64, colorSpace: .linearRec2020, data: Data(count: 64 * 64 * 8)),
            visibleCrop: SensorCropRect(x: 0, y: 0, width: 64, height: 64),
            orientation: 1,
            colorMatrices: CameraColorMatrices(),
            isLosslessMS: false,
            exif: WhitelistedExif(
                make: "SONY",
                model: "ILCE-7CM2",
                lensModel: "TAMRON 25-200mm F2.8-5.6 A075 E",
                focalLengthMM: 50.0,
                fNumber: 4.0
            ),
            cropFactor: 1.0
        )
        let allDisabledSubToggles = OpticalCorrectionParameters(
            enabled: true,
            source: .auto,
            distortion: false,
            tca: false,
            vignetting: false
        )
        let info = OpticsPipelineEngine.resolveOpticsInfo(frame: frame, params: allDisabledSubToggles, provider: provider)
        #expect(info == .none, "resolveOpticsInfo(.auto) must return .none when all 3 sub-toggles are false, got \(info)")
    }

    @Test(.enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests"))
    func testRealA7C2ISO12800Native1to1DenoiseAnd8GBMemoryBudget() async throws {
        let dir = TestFixtures.sampleDirectory
        let dsc2532 = dir.appendingPathComponent("DSC02532.ARW")
        let dsc2533 = dir.appendingPathComponent("DSC02533.ARW")
        try #require(FileManager.default.fileExists(atPath: dsc2532.path))
        try #require(FileManager.default.fileExists(atPath: dsc2533.path))

        let dev = try Self.requireDevice()
        let decoder = LibRawDecoder()
        let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)

        // 1. 1:1 native-resolution ISO 12800 (DSC02533.ARW) flat dark tile 5x5 high-pass luma & chroma variance
        let frame2533 = try await decoder.decodeFull(
            url: dsc2533,
            options: DecodeOptions(backend: .libraw, demosaicAlgorithm: .lmmse)
        )
        let engine = try MetalPipelineEngine(device: dev)
        for opticsEnabled in [true, false] {
            var base = EffectiveDevelopParams.resolve(preset: preset)
            base.maxLongEdge = nil // 1:1 native 7008x4672
            base.optics.enabled = opticsEnabled

            var pOff = base
            pOff.denoise.mode = .off
            let pDef = base // luma=25, chroma=65
            var pStrong = base
            pStrong.denoise.luminanceStrength = 80
            pStrong.denoise.chromaStrength = 100

            let rOff = try await engine.render(frame: frame2533, params: pOff, outputSpec: RenderOutputSpec())
            let rDef = try await engine.render(frame: frame2533, params: pDef, outputSpec: RenderOutputSpec())
            let rStrong = try await engine.render(frame: frame2533, params: pStrong, outputSpec: RenderOutputSpec())

            let texOff = try #require(rOff.hdrLinearTexture).texture
            let texDef = try #require(rDef.hdrLinearTexture).texture
            let texStrong = try #require(rStrong.hdrLinearTexture).texture

            let pxOff = try Self.readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: texOff)
            let pxDef = try Self.readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: texDef)
            let pxStrong = try Self.readRGBA16FPixels(device: dev, commandQueue: engine.commandQueue, texture: texStrong)

            for (tx, ty) in [(1856, 1344), (2496, 1216)] {
                let stOff = Self.computeTileHighPassLumaAndChroma(pxOff, width: texOff.width, height: texOff.height, x0: tx, y0: ty, tileW: 64, tileH: 64)
                let stDef = Self.computeTileHighPassLumaAndChroma(pxDef, width: texDef.width, height: texDef.height, x0: tx, y0: ty, tileW: 64, tileH: 64)
                let stStrong = Self.computeTileHighPassLumaAndChroma(pxStrong, width: texStrong.width, height: texStrong.height, x0: tx, y0: ty, tileW: 64, tileH: 64)

                #expect(stDef.allFinite && stStrong.allFinite)
                let chromaRatio = stDef.hpChromaVar / max(stOff.hpChromaVar, 1e-12)
                let lumaRatioDef = stDef.hpLumaVar / max(stOff.hpLumaVar, 1e-12)
                let lumaRatioStrong = stStrong.hpLumaVar / max(stOff.hpLumaVar, 1e-12)
                let meanDrift = abs(stDef.meanY - stOff.meanY) / max(stOff.meanY, 1e-6)

                #expect(chromaRatio < 0.60, "[optics=\(opticsEnabled) tile=(\(tx),\(ty))] 1:1 5x5 hpChromaVar ratio \(chromaRatio) >= 0.60")
                #expect(lumaRatioDef <= 0.80, "[optics=\(opticsEnabled) tile=(\(tx),\(ty))] 1:1 5x5 hpLumaVar(luma=25) ratio \(lumaRatioDef) > 0.80")
                #expect(lumaRatioStrong <= 0.45, "[optics=\(opticsEnabled) tile=(\(tx),\(ty))] 1:1 5x5 hpLumaVar(luma=80) ratio \(lumaRatioStrong) > 0.45")
                #expect(meanDrift < 0.05, "[optics=\(opticsEnabled) tile=(\(tx),\(ty))] 1:1 mean luma drift \(meanDrift) >= 5%")
            }
        }

        // 2. 33MP DSC02532.ARW full-res all-engines render under 8GB Mac cap (poolMaxBytes = 2688 MB)
        let frame2532Full = try await decoder.decodeFull(
            url: dsc2532,
            options: DecodeOptions(backend: .libraw, demosaicAlgorithm: .amaze)
        )
        let cap8GBEngine = try MetalPipelineEngine(device: dev, poolMaxBytes: 2688 * 1024 * 1024)
        var allEngines = EffectiveDevelopParams.resolve(preset: preset)
        allEngines.maxLongEdge = nil
        allEngines.denoise = DenoiseParameters(mode: .profiledWavelet, luminanceStrength: 25, chromaStrength: 65)
        allEngines.optics = OpticalCorrectionParameters(enabled: true, source: .auto)
        allEngines.develop.clarity = 50
        allEngines.develop.opticalSharpness = 60
        allEngines.sdrToneMapper = .sigmoid

        let fullRendered = try await cap8GBEngine.render(frame: frame2532Full, params: allEngines, outputSpec: RenderOutputSpec())
        let fullHdrTex = try #require(fullRendered.hdrLinearTexture).texture
        #expect(fullHdrTex.width == 7008 && fullHdrTex.height == 4672)
        let poolBytes33MP = cap8GBEngine.texturePool.stats.totalHeapBytes
        #expect(poolBytes33MP <= 2048 * 1024 * 1024, "33MP pool footprint exceeded 2.0 GiB: \(poolBytes33MP / (1024 * 1024)) MiB")

        // 3. 20-render proxy stress (3504x2336) under poolMaxBytes = 768 MB
        let frame2532Proxy = try await decoder.decodeProxy(url: dsc2532)
        let proxyEngine = try MetalPipelineEngine(device: dev, poolMaxBytes: 768 * 1024 * 1024)
        for iter in 0..<20 {
            let ren = try await proxyEngine.render(frame: frame2532Proxy, params: allEngines, outputSpec: RenderOutputSpec())
            let hdrTex = try #require(ren.hdrLinearTexture).texture
            #expect(hdrTex.width == 3504 && hdrTex.height == 2336, "Proxy iter \(iter) unexpected size")
        }
        #expect(proxyEngine.texturePool.stats.totalHeapBytes <= 768 * 1024 * 1024)
    }
}

}
