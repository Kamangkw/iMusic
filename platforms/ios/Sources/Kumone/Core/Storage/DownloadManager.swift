#if os(iOS)
import Combine
import Foundation

/// Downloads audio through the configured playback provider. Official APIs
/// report the returned tier; LX User API sources only accept a requested tier.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    struct Record: Codable, Identifiable, Hashable {
        let id: String
        let track: Track
        let quality: String
        let qualityVerified: Bool?
        let fileName: String
        let createdAt: Date

        var fileURL: URL { DownloadManager.downloadDirectory.appendingPathComponent(fileName) }
    }

    struct ActiveDownload: Identifiable {
        let id: String
        let track: Track
        let requestedQuality: AudioQuality
        var fraction: Double?
    }

    static let shared = DownloadManager()

    @Published private(set) var records: [Record] = []
    @Published private(set) var activeDownloads: [String: ActiveDownload] = [:]
    /// How many downloads are waiting for a free slot.
    @Published private(set) var queuedCount = 0
    /// The last error per track key, cleared when the same track is retried.
    @Published private(set) var failures: [String: String] = [:]

    /// Two at a time keeps the LX source from throttling a whole album.
    private let maxConcurrentDownloads = 2
    private var pendingQueue: [(track: Track, quality: AudioQuality, silent: Bool)] = []
    /// Identifies the current attempt per key, so a cancelled transfer that
    /// finishes late cannot clear the state of the one that replaced it.
    private var attemptTokens: [String: UUID] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var continuations: [Int: CheckedContinuation<(URL, URLResponse), Error>] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private nonisolated static var applicationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moumusic", isDirectory: true)
    }

    nonisolated static var downloadDirectory: URL {
        applicationDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    private nonisolated static var manifestURL: URL {
        applicationDirectory.appendingPathComponent("downloads.json")
    }

    /// Audio files are re-downloadable, so they must not inflate an iCloud
    /// backup. Re-applied whenever the directory is (re)created.
    private func prepareDownloadDirectory() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.downloadDirectory, withIntermediateDirectories: true)
        var directory = Self.downloadDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    private override init() {
        super.init()
        prepareDownloadDirectory()
        load()
        pruneStaleFiles()
    }

    func record(for track: Track) -> Record? {
        let key = track.normalizedForLXPlayback().playbackKey
        return records.first { $0.id == key && FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    func isDownloading(_ track: Track) -> Bool {
        let key = track.normalizedForLXPlayback().playbackKey
        return activeDownloads[key] != nil || pendingQueue.contains { $0.track.playbackKey == key }
    }

    func failureMessage(for track: Track) -> String? {
        failures[track.normalizedForLXPlayback().playbackKey]
    }

    /// Queues a transfer, or starts it right away while a slot is free.
    /// `silent` skips this track's toast so a batch shows one summary only.
    func download(_ track: Track, quality: AudioQuality? = nil, silent: Bool = false) {
        let normalized = track.normalizedForLXPlayback()
        let key = normalized.playbackKey
        guard record(for: normalized) == nil else {
            ToastCenter.shared.show("歌曲已经下载")
            return
        }
        guard tasks[key] == nil,
              !pendingQueue.contains(where: { $0.track.playbackKey == key }) else { return }

        if SettingsManager.shared.downloadOnlyOnWiFi, NetworkMonitor.shared.isOnCellular {
            ToastCenter.shared.show(String(localized: "正在使用移动数据，已暂停下载"))
            return
        }

        let requestedQuality = quality ?? SettingsManager.shared.audioQuality
        if tasks.count >= maxConcurrentDownloads {
            pendingQueue.append((track: normalized, quality: requestedQuality, silent: silent))
            queuedCount = pendingQueue.count
            return
        }
        start(normalized, quality: requestedQuality, silent: silent)
    }

    /// Starts one transfer. The caller has already checked the cap, so this
    /// always takes a slot.
    private func start(_ track: Track, quality: AudioQuality, silent: Bool) {
        let normalized = track.normalizedForLXPlayback()
        let key = normalized.playbackKey
        let token = UUID()
        attemptTokens[key] = token
        failures[key] = nil
        activeDownloads[key] = ActiveDownload(id: key, track: normalized,
                                              requestedQuality: quality,
                                              fraction: nil)
        if !silent {
            ToastCenter.shared.show("正在解析并下载 \(normalized.name)")
        }

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                // Only the attempt that still owns the key frees this slot,
                // then `pump` counts the next one.
                if self.attemptTokens[key] == token {
                    self.attemptTokens[key] = nil
                    self.activeDownloads[key] = nil
                    self.tasks[key] = nil
                    self.pump()
                }
            }
            do {
                let resolved = try await LXUserAPIService.shared.resolveDownloadMusicURL(
                    for: normalized, quality: quality.rawValue)
                let (temporaryURL, response) = try await self.downloadFile(from: resolved.url,
                                                                            key: key)
                if let response = response as? HTTPURLResponse,
                   !(200..<300).contains(response.statusCode) {
                    throw DownloadError.http(response.statusCode)
                }

                prepareDownloadDirectory()
                let ext = Self.fileExtension(for: resolved.url)
                let fileName = "\(UUID().uuidString).\(ext)"
                let destination = Self.downloadDirectory.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                let item = Record(id: key, track: normalized, quality: resolved.quality,
                                  qualityVerified: resolved.qualityIsVerified,
                                  fileName: fileName, createdAt: Date())
                records.insert(item, at: 0)
                save()
                failures[key] = nil
                ToastCenter.shared.show("已下载 \(normalized.name)")
            } catch is CancellationError {
                // A cancelled task is silent; the user can start it again.
                if !Task.isCancelled {
                    ToastCenter.shared.show("音源配置已更改，请重新开始下载")
                }
            } catch {
                // A queue the user stopped is not a failure worth retrying.
                if !Task.isCancelled {
                    failures[key] = error.localizedDescription
                    ToastCenter.shared.show("下载失败：\(error.localizedDescription)")
                }
            }
        }
        tasks[key] = task
    }

    /// Starts queued downloads until the concurrency cap is reached.
    private func pump() {
        while tasks.count < maxConcurrentDownloads, !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            queuedCount = pendingQueue.count
            start(next.track, quality: next.quality, silent: next.silent)
        }
    }

    /// Stops every transfer and empties the queue. Files already saved stay on
    /// the device.
    func cancelAllDownloads() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        attemptTokens.removeAll()
        pendingQueue.removeAll()
        queuedCount = 0
        activeDownloads.removeAll()
    }

    func downloadBatch(_ tracks: [Track], quality: AudioQuality) {
        for track in tracks { download(track, quality: quality) }
    }

    func availableQualities(for track: Track) async -> [AudioQuality] {
        let normalized = track.normalizedForLXPlayback()
        let names = Set(await LXUserAPIService.shared.availableQualityNames(for: normalized))
        var seenTypes = Set<String>()
        let result = AudioQuality.allCases.filter {
            names.contains($0.lxType) && seenTypes.insert($0.lxType).inserted
        }
        return result.isEmpty ? [.standard] : result
    }

    func delete(_ record: Record) {
        tasks[record.id]?.cancel()
        tasks[record.id] = nil
        activeDownloads[record.id] = nil
        try? FileManager.default.removeItem(at: record.fileURL)
        records.removeAll { $0.id == record.id }
        save()
    }

    private func downloadFile(from url: URL, key: String) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url)
                task.taskDescription = key
                continuations[task.taskIdentifier] = continuation
                task.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.session.getAllTasks { tasks in
                    tasks.first(where: { $0.taskDescription == key })?.cancel()
                }
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.manifestURL),
              let stored = try? JSONDecoder().decode([Record].self, from: data) else { return }
        records = stored.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        if records.count != stored.count { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: Self.manifestURL, options: .atomic)
    }

    /// Drops records whose file is gone and deletes files the manifest does not
    /// reference, so neither a crash mid-download nor iOS reclaiming app data
    /// leaves the library pointing at nothing or the disk holding dead weight.
    func pruneStaleFiles() {
        let fm = FileManager.default
        let before = records.count
        records.removeAll { !fm.fileExists(atPath: $0.fileURL.path) }
        if records.count != before { save() }

        let known = Set(records.map(\.fileName))
        guard let names = try? fm.contentsOfDirectory(atPath: Self.downloadDirectory.path) else { return }
        for name in names where !known.contains(name) {
            try? fm.removeItem(at: Self.downloadDirectory.appendingPathComponent(name))
        }
    }

    private static func fileExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["mp3", "m4a", "flac", "wav", "aac", "ogg", "opus"].contains(ext) ? ext : "m4a"
    }

    private enum DownloadError: LocalizedError {
        case http(Int)
        case temporaryFile

        var errorDescription: String? {
            switch self {
            case .http(let status): return "服务器返回 HTTP \(status)"
            case .temporaryFile: return "无法保存下载文件"
            }
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        let fraction = totalBytesExpectedToWrite > 0
            ? min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
            : nil
        Task { @MainActor [weak self] in
            guard let self, var item = self.activeDownloads[key] else { return }
            item.fraction = fraction
            self.activeDownloads[key] = item
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // URLSession deletes its temporary file after this callback returns.
        // Move it to a stable staging path before resuming the continuation.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Moumusic-\(UUID().uuidString).download")
        let moved = (try? {
            try FileManager.default.moveItem(at: location, to: destination)
            return true
        }()) ?? false
        Task { @MainActor [weak self] in
            guard let self, let continuation = self.continuations.removeValue(forKey: downloadTask.taskIdentifier) else { return }
            if moved {
                let response = downloadTask.response ?? URLResponse(
                    url: downloadTask.currentRequest?.url ?? URL(string: "about:blank")!,
                    mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
                continuation.resume(returning: (destination, response))
            } else {
                continuation.resume(throwing: DownloadError.temporaryFile)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.continuations.removeValue(forKey: task.taskIdentifier)?.resume(throwing: error)
        }
    }
}
#endif
