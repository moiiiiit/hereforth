#if HEREFORTH_BINARY_UPDATER
import Combine
import Sparkle
import SwiftUI

@MainActor
final class BinaryUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    let isBinary: Bool
    let version: String
    let configuration: BinaryUpdateConfiguration?
    private var controller: SPUStandardUpdaterController?

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyInstalls = false
    @Published private(set) var allowsAutomaticInstall = false

    init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        isBinary = info["HereforthUpdateChannel"] as? String == "binary"
        version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        configuration = BinaryUpdateConfiguration(info: info)
        super.init()

        guard configuration != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyInstalls)
        updater.publisher(for: \.allowsAutomaticUpdates).assign(to: &$allowsAutomaticInstall)
        controller.startUpdater()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        // A track follows its packaged feed, including when Sparkle has cached an older URL in preferences.
        configuration?.feedURL
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.updater.checkForUpdates()
    }

    func setAutomaticChecking(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticInstallation(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }
}

struct BinaryUpdateCommands: Commands {
    @ObservedObject var updates: BinaryUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updates.isBinary {
                Button("Check for Updates…", action: updates.checkForUpdates)
                    .disabled(!updates.canCheckForUpdates)
            }
        }
    }
}

struct BinaryUpdateSettings: View {
    @ObservedObject var updates: BinaryUpdater

    var body: some View {
        Form {
            if let configuration = updates.configuration {
                Section("Software Updates") {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updates.automaticallyChecks }, set: updates.setAutomaticChecking
                    ))
                    Toggle("Download and install updates automatically", isOn: Binding(
                        get: { updates.automaticallyInstalls }, set: updates.setAutomaticInstallation
                    ))
                    .disabled(!updates.automaticallyChecks || !updates.allowsAutomaticInstall)
                    Button("Check for Updates…", action: updates.checkForUpdates)
                        .disabled(!updates.canCheckForUpdates)
                }
                Section {
                    LabeledContent("Release channel", value: configuration.track.title)
                    LabeledContent("Installed version", value: updates.version)
                }
            } else {
                Text(updates.isBinary
                     ? "This installation is missing its update settings. Download a new copy of Hereforth."
                     : "This installation uses source updates.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}
#endif
