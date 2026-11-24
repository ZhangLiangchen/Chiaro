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
        verifyAfterExport: Bool = true
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
