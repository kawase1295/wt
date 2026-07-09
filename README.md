# wt

A bash CLI that manages git worktrees and [herdr](https://github.com/) workspaces together, letting you spin up parallel development sessions with a single command.

Run `wt new <task>` and it creates a worktree, fills in gitignored files (like `.env`) from the main checkout, opens a herdr workspace, and launches Claude Code — all in one shot. If herdr isn't available, it falls back to plain `git worktree` creation, so herdr is optional.

## Features

- **Unified management** — Consolidates worktree, branch, herdr workspace, and agent launch into one command
- **Missing-file completion** — Symlinks `.env` from the main checkout and copies `.claude/settings.local.json`, so a fresh worktree can run tests immediately
- **Repo-specific setup delegation** — Secrets symlinking, DB copies, native rebuilds, etc. are delegated to the repo's own `scripts/worktree-setup`
- **Graceful fallback** — If the herdr server is unreachable, continues with just `git worktree` creation

## Prerequisites

| Tool | Required | Purpose |
| --- | --- | --- |
| bash 4+ | Yes | Core runtime |
| git | Yes | Worktree operations |
| [herdr](https://github.com/) | Optional | Workspace / agent launch (git worktree only without it) |
| jq | When using herdr | Parsing herdr's JSON output |

## Installation

`wt` is a single file. Just place it in a directory on your PATH.

```bash
git clone https://github.com/kawase1295/wt.git
install -m 755 wt/wt ~/.local/bin/wt   # assumes ~/.local/bin is in PATH
```

You can also use the included `install.sh`:

```bash
./install.sh                # installs to ~/.local/bin/wt by default
PREFIX=~/bin ./install.sh   # change the install location
```

## Usage

Run from anywhere inside the target repository.

```bash
wt new <task> [--base <ref>] [--no-claude]
    Create a worktree at ~/.herdr/worktrees/<repo>/<task>, open a herdr
    workspace, bootstrap, and launch Claude Code (defaults to the main
    checkout's current branch if --base is omitted)

wt bootstrap [<path>]
    Fill in gitignored files missing from an existing worktree.
    Also works with .claude/worktrees/* created by Claude Code

wt open <task>
    Reopen an existing worktree as a herdr workspace

wt list
    Show worktrees and their corresponding herdr workspaces

wt rm <task> [--force]
    Remove worktree / workspace / branch (aborts if there are uncommitted changes)
```

### Examples

```bash
# Create a feature-branch worktree from main and start working
wt new fix-login

# Branch from a specific base, without launching Claude Code
wt new spike-cache --base release/2.0 --no-claude

# Switch to another parallel session
wt open fix-login

# List active sessions
wt list

# Clean up a finished worktree (also deletes the merged branch)
wt rm fix-login
```

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `WT_HOME` | `~/.herdr/worktrees` | Root directory for worktrees |
| `WT_LANG` | `en` | UI language (`en` or `ja`) |

Set `WT_LANG=ja` in your shell profile to switch all messages to Japanese.

```bash
export WT_LANG=ja
```

Worktrees are created at herdr's standard location `~/.herdr/worktrees/<repo>/<task>`. Override with the `WT_HOME` environment variable.

## How It Works

### Bootstrap responsibilities

A fresh worktree lacks gitignored files from the main checkout, which can break tests or the app. `wt` fills these in with a two-stage approach:

**Common steps (handled by `wt` itself)**

1. Symlink `.env` from the main checkout into the worktree (skipped if a real file already exists)
2. Copy `.claude/settings.local.json` (carries over Claude Code permission settings)
3. If a repo hook exists, delegate to it; otherwise, detect the package manager from lockfiles and install dependencies
   (supports npm / pnpm / yarn / bun / uv)

**Repo-specific steps (repo's `scripts/worktree-setup`, must be executable)**

Anything beyond simple file copying — dependency installation, secrets symlinking, native rebuilds — goes in the repo's own hook. The hook runs with:

- cwd = the worktree
- `WT_MAIN_ROOT` = absolute path to the main checkout
- `WT_TARGET` = absolute path to the worktree

When the hook exists, dependency installation becomes the hook's responsibility (`wt` won't run install).

### Repo hook example

```bash
#!/usr/bin/env bash
# scripts/worktree-setup — fill in repo-specific missing files for the worktree
set -euo pipefail

# Symlink gitignored secrets from the main checkout
ln -sfn "$WT_MAIN_ROOT/secrets" "$WT_TARGET/secrets"

# Install dependencies (wt skips install when a hook exists, so do it here)
npm ci --prefer-offline --no-audit --no-fund

# Rebuild native addons if needed
# npm rebuild better-sqlite3 --ignore-scripts=false --foreground-scripts
```

## Claude Code Integration

For parallel development with Claude Code, see [`docs/claude-code-skill.md`](docs/claude-code-skill.md) for guidance on when to use `wt` vs. native worktrees (`claude --worktree` / subagent isolation). The file can also be used directly as a Claude Code skill (`~/.claude/skills/`).

## Known Caveats

- If `~/.npmrc` has `ignore-scripts=true`, `npm ci` alone won't build native addons (e.g. better-sqlite3). Use the hook to rebuild, or copy the prebuilt `.node` files from the main checkout.
- Uncommitted changes in the main checkout don't carry over to worktrees (worktrees branch from a committed ref).
- When gitignoring shared directories, symlinks won't match trailing-slash patterns (`secrets/`). Use `secrets` instead.

## License

[MIT](LICENSE)
