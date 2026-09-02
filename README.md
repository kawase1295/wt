# wt

> One command: git worktree + [herdr](https://herdr.dev) workspace + Claude Code session.

[![ci](https://github.com/kawase1295/wt/actions/workflows/ci.yml/badge.svg)](https://github.com/kawase1295/wt/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![shell](https://img.shields.io/badge/shell-bash-lightgrey.svg)](wt)

**Languages: English | [日本語](README.ja.md)**

`wt` is a single-file bash CLI that manages a git worktree, its branch, a [herdr](https://herdr.dev) workspace, and a Claude Code agent as one unit, so you can spin up a parallel development session in one command.

`wt new <task>` creates the worktree, backfills the gitignored files a fresh checkout is missing (`.env` and friends), opens a herdr workspace, and launches Claude Code in it. `--prompt` hands the new session an initial prompt (the task description or an implementation plan). Without herdr it falls back to a plain `git worktree add`, so herdr is optional.

## Features

- **One unit** — worktree, branch, herdr workspace, and agent launch behind a single command
- **Backfills missing files** — copies the gitignored files listed in `.worktreeinclude`, symlinks the main checkout's `.env`, copies `.claude/settings.local.json`. Fixes the "tests don't run in a fresh worktree" problem
- **Hands work off** — `--prompt` / `--prompt-file` pass an initial prompt to the worktree's Claude Code session. Slash-command skills such as `/wt` ship with the repo
- **Cross-session chat** — the worktree session and the dev session talk to each other directly. `wt new` pins the worktree session name to `wt-<task>`, and `wt peers` lists the addresses
- **Repo-specific setup stays in the repo** — DB copies, native rebuilds and the like are delegated to the repo's own `scripts/worktree-setup` hook
- **Pre-merge gate** — runs the repo's `scripts/check` in the worktree before merging and refuses to merge on failure. Same entry point your CI calls
- **Approve from the review page** — `/wt-review` serves the page off a throwaway `127.0.0.1` HTTP server, so its 「承認してマージ」 (approve and merge) button lands the approval in the worktree session as *your* own input — no switching back to the terminal. Without herdr or python3 it falls back to `file://` with the button hidden
- **GitHub issue / PR integration (skills)** — `/wt` files an issue and ties its number into the worktree name and the initial prompt; `/wt-merge` opens a PR with `Fixes #N` and, once the `/wt-review` approval gate has passed, waits for CI and merges it. Task = issue = branch = PR, one-to-one. Repos without a remote keep the plain local merge
- **Guards the main checkout (hook)** — a `PreToolUse` hook asks for confirmation when something tries to branch off and work directly in the main checkout. Work that bypasses a worktree is stopped by a pre-execution check on Bash, not by prose in a skill (plugin only)
- **Graceful fallback** — if the herdr server is unreachable, it just creates the git worktree and carries on

## Requirements

| Tool | Required | Used for |
| --- | --- | --- |
| bash 4+ | yes | the CLI itself |
| git | yes | worktree operations |
| [herdr](https://herdr.dev) | optional | workspace / agent launch (without it, git worktree only). Verified against herdr 0.8 (socket API protocol 19), which the `worktree` and `agent start` calls target |
| jq | when using herdr, and for `wt peers` | parsing herdr JSON output and the Claude Code session registry |
| python3 | for `/wt-review` | `skills/wt-review/assets/render.py` builds the review page, `wt-review-serve.py` serves it and turns the approve button into a herdr prompt (standard library only) |
| curl | for mermaid diagrams in a review page | fetching `mermaid.min.js` once into `~/.cache/wt/` |
| [gh](https://cli.github.com/) | optional | GitHub issue / PR integration (`/wt` files issues, `/wt-merge` opens PRs, `/wt-clean` verifies the PR merged). Without it, the plain local flow |

## Install

### From the plugin marketplace (Claude Code)

This repository is also a Claude Code plugin marketplace, so `/plugin` installs the CLI and the skills in one step.

```
/plugin marketplace add kawase1295/wt
/plugin install wt@wt
```

The plugin puts `wt` on the Bash tool's `PATH` and registers the skills under the plugin's namespace, so you invoke them as `/wt:wt`, `/wt:wt-review` and so on.

How later changes reach you depends on how the marketplace was added:

- **GitHub source** (`/plugin marketplace add kawase1295/wt`) — the commit is snapshotted into `~/.claude/plugins/cache/`. Run `/plugin marketplace update wt` to move to a newer one.
- **Local directory source** (`/plugin marketplace add /path/to/wt`, handy while developing) — the plugin root resolves to that checkout, so the CLI and the skills track it live. Nothing to update; a new session picks up whatever is committed there.

Three things to know:

- **Your own shell won't see `wt`.** That `PATH` entry belongs to Claude Code's Bash tool. You can install the binary manually as well (below) to type `wt` in a terminal — but read the next point first.
- **A manual copy always beats the plugin's.** The plugin's `bin/` is appended at the *end* of the Bash tool's `PATH`, so a `~/.local/bin/wt` left by `install.sh` wins every lookup. If it is older than the plugin's, Claude Code silently keeps running the stale CLI — and you find out the day an upstream dependency changes its interface and `wt new` stops working. Either keep the manual copy deliberately in sync, or go plugin-only and delete it.
- **It won't clean up after `install.sh`.** Skills already sitting in `~/.claude/skills/` keep loading next to the plugin's copies, so you get two of each. Pick one route: either delete the wt skills from `~/.claude/skills/`, or don't install the plugin.

### Manually

`wt` is a single file. Drop it anywhere on your `PATH`, with `wt-review-serve.py` — the review page's throwaway HTTP server, launched by `wt serve` — next to it.

```bash
git clone https://github.com/kawase1295/wt.git
install -m 755 wt/wt ~/.local/bin/wt   # assumes ~/.local/bin is on PATH
install -m 755 wt/wt-review-serve.py ~/.local/bin/wt-review-serve.py
```

`wt` looks for the server as its own sibling. Leave it out and `wt serve` refuses to start, which only costs you the approve button: `/wt-review` falls back to `file://`.

The bundled `install.sh` also installs the Claude Code skills (see below) into `~/.claude/skills/`.

```bash
./install.sh                     # -> ~/.local/bin/wt and ~/.claude/skills/
PREFIX=~/bin ./install.sh        # change the binary destination
WT_SKILLS_DIR=~/.claude/skills ./install.sh  # change the skill destination
WT_INSTALL_SKILLS=0 ./install.sh # skip the skills
```

Skills are owned by `wt`: every install recreates each skill directory, so files dropped upstream do not linger — and neither do local edits. If you have edited them locally, protect them with `WT_INSTALL_SKILLS=0`.

The [branch-switch guard](#guarding-the-main-checkout-hook) is loaded through the plugin mechanism only. `install.sh` stops at the skills, so a manual install leaves the hook inactive.

## Usage

Run it from anywhere inside the target repository.

```bash
wt new <task> [--base <ref>] [--no-claude] [--prompt <text>|--prompt-file <path>]
    Create a worktree at <repo>/.claude/worktrees/<task> on branch worktree-<task>,
    open a herdr workspace, bootstrap it, and launch Claude Code
    (base defaults to the main checkout's current branch).
    --prompt / --prompt-file is the initial prompt for the launched Claude (needs herdr).
    The prompt is submitted after launch via herdr agent prompt rather than as a
    startup argv, so multi-line prompts arrive intact as a single turn.
    A body whose first non-space character is / ! # or @ is rejected: Claude Code
    would read it as a slash command / bash / memory / file mention.
    claude is invoked with --model opus --permission-mode auto by default
    (override via WT_CLAUDE_ARGS; empty string means no flags; values containing
    spaces are not supported)

wt bootstrap [<path>]
    Backfill the gitignored files a worktree did not inherit.
    Works on the .claude/worktrees/* that Claude Code creates natively, too

wt open <task>
    Reopen an existing worktree as a herdr workspace

wt browse <path|url>
    Open a local file with the platform's default handler — WSL's explorer.exe,
    macOS's open, Linux's xdg-open. Takes http(s) URLs too (for what wt serve
    prints); on WSL those go through rundll32's FileProtocolHandler, since
    explorer.exe cannot open a URL. The skills use it to show the HTML they
    generate; it fails with the path printed when no handler is available

wt serve <path> [--task <task>] / wt serve --stop [--task <task>]
    Serve a review page from a throwaway HTTP server bound to a free port on
    127.0.0.1 and print the URL (with ?token=...) on stdout. The page's approve
    button POSTs back and the server turns that into
    `herdr agent prompt claude-<task>`, delivering the approval to the worktree
    session as your own input, then exits. The HTML is re-read per request, so a
    re-review only needs a browser reload. Omit --task inside a worktree to
    infer it from the branch. Without herdr it refuses to start, and the caller
    (/wt-review) falls back to file://

wt list
    List worktrees and their herdr workspaces

wt peers [--json]
    List this repo's Claude Code sessions (main checkout and every worktree).
    The NAME column is the address for cross-session messages (SendMessage);
    (self) marks your own session. Worktree sessions carry the fixed name
    wt-<task> assigned by wt new

wt merge [<task>] [--no-check]
    Merge branch worktree-<task> into the main checkout's current branch.
    Inside a worktree, omit task to target yourself. Conflicts are left in the
    main checkout and abort the command.
    If the worktree has an executable scripts/check, it runs before the merge
    and a failure blocks it (skip with --no-check)

wt rm [<task>] [--force]
    Remove the worktree, workspace and branch (aborts on uncommitted changes).
    Inside a worktree, omit task to clean up after yourself
```

### Examples

```bash
# branch off main and start working
wt new fix-login

# launch the worktree's Claude Code with an initial prompt
wt new fix-login --prompt "Add retry on login failure. Commit when you are done."

# pass an implementation plan as a file (for long, multi-line prompts)
wt new fix-login --prompt-file /tmp/plan.md

# branch off a specific base, don't launch Claude Code
wt new spike-cache --base release/2.0 --no-claude

# switch to another parallel task / see what is in flight
wt open fix-login
wt list

# find the address of the session on the other side (dev <-> worktree)
wt peers

# from inside the worktree: land the work, then clean yourself up
wt merge   # runs scripts/check if present, then merges into the main branch
wt rm      # removes worktree / workspace / branch and closes the workspace
```

Worktrees are created at `<repo>/.claude/worktrees/<task>` on branch `worktree-<task>` — the same location and naming Claude Code's native worktrees use. Because they point at the same thing, worktrees created natively (`claude --worktree`) can be handled with `wt open` / `wt bootstrap` / `wt rm`. Set `WT_HOME` to use the older central layout `$WT_HOME/<repo>/<task>` instead.

## How it works

### Who backfills what

A fresh worktree has none of the main checkout's gitignored files, which is why tests and apps often fail in it. `wt` backfills in two layers.

**Shared logic (`wt` itself)**

1. Copies the gitignored files listed in `.worktreeinclude` (repo root, must be committed, gitignore syntax) from the main checkout — existing files are never overwritten
2. Symlinks the main checkout's `.env` into the worktree (skipped if a real file is already there; a `.env` entry in `.worktreeinclude` wins, since the copy happens first)
3. Copies `.claude/settings.local.json` (carries over Claude Code permissions)
4. Delegates to the repo hook if there is one; otherwise, when `node_modules` is absent, installs dependencies with the package manager detected from the lockfile (npm / pnpm / yarn / bun / uv)

**Repo-specific logic (the repo's `scripts/worktree-setup`, executable)**

Anything a file copy cannot express — dependency installs, regenerating environment symlinks, native rebuilds — belongs to the repo. The hook is invoked with:

- cwd = the worktree
- `WT_MAIN_ROOT` = absolute path of the main checkout
- `WT_TARGET` = absolute path of the worktree

When the hook exists, installing dependencies is its job too (`wt` will not do it).

### Repo hook example

```bash
#!/usr/bin/env bash
# scripts/worktree-setup — backfill repo-specific gaps in a worktree
set -euo pipefail

# share gitignored secrets from the main checkout via symlink
ln -sfn "$WT_MAIN_ROOT/secrets" "$WT_TARGET/secrets"

# install dependencies (wt skips this when a hook exists, so do it yourself)
npm ci --prefer-offline --no-audit --no-fund

# rebuild native addons if you have any
# npm rebuild better-sqlite3 --ignore-scripts=false --foreground-scripts
```

### Pre-merge check (`scripts/check`)

Right before merging, `wt merge` runs the worktree's `scripts/check` (executable, cwd = the worktree) and refuses to merge on a non-zero exit. Consolidate your merge conditions — tests, type checks, lint — into that one script.

- Repos without `scripts/check` get a warning and the merge proceeds (adopt it gradually)
- `--no-check` skips it
- The check runs against the working tree, so it sees uncommitted changes as well (those are not part of the merge; `wt merge` warns about them)
- Calling the same `scripts/check` from CI (GitHub Actions or otherwise) keeps the local gate and CI in sync. This repo's own [.github/workflows/ci.yml](.github/workflows/ci.yml) and [scripts/check](scripts/check) are a working example

```bash
#!/usr/bin/env bash
# scripts/check — everything that must pass before a merge (TypeScript repo example)
set -euo pipefail
npx tsc --noEmit
npm test
```

## Claude Code integration

[`skills/`](skills/) ships 8 skills, installed into `~/.claude/skills/` by `install.sh` or supplied by the [plugin](#from-the-plugin-marketplace-claude-code) (where they are namespaced: `/wt:wt-review`). They let a session in the dev (main) checkout throw work at a worktree, and let the worktree session review, land and clean up on its own. The two sides can talk while the work is in flight.

A skill is not always a lone `SKILL.md`. `/wt-review` bundles the review page's HTML template and its renderer under [`skills/wt-review/assets/`](skills/wt-review/assets/), which is why `install.sh` copies each skill directory whole.

| Skill | Runs on | Role |
| --- | --- | --- |
| `/wt <task description>` | dev | Derives a worktree name and launches the worktree + Claude Code with the description as the initial prompt. On GitHub repos it files an issue first (`/wt #123` reuses an existing one) and ties the number into the name and the prompt |
| `/wt-detail <task description>` | dev | Explores the codebase, asks you about anything underspecified, builds an implementation plan, and passes it to the worktree as the initial prompt. On GitHub repos it files an issue once the plan is settled and records the full plan there |
| `/wt-review` | worktree | Fills the bundled page template from the diff with `assets/render.py`, serves it over `wt serve` (approve button) or `file://`, opens it in the browser, and waits for approval before merging |
| `/wt-merge` | worktree | On GitHub repos: `scripts/check` → push → open a PR with `Fixes #N` → if the approval gate has passed, wait for CI, `gh pr merge --merge`, and delete the remote branch (without it, stops at the PR). Without a remote: merges its own branch into the main checkout's current branch (reports conflicts and stops) |
| `/wt-clean` | worktree | Verifies nothing is uncommitted and the work has landed (PR merged, or merged into the main checkout), then removes its own worktree and closes the workspace |
| `/wt-ask <message>` | both | Resolves the other session's address via `wt peers`, sends a question or status report, and waits for the reply |
| `worktree-parallel` | both | Policy for choosing between `wt` and native worktrees, plus the `.worktreeinclude` contract ([skills/worktree-parallel/SKILL.md](skills/worktree-parallel/SKILL.md)) |
| `local-artifact` | both | Contract for building HTML with the same design rules as Artifacts but publishing locally instead of to claude.ai. `/wt-review` no longer loads it — its template already carries the skeleton, theme toggle and mermaid |

A typical flow (GitHub repo):

```
dev:      /wt fix validation on the login screen
           -> issue #42 filed; worktree + workspace open, Claude starts with the issue body
worktree: (implement, commit) -> /wt-review -> (you review and approve) -> /wt-merge
           -> PR opened (Fixes #42) -> waits for CI (scripts/check) -> gh pr merge
           -> /wt-clean -> worktree, workspace and branch disappear
```

Task = issue = branch (`worktree-42-fix-login-validation`) = PR, one-to-one, and merging the PR closes the issue. The `/wt-review` approval gate is where the merge decision actually happens, so a session that passed it merges the PR itself; a session that did not stops at the open PR and waits for you. On repos without a GitHub remote (or without `gh`), the issue / PR steps drop out and `/wt-merge` becomes a local merge into the main checkout's current branch:

```
worktree: (implement, commit) -> /wt-review -> (you review and approve) -> /wt-merge -> /wt-clean
           -> work lands on the main branch; worktree, workspace and branch disappear
```

### Guarding the main checkout (hook)

`wt` keeps task = issue = branch = PR mapped one-to-one onto a worktree. Branching off and working directly in the main checkout breaks that mapping and skips the `/wt-review` gate. Prose in a skill only gets read once the skill fires, so it does nothing on the paths where no skill fires (asking to "look at issue #N" and sliding straight into implementation, say).

So the plugin ships a `PreToolUse` hook ([`hooks/main-checkout-guard.sh`](hooks/main-checkout-guard.sh)) that inspects Bash before it runs. When it sees a branch switch **in the main checkout** it returns `ask`, prompting you with `/wt` as the alternative. What counts as a switch:

- `git checkout -b` / `git switch -c` / `--orphan`, and any other way of creating a branch and landing on it
- a `checkout` of an existing branch — including a name that only exists on the remote, which git turns into a tracking branch
- `gh pr checkout`, which moves the main checkout's branch exactly like `git checkout` does. Reading a PR is one of the easiest ways to slide into working outside a worktree, so it gets the same treatment

It asks rather than denies: moving the main checkout's branch has legitimate uses — hopping between dev and main, rebasing, checking a branch in a hurry — and none of those should be dead ends.

It stays out of the way when:

- you are inside a linked worktree (a worktree session owns its branch)
- the target is an allowed branch — whatever `origin/HEAD` points at, plus `main` / `master` / `dev`
- the command restores files (`git checkout -- <path>`) or checks out something that is not a branch
- the `gh` subcommand is anything other than `pr checkout` (`gh pr view`, `gh pr diff`, …)
- the directory is not a git work tree, or neither `jq` nor `python3` is available to read the hook's JSON

That last case is deliberate: the guard fails open, because a misbehaving hook that fails closed would take all of Bash down with it.

| Environment variable | Effect |
| --- | --- |
| `WT_GUARD_DISABLE=1` | Turn the hook off |
| `WT_GUARD_ALLOW_BRANCHES` | Replace the allowed branch names (comma-separated). The default branch is always allowed; an empty value leaves only the default branch |

### Cross-session chat (dev <-> worktree)

The worktree session and the dev session can talk directly through Claude Code's cross-session messaging (`ListAgents` / `SendMessage`). The mechanism belongs to Claude Code — the registry lives at `<config>/sessions/<pid>.json` and its `name` field is the address. All `wt` does is **decide the address**.

- `wt new` launches with `claude -n wt-<task>`, so the **worktree side is always addressable as `wt-<task>`**. The dev side can derive the address from the task name alone
- The dev side keeps Claude Code's auto-generated name (`<directory>-<2 chars>`). Look it up in the `role=dev` row of `wt peers`
- `wt peers` lists only **live** sessions belonging to this repo (main checkout plus every worktree), tagged with a role — registry files of dead sessions stick around

```
$ wt peers
ROLE                 NAME                     KIND         STATUS   SELF   CWD
dev                  wt-92                    interactive  busy     (self) /home/you/projects/wt
fix-login            wt-fix-login             interactive  idle            /home/you/projects/wt/.claude/worktrees/fix-login
```

The intended uses are "the worktree asks the dev side for a spec decision" and "the dev side pushes a change of direction or extra context". `/wt` and `/wt-detail` both put "don't decide on your own, ask the dev side" into the initial prompt, so the worktree side asks instead of guessing. The etiquette for sending and receiving lives in `/wt-ask`.

Sessions started by older versions of Claude Code do not appear in the peer registry and cannot be reached (they show up in neither `wt peers` nor `ListAgents`).

## Known caveats

- Worktrees live under `<repo>/.claude/worktrees/`, so `.claude/` shows up as untracked in the main checkout's `git status` (same as Claude Code's native worktrees). `wt new` says so every time the directory is still not ignored; add `.claude/worktrees/` to the main checkout's `.gitignore` or `.git/info/exclude` and the notice stops. Until you do, be careful not to sweep a worktree into a `git add .`.
- With `ignore-scripts=true` in `~/.npmrc`, `npm ci` alone will not build native addons (better-sqlite3 and friends). Rebuild them in the hook, or copy the prebuilt `.node` from the main checkout.
- Uncommitted changes in the main checkout do not reach the worktree (a worktree branches off a committed ref).
- Directory patterns (`secrets/`) work as-is for `.worktreeinclude` copies. Only drop the trailing slash (`secrets`) when you symlink them from the hook.
- Negation (`!`) in `.worktreeinclude` cannot re-include anything under a directory excluded as a whole — that is gitignore's own rule. `secrets/` + `!secrets/x` has no effect; write `secrets/*` + `!secrets/x`.
- Empty directories, and entries that are themselves relative symlinks, cannot be carried over correctly (git does not enumerate the former; the latter breaks inside the worktree).
- `wt merge` conflicts land in the main checkout's working tree. The main checkout stays mid-merge until you resolve them or run `git merge --abort`.
- `wt serve` binds to `127.0.0.1` only. Reaching it from a Windows browser relies on WSL2's localhost forwarding (on by default); where that does not work, let `/wt-review` open the page over `file://` instead of `wt serve`.
- The server exits once approved, but a page closed without approving leaves it running. `wt rm` (/wt-clean) stops it, `wt serve --stop` stops it on its own, and it folds itself up after 24 hours regardless.

## Development

```bash
scripts/check     # shellcheck + manifest validation + tests — the same gate wt merge and CI run
tests/wt_test.sh  # 34 tests; needs only git and coreutils (no bats)
```

`scripts/check` runs `claude plugin validate .` when the `claude` CLI is around, so a broken `.claude-plugin/` manifest fails before it reaches the marketplace. It also byte-compiles the bundled python (`skills/wt-review/assets/render.py` and `wt-review-serve.py`) when `python3` is present; both stick to the standard library, so there is no linter to add. The plugin entries deliberately carry no `version`: setting one pins the plugin until you bump the string, and users would stop receiving commits pushed to `main`.

The tests hide `herdr` from `PATH` to force the git-worktree fallback path, stub it where the herdr path itself is under test, and point `HOME` at a temp directory so your real home is never touched.

## License

[MIT](LICENSE)
