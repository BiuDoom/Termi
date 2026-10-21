# Testing Termi

Three things, from fastest to closest to real use:

1. [Unit tests](#unit-tests) — hermetic, run anywhere.
2. [The test environment](#the-test-environment) — SSH servers in Docker and an app profile
   seeded with hosts for them, rebuilt from this repository with one command.
3. [Launch arguments](#debug-launch-arguments) — open a Debug build directly on a page or a
   state, for screenshots and checks without driving the interface.

One rule covers all of them:

> **Nothing is ever tested on the real profile.** The real profile is
> `~/Library/Application Support/Termi` plus the preferences domain `dev.termi.Termi`. A plain
> `open Termi.app`, or the binary started without `TERMI_PROFILE_DIR`, *is* the real profile.
> Tests, screenshots, acceptance runs and experiments use an
> [isolated profile](#isolated-profiles). Test hosts are never typed into the real one.

---

## Unit tests

```bash
xcodebuild test -project Termi.xcodeproj -scheme Termi -destination 'platform=macOS'
```

The tests are hosted in the app (they are injected into `Termi.app`), and they are hermetic.
That is guaranteed in one place, `Termi/App/AppProfile.swift`:

- A process that hosts a test run (xcodebuild sets `XCTestConfigurationFilePath`,
  `XCTestBundlePath` or `XCTestSessionIdentifier`) gets the **tests** profile: a fresh folder
  `$TMPDIR/Termi-Tests/<pid>` for the database, the vault key, session logs, sync and backups,
  and a preferences file inside that folder. The folder is removed when the process exits.
- In that process the app is only a bare `NSApplication` (`Termi/App/main.swift`): no scenes,
  no windows, no app delegate, no updater, no network monitor, no database opened by the host.
- `UserDefaults.standard` itself is redirected to the profile's preferences, so AppKit and
  libraries cannot write the real domain either.
- This precedes everything else: a test run stays in the tests profile even when
  `TERMI_PROFILE_DIR` is set.

`TermiTests/AppProfileTests.swift` checks both the pure resolver and that the running test
process really is in the tests profile.

When writing tests:

- Never build a path under Application Support and never use another `UserDefaults` domain: ask
  `AppProfile.current`, `AppProfile.defaults`, `AppProfile.arguments`.
- Tests that use `DatabaseManager.shared` or a `*Repository.shared` share one database for the
  whole test process and run in parallel: use your own rows, do not assert on whole tables.
- The same sources must compile with Swift 6.0 (the Xcode 16.2 job in CI): no enum pattern
  matching and no arithmetic inside `#expect` / `#require` — compute into a typed `let` first;
  file-level `@Test` function names are unique across all test files.
- Only one hosted test run at a time on one Mac.

---

## The test environment

Acceptance testing needs SSH servers that take a password, keys, an agent key and
keyboard-interactive prompts, a jump host, and a host that can only be reached through it.
`TestEnvironment/` holds everything needed to build them; nothing about them lives outside the
repository except the secrets, which are generated on your machine.

Requirements: Docker (Docker Desktop, OrbStack or colima) and Xcode.

```bash
make test-env-up        # generate secrets, build the image, start three containers
make run-isolated       # build the Debug app and open it on the test profile, hosts seeded
make test-env-status    # what is running, which ports, whether .test-env/ exists
make test-env-down      # remove the three containers and the network; keeps .test-env/
```

### What `up` starts

| Container | Listens on | What it is for |
|---|---|---|
| `termi-test-a` | `127.0.0.1:2222` | password and public-key authentication, SFTP, port forwarding (`http://127.0.0.1:8080` inside answers `termi-forward-ok`) |
| `termi-test-a` | `127.0.0.1:2224` | keyboard-interactive **only** — the app's prompt for it |
| `termi-test-jump` | `127.0.0.1:2223` | a jump host |
| `termi-test-inner` | no published port | `inner:22`, reachable only through the jump host |

All ports are bound to `127.0.0.1`, never to `0.0.0.0`. The user is `tester` everywhere. The
image is `termi-test-env-sshd:local` (Ubuntu 24.04 with OpenSSH, built from
`TestEnvironment/image/`); the network is `termi-test-env`. Running `up` twice is harmless:
existing secrets are kept, running containers are left alone, stopped ones are started again.
After changing something in `TestEnvironment/image/`, run `down` and then `up` to get containers
from the new image.

`up` starts everything or nothing. It refuses, before anything is started, when one of the
three ports is already in use by another program (it names the port), and when containers with
these names were started from another checkout of the repository — their password and keys are
that checkout's, not the ones in this `.test-env/`; run `down` first. When a server does not
answer within 30 seconds, what this `up` started is removed again.

### What `up` generates

Everything secret goes to `.test-env/` at the repository root — git-ignored, mode 0700, files
0600 — and is never printed or committed:

| In `.test-env/` | What |
|---|---|
| `tester_password` | random password of `tester` on every server |
| `id_plain`, `id_passphrase`, `id_agent` (+ `.pub`) | key pairs the servers accept; `id_passphrase` is encrypted |
| `key_passphrase` | the passphrase of `id_passphrase` |
| `hostkeys/<server>/` | each server's host key, so that it stays the same across `down` / `up` |
| `seed-hosts.json` | the hosts the app is seeded with, naming the files above |
| `ssh_config`, `known_hosts` | for plain `ssh` to the servers without touching `~/.ssh` |
| `profile/` | the app's isolated profile for this environment |

The containers get read-only mounts of the password, `authorized_keys` and their own host key.
The private client keys and the passphrase are never mounted.

### The hosts in the app

`make run-isolated` starts the Debug app with
`-debugSeedHosts .test-env/seed-hosts.json` (written from
`TestEnvironment/seed-hosts.template.json`). The seed creates or updates these hosts, keyed by
label, through the same repositories and vault the forms use:

| Host | Goes to | Authentication | Checks |
|---|---|---|---|
| `test-a` | `127.0.0.1:2222` | key `id_plain` from the vault | key authentication, the everyday host for SFTP, split panes, forwarding |
| `test-pass` | `127.0.0.1:2222` | key `id_passphrase`, passphrase saved in the vault | an encrypted key |
| `test-pw` | `127.0.0.1:2222` | password saved in the vault; a startup snippet | password authentication, startup snippets |
| `test-agent` | `127.0.0.1:2222` | the system SSH agent | agent authentication (add the key first, see below) |
| `test-kbd` | `127.0.0.1:2224` | nothing saved | the keyboard-interactive prompt; answer with the content of `.test-env/tester_password` |
| `jump` | `127.0.0.1:2223` | key `id_plain` | a jump host with its own credentials |
| `inner` | `inner:22` through `jump` | password saved in the vault | a jump chain, each hop with its own credentials |

Every seeded host is pinned to its server's generated host key (`hostKeyFile`), so there is no
"trust this host?" prompt and a changed key means what it should. To see the first-connection
prompt, remove the host under Known Hosts in the test profile.

The seed decides the whole host: a password saved by hand on `test-kbd`, for instance, is
removed by the next seeded launch. The seed runs once per launch, when the first window opens;
further windows do not seed again. What it does is written to `.test-env/profile/debug-seed.log`.

#### The agent key

`test-agent` uses whatever agent the app inherits (`SSH_AUTH_SOCK`). Add the test key with a
lifetime, and take it out again when you are done:

```bash
ssh-add -t 1h .test-env/id_agent
ssh-add -d .test-env/id_agent
```

`make test-env-status` says whether the agent holds it.

#### The servers without the app

```bash
ssh -F .test-env/ssh_config test-a        # also: jump, inner (through jump), test-kbd
```

That configuration uses `id_plain` and its own `known_hosts`; `~/.ssh` is not read or written.

### The seed file

`-debugSeedHosts <path to a JSON file>` exists in Debug builds only
(`Termi/App/DebugSeed.swift`) and **refuses to run in the standard profile**: it only seeds an
isolated profile or a test run.

```json
{
  "hosts": [
    {
      "label": "inner",
      "address": "inner",
      "port": 22,
      "user": "tester",
      "auth": { "type": "password", "passwordFile": "/abs/path/tester_password" },
      "jump": "jump",
      "hostKeyFile": "/abs/path/ssh_host_ed25519_key.pub",
      "startupSnippet": { "name": "where am I", "command": "hostname" }
    }
  ]
}
```

- `auth.type`: `agent`; `password` (`passwordFile` optional — without it nothing is saved and
  the app asks); `key` (`keyFile`, optional `passphraseFile`, optional `keyName` — the name in
  the key vault, by default the host's label; hosts that give the same `keyName` share one key).
- `jump` is the label of another host in the file, in any order. `port` defaults to 22, `user`
  to empty (inherited). `hostKeyFile`, `jump` and `startupSnippet` are optional.
- Paths are absolute, or relative to the folder of the JSON file. A secret's file loses one
  trailing line break, nothing else.
- Hosts are keyed by label, keys and snippets by name: seeding twice changes nothing. Hosts
  that are not in the file are left alone.
- The file is checked completely before anything is written (duplicate labels, an unknown jump
  host, a loop of jump hosts, a port that is not one, an unknown `auth.type`).

### Known limits

- A **new** profile must be opened once while the Mac's screen is unlocked. The app creates the
  profile's vault key with complete file protection, and macOS refuses to create such a file
  while the screen is locked; the seed then stops and `debug-seed.log` ends with a line
  `FAILED:` that names `.vault-key`. Once the key exists, the profile also works from a locked screen.
- `down` removes the three containers by name and the network if this script created it. It
  never removes `.test-env/` or the image. To start completely fresh, move `.test-env/` away
  yourself after `down`.

---

## Isolated profiles

```bash
open -n --env TERMI_PROFILE_DIR=/absolute/folder Termi.app
```

`TERMI_PROFILE_DIR` works like a browser's `--user-data-dir`: everything the run keeps is
inside that folder, and deleting the folder leaves nothing behind.

| In the folder | What |
|---|---|
| `termi.db` (+ `-wal`, `-shm`) | hosts, groups, keys, identities, snippets, known hosts, history, the encrypted vault |
| `.vault-key` | the key the vault is encrypted with while no master password is set |
| `SessionLogs/` | terminal transcripts |
| `Preferences.plist` | every preference, including what AppKit stores (window frames, toolbar state) |
| `sync/`, `Backups/` | encrypted exports and the suggested backup folder |

The value must be an absolute folder. The app **refuses to start** — it never falls back to the
real profile — when the value is empty, relative, `/`, or names the real profile folder or
anything inside it (also through a symbolic link or another spelling of the path).

To see what a run would use without starting it (Debug builds; creates nothing):

```bash
TERMI_PROFILE_DIR=/absolute/folder Termi.app/Contents/MacOS/Termi -debugPrintProfile YES
```

It prints the kind (`standard`, `isolated` or `tests`) and every location. `kind: standard` is
the warning that a command line would have touched real data.

Each profile has its own master password. Passwords and keys saved in one profile cannot be
read from another.

---

## Debug launch arguments

Debug builds read `-name value` pairs from the command line (through `AppProfile.arguments`;
they are never stored). They exist so that a page or a state can be opened without clicking —
for screenshots, and for checks while the screen is locked. None of them exists in a Release
build. Combine them freely:

```bash
open -n --env TERMI_PROFILE_DIR="$PWD/.test-env/profile" Termi.app --args \
    -debugSeedHosts "$PWD/.test-env/seed-hosts.json" \
    -debugPage sftp -debugSFTPHost test-a -debugAppearance Dark -debugWindowSize 1200x800
```

Hosts are named by their label; the defaults some arguments fall back to (`test-a`,
`test-agent`) are the labels of the test environment.

### Profile and data

| Argument | Effect |
|---|---|
| `-debugPrintProfile YES` | print the profile this run would use and exit |
| `-debugSeedHosts <file>` | create or update the hosts in the file (isolated profile or test run only) |

### Window

| Argument | Effect |
|---|---|
| `-debugPage <page>` | open on a page: `terminal` (Hosts), `sftp`, `keys`, `knownHosts`, `identities`, `snippets`, `batchCommand`, `monitoring`, `docker`, `portForwards`, `logs`, `settings` |
| `-debugSheet <name>` | `quickConnect`, `palette`, `shortcuts`, `settings`, `lock`, `gallery`; or a sheet on its own: `hostForm`, `hostFormEdit`, `groupForm`, `portForwardForm`, `portForwardPicker`, `identityForm`, `keyGenerate`, `keyImport`, `keyInstall`, `snippetForm`, `masterPassword`, `transcript`, `containerLogs` |
| `-debugAppearance Light\|Dark` | appearance for this run, not saved |
| `-debugWindowSize 900x600` | content size of the window |
| `-debugActive YES` | draw the window as the active one (a window captured while the screen is locked, or behind another app, is otherwise drawn greyed) |
| `-debugDumpWindow <file>` | write the window's frame, minimum size and split view layout to a file |
| `-debugGalleryPage 1…5`, `-debugGalleryScroll <points>` | with `-debugSheet gallery`: which page of the shared components |
| `-settingsSelectedTab <tab>` | with `-debugSheet settings`: which tab (`terminal`, `backup`, …) |

### Sessions and terminal

| Argument | Effect |
|---|---|
| `-debugConnect a,b,local` | open a tab per host label (or `user@host`); `local` is a local shell |
| `-debugSplit <n>` | split the last tab n times |
| `-debugBroadcast YES` | turn broadcast input on |
| `-debugSnippets YES` | open the snippets inspector |
| `-debugSessionState connecting\|reconnecting\|failed\|ended` | show a pane's state card without that state happening |
| `-debugSampleForwards YES` | two sample forwarding rules in the Info inspector |
| `-debugLeaveTerminal YES` | once the sessions of `-debugConnect` are up, go to the page given by `-debugPage` |

### Hosts

| Argument | Effect |
|---|---|
| `-debugHostSelect <label>` | select a host (its card is outlined; the details panel stays closed) |
| `-debugHostDetails <label>` | select a host and open its details panel |
| `-debugHostHover <label>` | draw that host's card (or row) as with the pointer on it: the details button shows |
| `-hostsLayout grid\|list` | the cards or the list for this run (the stored preference is not changed) |
| `-debugHostEdit <label>` | open a host's form |
| `-debugHostsOnline YES` | turn the "online" filter on |
| `-debugHostsAfterConnect YES` | return to the hosts page once `-debugConnect` has opened its sessions |
| `-debugQuickConnectText user@host:port` | Quick Connect with an address typed |
| `-debugPaletteQuery <text>` | the command palette with a query typed |

### SFTP

| Argument | Effect |
|---|---|
| `-debugSFTP <label>` | open SFTP for a host from the window |
| `-debugSFTPHost <label>` | connect the SFTP page to a host |
| `-debugSFTPPath <folder>`, `-debugSFTPLocalPath <folder>` | the remote and the local folder to show |
| `-debugSFTPSelect <name>` | select a remote row |
| `-debugSFTPTransfers YES` | a sample running and a finished transfer in the bar (nothing is transferred) |
| `-debugSFTPState connecting\|failed` | the connection card in that state |

### Vault pages

| Argument | Effect |
|---|---|
| `-debugVaultSelect <name>` | select a key (by name), an identity (by name) or a known host (`address:port`) on its page |
| `-debugVaultEdit YES` | with an identity selected: open its form |
| `-debugVaultSample YES` | sample identities on the Identities page (not written) |
| `-debugHostKeyPrompt new\|changed` | the host key prompt on the Known Hosts page |

### Tools

| Argument | Effect |
|---|---|
| `-debugSnippet <name>` | select a snippet |
| `-debugSnippetSessions local,<label>` | open sessions behind the Snippets page so that "Run In" has rows |
| `-debugSnippetValues name=world,lines=200` | values for a snippet's variables |
| `-debugBatchSample host\|output` | made-up batch results, by host or by output, without connecting |
| `-debugBatchRun <command>`, `-debugBatchHosts a,b` | really run a command on those hosts (default `test-agent`) |
| `-debugMonitorHost <label>` | select a host on the Monitoring page and turn auto refresh on |
| `-debugMonitorHistory YES` | five minutes of made-up readings before the real ones |
| `-debugDockerSample <label>` | sample containers on that host (the test servers run no Docker) |
| `-debugDockerHost <label>` | really ask that host |
| `-debugPortForwards running\|empty` | sample rule states, or the page without rules (nothing is started or deleted) |
| `-debugLogsSelect timed\|failed` | in History, select the newest record that has a duration / that failed |

### Lock screen and Settings

| Argument | Effect |
|---|---|
| `-debugLockSessions <n>` | the "n sessions stay connected" line without connecting anything |
| `-debugLockTyped YES` | the password field with something typed (nothing is submitted) |
| `-debugLockCaps YES` | the Caps Lock notice |
| `-debugBackupSample YES` | Settings › Backup with sample backups (nothing is written) |

The arguments are implemented next to what they open: `applyDebugLaunchArguments` in
`Termi/Views/MainWindow/WindowRootView.swift`, and the `#if DEBUG` blocks of the pages and view
models. When you add one, add it to this list.

## Localization check

The interface is written with English keys and translated to Simplified Chinese in
`Termi/Localizable.xcstrings`. The app target is built with `SWIFT_EMIT_LOC_STRINGS` (see
`project.yml`), so the compiler writes down every localizable string it sees.

```bash
make check-strings
```

builds the Debug configuration and compares those strings with the catalog
(`scripts/check-strings.py`):

- **missing** — a string the code shows that has no zh-Hans translation. This fails the check, and
  CI runs it on every push.
- **stale** — a catalog entry no source uses any more. Reported; remove such entries with
  `python3 scripts/check-strings.py Termi/Localizable.xcstrings build/DerivedData-Debug Termi --prune`
  (a text edit of the catalog: nothing is reordered).

A key that is only reached through a variable (an enum's raw value, a name kept in a model and
localized when shown) counts as used as long as its text is a string literal somewhere in the
sources. Add new strings to the catalog in Xcode, or from the command line with
`python3 scripts/add-strings.py Termi/Localizable.xcstrings <list.json>` (a JSON list of
`{"key", "zh"}`, plus `enOne` / `enOther` for keys that count something — it inserts the entries as
text and never rewrites the file); never leave one untranslated.
