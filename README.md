# Dal

**A fast, native Git client for macOS** — a commit graph you can read at a glance, line-level staging,
drag-and-drop merges, a conflict resolver, GitHub pull requests, Chrome-style tab groups and
switchable Git identities. Built with SwiftUI on top of the `git` you already have.

*Dal* is Turkish for "branch".

![Dal](docs/screenshot.png)

## Features

- **Commit graph** — lanes, merges and branch tips with avatars; branch/tag column with local ↔ remote
  badges and ahead/behind counts; search by message, author, SHA or branch (`⌘F`, Enter / ⇧Enter to jump).
- **Staging** — stage, unstage or discard whole files, single hunks or **individual lines**
  (click a line, ⇧-click for a range).
- **Commit composer** — summary + description, amend, `⌘↩` to commit, and a line that shows exactly
  which name/email the commit will carry.
- **Branches** — checkout, create, rename, delete, push, set upstream, fast-forward;
  **drag a branch onto another** to merge or rebase.
- **History editing** — merge, rebase, cherry-pick, revert, reset (soft/mixed/hard), tags.
- **Undo / Redo** for commits, checkouts, branch create/delete, merges, rebases, pulls and resets.
- **Conflict resolver** — pick current / incoming / both per conflict, or take a whole side;
  Continue / Abort banner for merges, rebases, cherry-picks and reverts.
- **Stashes, tags, worktrees** in the sidebar.
- **GitHub** (via the [GitHub CLI](https://cli.github.com)) — open pull requests and issues in the sidebar,
  create a PR (pushes the branch first), check out a PR.
- **Tab groups** — keep dozens of repositories open; group them like Chrome tabs (name, colour,
  collapse), and jump anywhere with **`⌘P`**. Only the visible tab watches the disk, so many open tabs stay cheap.
- **Profiles** — switch between Git identities (e.g. Personal / Work) from the tab bar, or pin a
  profile to one repository. A profile sets the commit name/email, the GitHub account (`gh auth login`
  multiple accounts) and an optional SSH key. Dal never edits your `~/.gitconfig`; it passes the identity to
  the commands it runs.
- **Auto-updates** via [Sparkle](https://sparkle-project.org) from GitHub Releases.

## Install

1. Download `Dal-x.y.z.zip` from [Releases](https://github.com/Bur0/dal/releases) and move `Dal.app` to
   `/Applications`.
2. Dal isn't notarized yet, so the first launch needs one of:
   - right-click `Dal.app` → **Open** → **Open**, or
   - `xattr -dr com.apple.quarantine /Applications/Dal.app`

After that, Dal checks for updates daily (or **Dal → Check for Updates…**).

Requires macOS 14 Sonoma or later and Git (Xcode Command Line Tools or Homebrew).
For pull requests/issues, install and log in to the GitHub CLI: `brew install gh && gh auth login`.

Open a repository from the command line: `open -a Dal .`

## Keyboard shortcuts

| | |
|---|---|
| `⌘O` / `⇧⌘O` | Open / clone repository |
| `⌘T` · `⇧⌘W` | New tab · close tab |
| `⌘P` | Go to repository (fuzzy search over open tabs and recents) |
| `⇧⌘]` / `⇧⌘[` | Next / previous tab |
| `⌘F` | Search commits |
| `↑` `↓` | Move through the graph |
| `⌘0` | Show working changes |
| `⇧⌘A` | Stage all |
| `⌘↩` | Commit |
| `⌥⌘F` / `⌥⌘L` / `⌥⌘P` | Fetch / Pull / Push |
| `⌥⌘B` | New branch |
| `⌥⌘S` / `⇧⌥⌘S` | Stash / pop |
| `⌥⌘Z` / `⇧⌥⌘Z` | Undo / redo the last Git action |
| `Esc` | Close the diff |

## Build from source

```bash
brew install xcodegen
git clone https://github.com/Bur0/dal.git && cd dal
scripts/bootstrap.sh          # generates Dal.xcodeproj and opens Xcode
```

Run the tests with `xcodebuild -project Dal.xcodeproj -scheme Dal test`.

### Layout

```
Dal/
  App/      app entry, tabs & groups (AppState), profiles, Sparkle updater
  Git/      git CLI wrapper, parsers, graph lane layout, partial-patch builder, conflict parser
  Store/    RepoStore — one repository's state and every action (checkout, merge, stage…)
  Views/    SwiftUI views
DalTests/   parser, graph, patch and real-git integration tests
scripts/    bootstrap, release, icon generator
```

Dal shells out to `git` and `gh` rather than embedding libgit2, so it behaves exactly like your
command line (hooks, credential helpers, signing, LFS).

## Releasing (maintainers)

```bash
scripts/release.sh 0.2.0 "- What changed"
```

The script bumps the version in `project.yml`, builds a Release app, signs the zip with the Sparkle
EdDSA key from the login keychain, publishes a GitHub release, then adds the entry to `appcast.xml`
(which installed copies poll). Generate the key pair once with Sparkle's `generate_keys` and put the
public key in `project.yml` (`SUPublicEDKey`).

## Privacy

Dal talks to the network only for: your Git remotes, GitHub via `gh`, the update feed on GitHub, and
avatars (an MD5 hash of each author's email is sent to Gravatar; turn it off in Settings).

## License

[MIT](LICENSE)
