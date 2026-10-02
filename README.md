# brevity

One short instruction text that makes AI assistants answer concisely and work economically with files and commands. Installed once, loaded automatically every session. No proxy, no MCP.

## Levels

| Level  | What it does                                              |
|--------|-----------------------------------------------------------|
| lite   | No preambles/closers, code diffs only                     |
| normal | lite + one recommended option, minimal questions          |
| ultra  | normal + short sentences, lists, no background/examples   |

Every level also includes the rules in `levels/efficiency.md` (don't read whole large files, skip generated paths, limit command output, targeted edits, run only affected tests, batch independent reads, short plan before big changes, no redundant re-reads). Set `BREVITY_EFFICIENCY=0` to install only the level text.

Two things apply to every level:

- **No unnecessary code comments**, and existing comments are left alone.
- **`full:` escape hatch.** Start a message with `full:` and the brevity rules are ignored for that answer, so hard tasks don't need a reinstall.

The Claude Code file also gets `levels/claude-extra.md` (compaction guidance: what `/compact` should keep). Codex and Copilot don't get it.

The text lives in `levels/*.md`. Edit it to taste.

## CLIs (Claude Code, Codex, GitHub Copilot CLI)

```bash
./install.sh normal   # install or switch level
./install.sh ultra    # switch to ultra
./install.sh off      # remove everywhere
./install.sh status   # what is installed where, RTK found?, ignore rules active?
./install.sh cost     # approximate tokens each level adds to every session
```

On Windows PowerShell there is an equivalent: `.\install.ps1 normal` (or `install.cmd normal`). See "PowerShell" below.

Add `--dry-run` to `install`, `off`, `ignore`, `unignore` or `init-project` to see what would change without touching anything.

It writes a marked block (`<!-- brevity:start level=normal -->`) into:

- `~/.claude/CLAUDE.md`
- `~/.codex/AGENTS.md`
- `~/.copilot/copilot-instructions.md`

Re-running replaces the block, so it never duplicates. Anything else in those files is left untouched.

## PowerShell (Windows)

`install.ps1` does everything `install.sh` does (same commands, same `--dry-run`, same environment variables, same marked block) on Windows PowerShell 5.1 and PowerShell 7. No bash or Python needed.

```powershell
.\install.cmd normal --dry-run   # preview
.\install.cmd normal             # install or switch level
.\install.cmd status
```

- **Execution policy:** `install.cmd` runs the script with `-ExecutionPolicy Bypass` for that one run. Or run `powershell -ExecutionPolicy Bypass -File .\install.ps1 normal`, or `Unblock-File .\install.ps1` once if the zip marked it as downloaded.
- **Mixing both scripts is safe:** they write byte-identical blocks and each can switch or remove what the other installed. Existing line endings (CRLF or LF) in your files are preserved.
- **`ignore` / `unignore`** rewrite `settings.json` with PowerShell's JSON support: your settings are kept, but the file is reformatted (2-space layout may differ, key order is kept). A one-time `settings.json.brevity.bak` keeps the original.
- If a file has a `<!-- brevity:start` marker without the matching `<!-- brevity:end -->` (for example after a manual edit), both scripts stop with an error instead of changing it.

## Claude Code: block heavy paths (optional)

```bash
./install.sh ignore     # add the rules below to ~/.claude/settings.json
./install.sh unignore   # remove exactly those rules again
```

- **Blocked (`deny`):** node_modules, dist, build, .next, coverage, lockfiles, `*.min.js`.
- **Ask first (`ask`), for .NET build output:** `bin/`, `obj/`, `.vs/`, `TestResults/`. Claude Code asks for your approval before reading them, so they stay reachable when really needed.

This merges the rules into `~/.claude/settings.json`, keeping your other settings, and saves a one-time backup as `settings.json.brevity.bak`. If the file isn't valid JSON it refuses to touch it. Requires `python3` or `python`.

Codex and Copilot CLI get the same intent through the instruction text only (the "don't open generated paths" rule, plus the .NET line that `init-project` writes into a project's `AGENTS.md`); no equivalent hard block is configured for them.

## RTK (optional, auto-detected)

[RTK](https://github.com/rtk-ai/rtk) compresses the output of commands like `dotnet build` or `npm install` before it reaches the model, which brevity can't do. If `rtk` is on your PATH, `./install.sh <level>` also runs, safely and repeatably:

```bash
rtk init -g             # Claude Code
rtk init -g --codex     # Codex
rtk init -g --copilot   # GitHub Copilot (VS Code / CLI)
```

and replaces the manual "limit command output" rule with one telling the agent to run build/test/install commands plain, without piping into `head`, `tail` or `grep`: RTK doesn't rewrite piped commands, so a `dotnet build | tail` would bypass it. If any `rtk init` fails you get a warning and brevity's install still completes.

Copilot CLI can't have commands rewritten transparently, so with RTK detected brevity also adds a short block (`levels/copilot-rtk.md`) to Copilot's file telling it to prefix supported commands with `rtk` from the first attempt (`rtk dotnet build`, `rtk git status`, ...), with a fallback to the plain command if `rtk` is missing or doesn't support it. It is only written when RTK is detected at install time; re-running `./install.sh` without RTK removes it. Claude Code and Codex don't need it.

- `BREVITY_RTK=0` never touches RTK; `BREVITY_RTK=1` fails if RTK isn't installed.
- `./install.sh off` removes only brevity's text. To undo RTK, use RTK's own uninstall (`rtk init -g --uninstall`; see its README for per-agent flags).
- RTK only intercepts Bash commands, so brevity's `ignore` rules and file-reading advice still matter for `Read`/`Grep`/`Glob`.
- Without RTK, silent flags do most of the same job: `dotnet build --nologo -v:q -clp:ErrorsOnly`, `npm install --silent --no-audit --no-fund`.

## What works where

Checked against each tool's documentation (not by running the real CLIs):

| | Claude Code | Codex | Copilot CLI |
|---|---|---|---|
| Global text file | `~/.claude/CLAUDE.md` | `~/.codex/AGENTS.md` | `~/.copilot/copilot-instructions.md` |
| Folder relocated by | `CLAUDE_CONFIG_DIR` | `CODEX_HOME` | `COPILOT_HOME` |
| Project file | `CLAUDE.md` (or `AGENTS.md`; `@AGENTS.md` import) | `AGENTS.md` | `AGENTS.md`, `CLAUDE.md`, `.github/copilot-instructions.md` |
| Hard path rules (`ignore`) | yes | no | no |
| Compaction extras | yes | no | no |
| `rtk` prefix rules in the text | no | no | yes, when RTK is detected |
| RTK hook | `rtk init -g` | `rtk init -g --codex` | `rtk init -g --copilot` |

The script honors the three environment variables, so a relocated config folder is used automatically.

Things to know:

- **Claude Code** loads `CLAUDE.md` at session start; edits apply on the next session, `/clear` or `/compact`.
- **Codex** reads `AGENTS.override.md` instead of `AGENTS.md` if it exists in the same folder; `status` and the installer warn when it does. Instructions are capped at 32 KiB by default; brevity's text is a small fraction of that.
- **Copilot CLI** combines all instruction files it finds and defines no precedence between them. With RTK there are two routes that work together: the hook from `rtk init -g --copilot` denies a plain command and suggests the `rtk` one, and brevity's prefix rules (above) make Copilot use `rtk` from the start, so the hook is just a safety net. A community file such as [rtk-for-copilot](https://github.com/Martin-Sciarrillo/rtk-for-copilot) does the same job as those rules; you don't need it with brevity, and brevity only touches its own marked block, so the two can coexist if you already use it. Review third-party instruction files before using them: a rule asking the agent to run `rtk gain` and report savings costs tokens every session, and you can run it yourself.
- **Shell-neutral text.** On Windows, Copilot CLI may run PowerShell, where `tail`, `head` and `grep` don't exist, so brevity's text doesn't name any shell tool.

To confirm a tool actually loaded the text: in Claude Code run `/memory` (it lists the loaded files); in Codex and Copilot CLI start a new session and ask it to list the instructions it received. `./install.sh status` shows which of the three CLIs are on your PATH.

## Chat apps (claude.ai, ChatGPT, mobile)

Print the text and paste it once:

```bash
./install.sh show normal
```

- Claude: Settings > Profile > Preferences (or a Project's instructions)
- ChatGPT: Settings > Personalization > Custom Instructions

## Per project (optional)

```bash
./install.sh init-project [dir]   # default: current directory
```

Creates a short `AGENTS.md` (build/test commands guessed for .NET or Node, plus TODO sections for structure, conventions and pitfalls) and a `CLAUDE.md` containing `@AGENTS.md`. One file feeds all three tools: Codex reads `AGENTS.md`, Claude Code imports it, and Copilot CLI reads `AGENTS.md` too. It never overwrites existing files. If `AGENTS.md` already exists, a short marked block (`<!-- brevity:project:start -->`, with just the .NET `bin/obj` line) is appended once at the end; nothing else in the file changes. Build/test commands are never guessed for an existing file, since it usually documents them already. Non-.NET projects: nothing is added. In a .NET project it also adds a line telling the agent to avoid `bin/`, `obj/`, `.vs/` and `TestResults/`. Fill in the TODOs and keep it short, since it is loaded in every session; the point is that the agent stops spending tokens exploring the repo.

## Analyze your project instructions (read-only)

```bash
./install.sh analyze [dir]     # or: .\install.cmd analyze [dir]   (default: current directory)
```

Reports how many tokens a project's instruction files add to every session. It looks at `AGENTS.md`, `CLAUDE.md`, `.claude/CLAUDE.md` and `.github/copilot-instructions.md` (following `@imports`, counting each file once) and warns when two of them are identical, since tools that read both load the text twice. For each file: the largest sections, long code blocks, and sections that read like incident history rather than rules. When the total is over ~1500 tokens it prints a prompt you can paste into Claude Code or Copilot Chat to shorten the file safely (keep every rule, move anecdotes to `docs/agent-notes.md`, show a diff first). It never writes anything: deciding what is a rule and what is background takes judgment, so brevity only measures and the rewrite is yours to review.

## Habits that matter (not automated)

- **Don't switch models mid-task.** Each model has its own cache, so `/model` makes the next request reprocess the whole history. Pick the model at the start; use `/compact` or `/clear` at natural breaks.
- **Editing instruction files mid-session** does not invalidate the cache in Claude Code, but it doesn't apply either: `CLAUDE.md` changes load on the next `/clear`, `/compact` or restart. Re-running `./install.sh` therefore only affects new sessions.
- **Paste only the relevant lines** of a log or stack trace, not the whole dump; it stays in context and is re-read on every turn.

## Notes

- Savings come mostly from shorter **output** and from not reading or printing unneeded content. Thinking tokens are unaffected.
- The biggest levers are outside this repo: start a new session per task (`/clear`, `/compact`), disable unused MCP servers, and use a smaller model for mechanical tasks.
- For hard debugging or reasoning tasks, start the message with `full:` (or run `./install.sh off`); forced brevity can hurt answer quality.
- Reasoning effort is deliberately left to each person; brevity doesn't touch it.
- `install.sh` is plain bash (Linux, macOS, Git Bash, WSL); `install.ps1` covers native Windows PowerShell.
- The text is static and sits at the start of the context, so it works with prompt caching.
