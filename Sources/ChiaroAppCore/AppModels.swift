import Foundation
import ChiaroCore

public enum QueueItemStatus: Equatable, Sendable {
    case idle
    case queued
    case decoding
    case rendered
    case completed
    case failed(String)

    public var label: String {
        switch self {
        case .idle: return "就绪"
        case .queued: return "排队中"
        case .decoding: return "解码中"
        case .rendered: return "编码中"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }
}

public struct BatchItem: Identifiable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public var fileName: String { sourceURL.lastPathComponent }
    public var status: QueueItemStatus = .idle
    public var lastFallbackReason: String?
    public var result: ExportResult?

    public init(id: UUID = UUID(), sourceURL: URL) {
        self.id = id
        self.sourceURL = sourceURL
    }
}

public enum InspectorEditScope: String, CaseIterable, Identifiable, Sendable {
    case globalPreset = "全局预设"
    case perPhotoDelta = "单图微调"

    public var id: String { rawValue }
}

public enum CreativeLookOption: String, CaseIterable, Identifiable, Sendable {
    case standard = "ST"
    case vivid = "VV"
    case vivid2 = "VV2"
    case portrait = "PT"
    case neutral = "NT"
    case film = "FL"
    case instant = "IN"
    case softHighkey = "SH"
    case monochrome = "BW"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: return "ST (Standard)"
        case .vivid: return "VV (Vivid)"
        case .vivid2: return "VV2 (Vivid 2)"
        case .portrait: return "PT (Portrait)"
        case .neutral: return "NT (Neutral)"
        case .film: return "FL (Film)"
        case .instant: return "IN (Instant)"
        case .softHighkey: return "SH (Soft Highkey)"
        case .monochrome: return "BW (Monochrome)"
        }
    }
}

public struct BatchExportSummary: Sendable, Equatable {
    public let totalJobs: Int
    public let succeeded: Int
    public let failed: Int
    public let elapsedSeconds: Double

    public init(totalJobs: Int, succeeded: Int, failed: Int, elapsedSeconds: Double) {
        self.totalJobs = totalJobs
        self.succeeded = succeeded
        self.failed = failed
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct PreviewRenderSnapshot: Sendable {
    public let sourceURL: URL
    public let renderedFrame: RenderedFrame
    public let effectiveParams: EffectiveDevelopParams
    public let fallbackReason: String?
    public let backendUsed: RAWBackend
    public let colorMatrices: CameraColorMatrices
    public let histogramBins: [UInt32]
    public let uniforms: EDRPreviewUniforms

    public init(
        sourceURL: URL,
        renderedFrame: RenderedFrame,
        effectiveParams: EffectiveDevelopParams,
        fallbackReason: String?,
        backendUsed: RAWBackend,
        colorMatrices: CameraColorMatrices,
        histogramBins: [UInt32],
        uniforms: EDRPreviewUniforms
    ) {
        self.sourceURL = sourceURL
        self.renderedFrame = renderedFrame
        self.effectiveParams = effectiveParams
        self.fallbackReason = fallbackReason
        self.backendUsed = backendUsed
        self.colorMatrices = colorMatrices
        self.histogramBins = histogramBins
        self.uniforms = uniforms
    }
}

public extension PerPhotoDelta {
    var isEmpty: Bool {
        self == PerPhotoDelta()
    }
}
