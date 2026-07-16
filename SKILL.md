---
name: windows-utf8-text-hygiene
description: >-
  Normalize and verify text-file encodings on Windows, especially Japanese
  content: repo text = UTF-8 without BOM, LF, no trailing whitespace, no NUL
  bytes. Use on symptoms like mojibake / garbled Japanese (文字化け), a UTF-8
  BOM appearing in diffs, CRLF creeping into a repo, git diff --check
  trailing-whitespace warnings, ripgrep saying "binary file matches" (a NUL
  byte) or "pattern contains \0 but it is impossible to match", Windows
  PowerShell 5.1 breaking on a BOM-less UTF-8 .ps1 with Japanese comments
  (parse errors or silently skipped statements), PowerShell backtick
  expansion turning `t / `f into TAB / form feed inside generated Markdown,
  or hook stdout emitting garbled Japanese. Includes a strict UTF-8 decode
  guard (DecoderFallbackException) that stops lenient reads from
  irreversibly destroying ANSI / CP932 (Shift_JIS) files via silent U+FFFD
  replacement.
---

# Windows UTF-8 Text Hygiene

Procedure for normalizing and verifying text-file encodings on Windows,
aimed at repositories that carry Japanese (or any non-ASCII) content. The
convention it enforces: **repository text files are UTF-8 without BOM, LF
line endings, no trailing whitespace, no NUL bytes** — with one deliberate
exception for Windows PowerShell 5.1 scripts, explained below.

The core of the skill is ordering: inspect non-destructively first,
normalize only what passes a strict UTF-8 decode, prevent corruption at
generation time, and verify again after every append.

## When To Use

- After writing or appending Japanese text to a repository's Markdown,
  docs, or scripts, as the post-edit verification step.
- When `git diff --check` warns about trailing whitespace, or CRLF shows up
  in a diff.
- When Japanese renders as mojibake (garbled characters such as `縺` or
  `?`), or ripgrep/grep starts reporting `binary file matches` — a sign of
  NUL-byte contamination.
- When a code span in PowerShell-generated Markdown is broken — `` `t ``
  became a TAB, `` `f `` became a form feed (backtick expansion).
- When adding a Japanese comment to a `.ps1` executed by Windows PowerShell
  5.1 caused a parse error — or worse, a statement silently stopped
  executing.
- When Japanese written to hook stdout (for example agent-harness hooks
  configured in a settings file) arrives garbled on the reading side.

## Ground Rules

- Repository text files are **UTF-8 without BOM + LF + no trailing
  whitespace**.
- Exception: **a `.ps1` with Japanese (non-ASCII) content that Windows
  PowerShell 5.1 executes must keep a UTF-8 BOM.** Without the BOM, 5.1
  reads the file as the system ANSI code page (CP932 on Japanese systems)
  instead of UTF-8. Scripts run only by PowerShell 7 (`pwsh`) do not need
  the BOM — 7 defaults to UTF-8.
- General git hygiene (line-ending strategy per repository, commit
  practices) follows your own project conventions; this skill carries only
  the encoding-specific rules.

### Why the PowerShell 5.1 exception exists (measured failure modes)

When 5.1 misreads BOM-less UTF-8 as CP932, a multi-byte sequence whose last
byte falls in the CP932 lead-byte range (0x81–0x9F, 0xE0–0xFC) makes the
decoder consume the NEXT byte as its trail byte. Three failure modes were
measured on Windows 11 with a `.ps1` containing Japanese comments and
string literals (all three reproduce with the katakana `ト`, UTF-8
`E3 83 88` — the trailing `88` is a CP932 lead byte):

1. **Silently skipped statement (worst case).** A comment line ending in
   such a byte swallows the following newline (`0x0A`), so the comment and
   the next line fuse into one comment line. A `$msg = '...'` assignment on
   that next line simply never executes — the script exits 0 with no error
   and the variable is empty.
2. **`TerminatorExpectedAtEndOfString`.** A string literal ending in such a
   byte swallows its own closing quote (`0x27`), producing "The string is
   missing the terminator".
3. **`UnexpectedToken`.** The same mechanism eats a structural token,
   breaking the surrounding construct — measured as `Unexpected token '}'`
   on a function's closing brace after a `param(...)` default-value string
   lost its terminator. The exact parser error ID varies with the
   construction; the constant part is the mechanism and the broken
   surrounding definition.

The same BOM-less file runs correctly under `pwsh` 7, and the same file
with a BOM runs correctly under 5.1 — hence the exception.

## Procedure

### Inspection (non-destructive)

1. Limit the target to files you changed, then check trailing whitespace
   and CRLF (Git Bash / POSIX paths). `git diff --check` inspects **only
   unstaged changes** — anything already staged with `git add` needs
   `--cached` separately. Measured: appending a CRLF line with trailing
   spaces produced warnings (exit 2) while unstaged; after `git add` the
   plain form passed silently (exit 0) and only `--cached --check` caught
   it (exit 2):

   ```bash
   git -C <repo> status --short
   git -C <repo> diff --check            # unstaged: trailing whitespace, conflict markers
   git -C <repo> diff --cached --check   # staged: required after git add, or issues pass silently
   ```

2. Check for a BOM at the byte level (PowerShell):

   ```powershell
   $b = [System.IO.File]::ReadAllBytes($path)
   $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
   ```

   In Git Bash, `head -c 3 <file> | od -An -tx1` prints `ef bb bf` when a
   BOM is present.

3. Check for NUL bytes (Git Bash; behavior measured):

   ```bash
   rg -al '\x00' <dir-or-files>   # any file listed = NUL contamination
   ```

   Without `-a`, ripgrep refuses with `pattern contains "\0" but it is
   impossible to match` and exits 2 (measured) — the flag is not optional.
   grep needs `-a` for the same reason: `grep -laP '\x00'` detects the
   file, while `grep -lP '\x00'` treats it as binary and exits 1 with no
   output (measured). `rg -al` is the faster, terser option for listing
   affected files. PowerShell alternative:
   `[System.IO.File]::ReadAllBytes($path) -contains 0`.

### Normalization (destructive — every safety condition below must hold first)

4. Run a strict UTF-8 decode first, and rewrite (BOM removal + LF + trailing
   whitespace removal) **only the files that pass**. A plain
   `ReadAllText($path)` silently replaces invalid UTF-8 bytes with U+FFFD,
   so applying this step to an ANSI / Shift_JIS (CP932) file destroys the
   original text irreversibly. Measured with a CP932 file containing
   `日本語テスト`: the strict read threw `DecoderFallbackException`; the
   lenient read returned text with U+FFFD in it; writing that text back left
   irrecoverable `�`-junk in place of the Japanese (only the ASCII-range
   bytes survived — the visual rendering of the wreckage varies with the
   viewer's encoding, but the original bytes are gone either way):

   ```powershell
   try {
       # throwOnInvalidBytes=true: non-UTF-8 input (ANSI/Shift_JIS etc.) throws
       # instead of silently corrupting. A leading BOM is stripped on read.
       $t = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false, $true))
   } catch [System.Text.DecoderFallbackException] {
       # This file is not UTF-8. Abort normalization for it and record the
       # decision as an open unknown in the report (no silent Shift_JIS->UTF-8
       # conversion). Continue with the other files.
       return
   }
   $t = $t.Replace("`r`n", "`n")
   $t = ($t -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n"
   [System.IO.File]::WriteAllText($path, $t, [System.Text.UTF8Encoding]::new($false))  # no BOM
   ```

5. For `.ps1` files that Windows PowerShell 5.1 executes, write with a BOM
   instead:

   ```powershell
   [System.IO.File]::WriteAllText($path, $t, [System.Text.UTF8Encoding]::new($true))
   ```

### Prevention at generation time

6. When assembling backtick-bearing Markdown in PowerShell, use a
   **single-quoted here-string plus placeholder substitution**. In
   double-quoted strings and here-strings, `` `t `` expands to TAB and
   `` `f `` to form feed (measured), so code spans written there arrive
   corrupted:

```powershell
$tpl = @'
Body text. Write code spans like `auth.json` directly here. Variable values go in as __NAME__.
'@
$out = $tpl.Replace('__NAME__', $value)
```

   Note: the closing `'@` of a here-string must sit at **column 0** (start
   of line). Pasting this pattern into indented code moves the terminator
   off column 0 and produces a parse error — strip the indentation when
   embedding. (The example above is deliberately left unindented.)

7. Write hook stdout as raw UTF-8 bytes. By default, console output follows
   the console code page, and a harness that reads the stream as UTF-8 sees
   garbled Japanese:

   ```powershell
   function Write-Utf8Stdout([string]$s) {
       $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
       $stream = [Console]::OpenStandardOutput()
       $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
   }
   ```

### Post-append verification

8. After appending to a Japanese document, read the appended lines back and
   check for mojibake and control-character contamination (PowerShell):

   ```powershell
   Select-String -Path $path -Pattern '<part of the heading you appended>' -Encoding utf8
   Select-String -Path $path -Pattern "[`t`f]"   # any hit = suspected backtick-expansion accident
   ```

   The second pattern is deliberately double-quoted so `` `t `` and
   `` `f `` expand into the actual TAB / form-feed characters being hunted.

9. Finish with `git diff --check` AND `git diff --cached --check` (see step
   1 for why both), plus `git diff <file>` to confirm only the intended
   change is present.

## Safety Conditions

Preconditions for normalization (steps 4–5) — check every box first:

- [ ] The target file is under git control and can be restored with
  `git diff` / `git checkout -- <file>`. Take a backup copy of untracked
  files before touching them.
- [ ] The strict UTF-8 decode (`[System.Text.UTF8Encoding]::new($false,
  $true)`) completes without an exception. A file that fails is suspected
  ANSI / Shift_JIS: do not apply steps 4–5, do not convert its encoding as
  a side effect — record it as an open unknown in the report.
- [ ] The targets are text files you changed or added yourself. Do not
  apply to binaries (images, executables), vendored code, or generated
  artifacts such as `node_modules`.
- [ ] Before removing a BOM from any `.ps1`, confirm the script is never
  executed via Windows PowerShell 5.1 (hooks and Task Scheduler entries may
  run 5.1 even when your interactive shell is `pwsh` 7).
- [ ] Repository-wide bulk CRLF→LF conversion is out of scope for this
  skill (it collides with `.gitattributes` / `core.autocrlf` policy and
  produces huge diffs). When in doubt, do not bulk-convert: keep working
  file-by-file on the files you changed, and record the deferred decision
  as an open unknown (do not stop).
- [ ] Do not machine-apply the control-character check of step 8 to files
  where TAB is syntactically required (Makefiles and similar). On a false
  positive, exclude the file and continue.

Stop condition:

- If the same failure class does not improve after three attempts, stop and
  report what failed and what evidence remains.

## Completion Checklist

- [ ] `git diff --check` and `git diff --cached --check` both produce no
  output.
- [ ] `rg -al '\x00'` matches none of the target files.
- [ ] The BOM byte-check is False for repository text (True only for `.ps1`
  files executed by Windows PowerShell 5.1).
- [ ] Appended Japanese lines read back correctly via `Select-String`, with
  no TAB / form-feed characters introduced by backtick expansion.
- [ ] `git diff` shows no unintended changes beyond the encoding
  normalization itself.

## Reporting

- Number of files inspected, and the breakdown of problems found (BOM /
  CRLF / trailing whitespace / NUL / mojibake).
- The list of files normalized, and a summary of the verification commands
  actually run with their results (never report a verification that was not
  run).
- Any `.ps1` whose BOM was kept, with the reason (executed by Windows
  PowerShell 5.1).
- Deferred decisions and open unknowns: files skipped because strict decode
  failed, bulk CRLF→LF conversion left out of scope, and similar.

## Provenance

This skill is distilled from repeated real-world agent operations on
Windows development machines carrying Japanese-language repositories —
every rule above traces back to an observed failure or a verified recovery,
not to speculation. The concrete behaviors documented here (the CP932
lenient-read round-trip destruction, the ripgrep/grep `-a` requirement for
NUL patterns, the `git diff --check` staged/unstaged split, the backtick
expansion of `` `t `` / `` `f ``, and the three Windows PowerShell 5.1
BOM-less failure modes) were each reproduced by executing the commands
shown, on Windows 11 with PowerShell 7.x, Windows PowerShell 5.1, ripgrep,
and Git Bash. Wording like "measured" marks those direct observations.
Behavior not directly measured (for example exact rendering of destroyed
bytes under other viewers) is qualified inline.
