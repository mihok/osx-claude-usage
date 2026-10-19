import AppKit
import ClaudeUsageCore
import SwiftUI

/// What the Settings window tracks besides the preferences themselves.
///
/// Kept in a model object rather than SwiftUI's `@State`: recent SDKs implement `@State` as a
/// macro, and the Command Line Tools can't expand it, so the app wouldn't build without Xcode.
@MainActor
final class SettingsModel: ObservableObject {
    /// Where Claude Code was found, or nil if it wasn't; empty string while looking.
    @Published private(set) var detectedClaudePath: String? = ""
    @Published private(set) var detectedClaudeVersion: String?
    @Published private(set) var launchAtLogin = LaunchAtLogin.isEnabled
    @Published private(set) var launchAtLoginMessage: String?

    func detectClaude(customPath: String) async {
        detectedClaudePath = ""
        let found = await Task.detached(priority: .utility) {
            try? ClaudeCLI.resolve(customPath: customPath, shell: UsageStore.loginShell, workingDirectory: nil)
        }.value
        // A newer lookup has started if the path changed meanwhile.
        guard !Task.isCancelled else { return }
        detectedClaudePath = found?.executable.path
        detectedClaudeVersion = found?.version
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLoginMessage = LaunchAtLogin.requiresApproval
                ? "Allow Claude Usage in System Settings › General › Login Items."
                : nil
        } catch {
            launchAtLoginMessage = error.localizedDescription
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Found at") {
                    Text(detectedClaudeDescription)
                        .foregroundColor(model.detectedClaudePath == nil ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    TextField("Location", text: $settings.claudePath, prompt: Text("Find automatically"))
                    Button("Choose…", action: chooseClaude)
                }
                Text(Self.claudeCodeExplanation)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Claude Code")
            }
            .task(id: settings.claudePath) { await model.detectClaude(customPath: settings.claudePath) }

            Section {
                ForEach(meterChoices, id: \.id) { choice in
                    Toggle(choice.title, isOn: Binding(
                        get: { settings.isShownInMenuBar(choice.id) },
                        set: { settings.setShownInMenuBar($0, meterID: choice.id) }
                    ))
                }
                Picker("Colors", selection: $settings.meterStyle) {
                    ForEach(MeterStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Toggle("Label inside each ring (5, W, …)", isOn: $settings.showGlyphs)
                Toggle("Percentage next to each ring", isOn: $settings.showPercentages)
            } header: {
                Text("Menu bar")
            } footer: {
                Text(Self.thresholdFootnote)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section {
                Picker("Refresh every", selection: $settings.refreshInterval) {
                    ForEach(AppSettings.refreshIntervals, id: \.self) { interval in
                        Text(Self.intervalLabel(interval)).tag(interval)
                    }
                }
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let launchAtLoginMessage = model.launchAtLoginMessage {
                    Text(launchAtLoginMessage)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                LabeledContent("Troubleshooting") {
                    Button("Copy Diagnostics") {
                        if let diagnostics = store.diagnostics { Diagnostics.copy(diagnostics) }
                    }
                    .disabled(store.diagnostics == nil)
                    .help("Copy what Claude Code reported on the last check, to paste into a bug report")
                }
            } header: {
                Text("General")
            } footer: {
                Text("Claude rate-limits its usage endpoint, so short intervals can be throttled. Claude Usage \(AppInfo.version).")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 560)
    }

    // MARK: - Claude Code location

    private var detectedClaudeDescription: String {
        switch model.detectedClaudePath {
        case .none: return settings.claudePath.isEmpty ? "Not found" : "Nothing runnable at that location"
        case .some(""): return "Looking…"
        case let .some(path):
            let shortPath = (path as NSString).abbreviatingWithTildeInPath
            return model.detectedClaudeVersion.map { "\(shortPath) (\($0))" } ?? shortPath
        }
    }

    private func chooseClaude() {
        let panel = NSOpenPanel()
        panel.title = "Choose Claude Code"
        panel.message = "Select the claude executable, for example ~/.local/bin/claude."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            settings.claudePath = url.path
        }
    }

    // MARK: - Helpers

    private struct MeterChoice {
        let id: String
        let title: String
    }

    /// The meters that can be shown in the menu bar: what Claude currently reports, or the
    /// two windows every plan has before the first refresh.
    private var meterChoices: [MeterChoice] {
        if let snapshot = store.snapshot {
            return snapshot.relevantMeters.map { MeterChoice(id: $0.id, title: $0.title) }
        }
        return [
            MeterChoice(id: MeterID.session, title: "Session"),
            MeterChoice(id: MeterID.weekly, title: "Weekly"),
        ]
    }

    private static let thresholdFootnote =
        "Rings turn orange, then red, as you get close to a limit. Per-model limits appear once you start using them."

    private static let claudeCodeExplanation =
        "Claude Usage asks Claude Code for its /usage report in the background. Claude Code doesn't need to be open, "
        + "no messages are sent, and your sign-in stays inside Claude Code. If you haven't yet, run `claude` once in Terminal to sign in."

    static func intervalLabel(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
