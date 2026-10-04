import AppKit
import ClaudeUsageCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore

    @State private var cookieInput = ""
    @State private var cookieMessage: String?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Read usage from", selection: $settings.dataSource) {
                    ForEach(UsageSourceKind.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.radioGroup)

                switch settings.dataSource {
                case .claudeCode:
                    Text("Uses the sign-in Claude Code keeps in your Keychain. Run `claude` once in Terminal to sign in. The token is only read, never changed. If macOS asks for Keychain access, choose Always Allow.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .claudeWeb:
                    cookieEditor
                }
            } header: {
                Text("Data source")
            }

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
                Toggle("Label inside each ring (5h, 7d, …)", isOn: $settings.showGlyphs)
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

    // MARK: - claude.ai cookie

    @ViewBuilder
    private var cookieEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1. Open claude.ai › Settings › Usage in your browser and sign in.")
            Text("2. Open Developer Tools › Network, reload, and select the “usage” request.")
            Text("3. Copy its Cookie request header (or just the sessionKey value) and paste it below.")
        }
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Button("Open claude.ai Usage Page") {
            if let url = URL(string: "https://claude.ai/settings/usage") {
                NSWorkspace.shared.open(url)
            }
        }

        SecureField("Cookie header or sessionKey", text: $cookieInput)
            .onSubmit(saveCookie)

        HStack {
            Button("Save to Keychain", action: saveCookie)
                .disabled(ClaudeWebCookie.normalize(cookieInput) == nil)
            if settings.hasSavedCookie {
                Button("Remove", role: .destructive, action: removeCookie)
            }
            Spacer()
            Text(cookieMessage ?? (settings.hasSavedCookie ? "A session is saved." : "No session saved."))
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    private func saveCookie() {
        guard let cookie = ClaudeWebCookie.normalize(cookieInput) else { return }
        do {
            try CookieKeychain.save(cookie)
            settings.hasSavedCookie = true
            cookieInput = ""
            cookieMessage = "Saved to your Keychain."
            store.cookieDidChange()
        } catch {
            cookieMessage = error.localizedDescription
        }
    }

    private func removeCookie() {
        CookieKeychain.delete()
        settings.hasSavedCookie = false
        cookieMessage = "Removed."
        store.cookieDidChange()
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

    /// Built as a plain String so the % signs are not read as format specifiers.
    private static let thresholdFootnote =
        "Rings turn orange at \(Int(MeterLevel.elevatedThreshold))% and red at \(Int(MeterLevel.criticalThreshold))%. "
        + "Per-model limits appear once you start using them."

    static func intervalLabel(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
