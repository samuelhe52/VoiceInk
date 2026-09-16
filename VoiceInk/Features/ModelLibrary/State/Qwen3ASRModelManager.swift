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
        guard let model = Qwen3ASRModelCatalog.variant(named: model.name) else { return false }
        return Qwen3ASRModelCatalog.installedModelDirectory(for: model) != nil
    }

    func isModelDownloaded(named modelName: String) -> Bool {
        Qwen3ASRModelCatalog.installedModelDirectory(named: modelName) != nil
    }

    func isModelDownloading(_ model: Qwen3ASRModel) -> Bool {
        activeDownloadIDs[model.name] != nil
    }

    func downloadStatus(for model: Qwen3ASRModel) -> Qwen3ASRDownloadStatus? {
        downloadStatuses[model.name]
    }

    func downloadModel(_ model: Qwen3ASRModel) async {
        guard SystemArchitecture.isAppleSilicon,
            let model = Qwen3ASRModelCatalog.variant(named: model.name),
            activeDownloadIDs[model.name] == nil,
            !isModelDownloaded(model)
        else {
            return
        }

        guard let repositoryID = Repo.ID(rawValue: model.repository) else {
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
        // Catalog repositories are public. Explicitly disable automatic token discovery so an
        // expired Hugging Face CLI/OAuth token cannot make otherwise anonymous downloads fail.
        let client = HubClient(
            host: HubClient.defaultHost,
            tokenProvider: .none,
            cache: cache
        )

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
                revision: model.repositoryRevision,
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
            guard checksum == model.expectedWeightsSHA256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try checksum.write(
                to: stagingDirectory.appendingPathComponent(".model.safetensors.sha256"),
                atomically: true,
                encoding: .utf8
            )
            guard Qwen3ASRModelCatalog.modelDirectoryIsValid(stagingDirectory, for: model) else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let modelDirectory = Qwen3ASRModelCatalog.modelDirectory(for: model)
            if fileManager.fileExists(atPath: modelDirectory.path) {
                try fileManager.removeItem(at: modelDirectory)
            }
            try fileManager.moveItem(at: stagingDirectory, to: modelDirectory)
            guard Qwen3ASRModelCatalog.installedModelDirectory(for: model) != nil else {
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
        guard let model = Qwen3ASRModelCatalog.variant(named: model.name) else { return }
        objectWillChange.send()
        try? FileManager.default.removeItem(at: Qwen3ASRModelCatalog.modelDirectory(for: model))
        onModelDeleted?(model.name)
        onModelsChanged?()
    }

    func showModelInFinder(_ model: Qwen3ASRModel) {
        guard
            let model = Qwen3ASRModelCatalog.variant(named: model.name),
            let modelDirectory = Qwen3ASRModelCatalog.installedModelDirectory(for: model)
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
