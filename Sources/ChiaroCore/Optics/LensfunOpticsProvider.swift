/*
 * This file is part of Chiaro.
 *
 * Chiaro is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import CLensfunBridge
import Foundation
import os

public enum LensfunProviderError: Error, Sendable, CustomStringConvertible {
    case databaseUnavailable
    case invalidXMLFile(URL)
    case userDirectoryUnavailable

    public var description: String {
        switch self {
        case .databaseUnavailable:
            return "Lensfun database handle could not be initialized."
        case let .invalidXMLFile(url):
            return "File '\(url.lastPathComponent)' is not a valid Lensfun XML file."
        case .userDirectoryUnavailable:
            return "Could not resolve Application Support user directory for Lensfun XMLs."
        }
    }
}

public struct LensfunMatchResult: Sendable, Equatable, Hashable {
    public let cameraMatched: String
    public let lensMatched: String
    public let resolvedCropFactor: Double
    public let isSonyEFallback: Bool
    public let hasDistortion: Bool
    public let hasTCA: Bool
    public let hasVignetting: Bool
}

public final class LensfunOpticsProvider: @unchecked Sendable {
    public static let shared = LensfunOpticsProvider()

    public static var bundledDatabaseURL: URL? {
        PresetLoader.resourceBundle.url(forResource: "LensfunDB", withExtension: nil)
    }

    public static var defaultUserDatabaseURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Chiaro/Lensfun", isDirectory: true)
    }

    private final class HandleBox: @unchecked Sendable {
        var handle: OpaquePointer?
        var databaseGeneration: UInt64 = 0
        init(handle: OpaquePointer?) {
            self.handle = handle
        }
        deinit {
            if let handle {
                chiaro_lensfun_destroy(handle)
            }
        }
    }

    private let lock: OSAllocatedUnfairLock<HandleBox>
    public let primaryDatabaseURL: URL?
    public let userDatabaseURL: URL?

    public var databaseGeneration: UInt64 {
        lock.withLock { $0.databaseGeneration }
    }

    public init(
        primaryDatabaseURL: URL? = LensfunOpticsProvider.bundledDatabaseURL,
        userDatabaseURL: URL? = LensfunOpticsProvider.defaultUserDatabaseURL
    ) {
        self.primaryDatabaseURL = primaryDatabaseURL
        self.userDatabaseURL = userDatabaseURL

        let primaryPath = primaryDatabaseURL?.path
        let userPath: String?
        if let u = userDatabaseURL, FileManager.default.fileExists(atPath: u.path) {
            userPath = u.path
        } else {
            userPath = nil
        }

        let created: OpaquePointer? = primaryPath.withOptionalCString { pPtr in
            userPath.withOptionalCString { uPtr in
                chiaro_lensfun_create(pPtr, uPtr)
            }
        }
        self.lock = OSAllocatedUnfairLock(initialState: HandleBox(handle: created))
    }

    public func databaseInfo() -> (
        version: String,
        cameraCount: Int,
        lensCount: Int,
        loadedPrimary: Bool,
        loadedUser: Bool
    ) {
        lock.withLock { box in
            guard let handle = box.handle else {
                return ("0.0.0", 0, 0, false, false)
            }
            var info = ChiaroLensfunLibraryInfo()
            guard chiaro_lensfun_get_info(handle, &info) == 0 else {
                return ("0.0.0", 0, 0, false, false)
            }
            let ver = "\(info.version_major).\(info.version_minor).\(info.version_micro)"
            return (
                ver,
                Int(info.db_camera_count),
                Int(info.db_lens_count),
                info.loaded_primary_db != 0,
                info.loaded_user_db != 0
            )
        }
    }

    public func reloadUserDatabase() {
        lock.withLock { box in
            guard let handle = box.handle else { return }
            let userPath: String?
            if let u = userDatabaseURL, FileManager.default.fileExists(atPath: u.path) {
                userPath = u.path
            } else {
                userPath = nil
            }
            _ = userPath.withOptionalCString { uPtr in
                chiaro_lensfun_reload_user_db(handle, uPtr)
            }
            box.databaseGeneration &+= 1
        }
    }

    public func importCustomXML(from sourceURL: URL) throws {
        guard sourceURL.isFileURL, FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw LensfunProviderError.invalidXMLFile(sourceURL)
        }
        let xmlDoc: XMLDocument
        do {
            xmlDoc = try XMLDocument(contentsOf: sourceURL, options: [])
        } catch {
            throw LensfunProviderError.invalidXMLFile(sourceURL)
        }
        guard let root = xmlDoc.rootElement(),
              root.name == "lensdatabase",
              (root.childCount > 0) else {
            throw LensfunProviderError.invalidXMLFile(sourceURL)
        }

        // Validate that Lensfun's XML loader cleanly accepts this file in an isolated staging directory
        // before copying it into the persistent user database folder.
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chiaro-lensfun-validate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let stagedXML = stagingDir.appendingPathComponent(sourceURL.lastPathComponent)
        try FileManager.default.copyItem(at: sourceURL, to: stagedXML)

        let validated: Bool = stagingDir.path.withCString { stagePtr in
            guard let testHandle = chiaro_lensfun_create(nil, stagePtr) else {
                return false
            }
            defer { chiaro_lensfun_destroy(testHandle) }
            var info = ChiaroLensfunLibraryInfo()
            guard chiaro_lensfun_get_info(testHandle, &info) == 0 else {
                return false
            }
            return info.loaded_user_db != 0 && (info.db_lens_count > 0 || info.db_camera_count > 0)
        }
        guard validated else {
            throw LensfunProviderError.invalidXMLFile(sourceURL)
        }

        guard let userDir = userDatabaseURL else {
            throw LensfunProviderError.userDirectoryUnavailable
        }
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        let destURL = userDir.appendingPathComponent(sourceURL.lastPathComponent)
        let backupData = FileManager.default.fileExists(atPath: destURL.path) ? try? Data(contentsOf: destURL) : nil
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        reloadUserDatabase()
        if !databaseInfo().loadedUser {
            try? FileManager.default.removeItem(at: destURL)
            if let backupData {
                try? backupData.write(to: destURL, options: .atomic)
            }
            reloadUserDatabase()
            throw LensfunProviderError.invalidXMLFile(sourceURL)
        }
    }

    public func availableLenses(mountFilter: String? = nil) -> [String] {
        lock.withLock { box in
            guard let handle = box.handle else { return [] }
            var namesPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            var count: Int32 = 0
            let rc = mountFilter.withOptionalCString { mPtr in
                chiaro_lensfun_list_lenses(handle, mPtr, &namesPtr, &count)
            }
            guard rc == 0, let namesPtr, count > 0 else {
                return []
            }
            defer { chiaro_lensfun_free_string_list(namesPtr, count) }
            var result: [String] = []
            result.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                if let cStr = namesPtr[i] {
                    result.append(String(cString: cStr))
                }
            }
            return result
        }
    }

    public func resolveMatch(
        make: String?,
        model: String?,
        lensMake: String?,
        lensModel: String?,
        cropFactor: Double,
        params: OpticalCorrectionParameters
    ) -> LensfunMatchResult? {
        lock.withLock { box in
            guard let handle = box.handle else { return nil }
            var cRes = ChiaroLensfunMatchResult()
            let rc = withMatchQuery(
                make: make,
                model: model,
                lensMake: lensMake,
                lensModel: lensModel,
                cameraOverride: params.lensfunCameraOverride,
                lensOverride: params.lensfunLensOverride,
                cropFactor: Float(cropFactor)
            ) { query in
                var q = query
                return chiaro_lensfun_match(handle, &q, &cRes)
            }
            guard rc == 0, cRes.matched != 0 else {
                return nil
            }
            return Self.convertMatchResult(cRes)
        }
    }

    public func computeLUT(
        make: String?,
        model: String?,
        lensMake: String?,
        lensModel: String?,
        focalLengthMM: Double?,
        apertureFNumber: Double?,
        cropFactor: Double,
        width: Int,
        height: Int,
        lutWidth: Int = 256,
        lutHeight: Int = 192,
        params: OpticalCorrectionParameters
    ) -> (lut: OpticsLUTData, match: LensfunMatchResult)? {
        guard width > 1, height > 1, lutWidth >= 2, lutHeight >= 2 else {
            return nil
        }
        return lock.withLock { box in
            guard let handle = box.handle else { return nil }
            let sliceFloats = lutWidth * lutHeight * 2
            var warp = [Float](repeating: 0, count: 3 * sliceFloats)
            var vigFloat = [Float](repeating: 1.0, count: lutWidth * lutHeight)
            var cRes = ChiaroLensfunMatchResult()

            var lutParams = ChiaroLensfunLUTParams(
                image_width: Int32(width),
                image_height: Int32(height),
                lut_width: Int32(lutWidth),
                lut_height: Int32(lutHeight),
                focal_length_mm: Float(focalLengthMM ?? 0),
                aperture_f_number: Float(apertureFNumber ?? 0),
                enable_distortion: params.distortion ? 1 : 0,
                enable_auto_scale: params.autoScale ? 1 : 0,
                enable_tca: params.tca ? 1 : 0,
                enable_vignetting: params.vignetting ? 1 : 0
            )

            let rc: Int32 = withMatchQuery(
                make: make,
                model: model,
                lensMake: lensMake,
                lensModel: lensModel,
                cameraOverride: params.lensfunCameraOverride,
                lensOverride: params.lensfunLensOverride,
                cropFactor: Float(cropFactor)
            ) { query in
                var q = query
                return warp.withUnsafeMutableBufferPointer { wPtr in
                    vigFloat.withUnsafeMutableBufferPointer { vPtr in
                        chiaro_lensfun_compute_lut(
                            handle,
                            &q,
                            &lutParams,
                            wPtr.baseAddress,
                            vPtr.baseAddress,
                            &cRes
                        )
                    }
                }
            }

            guard rc == 0, cRes.matched != 0 else {
                return nil
            }

            let vigHalf = vigFloat.map { Float16($0.isFinite ? min(max($0, 0.25), 8.0) : 1.0) }
            let match = Self.convertMatchResult(cRes)
            let lut = OpticsLUTData(
                lutWidth: lutWidth,
                lutHeight: lutHeight,
                warpRGBUV: warp,
                vignettingGain: vigHalf,
                distortionApplied: cRes.has_distortion != 0 && params.distortion,
                tcaApplied: cRes.has_tca != 0 && params.tca,
                vignettingApplied: cRes.has_vignetting != 0 && params.vignetting
            )
            return (lut, match)
        }
    }

    private func withMatchQuery<R>(
        make: String?,
        model: String?,
        lensMake: String?,
        lensModel: String?,
        cameraOverride: String?,
        lensOverride: String?,
        cropFactor: Float,
        body: (ChiaroLensfunMatchQuery) -> R
    ) -> R {
        make.withOptionalCString { mkPtr in
            model.withOptionalCString { mdPtr in
                lensMake.withOptionalCString { lmkPtr in
                    lensModel.withOptionalCString { lmdPtr in
                        cameraOverride.withOptionalCString { coPtr in
                            lensOverride.withOptionalCString { loPtr in
                                let q = ChiaroLensfunMatchQuery(
                                    camera_make: mkPtr,
                                    camera_model: mdPtr,
                                    lens_make: lmkPtr,
                                    lens_model: lmdPtr,
                                    camera_override: coPtr,
                                    lens_override: loPtr,
                                    crop_factor: cropFactor
                                )
                                return body(q)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func convertMatchResult(_ cRes: ChiaroLensfunMatchResult) -> LensfunMatchResult {
        let camStr = withUnsafeBytes(of: cRes.camera_matched) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let lensStr = withUnsafeBytes(of: cRes.lens_matched) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return LensfunMatchResult(
            cameraMatched: camStr,
            lensMatched: lensStr,
            resolvedCropFactor: Double(cRes.resolved_crop_factor),
            isSonyEFallback: cRes.is_sony_e_fallback != 0,
            hasDistortion: cRes.has_distortion != 0,
            hasTCA: cRes.has_tca != 0,
            hasVignetting: cRes.has_vignetting != 0
        )
    }
}

private extension Optional where Wrapped == String {
    func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case let .some(str):
            return str.withCString { body($0) }
        case .none:
            return body(nil)
        }
    }
}
