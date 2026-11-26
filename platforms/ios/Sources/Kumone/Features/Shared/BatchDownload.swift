#if os(iOS)
import Foundation

/// Starts a download for every track that is not already on the device.
/// The engine de-duplicates on its own, but skipping here keeps the toast
/// honest and avoids one toast per skipped song.
@MainActor
enum BatchDownload {
    struct Summary {
        let started: Int
        let skipped: Int
    }

    @discardableResult
    static func start(_ tracks: [Track], quality: AudioQuality? = nil) -> Summary {
        let downloads = DownloadManager.shared
        let resolvedQuality = quality ?? SettingsManager.shared.audioQuality
        var started = 0
        var skipped = 0
        for track in tracks {
            if downloads.record(for: track) != nil || downloads.isDownloading(track) {
                skipped += 1
                continue
            }
            downloads.download(track, quality: resolvedQuality)
            started += 1
        }
        if started == 0 {
            ToastCenter.shared.show(String(localized: "全部歌曲已下载"))
        } else {
            ToastCenter.shared.show(String(localized: "已开始下载 \(started) 首（跳过 \(skipped) 首）"))
        }
        return Summary(started: started, skipped: skipped)
    }
}
#endif
