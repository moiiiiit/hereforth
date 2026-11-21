#if HEREFORTH_BINARY_UPDATER
import Foundation

struct BinaryUpdateConfiguration {
    enum Track: String {
        case production
        case beta

        var title: String { self == .production ? "Production" : "Beta" }
    }

    let track: Track
    let feedURL: String

    init?(info: [String: Any]) {
        guard info["HereforthUpdateChannel"] as? String == "binary",
              let trackName = info["HereforthBinaryUpdateTrack"] as? String, let track = Track(rawValue: trackName),
              let feed = info["SUFeedURL"] as? String, let components = URLComponents(string: feed),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil, let url = components.url,
              let publicKey = info["SUPublicEDKey"] as? String, Data(base64Encoded: publicKey)?.count == 32 else {
            return nil
        }
        self.track = track
        feedURL = url.absoluteString
    }
}
#endif
