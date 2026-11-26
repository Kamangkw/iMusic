import Foundation

/// Simplified → Traditional conversion backed by the system's ICU transform,
/// so no character table ships with the app. Every entry point returns the
/// input unchanged when the platform has no such transform.
enum ChineseScript {
    private static let transform = StringTransform("Simplified-Traditional")

    static func traditional(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text.applyingTransform(transform, reverse: false) ?? text
    }
}
