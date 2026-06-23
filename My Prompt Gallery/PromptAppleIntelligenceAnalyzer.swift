import Foundation

struct PromptAppleIntelligencePayload {
    let summary: String
    let style: String
    let promptType: String
    let keywords: [String]
}

enum PromptAppleIntelligenceError: LocalizedError {
    case unsupportedOS
    case unavailable(String)
    case unsupportedBuild

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            "Apple Intelligence requires a newer version of iOS."
        case .unavailable(let reason):
            reason
        case .unsupportedBuild:
            "FoundationModels is not available in this SDK."
        }
    }
}

enum PromptAppleIntelligenceAnalyzer {
    static func unavailableReason() -> String? {
        guard #available(iOS 26.0, *) else {
            return PromptAppleIntelligenceError.unsupportedOS.localizedDescription
        }

        #if canImport(FoundationModels)
        return PromptAppleIntelligenceFoundationModelsAnalyzer.unavailableReason()
        #else
        return PromptAppleIntelligenceError.unsupportedBuild.localizedDescription
        #endif
    }

    static func generate(for promptText: String) async throws -> PromptAppleIntelligencePayload {
        guard #available(iOS 26.0, *) else {
            throw PromptAppleIntelligenceError.unsupportedOS
        }

        #if canImport(FoundationModels)
        return try await PromptAppleIntelligenceFoundationModelsAnalyzer.generate(for: promptText)
        #else
        throw PromptAppleIntelligenceError.unsupportedBuild
        #endif
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable(description: "Structured semantic analysis of a text prompt for an image generation gallery")
private struct GeneratedPromptAppleIntelligenceAnalysis {
    @Guide(description: "Very short label, maximum 6 words. Do not rewrite or paraphrase the full prompt.")
    var summary: String

    @Guide(description: "Visual style requested in the prompt, in 1 to 5 words, or the user's-language equivalent of 'Not specified' when absent")
    var style: String

    @Guide(description: "Broad prompt category in the user's language, such as portrait, product, scene, UI, photo, illustration, character, architecture, or other")
    var promptType: String

    @Guide(description: "Three to six short keywords derived only from the prompt text")
    var keywords: [String]
}

@available(iOS 26.0, *)
private enum PromptAppleIntelligenceFoundationModelsAnalyzer {
    static func unavailableReason() -> String? {
        let model = SystemLanguageModel.default

        switch model.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return message(for: reason)
        }
    }

    static func generate(for promptText: String) async throws -> PromptAppleIntelligencePayload {
        let model = SystemLanguageModel.default

        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw PromptAppleIntelligenceError.unavailable(message(for: reason))
        }

        let session = LanguageModelSession(model: model)
        let response = try await session.respond(
            to: """
            Analyze this image-generation prompt using only the prompt text. Do not infer from any attached image.
            Keep every field concise and useful for search and organization.
            Preserve the user's language when possible.
            Use natural sentence/title capitalization for each generated field and keyword.
            Do not return ALL CAPS unless the text is a real acronym, brand spelling, or code term that must stay uppercase.
            If the original prompt is written in uppercase, normalize generated labels back to natural capitalization.
            The summary must be a compact label, not a sentence, and must not repeat the full prompt.
            Use the same language as the user's prompt for every generated field, including fallback values and categories.

            Prompt:
            \(promptText)
            """,
            generating: GeneratedPromptAppleIntelligenceAnalysis.self
        )
        let content = response.content

        return PromptAppleIntelligencePayload(
            summary: content.summary,
            style: content.style,
            promptType: content.promptType,
            keywords: content.keywords
        )
    }

    private static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is not enabled on this device."
        case .deviceNotEligible:
            "This device is not compatible with Apple Intelligence."
        case .modelNotReady:
            "The Apple Intelligence model is not ready yet. Try again later."
        @unknown default:
            "Apple Intelligence is not available right now."
        }
    }
}
#endif
