import AppKit
import ClaudeUsageCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore

    /// Where Claude Code was found, or nil if it wasn't; empty string while looking.
    @State private var detectedClaudePath: String? = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginMessage: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Found at") {
                    Text(detectedClaudeDescription)
                        .foregroundColor(detectedClaudePath == nil ? Color.red : Color.secondary)
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
            .task(id: settings.claudePath) { await detectClaude() }

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
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let launchAtLoginMessage {
                    Text(launchAtLoginMessage)
                        .font(.callout)
                        .foregroundColor(.secondary)
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
        switch detectedClaudePath {
        case .none: return settings.claudePath.isEmpty ? "Not found" : "Nothing runnable at that location"
        case .some(""): return "Looking…"
        case let .some(path): return (path as NSString).abbreviatingWithTildeInPath
        }
    }

    private func detectClaude() async {
        detectedClaudePath = ""
        let customPath = settings.claudePath
        let found = await Task.detached(priority: .utility) {
            try? ClaudeCLI.resolve(customPath: customPath, shell: UsageStore.loginShell, workingDirectory: nil)
        }.value
        detectedClaudePath = found?.executable.path
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

    private func setLaunchAtLogin(_ enabled: Bool) {
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
