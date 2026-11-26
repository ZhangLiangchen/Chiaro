/*
 * This file is part of Chiaro.
 *
 * Chiaro is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Embedded Sony .ARW optical curve evaluator ported from darktable:
 *   darktable/src/iop/lens.cc (_init_coeffs_md_v2, GPL-3.0-or-later)
 */

import Foundation

public struct OpticsLUTData: Sendable {
    public let lutWidth: Int
    public let lutHeight: Int
    /// 3 slices (`0=R`, `1=G`, `2=B`), each `lutWidth * lutHeight * 2` floats storing normalized `(u_src, v_src)`.
    public let warpRGBUV: [Float]
    /// `lutWidth * lutHeight` `Float16` full (`100%`) linear vignetting gain values.
    public let vignettingGain: [Float16]
    public let distortionApplied: Bool
    public let tcaApplied: Bool
    public let vignettingApplied: Bool

    public init(
        lutWidth: Int,
        lutHeight: Int,
        warpRGBUV: [Float],
        vignettingGain: [Float16],
        distortionApplied: Bool,
        tcaApplied: Bool,
        vignettingApplied: Bool
    ) {
        self.lutWidth = lutWidth
        self.lutHeight = lutHeight
        self.warpRGBUV = warpRGBUV
        self.vignettingGain = vignettingGain
        self.distortionApplied = distortionApplied
        self.tcaApplied = tcaApplied
        self.vignettingApplied = vignettingApplied
    }
}

/// Pure-Swift evaluator for Sony `.ARW` SubIFD / SR2SubIFD optical curves (`ADR-013`),
/// faithfully implementing darktable `src/iop/lens.cc` (`DT_IOP_LENS_EMBEDDED_METADATA_VERSION_2`).
public struct EmbeddedSonyOpticsEvaluator: Sendable {
    public static func computeLUT(
        payload: EmbeddedSonyOpticsPayload,
        width: Int,
        height: Int,
        lutWidth: Int = 256,
        lutHeight: Int = 192,
        distortion: Bool,
        autoScale: Bool,
        tca: Bool,
        vignetting: Bool
    ) -> OpticsLUTData {
        precondition(width > 0 && height > 0, "Image dimensions must be positive")
        precondition(lutWidth >= 2 && lutHeight >= 2, "LUT dimensions must be >= 2")

        let applyDistortion = distortion && payload.hasDistortion
        let applyTCA = tca && payload.hasTCA
        let applyVignetting = vignetting && payload.hasVignetting

        let sliceFloats = lutWidth * lutHeight * 2
        var warpRGBUV = [Float](repeating: 0, count: 3 * sliceFloats)
        var vigGain = [Float16](repeating: Float16(1.0), count: lutWidth * lutHeight)

        var knotsDist = applyDistortion ? makeKnots(count: payload.distortionNodeCount) : []
        var distCurve = [Double](repeating: 1.0, count: knotsDist.count)
        if applyDistortion {
            let distScale = pow(2.0, -14.0)
            for i in 0..<knotsDist.count {
                distCurve[i] = Double(payload.distortionParams[i]) * distScale + 1.0
            }
        }

        var knotsCA = applyTCA ? makeKnots(count: payload.caNodeCount) : []
        var caRedCurve = [Double](repeating: 1.0, count: knotsCA.count)
        var caBlueCurve = [Double](repeating: 1.0, count: knotsCA.count)
        if applyTCA {
            let caScale = pow(2.0, -21.0)
            for i in 0..<knotsCA.count {
                caRedCurve[i] = Double(payload.caRedParams[i]) * caScale + 1.0
                caBlueCurve[i] = Double(payload.caBlueParams[i]) * caScale + 1.0
            }
        }

        var autoScaleDivisor = 1.0
        if autoScale && (applyDistortion || applyTCA) {
            let w2 = 0.5 * Double(width)
            let h2 = 0.5 * Double(height)
            let rMax = max(hypot(w2, h2), 1e-6)
            let srr = min(w2, h2) / rMax
            var scale = 0.0
            for k in 0..<200 {
                let xk = srr + (1.0 - srr) * Double(k) / 199.0
                let gVal = applyDistortion ? interpolateLinearSpline(knotsDist, distCurve, xk) : 1.0
                let rScale = applyTCA ? interpolateLinearSpline(knotsCA, caRedCurve, xk) : 1.0
                let bScale = applyTCA ? interpolateLinearSpline(knotsCA, caBlueCurve, xk) : 1.0
                scale = max(scale, gVal)
                scale = max(scale, gVal * rScale)
                scale = max(scale, gVal * bScale)
            }
            if scale > 1e-5 && scale.isFinite {
                autoScaleDivisor = scale
                for i in 0..<knotsDist.count {
                    knotsDist[i] *= scale
                    distCurve[i] /= scale
                }
                for i in 0..<knotsCA.count {
                    knotsCA[i] *= scale
                }
            }
        }

        let vigNodeCount = applyVignetting ? payload.vignettingNodeCount : 0
        let knotsVig = makeKnots(count: vigNodeCount)
        var vigCurve = [Double](repeating: 1.0, count: vigNodeCount)
        if vigNodeCount > 0 {
            for i in 0..<vigNodeCount {
                let exponent = Double(payload.vignettingParams[i]) * pow(2.0, -13.0) - 1.0
                let v = pow(2.0, 0.5 - pow(2.0, exponent))
                vigCurve[i] = v.isFinite ? v : 1.0
            }
        }

        let wD = Double(width)
        let hD = Double(height)
        let rMax = max(hypot(0.5 * wD, 0.5 * hD), 1e-6)

        for gy in 0..<lutHeight {
            let vDst = Double(gy) / Double(lutHeight - 1)
            let cy = (vDst - 0.5) * hD

            for gx in 0..<lutWidth {
                let uDst = Double(gx) / Double(lutWidth - 1)
                let cx = (uDst - 0.5) * wD

                let uSrcR: Double
                let vSrcR: Double
                let uSrcG: Double
                let vSrcG: Double
                let uSrcB: Double
                let vSrcB: Double

                if applyDistortion || applyTCA {
                    let rNorm = hypot(cx, cy) / rMax
                    let drG = applyDistortion
                        ? interpolateLinearSpline(knotsDist, distCurve, rNorm)
                        : (1.0 / autoScaleDivisor)
                    let rScale = applyTCA ? interpolateLinearSpline(knotsCA, caRedCurve, rNorm) : 1.0
                    let bScale = applyTCA ? interpolateLinearSpline(knotsCA, caBlueCurve, rNorm) : 1.0
                    let drR = drG * rScale
                    let drB = drG * bScale

                    uSrcR = 0.5 + (drR * cx) / wD
                    vSrcR = 0.5 + (drR * cy) / hD
                    uSrcG = 0.5 + (drG * cx) / wD
                    vSrcG = 0.5 + (drG * cy) / hD
                    uSrcB = 0.5 + (drB * cx) / wD
                    vSrcB = 0.5 + (drB * cy) / hD
                } else {
                    uSrcR = uDst; vSrcR = vDst
                    uSrcG = uDst; vSrcG = vDst
                    uSrcB = uDst; vSrcB = vDst
                }

                let pxIdx = gy * lutWidth + gx
                let uvIdx = pxIdx * 2
                warpRGBUV[0 * sliceFloats + uvIdx + 0] = uSrcR.isFinite ? Float(uSrcR) : Float(uDst)
                warpRGBUV[0 * sliceFloats + uvIdx + 1] = vSrcR.isFinite ? Float(vSrcR) : Float(vDst)
                warpRGBUV[1 * sliceFloats + uvIdx + 0] = uSrcG.isFinite ? Float(uSrcG) : Float(uDst)
                warpRGBUV[1 * sliceFloats + uvIdx + 1] = vSrcG.isFinite ? Float(vSrcG) : Float(vDst)
                warpRGBUV[2 * sliceFloats + uvIdx + 0] = uSrcB.isFinite ? Float(uSrcB) : Float(uDst)
                warpRGBUV[2 * sliceFloats + uvIdx + 1] = vSrcB.isFinite ? Float(vSrcB) : Float(vDst)

                if vigNodeCount > 0 {
                    // Vignetting is evaluated at warped green source coordinate in sensor plane.
                    let sx = (uSrcG - 0.5) * wD
                    let sy = (vSrcG - 0.5) * hD
                    let rVig = hypot(sx, sy) / rMax
                    let sf = interpolateLinearSpline(knotsVig, vigCurve, rVig)
                    let gain = min(max(1.0 / max(1e-4, sf), 0.25), 8.0)
                    vigGain[pxIdx] = Float16(gain.isFinite ? gain : 1.0)
                } else {
                    vigGain[pxIdx] = Float16(1.0)
                }
            }
        }

        return OpticsLUTData(
            lutWidth: lutWidth,
            lutHeight: lutHeight,
            warpRGBUV: warpRGBUV,
            vignettingGain: vigGain,
            distortionApplied: applyDistortion,
            tcaApplied: applyTCA,
            vignettingApplied: applyVignetting
        )
    }

    private static func makeKnots(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        if count == 1 { return [0.5] }
        let denom = Double(count - 1)
        return (0..<count).map { (Double($0) + 0.5) / denom }
    }

    private static func interpolateLinearSpline(
        _ xi: [Double],
        _ yi: [Double],
        _ x: Double
    ) -> Double {
        let n = min(xi.count, yi.count)
        guard n > 0 else { return 1.0 }
        if n == 1 || x <= xi[0] {
            return yi[0]
        }
        if x >= xi[n - 1] {
            return yi[n - 1]
        }
        for i in 1..<n {
            if x <= xi[i] {
                let dx = xi[i] - xi[i - 1]
                guard abs(dx) > 1e-12 else { return yi[i] }
                let t = (x - xi[i - 1]) / dx
                return yi[i - 1] + t * (yi[i] - yi[i - 1])
            }
        }
        return yi[n - 1]
    }
}
