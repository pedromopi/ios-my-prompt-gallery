import Foundation
import SwiftData

@Model
final class PromptEntry {
    var promptText: String = ""
    var createdAt: Date = Date()
    @Relationship(inverse: \PromptMedia.entry)
    var media: PromptMedia?
    var appleIntelligenceSummary: String?
    var appleIntelligenceStyle: String?
    var appleIntelligencePromptType: String?
    var appleIntelligenceKeywordsRaw: String?
    var appleIntelligenceAnalyzedAt: Date?

    init(
        promptText: String,
        createdAt: Date = .now,
        media: PromptMedia? = nil,
        appleIntelligenceSummary: String? = nil,
        appleIntelligenceStyle: String? = nil,
        appleIntelligencePromptType: String? = nil,
        appleIntelligenceKeywordsRaw: String? = nil,
        appleIntelligenceAnalyzedAt: Date? = nil
    ) {
        self.promptText = promptText
        self.createdAt = createdAt
        self.media = media
        self.appleIntelligenceSummary = appleIntelligenceSummary
        self.appleIntelligenceStyle = appleIntelligenceStyle
        self.appleIntelligencePromptType = appleIntelligencePromptType
        self.appleIntelligenceKeywordsRaw = appleIntelligenceKeywordsRaw
        self.appleIntelligenceAnalyzedAt = appleIntelligenceAnalyzedAt
    }
}

@Model
final class PromptMedia {
    var entry: PromptEntry?

    @Attribute(.externalStorage)
    var imageData: Data?
    @Attribute(.externalStorage)
    var thumbnailData: Data?

    init(
        imageData: Data? = nil,
        thumbnailData: Data? = nil
    ) {
        self.imageData = imageData
        self.thumbnailData = thumbnailData
    }
}

extension PromptEntry {
    var displayTitle: String {
        if let summary = appleIntelligenceSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return summary
        }
        return promptText
    }

    var appleIntelligenceKeywords: [String] {
        splitRawAnalysisField(appleIntelligenceKeywordsRaw)
    }

    var searchableAnalysisText: String {
        [
            promptText,
            appleIntelligenceSummary,
            appleIntelligenceStyle,
            appleIntelligencePromptType,
            appleIntelligenceKeywordsRaw
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    var isMissingAppleIntelligenceData: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (
            isBlank(appleIntelligenceSummary) ||
            isBlank(appleIntelligenceStyle) ||
            isBlank(appleIntelligencePromptType) ||
            appleIntelligenceKeywords.isEmpty ||
            appleIntelligenceAnalyzedAt == nil
        )
    }

    func applyAppleIntelligencePayload(_ payload: PromptAppleIntelligencePayload) {
        appleIntelligenceSummary = payload.summary.capitalizingFirstLetter()
        appleIntelligenceStyle = payload.style.capitalizingFirstLetter()
        appleIntelligencePromptType = payload.promptType.capitalizingFirstLetter()
        appleIntelligenceKeywordsRaw = payload.keywords
            .map { $0.capitalizingFirstLetter() }
            .joined(separator: "\n")
        appleIntelligenceAnalyzedAt = .now
    }

    private func splitRawAnalysisField(_ rawValue: String?) -> [String] {
        guard let rawValue, !rawValue.isEmpty else { return [] }
        return rawValue
            .split(separator: "\n")
            .map(String.init)
    }

    private func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}

extension String {
    func capitalizingFirstLetter() -> String {
        guard !isEmpty else { return self }
        return prefix(1).uppercased() + dropFirst()
    }
}
