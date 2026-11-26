import Foundation

public enum ConflictPolicy: String, Sendable, Codable, CaseIterable, Hashable {
    case overwrite
    case skip
    case autoNumber
}

public struct ExportJob: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var inputURL: URL
    public var outputDirectory: URL
    public var preset: PresetSchema
    public var formatOverrides: [OutputFormat]?
    public var delta: PerPhotoDelta?
    public var decodeOptions: DecodeOptions
    public var namingTemplate: String
    public var useFormatSubdirectories: Bool
    public var conflictPolicy: ConflictPolicy
    public var verifyAfterExport: Bool
    public var cliOverrides: CLIDevelopOverrides?
    public var useSidecar: Bool
    public var avifCodecOverride: AVIFCodecChoice?

    public init(
        id: UUID = UUID(),
        inputURL: URL,
        outputDirectory: URL,
        preset: PresetSchema,
        formatOverrides: [OutputFormat]? = nil,
        delta: PerPhotoDelta? = nil,
        decodeOptions: DecodeOptions = .default,
        namingTemplate: String = "{name}_HDR.{ext}",
        useFormatSubdirectories: Bool = false,
        conflictPolicy: ConflictPolicy = .overwrite,
        verifyAfterExport: Bool = true,
        cliOverrides: CLIDevelopOverrides? = nil,
        useSidecar: Bool = false,
        avifCodecOverride: AVIFCodecChoice? = nil
    ) {
        self.id = id
        self.inputURL = inputURL
        self.outputDirectory = outputDirectory
        self.preset = preset
        self.formatOverrides = formatOverrides
        self.delta = delta
        self.decodeOptions = decodeOptions
        self.namingTemplate = namingTemplate
        self.useFormatSubdirectories = useFormatSubdirectories
        self.conflictPolicy = conflictPolicy
        self.verifyAfterExport = verifyAfterExport
        self.cliOverrides = cliOverrides
        self.useSidecar = useSidecar
        self.avifCodecOverride = avifCodecOverride
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case inputURL
        case outputDirectory
        case preset
        case formatOverrides
        case delta
        case decodeOptions
        case namingTemplate
        case useFormatSubdirectories
        case conflictPolicy
        case verifyAfterExport
        case cliOverrides
        case useSidecar
        case avifCodecOverride
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.inputURL = try c.decode(URL.self, forKey: .inputURL)
        self.outputDirectory = try c.decode(URL.self, forKey: .outputDirectory)
        self.preset = try c.decode(PresetSchema.self, forKey: .preset)
        self.formatOverrides = try c.decodeIfPresent([OutputFormat].self, forKey: .formatOverrides)
        self.delta = try c.decodeIfPresent(PerPhotoDelta.self, forKey: .delta)
        self.decodeOptions = try c.decodeIfPresent(DecodeOptions.self, forKey: .decodeOptions) ?? .default
        self.namingTemplate = try c.decodeIfPresent(String.self, forKey: .namingTemplate) ?? "{name}_HDR.{ext}"
        self.useFormatSubdirectories = try c.decodeIfPresent(Bool.self, forKey: .useFormatSubdirectories) ?? false
        self.conflictPolicy = try c.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy) ?? .overwrite
        self.verifyAfterExport = try c.decodeIfPresent(Bool.self, forKey: .verifyAfterExport) ?? true
        self.cliOverrides = try c.decodeIfPresent(CLIDevelopOverrides.self, forKey: .cliOverrides)
        self.useSidecar = try c.decodeIfPresent(Bool.self, forKey: .useSidecar) ?? false
        self.avifCodecOverride = try c.decodeIfPresent(AVIFCodecChoice.self, forKey: .avifCodecOverride)
    }

    public var activeFormats: [OutputFormat] {
        formatOverrides ?? preset.outputFormats
    }
}

public enum ComplianceSeverity: String, Sendable, Codable, Hashable {
    case pass
    case warning
    case fail
}

public struct ComplianceCheckItem: Sendable, Codable, Equatable, Hashable {
    public var name: String
    public var severity: ComplianceSeverity
    public var message: String

    public init(name: String, severity: ComplianceSeverity, message: String) {
        self.name = name
        self.severity = severity
        self.message = message
    }
}

public struct ComplianceExpectation: Sendable, Codable, Equatable, Hashable {
    public var format: OutputFormat
    public var expectedHeadroom: LinearHeadroom
    public var expectedBitDepth: BitDepth
    public var expectedGainMapChannels: GainMapChannels
    public var maxFileBytes: Int?
    public var expectLegacyAppleGainMap: Bool
    public var expectUltrahdrXMP: Bool

    public init(
        format: OutputFormat,
        expectedHeadroom: LinearHeadroom,
        expectedBitDepth: BitDepth,
        expectedGainMapChannels: GainMapChannels,
        maxFileBytes: Int? = nil,
        expectLegacyAppleGainMap: Bool = false,
        expectUltrahdrXMP: Bool = false
    ) {
        self.format = format
        self.expectedHeadroom = expectedHeadroom
        self.expectedBitDepth = expectedBitDepth
        self.expectedGainMapChannels = expectedGainMapChannels
        self.maxFileBytes = maxFileBytes
        self.expectLegacyAppleGainMap = expectLegacyAppleGainMap
        self.expectUltrahdrXMP = expectUltrahdrXMP
    }
}

public struct HLGComplianceExpectation: Sendable, Codable, Equatable, Hashable {
    public var expectedDimensions: PixelDimensions
    public var minDurationSeconds: Double
    public var maxDurationSeconds: Double
    public var expectedFPS: Int

    public init(
        expectedDimensions: PixelDimensions,
        minDurationSeconds: Double = 3.0,
        maxDurationSeconds: Double = 5.0,
        expectedFPS: Int = 30
    ) {
        self.expectedDimensions = expectedDimensions
        self.minDurationSeconds = minDurationSeconds
        self.maxDurationSeconds = maxDurationSeconds
        self.expectedFPS = expectedFPS
    }
}

public struct ComplianceReport: Sendable, Codable, Equatable, Hashable {
    public var fileURL: URL
    public var passed: Bool
    public var hasISOGainMap: Bool
    public var measuredHeadroom: LinearHeadroom?
    public var measuredBitDepth: Int?
    public var measuredOrientation: Int?
    public var fileSizeBytes: Int64
    public var checks: [ComplianceCheckItem]

    public init(
        fileURL: URL,
        passed: Bool,
        hasISOGainMap: Bool,
        measuredHeadroom: LinearHeadroom? = nil,
        measuredBitDepth: Int? = nil,
        measuredOrientation: Int? = nil,
        fileSizeBytes: Int64,
        checks: [ComplianceCheckItem] = []
    ) {
        self.fileURL = fileURL
        self.passed = passed
        self.hasISOGainMap = hasISOGainMap
        self.measuredHeadroom = measuredHeadroom
        self.measuredBitDepth = measuredBitDepth
        self.measuredOrientation = measuredOrientation
        self.fileSizeBytes = fileSizeBytes
        self.checks = checks
    }
}

public struct ExportArtifact: Sendable, Codable, Equatable, Hashable {
    public var format: OutputFormat
    public var outputURL: URL
    public var fileSizeBytes: Int64
    public var usedGridTiling: Bool
    public var gridRows: Int?
    public var gridColumns: Int?
    public var compliance: ComplianceReport?

    public init(
        format: OutputFormat,
        outputURL: URL,
        fileSizeBytes: Int64,
        usedGridTiling: Bool = false,
        gridRows: Int? = nil,
        gridColumns: Int? = nil,
        compliance: ComplianceReport? = nil
    ) {
        self.format = format
        self.outputURL = outputURL
        self.fileSizeBytes = fileSizeBytes
        self.usedGridTiling = usedGridTiling
        self.gridRows = gridRows
        self.gridColumns = gridColumns
        self.compliance = compliance
    }
}

public struct ExportResult: Sendable, Codable, Equatable, Hashable {
    public var jobID: UUID
    public var sourceURL: URL
    public var backendUsed: RAWBackend
    public var fallbackReason: String?
    public var artifacts: [ExportArtifact]
    public var elapsedSeconds: Double
    public var errorDescription: String?

    public init(
        jobID: UUID,
        sourceURL: URL,
        backendUsed: RAWBackend,
        fallbackReason: String? = nil,
        artifacts: [ExportArtifact],
        elapsedSeconds: Double,
        errorDescription: String? = nil
    ) {
        self.jobID = jobID
        self.sourceURL = sourceURL
        self.backendUsed = backendUsed
        self.fallbackReason = fallbackReason
        self.artifacts = artifacts
        self.elapsedSeconds = elapsedSeconds
        self.errorDescription = errorDescription
    }
}
