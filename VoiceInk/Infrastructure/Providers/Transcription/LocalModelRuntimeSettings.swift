import Foundation

enum LocalModelRuntimeSettings {
    // Keep the existing defaults key so users retain the value from the Qwen-only setting.
    static let keepAliveSecondsKey = "Qwen3ASRKeepAliveSeconds"
    static let defaultKeepAliveSeconds = 30

    static var keepAliveSeconds: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keepAliveSecondsKey) != nil else {
            return defaultKeepAliveSeconds
        }
        return max(0, min(defaults.integer(forKey: keepAliveSecondsKey), 600))
    }
}
