# MacSCP

A native macOS SFTP and SCP client with a dual-pane Commander window, based on [WinSCP](https://winscp.net).

[![CI](https://github.com/tomaszkubiak-courses/macscp/actions/workflows/ci.yml/badge.svg)](https://github.com/tomaszkubiak-courses/macscp/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/tomaszkubiak-courses/macscp)](https://github.com/tomaszkubiak-courses/macscp/releases/latest)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)

MacSCP brings WinSCP's way of working to the Mac: local files on the left, the server on the right, a transfer queue below. It is written in Swift with AppKit and SwiftUI, on top of [libssh](https://www.libssh.org).

> **Status: beta.** Version 0.1.0 is the first public release. Please [report problems](https://github.com/tomaszkubiak-courses/macscp/issues).

## Features

- **SFTP and SCP**, including SCP to servers with a BusyBox or BSD userland.
- **Logins:**
  - Password, keyboard-interactive (one-time codes), private keys (with passphrase), ssh-agent and Kerberos (GSSAPI).
  - Saved passwords are kept in the macOS Keychain.
- **Your SSH setup is used as is:** `~/.ssh/config` (host aliases, users, ports, `ProxyJump`) and `~/.ssh/known_hosts`. Unknown or changed host keys are always shown before connecting.
- **Commander window:**
  - Local and remote panes, with sorting, type-to-select, hidden files and a path bar.
  - Sessions open as native window tabs.
  - Folders with 100,000 files open in about two seconds.
- **Transfers:**
  - A background queue with two parallel transfers.
  - Interrupted transfers resume, and dropped connections reconnect automatically.
  - Options: overwrite rules, preserved timestamps, permissions on upload, and WinSCP's file mask syntax (`*.txt; *.log | .git/; >1M`).
- **Safe by default:**
  - Files are written to a temporary `.filepart` file and replace the target only when complete.
  - An overwritten server file keeps its permissions.
  - Local deletions go to the Trash.
- **Remote editing:**
  - Open a server file in TextEdit, VS Code, BBEdit, vim or any other editor. Every save is uploaded.
  - MacSCP asks before overwriting a file that changed on the server in the meantime.
- **Drag and drop:** between the panes, from Finder to upload, and to Finder to download.
- **Get Info** with permission editing, **Quick Look** for local files, and **Open in Terminal** for an `ssh` shell in the current folder.
- **Directory synchronization** (on `main`, in the next release):
  - Compare and sync a local and a remote folder, in either or both directions, with a preview before anything changes.
  - **Keep Remote Folder Up to Date** uploads local changes as you save them.

## Requirements

macOS 14 Sonoma or later, on Apple silicon or Intel.

## Installation

**Download:** get the DMG from the [latest release](https://github.com/tomaszkubiak-courses/macscp/releases/latest), open it, and drag MacSCP to Applications. The app is signed and notarized by Apple.

**Homebrew:**

```sh
brew trust tomaszkubiak-courses/macscp
brew install --cask tomaszkubiak-courses/macscp/macscp
```

Homebrew requires `brew trust` once for any third-party tap.

**Updates:** MacSCP checks for new versions itself, and you can check any time with MacSCP › Check for Updates….

## Getting started

1. Open MacSCP. The Login window lists your saved sites.
2. Enter a host name, then click **Login**. A host alias from `~/.ssh/config` works too. User name, port and key come from your SSH configuration unless you fill them in.
3. Browse with the two panes. To transfer, select files and press ⌘K, or drag them to the other pane.

To edit a server file, select it and press ⌘E. **Files › Edit With…** picks a different editor, and MacSCP remembers the choice for that file type.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New session | ⌘N |
| Open folder or file | Return, ⌘↓ |
| Enclosing folder | Backspace, ⌘↑ |
| Back / Forward | ⌘[ / ⌘] |
| Go to folder | ⇧⌘G |
| Switch pane | Tab |
| Copy to other pane | ⌘K |
| Edit / Edit With… | ⌘E / ⌥⌘E |
| Rename | ⇧⌘R |
| Delete | ⌘⌫ |
| New folder | ⇧⌘N |
| Get Info | ⌘I |
| Quick Look (local) | Space |
| Show hidden files | ⇧⌘. |
| Refresh | ⌘R |
| Show queue | ⌥⌘Q |
| Synchronize | ⇧⌘S |
| Keep remote folder up to date | ⇧⌘U |
| Edited files | ⇧⌘E |
| Open in Terminal | ⇧⌘T |

Coming from WinSCP? Turn on **Commander keys** in Settings for F2 (rename), F4 (edit), F5 (copy), F7 (new folder) and F8 (delete).

## Building from source

You need Xcode 26 or later and [Homebrew](https://brew.sh).

```sh
brew install cmake ninja xcodegen
scripts/build-cssh.sh          # builds libssh and OpenSSL as a universal xcframework (first time only)
swift build                    # the RemoteCore engine
xcodegen                       # generates MacSCP.xcodeproj from project.yml
open MacSCP.xcodeproj          # or: xcodebuild -project MacSCP.xcodeproj -scheme MacSCP build
```

### Tests

Unit tests run with `swift test`. Integration tests need SSH servers; the repository starts throwaway ones on localhost:

```sh
brew install dropbear
scripts/test-servers.sh start  # OpenSSH on 127.0.0.1:2222, Dropbear on 127.0.0.1:2223
MACSCP_INTEGRATION=1 swift test
scripts/test-servers.sh stop
```

CI runs the integration suite against:
- OpenSSH and Dropbear on macOS and Linux, including password logins.
- OpenSSH 7.4, a BusyBox userland and ProFTPD.

### Project layout

| Path | Contents |
| --- | --- |
| `Sources/RemoteCore` | Engine: SSH connection, SFTP and SCP, transfers, queue, synchronization, remote editing, sites. Foundation only; also builds on Linux. |
| `App/Sources` | The macOS app: Commander window, panes, queue, dialogs. |
| `Tests/RemoteCoreTests` | Unit and integration tests. |
| `scripts` | Building libssh, test servers, benchmarks, releases. |

## Roadmap

- **Next:** FTP and FTPS.
- **Then:** Amazon S3.
- **Later:** WebDAV, an internal text editor, importing WinSCP sites and PuTTY keys, and translations.

## Relationship to WinSCP

MacSCP is an independent project. It is not affiliated with or endorsed by WinSCP or its author, Martin Přikryl. WinSCP's source code serves as the reference for MacSCP's behavior. Logic ported from it (listing parser, file masks, transfer options, synchronization rules, SCP protocol handling) keeps the original GPL-3 attribution.

## License

MacSCP is licensed under the [GNU General Public License v3.0](LICENSE).

It includes:
- [libssh](https://www.libssh.org), LGPL-2.1
- [OpenSSL](https://www.openssl.org), Apache-2.0
- [Sparkle](https://sparkle-project.org), MIT
