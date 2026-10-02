#!/usr/bin/env bash
# brevity: install a "be concise" instruction block into AI CLI config files.
# Usage:
#   ./install.sh [lite|normal|ultra]   install or switch level (default: normal)
#   ./install.sh off                   remove the instruction block everywhere
#   ./install.sh status                show what is installed where
#   ./install.sh cost                  approximate tokens the installed text adds per session
#   ./install.sh show [level]          print the text (for pasting into chat apps)
#   ./install.sh ignore                Claude Code only: block heavy paths (deny) and ask
#                                      before reading .NET bin/obj output (ask)
#   ./install.sh unignore              remove those rules again
#   ./install.sh analyze [dir]         read-only: how heavy are AGENTS.md / CLAUDE.md, section by section
#   ./install.sh init-project [dir]    create a short AGENTS.md (+ CLAUDE.md importing it) in a project
#
# Add --dry-run to install, off, ignore, unignore or init-project to see what
# would change without touching anything.
#
# Env: BREVITY_EFFICIENCY=0 installs only the level text, without the
#      file/command efficiency rules (levels/efficiency.md).
#      BREVITY_RTK=auto (default) enables RTK for Claude Code, Codex and Copilot
#      when `rtk` is on PATH (Copilot's file also gets rtk-prefix rules); 0 never
#      touches RTK; 1 requires it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_PREFIX="<!-- brevity:start"   # full marker is: <!-- brevity:start level=NAME -->
END="<!-- brevity:end -->"
EFFICIENCY="${BREVITY_EFFICIENCY:-1}"
RTK_ACTIVE=0   # set to 1 during install when RTK is going to be enabled
DRY=0

# Each tool's config folder can be relocated with an environment variable.
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
COPILOT_DIR="${COPILOT_HOME:-$HOME/.copilot}"

CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
COPILOT_MD="$COPILOT_DIR/copilot-instructions.md"
# Global instruction files loaded automatically by each CLI.
TARGETS=(
  "$CLAUDE_MD"                              # Claude Code
  "$CODEX_DIR/AGENTS.md"                    # Codex CLI
  "$COPILOT_MD"                             # GitHub Copilot CLI
)
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"

# Pull --dry-run out of the arguments.
ARGS=()
for a in "$@"; do
  if [ "$a" = "--dry-run" ]; then DRY=1; else ARGS+=("$a"); fi
done
set -- ${ARGS[@]+"${ARGS[@]}"}

strip_block() {  # remove an existing block from file $1 (in place)
  local f="$1" tmp
  [ -f "$f" ] || return 0
  tmp="$(mktemp)"
  # Compare with any trailing \r removed so CRLF files (edited on Windows) work.
  # A start marker with no end marker is an error: never drop the rest of the file.
  if ! awk -v p="$START_PREFIX" -v e="$END" '
    { line = $0; sub(/\r$/, "", line) }
    index(line, p) == 1 {skip=1; next}
    line == e           {skip=0; next}
    !skip {print}
    END {if (skip) exit 2}
  ' "$f" > "$tmp"; then
    rm -f "$tmp"
    echo "error: $f has a '$START_PREFIX' marker without a matching end marker; fix it by hand, nothing changed" >&2
    exit 1
  fi
  # trim trailing blank lines
  sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp" > "$f"
  rm -f "$tmp"
}

emit_text() {  # level text, plus efficiency rules unless disabled
  cat "$DIR/levels/$1.md"
  if [ "$EFFICIENCY" != "0" ]; then
    echo
    if [ "$RTK_ACTIVE" = 1 ]; then
      # RTK already compresses command output, but only for plain commands: a pipe bypasses it.
      sed 's/^- Limit command output.*/- RTK compresses command output: run build, test and install commands plain, without piping into head, tail or grep, since a pipe bypasses RTK./' "$DIR/levels/efficiency.md"
    else
      cat "$DIR/levels/efficiency.md"
    fi
  fi
}

# Enable RTK's hooks for each agent. `rtk init -g` is idempotent per RTK's docs.
# Failures only warn: brevity's own install must not depend on RTK.
enable_rtk() {
  echo "rtk detected ($(rtk --version 2>/dev/null | head -n1)): enabling it"
  local flag label
  for flag in "" "--codex" "--copilot"; do
    label="${flag#--}"; label="${label:-claude}"
    if [ "$DRY" = 1 ]; then
      echo "would run: rtk init -g $flag"
      continue
    fi
    # $flag is intentionally unquoted: empty means no argument.
    # shellcheck disable=SC2086
    if rtk init -g $flag >/dev/null 2>&1; then
      echo "rtk enabled [$label]"
    else
      echo "warning: 'rtk init -g $flag' failed; run it manually" >&2
    fi
  done
}

find_python() {  # first working interpreter (skips the Windows Store python3 stub)
  local p
  for p in python3 python; do
    if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys' >/dev/null 2>&1; then
      echo "$p"; return 0
    fi
  done
  return 1
}

# Add or remove brevity's rules in ~/.claude/settings.json.
# Only the exact entries listed below are ever touched; everything else is kept.
claude_ignore() {
  local py
  py="$(find_python)" || { echo "python (python3 or python) is required for ignore/unignore" >&2; exit 1; }
  "$py" - "$1" "$CLAUDE_SETTINGS" "$DRY" <<'PY'
import json, os, shutil, sys

mode, path, dry = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
RULES = {
    # Hard block: almost never worth reading.
    "deny": [
        "Read(./node_modules/**)",
        "Read(./dist/**)",
        "Read(./build/**)",
        "Read(./.next/**)",
        "Read(./coverage/**)",
        "Read(./package-lock.json)",
        "Read(./yarn.lock)",
        "Read(./pnpm-lock.yaml)",
        "Read(./**/*.min.js)",
    ],
    # .NET build output: ask first, so it can still be read when really needed.
    "ask": [
        "Read(./**/bin/**)",
        "Read(./**/obj/**)",
        "Read(./**/.vs/**)",
        "Read(./**/TestResults/**)",
    ],
}

data = {}
exists = os.path.exists(path)
if exists:
    with open(path) as f:
        text = f.read().strip()
    if text:
        try:
            data = json.loads(text)
        except json.JSONDecodeError as e:
            sys.exit(f"{path} is not valid JSON ({e}); not touching it")

perms = data.setdefault("permissions", {})
total = 0
for kind, rules in RULES.items():
    cur = perms.setdefault(kind, [])
    if mode == "ignore":
        new = [r for r in rules if r not in cur]
        cur.extend(new)
        total += len(new)
    else:
        before = len(cur)
        cur[:] = [r for r in cur if r not in rules]
        total += before - len(cur)
    if not cur:
        perms.pop(kind)
if not perms:
    data.pop("permissions")

verb = "add" if mode == "ignore" else "remove"
if dry:
    print(f"would {verb} {total} rule(s) in {path}")
    sys.exit(0)

if exists:
    bak = path + ".brevity.bak"
    if not os.path.exists(bak):
        shutil.copy2(path, bak)
else:
    os.makedirs(os.path.dirname(path), exist_ok=True)

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"{verb}{'ed' if verb == 'add' else 'd'} {total} rule(s) in {path}")
PY
}

# Create AGENTS.md (single source of truth for every tool) and a CLAUDE.md that
# imports it. Never overwrites existing files. Build/test commands are guessed
# from the project type and must be reviewed.
init_project() {
  local dir="${1:-.}" build="TODO" tcmd="TODO" dotnet_note=""
  [ -d "$dir" ] || { echo "not a directory: $dir" >&2; exit 1; }
  if compgen -G "$dir/*.sln" >/dev/null || compgen -G "$dir/*.slnx" >/dev/null || compgen -G "$dir/*.csproj" >/dev/null; then
    build="dotnet build"; tcmd="dotnet test"
    dotnet_note="- Avoid reading or listing bin/, obj/, .vs/ and TestResults/ (build artifacts) unless truly necessary; rely on command output for build and test results."$'\n'
  elif [ -f "$dir/package.json" ]; then
    build="npm run build"; tcmd="npm test"
  fi

  if [ -e "$dir/AGENTS.md" ]; then
    # Existing file: never rewrite it, only append a small marked block (once).
    local pstart="<!-- brevity:project:start -->" pend="<!-- brevity:project:end -->"
    if grep -qF "$pstart" "$dir/AGENTS.md"; then
      echo "skipped (brevity section already in): $dir/AGENTS.md"
    elif [ -z "$dotnet_note" ]; then
      echo "skipped (already exists, nothing to add): $dir/AGENTS.md"
    elif [ "$DRY" = 1 ]; then
      echo "would append a brevity section to: $dir/AGENTS.md"
    else
      {
        [ -n "$(tail -c1 "$dir/AGENTS.md")" ] && echo
        echo
        echo "$pstart"
        echo "## Token-saving notes"
        printf '%s' "$dotnet_note"
        echo "$pend"
      } >> "$dir/AGENTS.md"
      echo "appended brevity section to: $dir/AGENTS.md"
    fi
  elif [ "$DRY" = 1 ]; then
    echo "would create: $dir/AGENTS.md (build: $build, test: $tcmd)"
  else
    cat > "$dir/AGENTS.md" <<EOF
# Project instructions

## Commands
- Build: $build
- Test: $tcmd
- Run: TODO

## Structure
- TODO: one line per key folder, e.g. \`src/Api/\` for the HTTP layer

## Conventions
- TODO: naming, patterns, anything that differs from tool defaults

## Pitfalls
${dotnet_note}- TODO: non-obvious gotchas (env vars, generated files, slow tests)
EOF
    echo "created: $dir/AGENTS.md"
  fi

  if [ -e "$dir/CLAUDE.md" ]; then
    echo "skipped (already exists): $dir/CLAUDE.md"
  elif [ "$DRY" = 1 ]; then
    echo "would create: $dir/CLAUDE.md (imports AGENTS.md)"
  else
    echo "@AGENTS.md" > "$dir/CLAUDE.md"
    echo "created: $dir/CLAUDE.md (imports AGENTS.md)"
  fi
  echo "Next: review the commands, replace the TODOs, and keep the file short; it is loaded every session."
}

# Codex reads AGENTS.override.md instead of AGENTS.md when it exists.
warn_codex_override() {
  if [ -f "$CODEX_DIR/AGENTS.override.md" ]; then
    echo "warning: $CODEX_DIR/AGENTS.override.md exists; Codex reads it instead of AGENTS.md, so brevity's text may not apply there" >&2
  fi
}

show_status() {
  local f lvl eff c found=""
  for f in "${TARGETS[@]}"; do
    if [ -f "$f" ] && grep -qF "$START_PREFIX" "$f"; then
      lvl="$(sed -n 's/.*brevity:start level=\([a-z]*\).*/\1/p' "$f" | head -n1)"
      lvl="${lvl:-unknown}"
      if grep -qF 'Token efficiency' "$f"; then eff="efficiency on"; else eff="efficiency off"; fi
      echo "installed [$lvl, $eff]: $f"
      if [ "$f" = "$COPILOT_MD" ] && grep -qF 'through rtk' "$f"; then
        echo "  + rtk prefix rules for Copilot"
      fi
    else
      echo "not installed: $f"
    fi
  done
  for c in claude codex copilot; do
    if command -v "$c" >/dev/null 2>&1; then found="$found $c"; fi
  done
  echo "CLIs on PATH:${found:- none}"
  warn_codex_override
  if command -v rtk >/dev/null 2>&1; then
    echo "rtk: found ($(rtk --version 2>/dev/null | head -n1))"
  else
    echo "rtk: not found"
  fi
  if [ -f "$CLAUDE_SETTINGS" ] && grep -qF 'Read(./node_modules/**)' "$CLAUDE_SETTINGS"; then
    echo "claude ignore rules: active"
  else
    echo "claude ignore rules: not active"
  fi
}

est_tokens() {  # rough estimate: bytes / 4, rounded up; 0 if the file is missing
  local f="$1" bytes=0
  [ -f "$f" ] && bytes="$(wc -c < "$f")"
  echo $(( (bytes + 3) / 4 ))
}

show_cost() {
  local l
  echo "Approximate tokens added to every session (bytes / 4, not an exact count):"
  for l in lite normal ultra; do
    echo "  $l: ~$(est_tokens "$DIR/levels/$l.md")" \
         "(+ ~$(est_tokens "$DIR/levels/efficiency.md") efficiency," \
         "+ ~$(est_tokens "$DIR/levels/claude-extra.md") Claude-only extras," \
         "+ ~$(est_tokens "$DIR/levels/copilot-rtk.md") Copilot-only RTK rules, when RTK is detected)"
  done
}

# Read-only report on how heavy a project's AGENTS.md / CLAUDE.md are, section by section.
analyze_file() {  # $1 = path, $2 = label
  local f="$1" label="$2" rows bytes lines blocks
  bytes="$(wc -c < "$f" | tr -d ' ')"
  rows="$(LC_ALL=C awk '
    function flush() {
      if (have) printf "S\t%d\t%d\t%d\t%s\n", int((sbytes + 3) / 4), idx, narr, name
      idx++; sbytes = 0; narr = 0; have = 0
    }
    BEGIN { name = "(before first heading)"; idx = 0; fence = 0; blen = 0; longblocks = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      sbytes += length(line) + 1
      if (line ~ /[^ \t]/) have = 1
      if (line ~ /^(```|~~~)/) {
        if (fence) { if (blen >= 15) longblocks++; fence = 0; blen = 0 } else { fence = 1; blen = 0 }
      } else if (fence) { blen++ }
      else if (line ~ /^#+[ \t]/) {
        flush(); name = substr(line, 1, 70); have = 1; sbytes = length(line) + 1
      }
      tmp = tolower(line)
      narr += gsub(/for real|really happened|was caught|this happened|silently|bit the /, "&", tmp)
    }
    END { flush(); printf "B\t%d\n", longblocks; printf "N\t%d\n", NR }
  ' "$f")"
  lines="$(printf '%s\n' "$rows" | awk -F'\t' '$1=="N"{print $2}')"
  blocks="$(printf '%s\n' "$rows" | awk -F'\t' '$1=="B"{print $2}')"
  echo "$label: ~$(est_tokens "$f") tokens ($bytes bytes, $lines lines)"
  echo "  Largest sections (approx. tokens):"
  printf '%s\n' "$rows" | awk -F'\t' '$1=="S"' | sort -t"$(printf '\t')" -k2,2nr -k3,3n | head -n 5 \
    | awk -F'\t' '{printf "    %5d  %s\n", $2, $5}'
  echo "  Code blocks of 15+ lines: $blocks"
  local inc
  inc="$(printf '%s\n' "$rows" | awk -F'\t' '$1=="S" && $4>=2 && $2>=150' | sort -t"$(printf '\t')" -k2,2nr -k3,3n | head -n 5 \
    | awk -F'\t' '{printf "    %5d  %s\n", $2, $5}')"
  if [ -n "$inc" ]; then
    echo "  Sections that read like incident history rather than rules:"
    echo "$inc"
  fi
}

analyze_project() {
  local dir="${1:-.}" total=0 seen="" rel f imp ipath only_imports line any=0
  local biggest="" biggest_tok=0 t sums="" cdir c clabel
  [ -d "$dir" ] || { echo "not a directory: $dir" >&2; exit 1; }
  echo "Analyzing: $dir (read-only; nothing is changed)"
  cdir="$(cd "$dir" && pwd)"
  # Every project instruction file the three tools read.
  for rel in AGENTS.md CLAUDE.md .claude/CLAUDE.md .github/copilot-instructions.md; do
    f="$dir/$rel"
    [ -f "$f" ] || continue
    any=1
    only_imports=1
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in ""|@*) ;; *) only_imports=0; break ;; esac
    done < "$f"
    if [ "$only_imports" = 1 ]; then
      echo "$rel: imports only ($(grep -h '^@' "$f" | tr -d '\r' | tr '\n' ' ' | sed 's/ $//'))"
      for imp in $(grep -h '^@' "$f" | tr -d '\r'); do
        imp="${imp#@}"
        ipath="$(dirname "$rel")/$imp"
        [ -f "$dir/$ipath" ] || continue
        c="$(cd "$(dirname "$dir/$ipath")" && pwd)/$(basename "$ipath")"
        case " $seen " in *" $c "*) continue ;; esac
        seen="$seen $c"
        ipath="${c#"$cdir"/}"
        analyze_file "$dir/$ipath" "$ipath"
        t="$(est_tokens "$dir/$ipath")"; total=$((total + t))
        if [ "$t" -gt "$biggest_tok" ]; then biggest="$ipath"; biggest_tok="$t"; fi
        sums="$sums$(tr -d '\r' < "$dir/$ipath" | cksum | cut -d' ' -f1,2) $ipath"$'\n'
      done
    else
      c="$cdir/$rel"
      case " $seen " in *" $c "*) continue ;; esac
      seen="$seen $c"
      analyze_file "$f" "$rel"
      t="$(est_tokens "$f")"; total=$((total + t))
      if [ "$t" -gt "$biggest_tok" ]; then biggest="$rel"; biggest_tok="$t"; fi
      sums="$sums$(tr -d '\r' < "$f" | cksum | cut -d' ' -f1,2) $rel"$'\n'
    fi
  done
  if [ "$any" = 0 ]; then echo "No AGENTS.md, CLAUDE.md or .github/copilot-instructions.md in $dir"; return 0; fi
  # Identical files are loaded twice by tools that read both (Copilot CLI combines all it finds).
  printf '%s' "$sums" | awk '
    { k = $1 " " $2; name = $3; if (k in first) printf "Note: %s is identical to %s; tools that read both load it twice. Keep one and delete or import the other.\n", name, first[k]; else first[k] = name }'
  echo "Loaded in every session from this folder: ~$total tokens (bytes / 4)"
  if [ "$total" -lt 1500 ]; then
    echo "That is lean; nothing to trim."
    return 0
  fi
  echo
  echo "Trimming ideas: keep rules, commands and constraints in the file; move incident stories,"
  echo "background and long explanations to a separate file the agent reads only when relevant."
  echo "A prompt you can paste into Claude Code or Copilot Chat (it asks for a diff, so you review before anything changes):"
  echo
  echo "  Read $biggest and shorten it without losing any rule. Keep every rule, command and constraint."
  echo "  Move incident stories, past-bug anecdotes and long background to docs/agent-notes.md and leave one"
  echo "  line in $biggest pointing to it (\"Background and past incidents: docs/agent-notes.md, read only"
  echo "  when relevant\"). Merge duplicated rules. Do not change the meaning of any rule. Show me the diff"
  echo "  before writing anything."
}

cmd="${1:-normal}"

case "$cmd" in
  off)
    for f in "${TARGETS[@]}"; do
      if [ -f "$f" ] && grep -qF "$START_PREFIX" "$f"; then
        if [ "$DRY" = 1 ]; then
          echo "would remove: $f"
        else
          strip_block "$f"
          echo "removed: $f"
        fi
      fi
    done
    ;;
  status)
    show_status
    ;;
  cost)
    show_cost
    ;;
  show)
    level="${2:-normal}"
    [ -f "$DIR/levels/$level.md" ] || { echo "unknown level: $level" >&2; exit 1; }
    emit_text "$level"
    ;;
  ignore|unignore)
    claude_ignore "$cmd"
    ;;
  analyze)
    analyze_project "${2:-.}"
    ;;
  init-project)
    init_project "${2:-.}"
    ;;
  lite|normal|ultra)
    [ -f "$DIR/levels/$cmd.md" ] || { echo "missing $DIR/levels/$cmd.md" >&2; exit 1; }
    case "${BREVITY_RTK:-auto}" in
      0) ;;
      1)
        command -v rtk >/dev/null 2>&1 || { echo "BREVITY_RTK=1 but rtk is not installed" >&2; exit 1; }
        RTK_ACTIVE=1
        ;;
      *)
        if command -v rtk >/dev/null 2>&1; then RTK_ACTIVE=1; fi
        ;;
    esac
    for f in "${TARGETS[@]}"; do
      if [ "$DRY" = 1 ]; then
        echo "would install [$cmd]: $f"
        continue
      fi
      mkdir -p "$(dirname "$f")"
      touch "$f"
      strip_block "$f"
      {
        [ -s "$f" ] && echo
        echo "$START_PREFIX level=$cmd -->"
        emit_text "$cmd"
        # Claude-only extras (e.g. compaction guidance); other tools don't read them.
        if [ "$f" = "$CLAUDE_MD" ] && [ -f "$DIR/levels/claude-extra.md" ]; then
          echo
          cat "$DIR/levels/claude-extra.md"
        fi
        # Copilot CLI can't rewrite commands transparently, so with RTK present tell it to prefix them.
        if [ "$f" = "$COPILOT_MD" ] && [ "$RTK_ACTIVE" = 1 ] && [ -f "$DIR/levels/copilot-rtk.md" ]; then
          echo
          cat "$DIR/levels/copilot-rtk.md"
        fi
        echo "$END"
      } >> "$f"
      echo "installed [$cmd]: $f"
    done
    if [ "$RTK_ACTIVE" = 1 ]; then enable_rtk; fi
    warn_codex_override
    ;;
  *)
    echo "usage: $0 [lite|normal|ultra|off|status|cost|show [level]|ignore|unignore|init-project [dir]|analyze [dir]] [--dry-run]" >&2
    exit 1
    ;;
esac
