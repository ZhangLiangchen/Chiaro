import ChiaroAppCore
import ChiaroCore
import Foundation
import Testing

@Suite("ParameterDocumentationTests")
struct ParameterDocumentationTests {

    @Test("100% ParameterID.allCases have complete bilingual docs within summary length limits")
    func testAllParameterIDsDocumentedBilingually() {
        #expect(ParameterID.allCases.count >= 45)

        var zhTitles: Set<String> = []
        var enTitles: Set<String> = []

        for id in ParameterID.allCases {
            let doc = ParameterDocumentationRegistry.doc(for: id)
            #expect(doc.id == id)

            let fields: [LocalizedText] = [
                doc.title,
                doc.shortSummary,
                doc.controlsWhat,
                doc.leftOrLowEffect,
                doc.rightOrHighEffect,
                doc.recommendedRange,
                doc.proTip,
            ]

            for field in fields {
                let zh = field.zhHans.trimmingCharacters(in: .whitespacesAndNewlines)
                let en = field.en.trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(!zh.isEmpty, "Missing zh-Hans text for ParameterID.\(id.rawValue)")
                #expect(!en.isEmpty, "Missing en text for ParameterID.\(id.rawValue)")
            }

            #expect(
                doc.shortSummary.zhHans.count <= 28,
                "zh-Hans shortSummary too long (\(doc.shortSummary.zhHans.count) > 28) for \(id.rawValue): \(doc.shortSummary.zhHans)"
            )
            #expect(
                doc.shortSummary.en.count <= 75,
                "en shortSummary too long (\(doc.shortSummary.en.count) > 75) for \(id.rawValue): \(doc.shortSummary.en)"
            )

            zhTitles.insert(doc.title.zhHans)
            enTitles.insert(doc.title.en)
        }

        #expect(zhTitles.count == ParameterID.allCases.count)
        #expect(enTitles.count == ParameterID.allCases.count)
    }

    @Test("ADR-013 redline: zero speculative manual distortion (k1/k2) or manual CA ParameterIDs")
    func testNoSpeculativeManualOpticsParameters() {
        let forbiddenTokens = ["k1", "k2", "manualdistortion", "manualca", "cashift", "chromaticshift"]
        for id in ParameterID.allCases {
            let lowered = id.rawValue.lowercased()
            for token in forbiddenTokens {
                #expect(!lowered.contains(token), "Forbidden ADR-013 manual optics token '\(token)' found in \(id.rawValue)")
            }
        }
    }

    @Test("AppLanguage resolution handles system, -AppleLanguages overrides, and explicit selections")
    func testAppLanguageResolution() {
        #expect(AppLanguage.zhHans.resolve(preferredLanguages: ["en-US"], appleLanguagesOverride: ["en"]) == .zhHans)
        #expect(AppLanguage.en.resolve(preferredLanguages: ["zh-Hans"], appleLanguagesOverride: ["zh-Hans"]) == .en)

        #expect(
            AppLanguage.system.resolve(preferredLanguages: ["en-US"], appleLanguagesOverride: ["zh-Hans"]) == .zhHans
        )
        #expect(
            AppLanguage.system.resolve(preferredLanguages: ["zh-Hans"], appleLanguagesOverride: ["en"]) == .en
        )
        #expect(
            AppLanguage.system.resolve(preferredLanguages: ["zh-Hant-CN"], appleLanguagesOverride: nil) == .zhHans
        )
        #expect(
            AppLanguage.system.resolve(preferredLanguages: ["en-US"], appleLanguagesOverride: nil) == .en
        )
    }

    @Test("ChiaroStrings localizes all 7 built-in presets and publishing guides in zh-Hans and en")
    func testBilingualPresetsAndStrings() throws {
        let presets = try PresetLoader.loadAllBuiltIn()
        #expect(presets.count == BuiltInPresetID.allCases.count)

        for preset in presets {
            let zhName = ChiaroStrings.presetName(preset, lang: .zhHans)
            let enName = ChiaroStrings.presetName(preset, lang: .en)
            let zhDesc = ChiaroStrings.presetDescription(preset, lang: .zhHans)
            let enDesc = ChiaroStrings.presetDescription(preset, lang: .en)
            let zhAdv = ChiaroStrings.presetAdvisory(preset, lang: .zhHans)
            let enAdv = ChiaroStrings.presetAdvisory(preset, lang: .en)

            #expect(!zhName.isEmpty && !enName.isEmpty)
            #expect(zhName != enName)
            #expect(!zhDesc.isEmpty && !enDesc.isEmpty)
            #expect(!zhAdv.isEmpty && !enAdv.isEmpty)
            #expect(!ChiaroStrings.presetSpecTags(preset, lang: .zhHans).isEmpty)
            #expect(!ChiaroStrings.presetSpecTags(preset, lang: .en).isEmpty)
        }

        let zhGuide = ChiaroStrings.guideCards(lang: .zhHans)
        let enGuide = ChiaroStrings.guideCards(lang: .en)
        #expect(zhGuide.count == 3)
        #expect(enGuide.count == 3)
        for idx in 0..<3 {
            #expect(!zhGuide[idx].title.isEmpty && !enGuide[idx].title.isEmpty)
            #expect(zhGuide[idx].title != enGuide[idx].title)
            #expect(!zhGuide[idx].dos.isEmpty && !enGuide[idx].dos.isEmpty)
            #expect(!zhGuide[idx].donts.isEmpty && !enGuide[idx].donts.isEmpty)
        }
    }
}
