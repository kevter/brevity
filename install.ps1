# brevity (PowerShell edition): install a "be concise" instruction block into AI CLI config files.
# Same behavior and same markers as install.sh, so the two scripts can be mixed freely.
# Works on Windows PowerShell 5.1 and PowerShell 7+.
#
# Usage:
#   .\install.ps1 [lite|normal|ultra]   install or switch level (default: normal)
#   .\install.ps1 off                   remove the instruction block everywhere
#   .\install.ps1 status                show what is installed where
#   .\install.ps1 cost                  approximate tokens the installed text adds per session
#   .\install.ps1 show [level]          print the text (for pasting into chat apps)
#   .\install.ps1 ignore                Claude Code only: block heavy paths (deny) and ask
#                                       before reading .NET bin/obj output (ask)
#   .\install.ps1 unignore              remove those rules again
#   .\install.ps1 analyze [dir]         read-only: how heavy are AGENTS.md / CLAUDE.md, section by section
#   .\install.ps1 init-project [dir]    create a short AGENTS.md (+ CLAUDE.md importing it) in a project
#
# Add --dry-run (or -DryRun) to install, off, ignore, unignore or init-project to see
# what would change without touching anything.
#
# If scripts are blocked on your machine, use install.cmd (it bypasses the execution
# policy for this one run) or:  powershell -ExecutionPolicy Bypass -File .\install.ps1 normal
#
# Env: BREVITY_EFFICIENCY=0 installs only the level text, without the efficiency rules.
#      BREVITY_RTK=auto (default) enables RTK for Claude Code, Codex and Copilot when
#      `rtk` is on PATH (Copilot's file also gets rtk-prefix rules); 0 never touches RTK;
#      1 requires it.
#      CLAUDE_CONFIG_DIR / CODEX_HOME / COPILOT_HOME relocate each tool's folder.

$ErrorActionPreference = 'Stop'

$Dir          = $PSScriptRoot
$StartPrefix  = '<!-- brevity:start'   # full marker is: <!-- brevity:start level=NAME -->
$EndMarker    = '<!-- brevity:end -->'
$Efficiency   = if ($env:BREVITY_EFFICIENCY) { $env:BREVITY_EFFICIENCY } else { '1' }
$RtkMode      = if ($env:BREVITY_RTK) { $env:BREVITY_RTK } else { 'auto' }
$script:RtkActive = $false
$script:Dry   = $false

$UserHome   = $HOME
$ClaudeDir  = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $UserHome '.claude' }
$CodexDir   = if ($env:CODEX_HOME)        { $env:CODEX_HOME }        else { Join-Path $UserHome '.codex' }
$CopilotDir = if ($env:COPILOT_HOME)      { $env:COPILOT_HOME }      else { Join-Path $UserHome '.copilot' }

$ClaudeMd       = Join-Path $ClaudeDir 'CLAUDE.md'
$CopilotMd      = Join-Path $CopilotDir 'copilot-instructions.md'
$Targets        = @($ClaudeMd, (Join-Path $CodexDir 'AGENTS.md'), $CopilotMd)
$ClaudeSettings = Join-Path $ClaudeDir 'settings.json'

# ---------- helpers ----------

function Write-Err([string]$msg) { [Console]::Error.WriteLine($msg) }

function Fail([string]$msg) { Write-Err $msg; exit 1 }

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Text([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    return [System.IO.File]::ReadAllText($path)   # detects and drops a BOM
}

function Write-Text([string]$path, [string]$text) {
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllText($path, $text, $Utf8NoBom)
}

function Get-Eol([string]$text) {
    if ($text.Contains("`r`n")) { return "`r`n" } else { return "`n" }
}

# Lines of a bundled text file, without the trailing newline.
function Get-Lines([string]$path) {
    $t = [System.IO.File]::ReadAllText($path).TrimEnd("`r", "`n")
    return [regex]::Split($t, "\r?\n")
}

# Remove the brevity block from $text. Works with LF and CRLF. A start marker with no
# end marker is an error: the rest of the file is never dropped.
function Remove-Block([string]$text, [string]$eol, [string]$what) {
    $out  = New-Object 'System.Collections.Generic.List[string]'
    $skip = $false
    foreach ($l in [regex]::Split($text, "\r?\n")) {
        if ($l.StartsWith($StartPrefix, [System.StringComparison]::Ordinal)) { $skip = $true; continue }
        if ($l -ceq $EndMarker) { $skip = $false; continue }
        if (-not $skip) { $out.Add($l) }
    }
    if ($skip) {
        throw "$what has a '$StartPrefix' marker without a matching end marker; fix it by hand, nothing changed"
    }
    while ($out.Count -gt 0 -and $out[$out.Count - 1] -eq '') { $out.RemoveAt($out.Count - 1) }
    if ($out.Count -eq 0) { return '' }
    return ($out -join $eol) + $eol
}

# Level text, plus efficiency rules unless disabled. Returns an array of lines.
function Get-Text([string]$level) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.AddRange([string[]](Get-Lines (Get-LevelPath $level)))
    if ($Efficiency -ne '0') {
        $lines.Add('')
        $eff = Get-Lines (Get-LevelPath 'efficiency')
        foreach ($l in $eff) {
            # RTK already compresses command output, but only for plain commands: a pipe bypasses it.
            if ($script:RtkActive -and $l -match '^- Limit command output') {
                $lines.Add('- RTK compresses command output: run build, test and install commands plain, without piping into head, tail or grep, since a pipe bypasses RTK.')
            } else { $lines.Add($l) }
        }
    }
    return , $lines.ToArray()
}

function Get-LevelPath([string]$name) { return Join-Path (Join-Path $Dir 'levels') "$name.md" }

function Test-Command([string]$name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# ---------- RTK ----------

function Get-RtkVersion {
    $ErrorActionPreference = 'Continue'   # Windows PowerShell 5.1 turns native stderr into errors otherwise
    try {
        $v = & rtk --version 2>$null | Select-Object -First 1
        return "$v"
    } catch { return '' }
}

# `rtk init -g` is idempotent per RTK's docs. Failures only warn.
function Enable-Rtk {
    Write-Host ("rtk detected ({0}): enabling it" -f (Get-RtkVersion))
    foreach ($flag in @('', '--codex', '--copilot')) {
        $label = if ($flag) { $flag.TrimStart('-') } else { 'claude' }
        $shown = ("init -g $flag").Trim()
        if ($script:Dry) { Write-Host "would run: rtk $shown"; continue }
        $ok = $false
        $ErrorActionPreference = 'Continue'
        try {
            if ($flag) { & rtk init -g $flag *> $null } else { & rtk init -g *> $null }
            $ok = ($LASTEXITCODE -eq 0)
        } catch { $ok = $false }
        $ErrorActionPreference = 'Stop'
        if ($ok) { Write-Host "rtk enabled [$label]" }
        else { Write-Err "warning: 'rtk $shown' failed; run it manually" }
    }
}

# ---------- Claude Code ignore rules ----------

$DenyRules = @(
    'Read(./node_modules/**)', 'Read(./dist/**)', 'Read(./build/**)', 'Read(./.next/**)',
    'Read(./coverage/**)', 'Read(./package-lock.json)', 'Read(./yarn.lock)',
    'Read(./pnpm-lock.yaml)', 'Read(./**/*.min.js)'
)
# .NET build output: ask first, so it can still be read when really needed.
$AskRules = @(
    'Read(./**/bin/**)', 'Read(./**/obj/**)', 'Read(./**/.vs/**)', 'Read(./**/TestResults/**)'
)

# Windows PowerShell 5.1 escapes & < > ' as \uXXXX in JSON. Valid, but ugly in a file people
# edit by hand, so put the plain characters back (skipping genuinely escaped backslashes).
function Restore-JsonChars([string]$json) {
    return [regex]::Replace($json, '(?<!\\)((?:\\\\)*)\\u(0026|003[cCeE]|0027)', {
        param($m)
        $m.Groups[1].Value + [string][char][Convert]::ToInt32($m.Groups[2].Value, 16)
    })
}

function Invoke-Ignore([string]$mode) {
    $exists = Test-Path -LiteralPath $ClaudeSettings -PathType Leaf
    $data = $null
    if ($exists) {
        $text = (Read-Text $ClaudeSettings).Trim()
        if ($text) {
            try { $data = ConvertFrom-Json -InputObject $text }
            catch { Fail "$ClaudeSettings is not valid JSON ($($_.Exception.Message)); not touching it" }
            if ($data -isnot [System.Management.Automation.PSCustomObject]) {
                Fail "$ClaudeSettings is not a JSON object; not touching it"
            }
        }
    }
    if ($null -eq $data) { $data = [pscustomobject]@{} }

    $permProp = $data.PSObject.Properties['permissions']
    if ($permProp -and $permProp.Value -is [System.Management.Automation.PSCustomObject]) {
        $perms = $permProp.Value
    } elseif ($permProp -and $null -ne $permProp.Value) {
        Fail "$ClaudeSettings has a 'permissions' value that is not an object; not touching it"
    } else {
        $perms = [pscustomobject]@{}
    }

    $total = 0
    foreach ($kind in @('deny', 'ask')) {
        $rules   = if ($kind -eq 'deny') { $DenyRules } else { $AskRules }
        $curProp = $perms.PSObject.Properties[$kind]
        $cur     = if ($curProp) { @($curProp.Value) } else { @() }
        if ($mode -eq 'ignore') {
            $new = @($rules | Where-Object { $cur -cnotcontains $_ })
            $cur = @($cur) + $new
            $total += $new.Count
        } else {
            $kept = @($cur | Where-Object { $rules -cnotcontains $_ })
            $total += $cur.Count - $kept.Count
            $cur = $kept
        }
        if ($cur.Count -gt 0) {
            Add-Member -InputObject $perms -NotePropertyName $kind -NotePropertyValue $cur -Force
        } elseif ($curProp) {
            $perms.PSObject.Properties.Remove($kind)
        }
    }
    if (@($perms.PSObject.Properties).Count -gt 0) {
        Add-Member -InputObject $data -NotePropertyName 'permissions' -NotePropertyValue $perms -Force
    } elseif ($permProp) {
        $data.PSObject.Properties.Remove('permissions')
    }

    $verb = if ($mode -eq 'ignore') { 'add' } else { 'remove' }
    $past = if ($mode -eq 'ignore') { 'added' } else { 'removed' }
    if ($script:Dry) { Write-Host "would $verb $total rule(s) in $ClaudeSettings"; return }

    if ($exists) {
        $bak = "$ClaudeSettings.brevity.bak"
        if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $ClaudeSettings -Destination $bak }
    }
    $json = ConvertTo-Json -InputObject $data -Depth 32
    $json = (Restore-JsonChars $json) -replace "`r`n", "`n"
    Write-Text $ClaudeSettings ($json + "`n")
    Write-Host "$past $total rule(s) in $ClaudeSettings"
}

# ---------- init-project ----------

function Invoke-InitProject([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Fail "not a directory: $dir" }
    $build = 'TODO'; $tcmd = 'TODO'; $dotnetNote = $null
    $files = @(Get-ChildItem -LiteralPath $dir -File -Force)
    $isDotnet = @($files | Where-Object { $_.Name -like '*.sln' -or $_.Name -like '*.slnx' -or $_.Name -like '*.csproj' }).Count -gt 0
    if ($isDotnet) {
        $build = 'dotnet build'; $tcmd = 'dotnet test'
        $dotnetNote = '- Avoid reading or listing bin/, obj/, .vs/ and TestResults/ (build artifacts) unless truly necessary; rely on command output for build and test results.'
    } elseif (Test-Path -LiteralPath (Join-Path $dir 'package.json') -PathType Leaf) {
        $build = 'npm run build'; $tcmd = 'npm test'
    }

    $agents = Join-Path $dir 'AGENTS.md'
    if (Test-Path -LiteralPath $agents) {
        # Existing file: never rewrite it, only append a small marked block (once).
        $pstart = '<!-- brevity:project:start -->'; $pend = '<!-- brevity:project:end -->'
        $cur = Read-Text $agents
        if ($cur.Contains($pstart)) {
            Write-Host "skipped (brevity section already in): $agents"
        } elseif (-not $dotnetNote) {
            Write-Host "skipped (already exists, nothing to add): $agents"
        } elseif ($script:Dry) {
            Write-Host "would append a brevity section to: $agents"
        } else {
            $eol = Get-Eol $cur
            $add = New-Object 'System.Collections.Generic.List[string]'
            $add.Add($pstart); $add.Add('## Token-saving notes')
            if ($dotnetNote) { $add.Add($dotnetNote) }
            $add.Add($pend)
            $sep = if ($cur.Length -eq 0 -or $cur.EndsWith("`n")) { $eol } else { $eol + $eol }
            Write-Text $agents ($cur + $sep + ($add -join $eol) + $eol)
            Write-Host "appended brevity section to: $agents"
        }
    } elseif ($script:Dry) {
        Write-Host "would create: $agents (build: $build, test: $tcmd)"
    } else {
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $lines.Add('# Project instructions')
        $lines.Add('')
        $lines.Add('## Commands')
        $lines.Add("- Build: $build")
        $lines.Add("- Test: $tcmd")
        $lines.Add('- Run: TODO')
        $lines.Add('')
        $lines.Add('## Structure')
        $lines.Add('- TODO: one line per key folder, e.g. `src/Api/` for the HTTP layer')
        $lines.Add('')
        $lines.Add('## Conventions')
        $lines.Add('- TODO: naming, patterns, anything that differs from tool defaults')
        $lines.Add('')
        $lines.Add('## Pitfalls')
        if ($dotnetNote) { $lines.Add($dotnetNote) }
        $lines.Add('- TODO: non-obvious gotchas (env vars, generated files, slow tests)')
        Write-Text $agents (($lines -join "`n") + "`n")
        Write-Host "created: $agents"
    }

    $claude = Join-Path $dir 'CLAUDE.md'
    if (Test-Path -LiteralPath $claude) {
        Write-Host "skipped (already exists): $claude"
    } elseif ($script:Dry) {
        Write-Host "would create: $claude (imports AGENTS.md)"
    } else {
        Write-Text $claude "@AGENTS.md`n"
        Write-Host "created: $claude (imports AGENTS.md)"
    }
    Write-Host 'Next: review the commands, replace the TODOs, and keep the file short; it is loaded every session.'
}

# ---------- status / cost ----------

function Write-CodexOverrideWarning {
    $o = Join-Path $CodexDir 'AGENTS.override.md'
    if (Test-Path -LiteralPath $o -PathType Leaf) {
        Write-Err "warning: $o exists; Codex reads it instead of AGENTS.md, so brevity's text may not apply there"
    }
}

function Show-Status {
    foreach ($f in $Targets) {
        $t = Read-Text $f
        if ($t.Contains($StartPrefix)) {
            $m = [regex]::Match($t, 'brevity:start level=([a-z]+)')
            $lvl = if ($m.Success) { $m.Groups[1].Value } else { 'unknown' }
            $eff = if ($t.Contains('Token efficiency')) { 'efficiency on' } else { 'efficiency off' }
            Write-Host "installed [$lvl, $eff]: $f"
            if ($f -eq $CopilotMd -and $t.Contains('through rtk')) { Write-Host '  + rtk prefix rules for Copilot' }
        } else {
            Write-Host "not installed: $f"
        }
    }
    $found = @('claude', 'codex', 'copilot' | Where-Object { Test-Command $_ })
    $list = if ($found.Count -gt 0) { $found -join ' ' } else { 'none' }
    Write-Host "CLIs on PATH: $list"
    Write-CodexOverrideWarning
    if (Test-Command 'rtk') { Write-Host ("rtk: found ({0})" -f (Get-RtkVersion)) }
    else { Write-Host 'rtk: not found' }
    if ((Read-Text $ClaudeSettings).Contains('Read(./node_modules/**)')) { Write-Host 'claude ignore rules: active' }
    else { Write-Host 'claude ignore rules: not active' }
}

function Get-EstTokens([string]$path) {  # rough estimate: bytes / 4, rounded up; 0 if the file is missing
    $bytes = 0
    if (Test-Path -LiteralPath $path -PathType Leaf) { $bytes = [System.IO.File]::ReadAllBytes($path).Length }
    return [int][math]::Floor(($bytes + 3) / 4)
}

function Show-Cost {
    Write-Host 'Approximate tokens added to every session (bytes / 4, not an exact count):'
    $eff = Get-EstTokens (Get-LevelPath 'efficiency')
    $cl  = Get-EstTokens (Get-LevelPath 'claude-extra')
    $rt  = Get-EstTokens (Get-LevelPath 'copilot-rtk')
    foreach ($l in @('lite', 'normal', 'ultra')) {
        $n = Get-EstTokens (Get-LevelPath $l)
        Write-Host "  ${l}: ~$n (+ ~$eff efficiency, + ~$cl Claude-only extras, + ~$rt Copilot-only RTK rules, when RTK is detected)"
    }
}

# ---------- analyze (read-only) ----------

function Show-FileAnalysis([string]$path, [string]$label) {
    $bytes = [System.IO.File]::ReadAllBytes($path).Length
    $text  = [System.IO.File]::ReadAllText($path)
    $lines = [regex]::Split($text, "\r?\n")
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '' -and $text.EndsWith("`n")) {
        $lines = $lines[0..($lines.Count - 2)]
    }
    $narrRe = [regex]'for real|really happened|was caught|this happened|silently|bit the '
    $sections = New-Object 'System.Collections.Generic.List[object]'
    $state = @{ name = '(before first heading)'; idx = 0; sbytes = 0; narr = 0; have = $false }
    $flush = {
        if ($state.have) {
            $sections.Add([pscustomobject]@{
                Tokens = [int][math]::Floor(($state.sbytes + 3) / 4); Idx = $state.idx
                Narr = $state.narr; Name = $state.name })
        }
        $state.idx++; $state.sbytes = 0; $state.narr = 0; $state.have = $false
    }
    $fence = $false; $blen = 0; $longBlocks = 0
    foreach ($line in $lines) {
        $state.sbytes += $Utf8NoBom.GetByteCount($line) + 1
        if ($line -match '[^ \t]') { $state.have = $true }
        if ($line -match '^(```|~~~)') {
            if ($fence) { if ($blen -ge 15) { $longBlocks++ }; $fence = $false; $blen = 0 }
            else { $fence = $true; $blen = 0 }
        } elseif ($fence) { $blen++ }
        elseif ($line -match '^#+[ \t]') {
            & $flush
            $state.name = if ($line.Length -gt 70) { $line.Substring(0, 70) } else { $line }
            $state.have = $true
            $state.sbytes = $Utf8NoBom.GetByteCount($line) + 1
        }
        $state.narr += $narrRe.Matches($line.ToLowerInvariant()).Count
    }
    & $flush

    Write-Host ("{0}: ~{1} tokens ({2} bytes, {3} lines)" -f $label, (Get-EstTokens $path), $bytes, $lines.Count)
    Write-Host '  Largest sections (approx. tokens):'
    foreach ($s in @($sections | Sort-Object @{Expression='Tokens';Descending=$true}, @{Expression='Idx';Descending=$false} | Select-Object -First 5)) {
        Write-Host ("    {0,5}  {1}" -f $s.Tokens, $s.Name)
    }
    Write-Host "  Code blocks of 15+ lines: $longBlocks"
    $inc = @($sections | Where-Object { $_.Narr -ge 2 -and $_.Tokens -ge 150 } |
        Sort-Object @{Expression='Tokens';Descending=$true}, @{Expression='Idx';Descending=$false} | Select-Object -First 5)
    if ($inc.Count -gt 0) {
        Write-Host '  Sections that read like incident history rather than rules:'
        foreach ($s in $inc) { Write-Host ("    {0,5}  {1}" -f $s.Tokens, $s.Name) }
    }
}

function Invoke-Analyze([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Fail "not a directory: $dir" }
    Write-Host "Analyzing: $dir (read-only; nothing is changed)"
    $cdir = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $dir).Path).TrimEnd('\', '/')
    $total = 0; $seen = @(); $any = $false
    $biggest = ''; $biggestTok = 0
    $texts = New-Object 'System.Collections.Generic.List[object]'
    $note = {
        param([string]$rel, [string]$path)
        $t = Get-EstTokens $path
        $script:an_total += $t
        if ($t -gt $script:an_bigTok) { $script:an_big = $rel; $script:an_bigTok = $t }
        $script:an_texts.Add([pscustomobject]@{ Name = $rel; Text = (Read-Text $path).Replace("`r", '') })
    }
    $script:an_total = 0; $script:an_big = ''; $script:an_bigTok = 0; $script:an_texts = $texts
    # Every project instruction file the three tools read.
    foreach ($rel in @('AGENTS.md', 'CLAUDE.md', '.claude/CLAUDE.md', '.github/copilot-instructions.md')) {
        $f = Join-Path $dir $rel
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        $any = $true
        $raw = [regex]::Split((Read-Text $f), "\r?\n")
        $onlyImports = $true
        foreach ($l in $raw) { if ($l -ne '' -and -not $l.StartsWith('@')) { $onlyImports = $false; break } }
        if ($onlyImports) {
            $imports = @($raw | Where-Object { $_.StartsWith('@') })
            Write-Host ("{0}: imports only ({1})" -f $rel, ($imports -join ' '))
            foreach ($imp in $imports) {
                $parent = [System.IO.Path]::GetDirectoryName($rel)
                $ipath = if ($parent) { ($parent -replace '\\', '/') + '/' + $imp.Substring(1) } else { $imp.Substring(1) }
                $full = [System.IO.Path]::GetFullPath((Join-Path $dir $ipath))
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
                if ($seen -contains $full) { continue }
                $seen += $full
                $ipath = ($full.Substring($cdir.Length).TrimStart('\', '/')) -replace '\\', '/'
                Show-FileAnalysis $full $ipath
                & $note $ipath $full
            }
        } else {
            $full = [System.IO.Path]::GetFullPath($f)
            if ($seen -contains $full) { continue }
            $seen += $full
            Show-FileAnalysis $f $rel
            & $note $rel $f
        }
    }
    if (-not $any) { Write-Host "No AGENTS.md, CLAUDE.md or .github/copilot-instructions.md in $dir"; return }
    # Identical files are loaded twice by tools that read both (Copilot CLI combines all it finds).
    $first = @{}
    foreach ($e in $script:an_texts) {
        if ($first.ContainsKey($e.Text)) {
            Write-Host ("Note: {0} is identical to {1}; tools that read both load it twice. Keep one and delete or import the other." -f $e.Name, $first[$e.Text])
        } else { $first[$e.Text] = $e.Name }
    }
    $total = $script:an_total; $biggest = $script:an_big
    Write-Host "Loaded in every session from this folder: ~$total tokens (bytes / 4)"
    if ($total -lt 1500) { Write-Host 'That is lean; nothing to trim.'; return }
    Write-Host ''
    Write-Host 'Trimming ideas: keep rules, commands and constraints in the file; move incident stories,'
    Write-Host 'background and long explanations to a separate file the agent reads only when relevant.'
    Write-Host 'A prompt you can paste into Claude Code or Copilot Chat (it asks for a diff, so you review before anything changes):'
    Write-Host ''
    Write-Host "  Read $biggest and shorten it without losing any rule. Keep every rule, command and constraint."
    Write-Host '  Move incident stories, past-bug anecdotes and long background to docs/agent-notes.md and leave one'
    Write-Host "  line in $biggest pointing to it (`"Background and past incidents: docs/agent-notes.md, read only"
    Write-Host '  when relevant"). Merge duplicated rules. Do not change the meaning of any rule. Show me the diff'
    Write-Host '  before writing anything.'
}

# ---------- main ----------

$rest = New-Object 'System.Collections.Generic.List[string]'
foreach ($a in $args) {
    if ($a -ieq '--dry-run' -or $a -ieq '-dryrun') { $script:Dry = $true } else { $rest.Add([string]$a) }
}
$cmd = if ($rest.Count -gt 0) { $rest[0] } else { 'normal' }
$arg = if ($rest.Count -gt 1) { $rest[1] } else { $null }

try {
    switch ($cmd.ToLowerInvariant()) {
        'off' {
            foreach ($f in $Targets) {
                $t = Read-Text $f
                if ($t.Contains($StartPrefix)) {
                    if ($script:Dry) { Write-Host "would remove: $f"; continue }
                    $new = Remove-Block $t (Get-Eol $t) $f
                    Write-Text $f $new
                    Write-Host "removed: $f"
                }
            }
        }
        'status' { Show-Status }
        'cost'   { Show-Cost }
        'show' {
            $level = if ($arg) { $arg } else { 'normal' }
            if (-not (Test-Path -LiteralPath (Get-LevelPath $level) -PathType Leaf)) { Fail "unknown level: $level" }
            foreach ($l in (Get-Text $level)) { Write-Output $l }
        }
        { $_ -in 'ignore', 'unignore' } { Invoke-Ignore $_.ToLowerInvariant() }
        'analyze' { Invoke-Analyze $(if ($arg) { $arg } else { '.' }) }
        'init-project' { Invoke-InitProject $(if ($arg) { $arg } else { '.' }) }
        { $_ -in 'lite', 'normal', 'ultra' } {
            $level = $_.ToLowerInvariant()
            if (-not (Test-Path -LiteralPath (Get-LevelPath $level) -PathType Leaf)) { Fail "missing levels\$level.md" }
            switch ($RtkMode) {
                '0' { }
                '1' {
                    if (-not (Test-Command 'rtk')) { Fail 'BREVITY_RTK=1 but rtk is not installed' }
                    $script:RtkActive = $true
                }
                default { if (Test-Command 'rtk') { $script:RtkActive = $true } }
            }
            foreach ($f in $Targets) {
                if ($script:Dry) { Write-Host "would install [$level]: $f"; continue }
                $existing = Read-Text $f
                $eol = Get-Eol $existing
                $content = Remove-Block $existing $eol $f
                $block = New-Object 'System.Collections.Generic.List[string]'
                $block.Add("$StartPrefix level=$level -->")
                $block.AddRange([string[]](Get-Text $level))
                # Claude-only extras (compaction guidance); other tools don't read them.
                $extra = Get-LevelPath 'claude-extra'
                if ($f -eq $ClaudeMd -and (Test-Path -LiteralPath $extra)) {
                    $block.Add(''); $block.AddRange([string[]](Get-Lines $extra))
                }
                # Copilot CLI can't rewrite commands transparently, so with RTK present tell it to prefix them.
                $rtkRules = Get-LevelPath 'copilot-rtk'
                if ($f -eq $CopilotMd -and $script:RtkActive -and (Test-Path -LiteralPath $rtkRules)) {
                    $block.Add(''); $block.AddRange([string[]](Get-Lines $rtkRules))
                }
                $block.Add($EndMarker)
                $blockText = ($block -join $eol) + $eol
                $new = if ($content.Length -gt 0) { $content + $eol + $blockText } else { $blockText }
                Write-Text $f $new
                Write-Host "installed [$level]: $f"
            }
            if ($script:RtkActive) { Enable-Rtk }
            Write-CodexOverrideWarning
        }
        default {
            Write-Err 'usage: install.ps1 [lite|normal|ultra|off|status|cost|show [level]|ignore|unignore|init-project [dir]|analyze [dir]] [--dry-run]'
            exit 1
        }
    }
} catch {
    Write-Err ("error: " + $_.Exception.Message)
    exit 1
}
