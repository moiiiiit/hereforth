import AppKit
import SwiftUI

struct KeepAwakeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var awake: KeepAwake

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keep Awake")
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(24)
            Divider()

            Form {
                Section {
                    LabeledContent("Status", value: awake.status)
                    Picker("Keep awake", selection: $awake.preferredMode) {
                        ForEach(AwakeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .disabled(awake.mode != nil)
                    Picker("Duration", selection: $awake.preferredDuration) {
                        ForEach(AwakeDuration.allCases) { duration in
                            Text(duration.title).tag(duration)
                        }
                    }
                    .disabled(awake.mode != nil)

                    if awake.mode == nil {
                        Button {
                            awake.start(awake.preferredMode, seconds: awake.preferredDuration.seconds)
                        } label: {
                            Text("Start Keep Awake")
                                .foregroundStyle(colorScheme == .dark ? Color.black : .white)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Stop Keep Awake") { awake.stop() }
                    }
                    if let problem = awake.problem {
                        Text(problem).foregroundStyle(.red)
                    }
                } header: {
                    Text("Idle sleep")
                } footer: {
                    Text("Closing the lid, choosing Sleep, or quitting Hereforth still lets your Mac sleep.")
                }

                Section {
                    Toggle("Move pointer during Keep Awake", isOn: Binding(
                        get: { awake.pointerEnabled },
                        set: { awake.setPointerEnabled($0) }
                    ))
                    Picker("Interval", selection: Binding(
                        get: { awake.intervalSeconds },
                        set: { awake.setPointerInterval($0) }
                    )) {
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                    }
                    .disabled(!awake.pointerEnabled)
                    if awake.pointerPermissionRequired {
                        Text("Allow Hereforth under System Settings → Privacy & Security → Accessibility, then turn on pointer movement again.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Pointer")
                } footer: {
                    Text("Moves the pointer one point when your Mac is idle and unlocked. Movement pauses while the screen sleeps, locks, or shows a screen saver.")
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct HereforthMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var awake: KeepAwake
    @Binding var selection: String?

    var body: some View {
        Button("Open Hereforth") { showWindow() }
        Button("Usage") { showWindow("usage") }

        Divider()

        Label(awake.status, systemImage: awake.mode == nil ? "moon" : "checkmark")
        if awake.mode == nil {
            Button("Keep Awake for 1 Hour") {
                awake.start(awake.preferredMode, seconds: AwakeDuration.hour.seconds)
            }
            Menu("Other Durations") {
                ForEach(AwakeDuration.allCases.filter { $0 != .hour }) { duration in
                    Button(duration.title) { awake.start(awake.preferredMode, seconds: duration.seconds) }
                }
            }
        } else {
            Button("Stop Keep Awake") { awake.stop() }
        }
        Button("Keep Awake Settings…") { showWindow("power") }
        if let problem = awake.problem { Text(problem) }

        Divider()

        Button("Quit Hereforth") {
            awake.stop()
            NSApp.terminate(nil)
        }
    }

    private func showWindow(_ destination: String? = nil) {
        if let destination { selection = destination }
        openWindow(id: "library")
        NSApp.activate()
    }
}
