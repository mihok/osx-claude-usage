import ClaudeUsageCore
import SwiftUI

/// The panel shown when clicking the menu bar meters.
struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    var openSettings: () -> Void
    var quit: () -> Void
    /// Fixed clock for previews; nil follows the real time.
    var fixedNow: Date?

    var body: some View {
        if let fixedNow {
            content(now: fixedNow)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
            meters(now: now)
            if let error = store.lastError {
                ErrorBanner(error: error, hasData: store.snapshot != nil, openSettings: openSettings)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
            Divider()
            footer(now: now)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 320)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude Usage")
                .font(.system(size: 14, weight: .semibold))
            if let plan = store.planName {
                Text(plan)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundColor(.accentColor)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Button {
                    store.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }
        }
    }

    @ViewBuilder
    private func meters(now: Date) -> some View {
        if let snapshot = store.snapshot {
            VStack(spacing: 14) {
                ForEach(snapshot.relevantMeters) { meter in
                    MeterRow(
                        meter: meter,
                        style: settings.meterStyle,
                        now: now,
                        isShownInMenuBar: settings.isShownInMenuBar(meter.id),
                        toggleMenuBar: {
                            settings.setShownInMenuBar(!settings.isShownInMenuBar(meter.id), meterID: meter.id)
                        }
                    )
                }
            }
            .padding(16)
            .opacity(store.isStale ? 0.6 : 1)
        } else if store.lastError == nil {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(28)
        } else {
            Spacer().frame(height: 14)
        }
    }

    private func footer(now: Date) -> some View {
        HStack(spacing: 4) {
            if let snapshot = store.snapshot {
                Text("Updated \(UsageFormatting.age(of: snapshot.fetchedAt, now: now)) · \(store.snapshotSource?.shortName ?? "")")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Text(settings.dataSource.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button(action: quit) {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Claude Usage")
        }
    }
}

/// A large ring with the meter's name and reset time.
private struct MeterRow: View {
    let meter: UsageMeter
    let style: MeterStyle
    let now: Date
    let isShownInMenuBar: Bool
    let toggleMenuBar: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RingGauge(fraction: meter.fraction, color: style.popoverColor(for: meter.level), lineWidth: 5)
                Text(UsageFormatting.percent(meter.percent))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(meter.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(UsageFormatting.resetDescription(meter.resetsAt, now: now))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(meter.detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            Spacer(minLength: 4)
            Button(action: toggleMenuBar) {
                Image(systemName: isShownInMenuBar ? "pin.fill" : "pin.slash")
                    .foregroundColor(isShownInMenuBar ? .accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isShownInMenuBar ? "Shown in the menu bar – click to hide" : "Hidden from the menu bar – click to show")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(meter.title), \(UsageFormatting.percent(meter.percent)) used")
    }
}

struct RingGauge: View {
    let fraction: Double
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(min(fraction, 1), fraction > 0 ? 0.015 : 0))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

private struct ErrorBanner: View {
    let error: UsageError
    let hasData: Bool
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: hasData ? "exclamationmark.triangle" : "exclamationmark.circle")
                .foregroundColor(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(error.localizedDescription)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if needsSettings {
                    Button("Open Settings…", action: openSettings)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }

    private var needsSettings: Bool {
        switch error {
        case .missingCookie, .notSignedIn, .noOrganization:
            return true
        case let .unauthorized(source, _, _):
            return source == .claudeWeb
        default:
            return false
        }
    }
}
