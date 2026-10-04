# Claude Usage

A small macOS menu bar app that shows your Claude plan usage as a row of circular meters, one per limit:

- **5**: the rolling 5-hour session limit
- **W**: the weekly limit across all models
- **S**, **O**, **F**, …: per-model weekly limits (Sonnet, Opus, Fable, …), shown once you start using them

Each ring fills as you use more of that limit. It turns orange at 70% and red at 90%. Click the meters for details, including the exact percentages and when each limit resets. Right-click for Refresh, Settings and Quit.

These are the same numbers shown by `/usage` in Claude Code and on **claude.ai › Settings › Usage**. The limits are shared between claude.ai, the desktop app and Claude Code, so the meters reflect all of them.

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ or the Xcode Command Line Tools (Swift 5.9+) to build. `make test` needs full Xcode for XCTest.
- A Claude Pro, Max, Team or Enterprise plan

## Install

```sh
git clone https://github.com/mihok/osx-claude-usage.git
cd osx-claude-usage
make install
```

`make install` builds `Claude Usage.app`, copies it to `/Applications` (or `~/Applications`) and starts it. The meters appear in the menu bar right away. To keep them there after a restart, open **Settings…** and turn on **Launch at login**.

Other targets:

| Command        | What it does                                                      |
| -------------- | ----------------------------------------------------------------- |
| `make app`     | Build `build/Claude Usage.app` without installing it              |
| `make run`     | Build and launch from `build/`                                    |
| `make test`    | Run the unit tests                                                |
| `make preview` | Render the meters, popover and icon with sample data to PNG files |

CI builds a universal (Apple silicon + Intel) app for every push. You can download it from the workflow run's **Claude-Usage** artifact. It's ad-hoc signed, so macOS will block it the first time: right-click the app, choose **Open**, or run `xattr -dr com.apple.quarantine "/Applications/Claude Usage.app"`.

## Where the numbers come from

Pick a source in **Settings › Data source**.

### Claude Code sign-in (default, no setup)

If you've signed in to [Claude Code](https://claude.com/claude-code) with your Claude account, the app reads that sign-in from the macOS Keychain (`Claude Code-credentials`). It then asks Claude's usage endpoint (`api.anthropic.com/api/oauth/usage`), the same one `/usage` uses.

- The token is **only read**. The app never refreshes, rewrites or copies it anywhere.
- macOS may ask once whether Claude Usage can read the Keychain item. Choose **Always Allow**.
- Claude Code refreshes its token whenever you use it. If you haven't used Claude Code for a while, the token can expire. The app then tells you to run any `claude` command, and picks up the fresh token automatically.

### claude.ai browser session

Use this if you don't use Claude Code, or if the Claude Code endpoint keeps rate-limiting you.

1. Open <https://claude.ai/settings/usage> in your browser.
2. Open Developer Tools › Network, reload the page and select the `usage` request.
3. Copy its **Cookie** request header (or just the `sessionKey` value) and paste it into Settings.

The cookie is stored in your login Keychain, never in preferences. It's sent only to `claude.ai`.

## Privacy

The app talks only to `api.anthropic.com` (Claude Code source) or `claude.ai` (browser session source). It has no analytics or telemetry, and it makes no other network requests.

## Notes and limitations

- Both usage endpoints are internal to Claude's own apps rather than a published API. They may change or rate-limit without notice. The app backs off automatically on errors and `429` responses, keeps showing the last known values (faded when they're out of date), and refreshes shortly after a limit resets.
- The default refresh interval is 5 minutes. Shorter intervals are more likely to be throttled.
- This project is not affiliated with or endorsed by Anthropic.

## Project layout

```
Sources/ClaudeUsageCore/   Response parsing, credentials, formatting, refresh scheduling (unit-tested)
Sources/ClaudeUsage/       The menu bar app: status item, ring renderer, popover, settings
Tests/                     XCTest suite for ClaudeUsageCore
Packaging/Info.plist       App bundle metadata (LSUIElement: menu bar only, no Dock icon)
scripts/                   build-app.sh (assemble + sign the .app), install.sh
```
