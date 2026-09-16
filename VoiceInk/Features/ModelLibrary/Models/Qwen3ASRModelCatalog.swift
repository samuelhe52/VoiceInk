import Foundation

enum Qwen3ASRModelCatalog {
    static let weightsFileName = "model.safetensors"

    static let supportedVariants: [Qwen3ASRModel] = [
        variant(
            parameterCount: "0.6B", quantization: "4-bit",
            revision: "313d850181767edf09f00a9c289becca70e58cd0",
            weightsSize: 708_236_945,
            weightsSHA256: "70c7e67e588062adce4f10796e47ad42ead51c6671eda61a0987eae38ca95ddf"
        ),
        variant(
            parameterCount: "0.6B", quantization: "6-bit",
            revision: "468b9b6d692d3397d5d17b84a1166876a00c9bfa",
            weightsSize: 857_233_233,
            weightsSHA256: "1df8abe1df012cf60cbf953acb9e2515ea1d1ac081ca09b5f6c1d6c9538c8d0c"
        ),
        variant(
            parameterCount: "0.6B", quantization: "8-bit",
            revision: "89e96d92ba34aca20b3e29fb10cc284097d1219f",
            weightsSize: 1_006_229_426,
            weightsSHA256: "b5bfe4abc1b4c6e58b633096682ec2b6297298add1527119936107d211adf0e8"
        ),
        variant(
            parameterCount: "0.6B", quantization: "BF16",
            revision: "eae2b51f96265328f1e7beced788adb0e4536f92",
            weightsSize: 1_564_921_888,
            weightsSHA256: "a6e635fd9c8dfd5cdd7465db9bd8c947ab30737b90b83b6b09c304e836bb8a7f"
        ),
        variant(
            parameterCount: "1.7B", quantization: "4-bit",
            revision: "78a389c776a5483b2d0d4ea5494e11012e0d6159",
            weightsSize: 1_603_081_617,
            weightsSHA256: "9848eaf7a5c1589c671b35035ac27b72e248dd0c604eacae547e7e403d29db45"
        ),
        variant(
            parameterCount: "1.7B", quantization: "6-bit",
            revision: "edd077a475c4da058e25b6e6ec1199115ca1be2b",
            weightsSize: 2_033_194_557,
            weightsSHA256: "cacb094fef227ec2a5908d0136b3ad3384d95e0e2a8a915984ce577e4b12b2ba"
        ),
        variant(
            parameterCount: "1.7B", quantization: "8-bit",
            revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
            weightsSize: 2_463_307_541,
            weightsSHA256: "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c"
        ),
        variant(
            parameterCount: "1.7B", quantization: "BF16",
            revision: "e1f6c266914abc5a46e8756e02580f834a6cf8a7",
            weightsSize: 4_076_186_653,
            weightsSHA256: "2f080a3b769ae469aeaaa2dcb9e13a94141e54c9e6d5a7aa63392e0dc5a51789"
        ),
    ]

    static var modelsRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
            .appendingPathComponent("Qwen3ASR", isDirectory: true)
    }

    static func variant(named modelName: String) -> Qwen3ASRModel? {
        supportedVariants.first { $0.name == modelName }
    }

    static func modelDirectory(for model: Qwen3ASRModel) -> URL {
        modelsRootDirectory.appendingPathComponent(model.name, isDirectory: true)
    }

    static func installedModelDirectory(for model: Qwen3ASRModel) -> URL? {
        let directory = modelDirectory(for: model)
        return modelDirectoryIsValid(directory, for: model) ? directory : nil
    }

    static func installedModelDirectory(named modelName: String) -> URL? {
        guard let model = variant(named: modelName) else { return nil }
        return installedModelDirectory(for: model)
    }

    static func modelDirectoryIsValid(_ directory: URL, for model: Qwen3ASRModel) -> Bool {
        for fileName in requiredFileNames {
            let fileURL = directory.appendingPathComponent(fileName)
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { return false }
        }

        let weightsURL = directory.appendingPathComponent(weightsFileName)
        let weightsSize = try? weightsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard Int64(weightsSize ?? 0) == model.expectedWeightsSize else { return false }

        let configURL = directory.appendingPathComponent("config.json")
        guard
            let configData = try? Data(contentsOf: configURL),
            let config = try? JSONDecoder().decode(ModelConfig.self, from: configData),
            config.modelType == "qwen3_asr"
        else {
            return false
        }

        let checksumURL = directory.appendingPathComponent(".model.safetensors.sha256")
        let installedChecksum = try? String(contentsOf: checksumURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return installedChecksum == model.expectedWeightsSHA256
    }

    private static let requiredFileNames = [
        "config.json",
        "merges.txt",
        "preprocessor_config.json",
        "tokenizer_config.json",
        "vocab.json",
        weightsFileName,
    ]

    private static func variant(
        parameterCount: String,
        quantization: String,
        revision: String,
        weightsSize: Int64,
        weightsSHA256: String
    ) -> Qwen3ASRModel {
        let repositorySuffix = quantization.lowercased().replacingOccurrences(of: "-", with: "")
        let slug = "qwen3-asr-\(parameterCount.lowercased())-\(repositorySuffix)"
        let description = parameterCount == "0.6B"
            ? "Compact multilingual transcription accelerated by MLX on Apple Silicon"
            : "Larger multilingual transcription model for higher accuracy on Apple Silicon"

        return Qwen3ASRModel(
            name: slug,
            displayName: "Qwen3-ASR \(parameterCount) (\(quantization))",
            description: description,
            repository: "mlx-community/Qwen3-ASR-\(parameterCount)-\(repositorySuffix)",
            repositoryRevision: revision,
            expectedWeightsSize: weightsSize,
            expectedWeightsSHA256: weightsSHA256,
            quantization: quantization,
            supportedLanguages: LanguageDictionary.qwen3ASR
        )
    }

    private struct ModelConfig: Decodable {
        let modelType: String

        private enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
        }
    }
}
