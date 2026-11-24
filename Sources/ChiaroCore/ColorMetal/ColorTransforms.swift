import Foundation
import simd

public struct OutputGeometry: Sendable, Equatable {
    public let srcWidth: Int
    public let srcHeight: Int
    public let orientation: Int
    public let uprightWidth: Int
    public let uprightHeight: Int
    public let cropX: Int
    public let cropY: Int
    public let cropWidth: Int
    public let cropHeight: Int
    public let outWidth: Int
    public let outHeight: Int
}

public enum ColorTransforms {
    // CIE D65 (x = 0.3127, y = 0.3290) and DNG/ICC PCS D50
    public static let xyzD65 = SIMD3<Double>(0.9504559270516716, 1.0, 1.0890577507598784)
    public static let xyzD50 = SIMD3<Double>(0.9642, 1.0, 0.8249)

    public static let rec2020Luma = SIMD3<Double>(0.2627002120, 0.6779980715, 0.0593017165)
    public static let displayP3Luma = SIMD3<Double>(0.2289745641, 0.6917385218, 0.0792869141)
    public static let srgbLuma = SIMD3<Double>(0.2126390059, 0.7151686788, 0.0721923154)

    public static let xyzD65ToRec2020 = matrix3x3(rows: [
        SIMD3<Double>(+1.7166511880, -0.3556707838, -0.2533662814),
        SIMD3<Double>(-0.6666843518, +1.6164812366, +0.0157685458),
        SIMD3<Double>(+0.0176398574, -0.0427706133, +0.9421031212),
    ])

    public static let rec2020ToXYZD65 = matrix3x3(rows: [
        SIMD3<Double>(+0.6369580483, +0.1446169036, +0.1688809752),
        SIMD3<Double>(+0.2627002120, +0.6779980715, +0.0593017165),
        SIMD3<Double>(+0.0000000000, +0.0280726930, +1.0609850577),
    ])

    public static let bradfordD50ToD65 = matrix3x3(rows: [
        SIMD3<Double>(+0.9555125889, -0.0230729752, +0.0633090847),
        SIMD3<Double>(-0.0283247593, +1.0099429264, +0.0210544388),
        SIMD3<Double>(+0.0123287032, -0.0205353077, +1.3307136899),
    ])

    public static let xyzD50ToRec2020D65 = matrix3x3(rows: [
        SIMD3<Double>(+1.6472324326, -0.3936124879, -0.2359668124),
        SIMD3<Double>(-0.6826173273, +1.6476123702, +0.0128103489),
        SIMD3<Double>(+0.0296814829, -0.0629492597, +1.2538857727),
    ])

    public static let displayP3ToRec2020 = matrix3x3(rows: [
        SIMD3<Double>(+0.7538330344, +0.1985973691, +0.0475695966),
        SIMD3<Double>(+0.0457438490, +0.9417772198, +0.0124789312),
        SIMD3<Double>(-0.0012103404, +0.0176017173, +0.9836086231),
    ])

    public static let rec2020ToDisplayP3 = matrix3x3(rows: [
        SIMD3<Double>(+1.3435782526, -0.2821796705, -0.0613985821),
        SIMD3<Double>(-0.0652974528, +1.0757879158, -0.0104904631),
        SIMD3<Double>(+0.0028217873, -0.0195984945, +1.0167767073),
    ])

    public static let rec2020ToSRGB = matrix3x3(rows: [
        SIMD3<Double>(+1.6604910021, -0.5876411388, -0.0728498633),
        SIMD3<Double>(-0.1245504745, +1.1328998971, -0.0083494226),
        SIMD3<Double>(-0.0181507634, -0.1005788980, +1.1187296614),
    ])

    public static let srgbToRec2020 = matrix3x3(rows: [
        SIMD3<Double>(+0.6274038959, +0.3292830384, +0.0433130657),
        SIMD3<Double>(+0.0690972893, +0.9195403951, +0.0113623156),
        SIMD3<Double>(+0.0163914389, +0.0880133079, +0.8955952532),
    ])

    public static let agxInset2020 = matrix3x3(rows: [
        SIMD3<Double>(+0.91725069, +0.04110084, +0.04164848),
        SIMD3<Double>(+0.06228230, +0.82450391, +0.11321379),
        SIMD3<Double>(+0.03407876, +0.02361892, +0.94230231),
    ])

    public static let agxOutset2020 = matrix3x3(rows: [
        SIMD3<Double>(+1.09540094, -0.05340171, -0.04199923),
        SIMD3<Double>(-0.07757292, +1.22082098, -0.14324806),
        SIMD3<Double>(-0.03767127, -0.02866873, +1.06634000),
    ])

    public static let rec2020ToLMS = matrix3x3(rows: [
        SIMD3<Double>(+0.6167557872, +0.3601983994, +0.0230458134),
        SIMD3<Double>(+0.2651330640, +0.6358393641, +0.0990275718),
        SIMD3<Double>(+0.1001026342, +0.2039065194, +0.6959908464),
    ])

    public static let lmsToRec2020 = matrix3x3(rows: [
        SIMD3<Double>(+2.1399067357, -1.2463895088, +0.1064827729),
        SIMD3<Double>(-0.8847358625, +2.1632309820, -0.2784951193),
        SIMD3<Double>(-0.0485737579, -0.4545031429, +1.5030769008),
    ])

    public static let displayP3ToLMS = matrix3x3(rows: [
        SIMD3<Double>(+0.4813798544, +0.4621183697, +0.0565017758),
        SIMD3<Double>(+0.2288319449, +0.6532168129, +0.1179512422),
        SIMD3<Double>(+0.0839457557, +0.2241652689, +0.6918889754),
    ])

    public static let lmsToDisplayP3 = matrix3x3(rows: [
        SIMD3<Double>(+3.1277689867, -2.2571357953, +0.1293668086),
        SIMD3<Double>(-1.0910090474, +2.4133317580, -0.3223227107),
        SIMD3<Double>(-0.0260108132, -0.5080413256, +1.5340521389),
    ])

    public static let srgbToLMS = matrix3x3(rows: [
        SIMD3<Double>(+0.4122214708, +0.5363325363, +0.0514459929),
        SIMD3<Double>(+0.2119034982, +0.6806995451, +0.1073969566),
        SIMD3<Double>(+0.0883024619, +0.2817188376, +0.6299787005),
    ])

    public static let lmsToSRGB = matrix3x3(rows: [
        SIMD3<Double>(+4.0767416614, -3.3077115904, +0.2309699286),
        SIMD3<Double>(-1.2684380041, +2.6097574005, -0.3413193961),
        SIMD3<Double>(-0.0041960865, -0.7034186144, +1.7076147009),
    ])

    public static let lmsCbrtToOKLab = matrix3x3(rows: [
        SIMD3<Double>(+0.2104542553, +0.7936177850, -0.0040720468),
        SIMD3<Double>(+1.9779984951, -2.4285922050, +0.4505937099),
        SIMD3<Double>(+0.0259040371, +0.7827717662, -0.8086757660),
    ])

    public static let oklabToLMSCbrt = matrix3x3(rows: [
        SIMD3<Double>(+1.0, +0.3963377774, +0.2158037573),
        SIMD3<Double>(+1.0, -0.1055613458, -0.0638541728),
        SIMD3<Double>(+1.0, -0.0894841775, -1.2914855480),
    ])

    private static let bradfordConeResponse = matrix3x3(rows: [
        SIMD3<Double>(+0.8951, +0.2664, -0.1614),
        SIMD3<Double>(-0.7502, +1.7135, +0.0367),
        SIMD3<Double>(+0.0389, -0.0685, +1.0296),
    ])

    public static func matrix3x3(rows: [SIMD3<Double>]) -> simd_double3x3 {
        precondition(rows.count == 3)
        return simd_double3x3(rows: rows)
    }

    public static func toFloat3x3(_ m: simd_double3x3) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(Float(m.columns.0.x), Float(m.columns.0.y), Float(m.columns.0.z)),
            SIMD3<Float>(Float(m.columns.1.x), Float(m.columns.1.y), Float(m.columns.1.z)),
            SIMD3<Float>(Float(m.columns.2.x), Float(m.columns.2.y), Float(m.columns.2.z))
        )
    }

    public static func isApproxIdentity(_ m: [Double], tol: Double = 1e-6) -> Bool {
        guard m.count == 9 else { return false }
        let id: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        for i in 0..<9 where abs(m[i] - id[i]) > tol {
            return false
        }
        return true
    }

    public static func matrixFromRowMajor9(_ arr: [Double]) -> simd_double3x3? {
        guard arr.count >= 9 else { return nil }
        for i in 0..<9 where !arr[i].isFinite { return nil }
        return matrix3x3(rows: [
            SIMD3<Double>(arr[0], arr[1], arr[2]),
            SIMD3<Double>(arr[3], arr[4], arr[5]),
            SIMD3<Double>(arr[6], arr[7], arr[8]),
        ])
    }

    public static func isInvertible(_ m: simd_double3x3, minDet: Double = 1e-8) -> Bool {
        let d = m.determinant
        return d.isFinite && abs(d) > minDet
    }

    /// Computes camera RGB -> Linear Rec.2020 (D65) 3x3 matrix following the 4-tier priority:
    /// 1. DCP dual-illuminant ForwardMatrix
    /// 2. Embedded DNG ForwardMatrix
    /// 3. DCP dual-illuminant ColorMatrix fallback
    /// 4. LibRaw camXYZ (9-elem 3x3 or 12-elem 4x3)
    public static func buildCameraToRec2020Matrix(
        matrices: CameraColorMatrices,
        dcp: DCPProfile?,
        sceneKelvin: Double
    ) -> simd_double3x3 {
        // Priority 1: DCP ForwardMatrix
        if let dcp, let fm = dcp.interpolatedForwardMatrix(sceneKelvin: sceneKelvin), isInvertible(fm) {
            return xyzD50ToRec2020D65 * normalizeForwardMatrixToD50(fm)
        }

        // Priority 2: Embedded DNG ForwardMatrix (non-identity)
        if !isApproxIdentity(matrices.forwardMatrix),
           let fm = matrixFromRowMajor9(matrices.forwardMatrix),
           isInvertible(fm) {
            return xyzD50ToRec2020D65 * normalizeForwardMatrixToD50(fm)
        }

        // Priority 3: DCP ColorMatrix fallback
        if let dcp, let cm = dcp.interpolatedColorMatrix(sceneKelvin: sceneKelvin), isInvertible(cm) {
            let camToXYZD50 = cm.inverse
            return xyzD50ToRec2020D65 * normalizeCamToXYZ(camToXYZD50, targetWhite: xyzD50)
        }

        // Priority 4: LibRaw camXYZ (XYZ_D65 -> CamRaw; top 3x3 of 9- or 12-elem array)
        if let camXYZ3x3 = matrixFromRowMajor9(matrices.camXYZ), isInvertible(camXYZ3x3) {
            let camD65 = camXYZ3x3 * xyzD65
            if camD65.x > 1e-6 && camD65.y > 1e-6 && camD65.z > 1e-6 {
                let rowNorm = simd_double3x3(rows: [
                    camXYZ3x3.transpose.columns.0 / camD65.x,
                    camXYZ3x3.transpose.columns.1 / camD65.y,
                    camXYZ3x3.transpose.columns.2 / camD65.z,
                ])
                if isInvertible(rowNorm) {
                    return xyzD65ToRec2020 * rowNorm.inverse
                }
            }
            return xyzD65ToRec2020 * camXYZ3x3.inverse
        }

        return matrix_identity_double3x3
    }

    private static func normalizeForwardMatrixToD50(_ fm: simd_double3x3) -> simd_double3x3 {
        let white = fm * SIMD3<Double>(1, 1, 1)
        guard white.x > 1e-6 && white.y > 1e-6 && white.z > 1e-6 else { return fm }
        let scale = xyzD50 / white
        return simd_double3x3(diagonal: scale) * fm
    }

    private static func normalizeCamToXYZ(_ m: simd_double3x3, targetWhite: SIMD3<Double>) -> simd_double3x3 {
        let white = m * SIMD3<Double>(1, 1, 1)
        guard white.x > 1e-6 && white.y > 1e-6 && white.z > 1e-6 else { return m }
        let scale = targetWhite / white
        return simd_double3x3(diagonal: scale) * m
    }

    public static func whitePointXYZ(kelvin rawKelvin: Double, tint rawTint: Double) -> SIMD3<Double> {
        let T = min(max(rawKelvin, 2000.0), 15000.0)
        let tint = min(max(rawTint, -150.0), 150.0)

        let x: Double
        let y: Double
        if T >= 4000.0 {
            let invT = 1000.0 / T
            if T <= 7000.0 {
                x = -4.6070 * invT * invT * invT + 2.9678 * invT * invT + 0.09911 * invT + 0.244063
            } else {
                x = -2.0064 * invT * invT * invT + 1.9018 * invT * invT + 0.24748 * invT + 0.237040
            }
            y = -3.000 * x * x + 2.870 * x - 0.275
        } else {
            let invT = 1000.0 / T
            x = -0.2661239 * invT * invT * invT - 0.2343589 * invT * invT + 0.8776956 * invT + 0.179910
            if T >= 2222.0 {
                y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
            } else {
                y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
            }
        }

        // Convert to CIE 1960 UCS (u, v) and apply perpendicular Duv tint shift.
        let denom = -2.0 * x + 12.0 * y + 3.0
        var u = (4.0 * x) / max(denom, 1e-6)
        var v = (6.0 * y) / max(denom, 1e-6)

        // Numerical tangent along locus for perpendicular Duv normal
        let T2 = min(T + 25.0, 15000.0)
        let invT2 = 1000.0 / T2
        let x2: Double
        let y2: Double
        if T2 >= 4000.0 {
            x2 = (T2 <= 7000.0)
                ? (-4.6070 * invT2 * invT2 * invT2 + 2.9678 * invT2 * invT2 + 0.09911 * invT2 + 0.244063)
                : (-2.0064 * invT2 * invT2 * invT2 + 1.9018 * invT2 * invT2 + 0.24748 * invT2 + 0.237040)
            y2 = -3.000 * x2 * x2 + 2.870 * x2 - 0.275
        } else {
            x2 = -0.2661239 * invT2 * invT2 * invT2 - 0.2343589 * invT2 * invT2 + 0.8776956 * invT2 + 0.179910
            y2 = (T2 >= 2222.0)
                ? (-1.1063814 * x2 * x2 * x2 - 1.34811020 * x2 * x2 + 2.18555832 * x2 - 0.20219683)
                : (-0.9549476 * x2 * x2 * x2 - 1.37418593 * x2 * x2 + 2.09137015 * x2 - 0.16748867)
        }
        let d2 = -2.0 * x2 + 12.0 * y2 + 3.0
        let u2 = (4.0 * x2) / max(d2, 1e-6)
        let v2 = (6.0 * y2) / max(d2, 1e-6)
        let tu = u2 - u
        let tv = v2 - v
        let tLen = max(hypot(tu, tv), 1e-9)
        // Normal pointing toward green (+v direction as T decreases -> (-tv, tu))
        var nu = -tv / tLen
        var nv = tu / tLen
        if nv < 0 {
            nu = -nu
            nv = -nv
        }

        // Positive tint -> magenta (-green / -Duv)
        let duv = -tint * 0.0002
        u += nu * duv
        v += nv * duv

        let denomXY = 2.0 * u - 8.0 * v + 4.0
        let xp = min(max((3.0 * u) / max(denomXY, 1e-6), 0.05), 0.75)
        let yp = min(max((2.0 * v) / max(denomXY, 1e-6), 0.05), 0.75)
        return SIMD3<Double>(xp / yp, 1.0, (1.0 - xp - yp) / yp)
    }

    public static func bradfordAdaptationMatrix(srcXYZ: SIMD3<Double>, dstXYZ: SIMD3<Double>) -> simd_double3x3 {
        let srcLMS = bradfordConeResponse * srcXYZ
        let dstLMS = bradfordConeResponse * dstXYZ
        let scale = SIMD3<Double>(
            dstLMS.x / max(srcLMS.x, 1e-6),
            dstLMS.y / max(srcLMS.y, 1e-6),
            dstLMS.z / max(srcLMS.z, 1e-6)
        )
        return bradfordConeResponse.inverse * simd_double3x3(diagonal: scale) * bradfordConeResponse
    }

    public static func customWBMultipliers(
        kelvin: Double,
        tint: Double,
        camXYZ: [Double]
    ) -> SIMD3<Double> {
        let targetXYZ = whitePointXYZ(kelvin: kelvin, tint: tint)
        guard let m = matrixFromRowMajor9(camXYZ), isInvertible(m) else {
            // Approximate fallback via sRGB/D65 chromaticity ratio
            let adapt = bradfordAdaptationMatrix(srcXYZ: targetXYZ, dstXYZ: xyzD65)
            let w = adapt * SIMD3<Double>(1, 1, 1)
            let g = max(w.y, 1e-6)
            return SIMD3<Double>(w.x / g, 1.0, w.z / g)
        }
        let camResponse = m * targetXYZ
        let invCam = SIMD3<Double>(
            1.0 / max(camResponse.x, 1e-6),
            1.0 / max(camResponse.y, 1e-6),
            1.0 / max(camResponse.z, 1e-6)
        )
        return invCam / max(invCam.y, 1e-6)
    }

    public static func customWBAdaptationMatrixRec2020(
        kelvin: Double,
        tint: Double,
        referenceSceneXYZ: SIMD3<Double> = xyzD65
    ) -> simd_double3x3 {
        let targetXYZ = whitePointXYZ(kelvin: kelvin, tint: tint)
        // Adapting scene illuminated by targetXYZ back to D65 reference (or relative to as-shot)
        let adaptXYZ = bradfordAdaptationMatrix(srcXYZ: targetXYZ, dstXYZ: referenceSceneXYZ)
        return xyzD65ToRec2020 * adaptXYZ * rec2020ToXYZD65
    }

    public static func estimateAsShotSceneXYZ(matrices: CameraColorMatrices) -> SIMD3<Double> {
        let wb = matrices.wbMultipliers
        if matrices.asShotWBApplied {
            let isUniform = wb.isEmpty || wb.allSatisfy { abs($0 - 1.0) < 1e-4 }
            if isUniform {
                return xyzD65
            }
        }
        guard wb.count >= 3,
              wb[0] > 0, wb[1] > 0, wb[2] > 0,
              let c = matrixFromRowMajor9(matrices.camXYZ),
              isInvertible(c) else {
            return xyzD65
        }
        let gAvg = wb.count >= 4 ? 0.5 * (wb[1] + wb[3]) : wb[1]
        let camNeutral = SIMD3<Double>(1.0 / wb[0], 1.0 / max(gAvg, 1e-6), 1.0 / wb[2])
        let xyz = c.inverse * camNeutral
        guard xyz.y > 1e-6, xyz.x > 0, xyz.z > 0 else { return xyzD65 }
        return xyz / xyz.y
    }

    public static func estimateSceneKelvin(matrices: CameraColorMatrices) -> Double {
        let xyz = estimateAsShotSceneXYZ(matrices: matrices)
        let sum = xyz.x + xyz.y + xyz.z
        guard sum > 1e-6 else { return 5500.0 }
        let x = xyz.x / sum
        let y = xyz.y / sum
        // McCamy's CCT approximation
        let n = (x - 0.3320) / (0.1858 - y)
        let cct = -449.0 * n * n * n + 3525.0 * n * n - 6823.3 * n + 5520.33
        return min(max(cct.isFinite ? cct : 5500.0, 2000.0), 15000.0)
    }

    public static func computeOutputGeometry(
        srcWidth: Int,
        srcHeight: Int,
        orientation: Int,
        cropAspect: AspectRatio,
        cropOffset: CropOffset,
        maxLongEdge: Int?,
        gainMapResolution: GainMapResolution,
        gainMapChannels: GainMapChannels
    ) -> OutputGeometry {
        let safeOrient = (1...8).contains(orientation) ? orientation : 1
        let uprightW = safeOrient >= 5 ? srcHeight : srcWidth
        let uprightH = safeOrient >= 5 ? srcWidth : srcHeight

        func roundEven(_ v: Double) -> Int {
            max(2, Int((v / 2.0).rounded()) * 2)
        }

        let evenUpW = max(2, uprightW & ~1)
        let evenUpH = max(2, uprightH & ~1)

        var cropW: Int
        var cropH: Int
        if let ratio = cropAspect.numericRatio {
            if Double(evenUpW) / Double(evenUpH) > ratio {
                cropH = evenUpH
                cropW = min(evenUpW, roundEven(Double(cropH) * ratio))
            } else {
                cropW = evenUpW
                cropH = min(evenUpH, roundEven(Double(cropW) / ratio))
            }
        } else {
            cropW = evenUpW
            cropH = evenUpH
        }

        let cropX = min(max(Int((Double(uprightW - cropW) * cropOffset.normalizedCenterX).rounded()), 0), max(0, uprightW - cropW))
        let cropY = min(max(Int((Double(uprightH - cropH) * cropOffset.normalizedCenterY).rounded()), 0), max(0, uprightH - cropH))

        var outW = cropW
        var outH = cropH
        if let maxEdge = maxLongEdge, max(cropW, cropH) > maxEdge {
            let safeMax = max(2, maxEdge)
            let scale = Double(safeMax) / Double(max(cropW, cropH))
            let maxEven = max(2, safeMax & ~1)
            outW = min(roundEven(Double(cropW) * scale), maxEven)
            outH = min(roundEven(Double(cropH) * scale), maxEven)
        }

        // Enforce multiple-of-4 alignment when half-res 3ch gain map is requested so
        // 0.5x gain maps always have even dimensions (required by AVIF YUV420 grid tiling).
        // Floor down (& ~3) so max(outW, outH) never exceeds maxLongEdge.
        if gainMapResolution == .half && gainMapChannels == .rgb3ch {
            if outW >= 4 {
                outW = max(4, outW & ~3)
            }
            if outH >= 4 {
                outH = max(4, outH & ~3)
            }
        }

        return OutputGeometry(
            srcWidth: srcWidth,
            srcHeight: srcHeight,
            orientation: safeOrient,
            uprightWidth: uprightW,
            uprightHeight: uprightH,
            cropX: cropX,
            cropY: cropY,
            cropWidth: cropW,
            cropHeight: cropH,
            outWidth: outW,
            outHeight: outH
        )
    }

    // MARK: - OKLab & CIEDE2000 Helpers

    public static func linearRec2020ToOKLab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let lms = rec2020ToLMS * rgb
        return lmsToOKLab(lms)
    }

    public static func linearDisplayP3ToOKLab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let lms = displayP3ToLMS * rgb
        return lmsToOKLab(lms)
    }

    public static func linearSRGBToOKLab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let lms = srgbToLMS * rgb
        return lmsToOKLab(lms)
    }

    private static func lmsToOKLab(_ lms: SIMD3<Double>) -> SIMD3<Double> {
        let cbrt = SIMD3<Double>(
            copysign(pow(abs(lms.x), 1.0 / 3.0), lms.x),
            copysign(pow(abs(lms.y), 1.0 / 3.0), lms.y),
            copysign(pow(abs(lms.z), 1.0 / 3.0), lms.z)
        )
        return lmsCbrtToOKLab * cbrt
    }

    public static func ciede2000(lab1: SIMD3<Double>, lab2: SIMD3<Double>) -> Double {
        let L1 = lab1.x, a1 = lab1.y, b1 = lab1.z
        let L2 = lab2.x, a2 = lab2.y, b2 = lab2.z

        let C1 = hypot(a1, b1)
        let C2 = hypot(a2, b2)
        let Cbar = 0.5 * (C1 + C2)
        let Cbar7 = pow(Cbar, 7.0)
        let pow25_7 = pow(25.0, 7.0)
        let G = 0.5 * (1.0 - sqrt(Cbar7 / (Cbar7 + pow25_7)))

        let a1p = (1.0 + G) * a1
        let a2p = (1.0 + G) * a2
        let C1p = hypot(a1p, b1)
        let C2p = hypot(a2p, b2)

        func hueAngle(_ b: Double, _ ap: Double) -> Double {
            if abs(b) < 1e-12 && abs(ap) < 1e-12 { return 0.0 }
            var h = atan2(b, ap) * 180.0 / .pi
            if h < 0 { h += 360.0 }
            return h
        }

        let h1p = hueAngle(b1, a1p)
        let h2p = hueAngle(b2, a2p)

        let dLp = L2 - L1
        let dCp = C2p - C1p

        let dhp: Double
        if C1p * C2p == 0.0 {
            dhp = 0.0
        } else {
            let diff = h2p - h1p
            if abs(diff) <= 180.0 {
                dhp = diff
            } else if diff > 180.0 {
                dhp = diff - 360.0
            } else {
                dhp = diff + 360.0
            }
        }
        let dHp = 2.0 * sqrt(C1p * C2p) * sin((dhp * .pi / 180.0) * 0.5)

        let Lbarp = 0.5 * (L1 + L2)
        let Cbarp = 0.5 * (C1p + C2p)

        let hbarp: Double
        if C1p * C2p == 0.0 {
            hbarp = h1p + h2p
        } else if abs(h1p - h2p) <= 180.0 {
            hbarp = 0.5 * (h1p + h2p)
        } else if h1p + h2p < 360.0 {
            hbarp = 0.5 * (h1p + h2p + 360.0)
        } else {
            hbarp = 0.5 * (h1p + h2p - 360.0)
        }

        let deg2rad = Double.pi / 180.0
        let T = 1.0
            - 0.17 * cos((hbarp - 30.0) * deg2rad)
            + 0.24 * cos((2.0 * hbarp) * deg2rad)
            + 0.32 * cos((3.0 * hbarp + 6.0) * deg2rad)
            - 0.20 * cos((4.0 * hbarp - 63.0) * deg2rad)

        let dTheta = 30.0 * exp(-pow((hbarp - 275.0) / 25.0, 2.0))
        let Cbarp7 = pow(Cbarp, 7.0)
        let RC = 2.0 * sqrt(Cbarp7 / (Cbarp7 + pow25_7))
        let L50 = Lbarp - 50.0
        let SL = 1.0 + (0.015 * L50 * L50) / sqrt(20.0 + L50 * L50)
        let SC = 1.0 + 0.045 * Cbarp
        let SH = 1.0 + 0.015 * Cbarp * T
        let RT = -sin(2.0 * dTheta * deg2rad) * RC

        let kL = 1.0, kC = 1.0, kH = 1.0
        let tL = dLp / (kL * SL)
        let tC = dCp / (kC * SC)
        let tH = dHp / (kH * SH)
        return sqrt(tL * tL + tC * tC + tH * tH + RT * tC * tH)
    }

    public static func linearDisplayP3ToCIELab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let rec2020 = displayP3ToRec2020 * rgb
        let xyz = rec2020ToXYZD65 * rec2020
        return xyzD65ToCIELab(xyz)
    }

    public static func linearSRGBToCIELab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let rec2020 = srgbToRec2020 * rgb
        let xyz = rec2020ToXYZD65 * rec2020
        return xyzD65ToCIELab(xyz)
    }

    private static func xyzD65ToCIELab(_ xyz: SIMD3<Double>) -> SIMD3<Double> {
        let n = xyz / xyzD65
        func f(_ t: Double) -> Double {
            let eps = 216.0 / 24389.0
            let kappa = 24389.0 / 27.0
            return t > eps ? cbrt(t) : (kappa * t + 16.0) / 116.0
        }
        let fx = f(n.x), fy = f(n.y), fz = f(n.z)
        return SIMD3<Double>(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))
    }
}
