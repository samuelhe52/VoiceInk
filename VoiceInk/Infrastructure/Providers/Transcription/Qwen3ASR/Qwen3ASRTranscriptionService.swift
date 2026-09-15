import Foundation
import MLX
import MLXAudioSTT
import os

final class Qwen3ASRTranscriptionService: TranscriptionService, @unchecked Sendable {
    private let runtime = Qwen3ASRRuntime()

    func loadModel(for model: Qwen3ASRModel) async throws {
        try await runtime.loadModel(for: model)
    }

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        guard let qwenModel = model as? Qwen3ASRModel else {
            throw Qwen3ASRError.unsupportedModel(model.name)
        }
        return try await runtime.transcribe(audioURL: audioURL, model: qwenModel, languageCode: context.language)
    }

    func cleanup() async {
        await runtime.cleanup()
    }
}

private actor Qwen3ASRRuntime {
    private var loadedModel: MLXAudioSTT.Qwen3ASRModel?
    private var loadedModelName: String?
    private let audioProcessor = AudioProcessor()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Qwen3ASR")

    func loadModel(for model: Qwen3ASRModel) async throws {
        guard model.name == Qwen3ASRModelCatalog.modelName else {
            throw Qwen3ASRError.unsupportedModel(model.name)
        }
        guard SystemArchitecture.isAppleSilicon else {
            throw Qwen3ASRError.appleSiliconRequired
        }
        guard let modelDirectory = Qwen3ASRModelCatalog.installedModelDirectory else {
            throw Qwen3ASRError.modelNotDownloaded
        }
        guard loadedModel == nil || loadedModelName != model.name else { return }

        loadedModel = nil
        loadedModelName = nil
        Memory.clearCache()

        logger.notice("Loading \(model.displayName, privacy: .public) on the MLX GPU backend")
        let modelInstance = try await MLXAudioSTT.Qwen3ASRModel.fromModelDirectory(modelDirectory)
        try Task.checkCancellation()
        loadedModel = modelInstance
        loadedModelName = model.name
        logger.notice("Loaded \(model.displayName, privacy: .public)")
    }

    func transcribe(audioURL: URL, model: Qwen3ASRModel, languageCode: String?) async throws -> String {
        try await loadModel(for: model)
        guard let loadedModel else {
            throw Qwen3ASRError.modelLoadFailed
        }

        let samples = try await audioProcessor.processAudioToSamples(audioURL)
        try Task.checkCancellation()
        guard !samples.isEmpty else {
            throw Qwen3ASRError.emptyAudio
        }

        let language = Self.languageName(for: languageCode)
        let audio = MLXArray(samples)
        let output = loadedModel.generate(
            audio: audio,
            temperature: 0,
            language: language,
            minChunkDuration: 0.1
        )
        logger.notice(
            "Transcribed with MLX in \(output.totalTime, privacy: .public)s; peak MLX memory \(output.peakMemoryUsage, privacy: .public) GB"
        )
        return output.text
    }

    func cleanup() {
        loadedModel = nil
        loadedModelName = nil
        Memory.clearCache()
    }

    nonisolated static func languageName(for code: String?) -> String? {
        guard let code, code != "auto" else { return nil }
        return languageNames[code]
    }

    private nonisolated static let languageNames: [String: String] = [
        "ar": "Arabic",
        "cs": "Czech",
        "da": "Danish",
        "de": "German",
        "el": "Greek",
        "en": "English",
        "es": "Spanish",
        "fa": "Persian",
        "fi": "Finnish",
        "fil": "Filipino",
        "fr": "French",
        "hi": "Hindi",
        "hu": "Hungarian",
        "id": "Indonesian",
        "it": "Italian",
        "ja": "Japanese",
        "ko": "Korean",
        "mk": "Macedonian",
        "ms": "Malay",
        "nl": "Dutch",
        "pl": "Polish",
        "pt": "Portuguese",
        "ro": "Romanian",
        "ru": "Russian",
        "sv": "Swedish",
        "th": "Thai",
        "tr": "Turkish",
        "vi": "Vietnamese",
        "yue": "Cantonese",
        "zh": "Chinese",
    ]
}

private enum Qwen3ASRError: LocalizedError {
    case appleSiliconRequired
    case emptyAudio
    case modelLoadFailed
    case modelNotDownloaded
    case unsupportedModel(String)

    var errorDescription: String? {
        switch self {
        case .appleSiliconRequired:
            return "Qwen3-ASR with MLX requires an Apple Silicon Mac."
        case .emptyAudio:
            return "The audio file contains no samples."
        case .modelLoadFailed:
            return "Qwen3-ASR could not be loaded."
        case .modelNotDownloaded:
            return "Download Qwen3-ASR before using it."
        case .unsupportedModel(let modelName):
            return "Unsupported Qwen3-ASR model: \(modelName)"
        }
    }
}
