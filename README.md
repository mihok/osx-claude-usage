<p align="center">
  <img src="docs/images/icon.png" width="112" alt="Claude Usage app icon">
</p>

<h1 align="center">Claude Usage</h1>

<p align="center">
  Your Claude plan limits as circular meters in the macOS menu bar.
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

<p align="center">
  🐧 On Linux? Try <a href="https://github.com/rogsme/polybar-claude-usage"><b>polybar-claude-usage</b></a> by <a href="https://github.com/rogsme">@rogsme</a>, which puts the same usage in your Polybar.
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-dark.png">
    <img src="docs/images/hero-light.png" width="580" alt="Four usage rings in the menu bar, with the details panel open below them">
  </picture>
</p>

Claude Usage puts one small ring in your menu bar for each of your Claude plan's limits. Each ring fills as you use that limit up, so you can see at a glance how close you are before you hit one.

- **5**: the rolling 5-hour session limit
- **W**: the weekly limit across all models
- **S**, **O**, **F**, …: per-model weekly limits (Sonnet, Opus, Fable, …). These appear once you start using them.

These are the same numbers shown by `/usage` in Claude Code and on **claude.ai › Settings › Usage**. The limits are shared between claude.ai, the Claude apps and Claude Code, so the rings show your usage across all of them.

## Features

- **At-a-glance rings.** They turn orange, then red, as you get close to a limit, following Claude's own reading of each one.
- **Details on click.** The panel shows exact percentages and when each limit resets. Pin or unpin any limit to choose which rings stay in the menu bar.
- **Claude Code doesn't need to be open.** The app asks your installed Claude Code for its `/usage` report in the background. Claude Code keeps its own sign-in fresh, and the app never sees a token.
- **Light and dark menu bars.** Three color styles, optional percentages, and labels inside the rings.
- **Polite polling.** It refreshes every 5 minutes by default and backs off when Claude rate-limits. It also refreshes right after a limit resets and fades the rings when the data is out of date.
- **Tiny and private.** It's a native AppKit/SwiftUI app with no dependencies, no analytics and no Dock icon.

## Install

You'll need:

- macOS 13 Ventura or later
- [Claude Code](https://claude.com/claude-code), signed in once with your Claude Pro, Max, Team or Enterprise account (run `claude` and follow the prompts)
- Xcode 15+ or the Xcode Command Line Tools (Swift 5.9+) to build

```sh
git clone https://github.com/mihok/osx-claude-usage.git
cd osx-claude-usage
make install
```

`make install` builds **Claude Usage.app**, copies it to `/Applications` (or `~/Applications`) and starts it. The rings appear in your menu bar right away. To keep them there after a restart, open **Settings…** and turn on **Launch at login**.

To update, `git pull` and run `make install` again.

## Using it

| Action | What happens |
| --- | --- |
| Click the rings | Opens the details panel |
| Right-click the rings | Refresh Now, Settings…, Quit |
| Click a 📌 pin in the panel | Shows or hides that limit's ring in the menu bar |
| Hover over the rings | A tooltip lists every limit and its reset time |

### Menu bar styles

Choose a style in **Settings › Menu bar**. You can also replace the labels inside the rings with percentages next to them.

<p align="center">
  <img src="docs/images/styles.png" width="720" alt="The ring styles on light and dark menu bars: adaptive, traffic light, monochrome, with percentages, and faded when out of date">
</p>

## Where the numbers come from

Every few minutes the app runs your installed Claude Code in the background with its `/usage` command:

```sh
claude -p /usage --output-format stream-json --verbose --no-session-persistence --safe-mode
```

- **`/usage` runs inside Claude Code.** No message is sent to a model, so checking usage doesn't use any of it up.
- **Claude Code fetches the numbers with its own sign-in.** It renews that sign-in when needed, so you never have to open Claude Code just to keep the rings working. The app never reads, stores or sends a Claude token or cookie.
- **The checks stay out of your way.** `--safe-mode` keeps your hooks, plugins and MCP servers from starting, and `--no-session-persistence` keeps the checks out of your session history.
- **Older Claude Code versions work too.** If yours doesn't know one of these options, the app drops it and tries again.

The app finds `claude` on your shell's PATH and in the usual install locations, such as `~/.local/bin` and `/opt/homebrew/bin`. If yours lives somewhere else, choose it in **Settings › Claude Code**.

## Privacy and security

- The app makes no network requests of its own. Claude Code does the fetching, with the sign-in it already has.
- It never reads, stores or sends Claude credentials, tokens or cookies.
- It has no analytics, telemetry or update checks.
- The source is small and readable. Start with [`ClaudeCLI.swift`](Sources/ClaudeUsageCore/ClaudeCLI.swift) to see exactly how Claude Code is run.

## Troubleshooting

**"Couldn't find Claude Code"**
Install [Claude Code](https://claude.com/claude-code). If it's already installed in an unusual place, choose the `claude` executable in **Settings › Claude Code**. Run `which claude` in Terminal to find it.

**"Claude Code isn't signed in"**
Run `claude` in Terminal once and sign in with your Claude account. You can quit it afterwards; the rings update within a minute. Your sign-in lasts a long time, but if it ever fully expires, Claude Code needs you to sign in again the same way.

**"Claude Code couldn't fetch your usage"**
Claude limits how often usage can be checked. The app keeps showing the last known values and retries with a growing delay. If it keeps happening, set a longer refresh interval. Updating Claude Code with `claude update` can also help.

**macOS says the app can't be opened**
This only happens with a copy you downloaded rather than built yourself. Right-click the app, choose **Open**, or run `xattr -dr com.apple.quarantine "/Applications/Claude Usage.app"`.

## Development

```sh
make build     # swift build (debug)
make test      # unit tests (needs full Xcode for XCTest)
make app       # build/Claude Usage.app, release, ad-hoc signed
make run       # build and launch the .app
make preview   # render the rings, panel, settings and icon with sample data to build/preview
```

You can also open the folder in Xcode (`xed .`), pick the **ClaudeUsage** scheme and press ⌘R.

```
Sources/ClaudeUsageCore/   Running Claude Code, parsing its usage report, formatting, refresh scheduling (unit-tested, Foundation only)
Sources/ClaudeUsage/       The app: status item, ring renderer, details panel, settings
Tests/                     XCTest suite for ClaudeUsageCore
Packaging/Info.plist       App bundle metadata (menu bar only, no Dock icon)
scripts/                   build-app.sh (assemble, render icon, sign) and install.sh
```

To build a universal (Apple silicon + Intel) binary, run `UNIVERSAL=1 make app`. To distribute a signed copy, set `CODESIGN_IDENTITY` to your Developer ID.

## Caveats

- The structured usage report Claude Code prints is marked experimental, so its shape may change between Claude Code versions. If it does, the app falls back to reading `/usage`'s text, which has percentages but not reset times.
- Not affiliated with or endorsed by Anthropic. Claude is a trademark of Anthropic, PBC.

## License

[MIT](LICENSE)
