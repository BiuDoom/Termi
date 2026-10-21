# Termi

A native macOS SSH client built with SwiftUI and Swift 6.

Termi manages your hosts, opens terminals, transfers files over SFTP, forwards ports and runs
day-to-day ops tools — on one SSH connection per host, with every secret in its own encrypted
vault on your Mac. The interface follows Apple's Liquid Glass design on macOS 26 and later, and
uses the standard materials on macOS 15.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/hosts-dark.png">
  <img src="docs/images/hosts-light.png" alt="The Hosts page: hosts as cards, with one host's details open in the panel at the right">
</picture>

![A terminal tab split into two panes, with the inspector's Info tab](docs/images/terminal.png)

| | |
|---|---|
| ![Monitoring: gauges, the last five minutes, load and network](docs/images/monitoring.png) | ![Keychain: keys with their fingerprint image and the hosts that use them](docs/images/keychain.png) |
| ![Docker: the containers of the selected host](docs/images/docker.png) | ![History: statistics over every record and the selected session's output](docs/images/history.png) |


Sparkle update checks use a placeholder feed, `https://example.com/appcast.xml` (`SUFeedURL` in `Termi/Resources/Info.plist`). Point that at your own appcast before shipping updates.

The screenshots show sample data and test servers. See the [User Guide](docs/USER_GUIDE.md) for how everything
works and the [Changelog](CHANGELOG.md) for what changed.

## Features

**SSH (OpenSSH underneath)**
- One connection per host, shared by every tab, split pane, SFTP browser, port forward and tool
  (OpenSSH `ControlMaster`): authenticate once, new tabs open instantly
- Password, private key (with passphrase), SSH agent and keyboard-interactive / 2FA prompts,
  with "Save to vault" for passwords and passphrases
- Jump hosts (ProxyJump), chainable, each hop with its own credentials
- Host key verification with a fingerprint prompt (trust on first use); a host whose key has
  changed is refused
- Agent forwarding, X11 forwarding, keep-alive
- Automatic reconnect with backoff, also after network changes and wake from sleep
- Optional: apply your own `~/.ssh/config` (e.g. legacy algorithms)

**Terminal**
- Sessions are tabs in the toolbar; split panes (`⌘D` / `⇧⌘D`) with pane headers, and broadcast
  input to all panes of a tab
- A floating status bar (address, state, uptime, tunnels, grid size) and an inspector with
  **Snippets** and **Info**
- Find in scrollback (`⌘F`), clear buffer, font zoom
- Snippets with `{{variables}}`, per-host startup snippet
- Font, cursor style, scrollback size, bell, Option-as-Meta, copy on select
- 12 built-in colour themes (Dracula, Nord, Monokai, Solarized, Tokyo Night, …) with a live
  preview, per-host theme
- Session transcripts in History

**Hosts**
- Hosts as cards (or a list); a host's details open in a side panel when asked for (`⌘I`):
  connection statistics, its port forwards, the last 14 days, configuration and route
- Host tiles show the distribution detected after connecting (Ubuntu, Debian, Fedora, Alpine, …)
- Groups with default username / identity / jump host, tags with filtering, sort by name or
  recent use
- Type `user@host` in the search field to connect right away; Quick Connect (`⇧⌘N`); command
  palette (`⌘K`)
- Import `~/.ssh/config` (hosts, identity files, ProxyJump chains, forwards); CSV import / export

**SFTP**
- Built-in SFTP v3 client over the host's shared connection — no second login
- Two cards (this Mac, the server) with breadcrumbs and drag & drop; a floating transfer bar with
  progress, speed, time left and cancel
- Recursive upload / download / delete, rename, chmod, new folder, hidden files
- Edit remote files in your default app; saving uploads them automatically
- Careful with your files: downloads go through a `.part` file, replaced files and unsent edits go
  to the Trash, renames never overwrite

**Port Forwarding**
- Local / Remote / Dynamic (SOCKS) rules with live status
- Start and stop them on their own, or let them start with a terminal session

**Vault**
- Keychain: generate Ed25519 / RSA keys, import existing keys, see each key's fingerprint image and
  who uses it, install a public key on hosts (`authorized_keys`) in one step
- Identities: one set of sign-in details shared by many hosts or a group
- Known Hosts: the host keys you trusted, grouped by machine
- AES-256-GCM encrypted storage — no macOS Keychain dependency

**Tools**
- Batch command across multiple hosts, results by host or grouped by output
- Server monitoring (CPU, memory, disk, load, network) with auto refresh and a trend
- Docker containers: list, start, stop, restart, remove, logs
- Connection history with statistics over every record

**Windows, security and data**
- Multiple windows, each with its own tabs and pages
- Master password with a lock screen (sessions stay connected in the background)
- Database backup and restore; password-protected encrypted export / import to move between Macs
- No cloud sync — all data stays local. A separate profile can be used with `TERMI_PROFILE_DIR`
- English and Simplified Chinese

## Requirements

- macOS 15.0 or later (Liquid Glass appearance on macOS 26 or later)
- To build from source: Xcode 26 for the released appearance — the macOS 26 SDK is what gives the
  app Liquid Glass. Xcode 16.2 (Swift 6.0, macOS 15 SDK) also builds and passes the tests; the app
  then has no glass effects

## Install

### Download DMG

Grab the latest release from [GitHub Releases](https://github.com/example/Termi/releases).

1. Open the `.dmg` file
2. Drag **Termi** to **Applications**
3. First launch: right-click the app and select **Open** (macOS Gatekeeper)

### Verify Download

```bash
shasum -a 256 Termi-*.dmg
```

Compare the output with the SHA-256 hash listed in the release notes.

### Build from Source

```bash
git clone https://github.com/example/Termi.git
cd Termi
make build   # build/Termi.app (Release, ad-hoc signed)
make dmg     # build/Termi-<version>.dmg
make clean   # removes build/
```

Run the unit tests with:

```bash
xcodebuild test -project Termi.xcodeproj -scheme Termi -destination 'platform=macOS'
```

The tests are hosted in the app but run on a temporary profile; they never touch your data.

For acceptance testing against real SSH servers (Docker) on a separate app profile:

```bash
make test-env-up     # three test servers on 127.0.0.1, secrets generated into .test-env/
make run-isolated    # a Debug build on .test-env/profile, seeded with hosts for them
make test-env-down
```

See [docs/TESTING.md](docs/TESTING.md).

The Xcode project is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen) from
`project.yml` and committed. After adding or moving Swift files run `xcodegen`; do not edit
`project.pbxproj` by hand.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘N` / `⇧⌘N` | New window / Quick Connect |
| `⌘T` | New local terminal tab |
| `⌘W` / `⇧⌘W` | Close tab or pane (confirms for SSH sessions) / close window |
| `⌘1`–`⌘9`, `⌘[` / `⌘]` | Switch tabs |
| `⌘D` / `⇧⌘D` | Split right / split down |
| `⌥⌘]` / `⌥⌘[` | Next / previous pane |
| `⇧⌘B` | Broadcast input to all panes |
| `⌘F`, `⌘G` / `⇧⌘G` | Find, find next / previous |
| `⌥⌘K` | Clear buffer |
| `⇧⌘S` | Snippets (inspector) |
| `⇧⌘O` | Open SFTP for the focused host |
| `⇧⌘R` | Reconnect |
| `⌘=` / `⌘-` / `⌘0` | Font size |
| `⌘R` | Refresh (Monitoring, Docker, History) |
| `⌘Return` | Run the batch command |
| `⌘K` | Command palette |
| `⌘/` | Keyboard shortcuts |
| `⇧⌘L` | Lock app |
| `⌘,` | Settings |

The full list, including keys inside pages, is in the
[User Guide](docs/USER_GUIDE.md#keyboard-shortcuts).

## Tech Stack

| Component | Technology |
|-----------|------------|
| Language | Swift 6 (strict concurrency) |
| UI | SwiftUI, with AppKit where needed |
| Database | GRDB (SQLite, WAL mode) |
| SSH | System OpenSSH (`ControlMaster` multiplexing) with a built-in askpass bridge |
| SFTP | Built-in SFTP v3 client over the shared SSH connection |
| Terminal | SwiftTerm (pinned to 1.18.x) |
| Encryption | CryptoKit AES-256-GCM; PBKDF2-SHA256 for the master password |
| Updates | Sparkle |

## Project Structure

```
Termi/
├── App/           # Entry point (also the SSH askpass helper), AppDelegate, menu commands,
│                  # AppProfile.swift — the one place that decides where a run keeps its data
├── Models/        # GRDB records, terminal themes and preferences, host system detection
├── Database/      # DatabaseManager (actor) + migrations
├── Repositories/  # Data access layer
├── Services/      # SSH engine (Services/SSH), SFTP client, vault and crypto, sync, import/export,
│                  # monitoring, Docker, notifications
├── ViewModels/    # @Observable view models (one AppViewModel per window)
├── Views/         # SwiftUI views by area: MainWindow, Sidebar, Terminal, Hosts, SFTP, Keys,
│                  # DevOps, Security, Settings, Shared
├── Theme/         # Shared design layer
│   ├── DesignSystem.swift   # spacing, radii, fonts, status and accent colours
│   ├── Glass.swift          # the only file that touches Liquid Glass APIs (with fallbacks)
│   ├── Tiles.swift          # host tiles (distribution marks), sidebar labels
│   ├── DataCards.swift      # stat cards, gauges, value rows
│   ├── Charts.swift         # meters, sparklines, activity charts
│   ├── Components.swift     # cards, groups, headers, master-detail, empty states …
│   └── DesignGallery.swift  # DEBUG: a sheet that shows every component
├── Utilities/
├── Resources/     # Info.plist, entitlements, asset catalog
└── Localizable.xcstrings    # English + Simplified Chinese
TermiTests/       # Unit tests (Swift Testing)
docs/              # User guide, screenshots, third-party notices
scripts/           # build-release.sh, create-dmg.sh …
project.yml        # XcodeGen source of Termi.xcodeproj
```

Design rules for anything a person sees are in `Termi/Views/AGENTS.md` and
`Termi/Theme/AGENTS.md`.

## CI/CD

| Workflow | Trigger | Action |
|----------|---------|--------|
| **CI** | Push to `main` / `claude/**`, PR to `main`, manual run (changes to `*.md`, `docs/` and `Casks/` alone do not start it on a push) | Release build + unit tests in two jobs: **Xcode 26** on macOS 26 (what ships) and **Xcode 16.2** on macOS 15 (compatibility). Logs and crash reports are uploaded when a job fails |
| **Release** | Push tag `v*`, or a manual run with a tag | Checks that the tag matches `MARKETING_VERSION`, builds the DMG with Xcode 26, publishes a GitHub Release with its SHA-256 |

The same source has to compile on both toolchains: APIs that only exist in the macOS 26 SDK live
in `Termi/Theme/Glass.swift` behind `#if compiler(>=6.2)` and `if #available(macOS 26, *)`.

## Acknowledgements

Operating system marks on host tiles are from [Simple Icons](https://simpleicons.org) (CC0 1.0); they are
trademarks of their respective owners. See [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md).

## License

All rights reserved.
