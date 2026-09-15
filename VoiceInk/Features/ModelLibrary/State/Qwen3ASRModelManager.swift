import AppKit
import CryptoKit
import Foundation
import HuggingFace
import os

struct Qwen3ASRDownloadStatus: Sendable {
    let fractionCompleted: Double
    let message: String
    let isIndeterminate: Bool
}

enum Qwen3ASRModelCatalog {
    static let modelName = "qwen3-asr-0.6b-8bit"
    static let repository = "mlx-community/Qwen3-ASR-0.6B-8bit"
    static let repositoryRevision = "89e96d92ba34aca20b3e29fb10cc284097d1219f"
    static let weightsFileName = "model.safetensors"
    static let expectedWeightsSize: Int64 = 1_006_229_426
    static let expectedWeightsSHA256 = "b5bfe4abc1b4c6e58b633096682ec2b6297298add1527119936107d211adf0e8"

    private static let requiredFileNames = [
        "config.json",
        "merges.txt",
        "preprocessor_config.json",
        "tokenizer_config.json",
        "vocab.json",
        weightsFileName,
    ]

    static var modelsRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
            .appendingPathComponent("Qwen3ASR", isDirectory: true)
    }

    static var modelDirectory: URL {
        modelsRootDirectory.appendingPathComponent(modelName, isDirectory: true)
    }

    static var checksumFileURL: URL {
        modelDirectory.appendingPathComponent(".model.safetensors.sha256")
    }

    static var installedModelDirectory: URL? {
        modelDirectoryIsValid(modelDirectory) ? modelDirectory : nil
    }

    static func modelDirectoryIsValid(_ directory: URL) -> Bool {
        for fileName in requiredFileNames {
            let fileURL = directory.appendingPathComponent(fileName)
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { return false }
        }

        let weightsURL = directory.appendingPathComponent(weightsFileName)
        let weightsSize = try? weightsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard Int64(weightsSize ?? 0) == expectedWeightsSize else { return false }

        let checksumURL = directory.appendingPathComponent(".model.safetensors.sha256")
        let installedChecksum = try? String(contentsOf: checksumURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return installedChecksum == expectedWeightsSHA256
    }
}

@MainActor
final class Qwen3ASRModelManager: ObservableObject {
    static let shared = Qwen3ASRModelManager()

    @Published private var downloadStatuses: [String: Qwen3ASRDownloadStatus] = [:]

    var onModelDeleted: ((String) -> Void)?
    var onModelsChanged: (() -> Void)?

    private var activeDownloadIDs: [String: UUID] = [:]
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Qwen3ASRModelManager")

    private init() {}

    func isModelDownloaded(_ model: Qwen3ASRModel) -> Bool {
        model.name == Qwen3ASRModelCatalog.modelName && Qwen3ASRModelCatalog.installedModelDirectory != nil
    }

    func isModelDownloaded(named modelName: String) -> Bool {
        modelName == Qwen3ASRModelCatalog.modelName && Qwen3ASRModelCatalog.installedModelDirectory != nil
    }

    func isModelDownloading(_ model: Qwen3ASRModel) -> Bool {
        activeDownloadIDs[model.name] != nil
    }

    func downloadStatus(for model: Qwen3ASRModel) -> Qwen3ASRDownloadStatus? {
        downloadStatuses[model.name]
    }

    func downloadModel(_ model: Qwen3ASRModel) async {
        guard SystemArchitecture.isAppleSilicon,
            model.name == Qwen3ASRModelCatalog.modelName,
            activeDownloadIDs[model.name] == nil,
            !isModelDownloaded(model)
        else {
            return
        }

        guard let repositoryID = Repo.ID(rawValue: Qwen3ASRModelCatalog.repository) else {
            reportFailure(CocoaError(.fileReadUnknown), for: model)
            return
        }

        let downloadID = UUID()
        activeDownloadIDs[model.name] = downloadID
        downloadStatuses[model.name] = Qwen3ASRDownloadStatus(
            fractionCompleted: 0,
            message: String(localized: "Downloading..."),
            isIndeterminate: false
        )

        let fileManager = FileManager.default
        let stagingDirectory = Qwen3ASRModelCatalog.modelsRootDirectory
            .appendingPathComponent(".installing-\(downloadID.uuidString)", isDirectory: true)
        let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
            .appendingPathComponent("Qwen3ASRDownloadCache", isDirectory: true)
        let cache = HubCache(cacheDirectory: cacheDirectory)
        let client = HubClient(cache: cache)

        defer {
            if activeDownloadIDs[model.name] == downloadID {
                activeDownloadIDs[model.name] = nil
                downloadStatuses[model.name] = nil
                onModelsChanged?()
            }
        }

        do {
            try fileManager.createDirectory(
                at: Qwen3ASRModelCatalog.modelsRootDirectory,
                withIntermediateDirectories: true
            )
            try? fileManager.removeItem(at: stagingDirectory)

            _ = try await client.downloadSnapshot(
                of: repositoryID,
                to: stagingDirectory,
                revision: Qwen3ASRModelCatalog.repositoryRevision,
                matching: ["*.json", "*.txt", "*.safetensors"],
                maxConcurrentDownloads: 4
            ) { [weak self] progress in
                self?.updateDownloadProgress(
                    progress.fractionCompleted,
                    for: model.name,
                    downloadID: downloadID
                )
            }
            try Task.checkCancellation()

            downloadStatuses[model.name] = Qwen3ASRDownloadStatus(
                fractionCompleted: 1,
                message: String(localized: "Verifying..."),
                isIndeterminate: true
            )

            let weightsURL = stagingDirectory.appendingPathComponent(Qwen3ASRModelCatalog.weightsFileName)
            let checksum = try await Task.detached(priority: .utility) {
                try Self.sha256(of: weightsURL)
            }.value
            try Task.checkCancellation()
            guard checksum == Qwen3ASRModelCatalog.expectedWeightsSHA256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try checksum.write(
                to: stagingDirectory.appendingPathComponent(".model.safetensors.sha256"),
                atomically: true,
                encoding: .utf8
            )
            guard Qwen3ASRModelCatalog.modelDirectoryIsValid(stagingDirectory) else {
                throw CocoaError(.fileReadCorruptFile)
            }

            if fileManager.fileExists(atPath: Qwen3ASRModelCatalog.modelDirectory.path) {
                try fileManager.removeItem(at: Qwen3ASRModelCatalog.modelDirectory)
            }
            try fileManager.moveItem(at: stagingDirectory, to: Qwen3ASRModelCatalog.modelDirectory)
            guard Qwen3ASRModelCatalog.installedModelDirectory != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }

            // The installed directory is a full copy, so discard the temporary Hub cache.
            try? fileManager.removeItem(at: cache.repoDirectory(repo: repositoryID, kind: .model))
            logger.notice("\(model.displayName, privacy: .public) installed successfully")
        } catch is CancellationError {
            try? fileManager.removeItem(at: stagingDirectory)
            logger.notice("\(model.displayName, privacy: .public) download paused")
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            reportFailure(error, for: model)
        }
    }

    func deleteModel(_ model: Qwen3ASRModel) {
        guard model.name == Qwen3ASRModelCatalog.modelName else { return }
        objectWillChange.send()
        try? FileManager.default.removeItem(at: Qwen3ASRModelCatalog.modelDirectory)
        onModelDeleted?(model.name)
        onModelsChanged?()
    }

    func showModelInFinder(_ model: Qwen3ASRModel) {
        guard model.name == Qwen3ASRModelCatalog.modelName,
            let modelDirectory = Qwen3ASRModelCatalog.installedModelDirectory
        else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([modelDirectory])
    }

    private func updateDownloadProgress(_ fraction: Double, for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID, fraction.isFinite else { return }
        let fraction = min(max(fraction, 0), 1)
        let currentFraction = downloadStatuses[modelName]?.fractionCompleted ?? 0
        guard fraction > currentFraction else { return }

        downloadStatuses[modelName] = Qwen3ASRDownloadStatus(
            fractionCompleted: fraction,
            message: String(localized: "Downloading..."),
            isIndeterminate: false
        )
    }

    private func reportFailure(_ error: Error, for model: Qwen3ASRModel) {
        logger.error("\(model.displayName, privacy: .public) download failed: \(error, privacy: .public)")
        NotificationManager.shared.showNotification(
            title: "\(model.displayName) download failed",
            type: .error
        )
    }

    nonisolated private static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 * 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
