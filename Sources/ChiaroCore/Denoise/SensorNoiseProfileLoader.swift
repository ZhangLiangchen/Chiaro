/*
 * This file is part of Chiaro.
 *
 * Chiaro is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Sensor noise profile data sourced from darktable data/noiseprofiles.json (GPL-3.0-or-later).
 */

import Foundation

public final class SensorNoiseProfileLoader: Sendable {
    public static let shared = SensorNoiseProfileLoader()

    public let database: SensorNoiseProfileDatabase

    public init(bundle: Bundle = PresetLoader.resourceBundle) {
        let url = bundle.url(
            forResource: "sony_a7c2_noiseprofile",
            withExtension: "json",
            subdirectory: "NoiseProfiles"
        ) ?? bundle.url(forResource: "sony_a7c2_noiseprofile", withExtension: "json")

        if let url,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(SensorNoiseProfileDatabase.self, from: data) {
            self.database = decoded
        } else {
            self.database = SensorNoiseProfileDatabase()
        }
    }

    public init(database: SensorNoiseProfileDatabase) {
        self.database = database
    }

    public func profile(forMake make: String?, model: String?) -> SensorNoiseProfile? {
        guard let normalizedMaker = Self.normalizeMaker(make),
              let normalizedModel = Self.normalizeModel(model) else {
            return nil
        }
        return database.profile(maker: normalizedMaker, model: normalizedModel)
    }

    public func profileWithSonyFallback(forMake make: String?, model: String?) -> SensorNoiseProfile? {
        if let exact = profile(forMake: make, model: model) {
            return exact
        }
        let mLower = make?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let modLower = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if mLower.contains("sony") || modLower.contains("ilce") || modLower.contains("7cm2") {
            return database.profile(maker: "Sony", model: "ILCE-7CM2")
        }
        return nil
    }

    private static func normalizeMaker(_ make: String?) -> String? {
        guard let trimmed = make?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if trimmed.lowercased().contains("sony") {
            return "Sony"
        }
        return trimmed
    }

    private static func normalizeModel(_ model: String?) -> String? {
        guard let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower.contains("7cm2") || lower.contains("7c ii") || lower.contains("7c2") || lower.contains("a7cm2") {
            return "ILCE-7CM2"
        }
        if lower.contains("7m4") || lower.contains("a7m4") {
            return "ILCE-7M4"
        }
        return trimmed
    }
}
