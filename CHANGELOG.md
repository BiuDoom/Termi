# Changelog

All notable changes to Termi are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The project version is 2.1.0; it has not been released yet.

### Added

- **One SSH connection per host.** Tabs, split panes, the SFTP browser, port forwards and the tools
  on the same host share it: you sign in once and everything else opens at once.
- Sign-in prompts for passwords, key passphrases, keyboard-interactive / 2FA codes and host key
  fingerprints, with *Save to vault* for passwords and passphrases.
- Jump hosts (ProxyJump) that can be chained, each hop with its own credentials; agent forwarding
  with the app's own agent; an option to apply settings from your `~/.ssh/config`.
- Automatic reconnect with increasing delays, and at once when the network returns or the Mac
  wakes.
- Split panes (`⌘D` / `⇧⌘D`) with pane headers, broadcast input to all panes (`⇧⌘B`), find in
  the scrollback (`⌘F`), clear buffer, and font, cursor, bell, scrollback, Option-as-Meta and
  copy-on-select settings.
- A terminal inspector (`⇧⌘S`) with **Snippets** — snippets can have `{{variables}}` that are
  asked for when they run — and **Info** about the focused session; a floating status bar with
  address, state, uptime, tunnels and grid size.
- Startup snippet and colour theme per host.
- Host tiles show the distribution detected after connecting (Ubuntu, Debian, Fedora, Alpine,
  FreeBSD, Windows and others). It can be turned off in Settings → General.
- The Hosts page shows the hosts as cards over the whole page (a list is the alternative in the
  toolbar). A host's details — connection statistics, the last 14 days, its port forwards with
  switches, configuration, and the route through jump hosts — open in a panel at the right only
  when asked for: the button a card shows under the pointer, `⌘I`, or **Show Details** in its
  menu. **Show in Hosts** on other pages opens that host's details.
- Groups with a default username, identity and jump host; tags with filter chips; sorting by name
  or recent use; an **Online** filter.
- Type `user@host` in the hosts search field (or the command palette) to connect without saving a
  host. Quick Connect reads the address back and lists recent connections.
- A new SFTP browser: drag & drop between your Mac, the server and Finder, a transfer bar with
  progress, speed, time left and cancel, recursive upload / download / delete, rename,
  permissions, new folder, and editing a remote file in its default app with automatic upload on
  save.
- Port forwards can be started and stopped on their own, show their state, and can be copied as an
  `ssh` command or opened in the browser.
- Keychain: each key with its fingerprint image, a strength mark and the hosts and identities
  that use it; **Install on Host…** adds the public key to `authorized_keys`.
- Identities show who uses them; Known Hosts groups the addresses of one machine and can remove
  the entries no saved host uses.
- Monitoring draws gauges and a five-minute trend of CPU and memory. Docker lists the containers
  in a table. History has statistics over every record, a 30-day chart, and the selected
  session's output next to the list.
- Batch command: inserting snippets, and results grouped by identical output.
- Settings → Terminal with a live preview; Settings → Backup with an overview of the backups made
  and the databases a restore or an import replaced.
- A richer command palette (`⌘K`): sessions, recent hosts, hosts, snippets, actions and pages,
  with `⌘Return` to open SFTP for a host.
- Notifications in English and Simplified Chinese.
- A separate profile: start the app with `TERMI_PROFILE_DIR=<folder>` to keep a second set of
  data and preferences in that folder.
- `README` screenshots, a rewritten user guide and this changelog.

### Changed

- **The whole interface was rebuilt** on Apple's Liquid Glass design (macOS 26 and later; standard
  materials on macOS 15): a system sidebar that lists pages only, sessions as tabs in the window
  toolbar (tiles while a page is showing), pages as a list next to a record, neutral content with
  one accent colour, and status colours that always come with a word.
- Every fact is in one place: pages no longer repeat totals, host names or charts, and explanatory
  text appears at the moment of the action instead of standing on the page.
- `⌘W` closes the focused pane, and the tab with its last pane; on a page it closes the window.
  `⇧⌘W` closes the window while a terminal is showing.
- Importing `~/.ssh/config` also brings identity files (into the Keychain), ProxyJump chains and
  forwards, follows `Include` files, skips hosts that already exist, and is offered on the Hosts
  page as well as in Settings.
- A saved password or key that cannot be decrypted on this Mac says so in plain words and tells
  you where to enter it again.
- Closing a pane, a tab or a window and quitting the app ask the same question, controlled by one
  setting. Quitting with live SSH sessions now asks first.
- Settings are no longer a page of the main window: they open in the Settings window (`⌘,`, or
  the sidebar's footer), organised as General, Terminal, Import / Export, Sync, Backup,
  Notifications and About.
- A backup is a complete single-file copy of the database. A restore or an encrypted import checks
  the file first and keeps the database it replaces as `termi.before-*.db`.
- The encrypted export protects its secrets with the export password alone, so it can be imported
  on another Mac.
- Error and status messages follow the app's language.
- Released builds are made with Xcode 26.

### Fixed

- **Clear History** and deleting a host left the recorded session output on disk for up to 90
  days. Deleting history now deletes the output saved with it; the confirmations say so.
- Searching the history only looked at the 200 listed records; it now searches every record.
- Settings → Backup showed a *last backup* whose file had been deleted. Backups are checked
  against the files; one on a disk that is not connected is kept and marked.
- After an encrypted import, a history record could show the output of a different session.
- Imported SSH keys were all labelled "unknown"; any text could be imported as a key.
- SFTP: a failed upload or download replaced the file list with its error. A refused action is
  now reported in an alert and the list stays.
- Smart quotes and dashes are no longer substituted into commands typed in snippets and batch
  commands.
- The app could crash when the notification permission was answered.

### Removed

- The in-page header bars: a page's title, actions and search are in the window toolbar.
- The Settings page inside the main window (see Changed).

### Security

- Passwords, passphrases and one-time codes reach `ssh` and `ssh-keygen` through a private helper;
  they are never on a command line or in an environment variable.
- Nothing of a locked window stays visible or reachable: pages, sheets, alerts and sign-in prompts
  are gone and menu commands do nothing; the Settings window locks too.
- Setting or removing the master password re-encrypts saved passwords, private keys and identity
  passwords in one step; a failure can no longer leave some of them unreadable.
- A backup contains everything written so far; a restore no longer deletes the current database
  before the new one is known to be good.
- SFTP treats file names by their exact bytes: names from a hostile or odd server cannot escape
  the folder being transferred, look-alike names are not mixed up, links are not followed and
  devices and pipes are not downloaded.
- SFTP never deletes silently: a replaced download and a remote edit whose changes the server has
  not received go to the Trash, and a rename never overwrites.
- For people who build from source: running the unit tests no longer starts the app on your real
  data; the tests use a temporary profile.

## [2.0.0] - 2026-03-07

### Added

- Import an SSH key by pasting it, in addition to choosing a file.
- Simplified Chinese and English interface, with a language setting.

## [1.0.0] - 2026-03-06

First release.

### Added

- Local terminal and SSH sessions in tabs; duplicate a tab; switch tabs with `⌘1`–`⌘9`,
  `⌘[` / `⌘]`.
- Host management with groups, identities and Quick Connect.
- SSH key generation and import; known hosts with host key checking.
- An encrypted local vault (AES-256-GCM) with a master password and a lock screen — no macOS
  Keychain, no iCloud.
- SFTP with a dual-pane file browser.
- Port forwarding rules (local, remote, dynamic) and X11 forwarding.
- Tools: batch command, monitoring, Docker, snippets, and connection history with session
  transcripts.
- 12 terminal colour themes.
- Multiple windows, each with its own state; command palette and keyboard shortcut list.
- CSV import / export of hosts, import of an SSH config file, encrypted local export, database
  backup and restore.
- System notifications for SSH, SFTP and batch events.
- An update check in the app (Sparkle); distribution as a DMG.

[Unreleased]: https://github.com/example/Termi/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/example/Termi/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/example/Termi/releases/tag/v1.0.0
