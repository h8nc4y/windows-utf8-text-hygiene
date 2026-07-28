# Guarded Normalization

The destructive half of the skill: rewrite a file as UTF-8 without BOM +
LF + no trailing whitespace — but only behind the strict-decode guard.
This page shows the full pattern for a list of changed files, and the
measured incident that justifies the guard.

## Why the guard exists (measured)

A CP932 (Shift_JIS) file containing `日本語テスト` was read two ways:

| Read | Result |
| --- | --- |
| Strict: `[System.Text.UTF8Encoding]::new($false, $true)` | throws `DecoderFallbackException` — file identified as non-UTF-8, nothing touched |
| Lenient: `[System.IO.File]::ReadAllText($path)` | returns text with U+FFFD replacement characters — **no error, no warning** |

Writing the lenient result back produced a file whose Japanese was reduced
to unrecoverable `�`-junk; only ASCII-range bytes survived. There is no
undo for this outside version control — the original bytes are gone. The
lenient default makes the worst path the silent one, which is why the
strict decode comes first, always.

## Safety checklist (all boxes before running)

- [ ] Every target file is git-tracked and restorable
  (`git checkout -- <file>`); untracked targets are backed up first.
- [ ] Targets are text files you changed or added yourself — no binaries,
  no vendored code, no generated artifacts.
- [ ] No target `.ps1` is executed via Windows PowerShell 5.1 (hooks and
  Task Scheduler may run 5.1) — those must keep their BOM; see below.
- [ ] You are normalizing individual changed files, not bulk-converting
  the repository's line endings.

## The pattern

Normalize the files you changed in the current work (PowerShell; run from
anywhere, paths are explicit):

```powershell
$repo = '<repo>'
# Changed + added files via NUL-separated porcelain output. -z prints paths
# raw and unquoted; naive `git status --short` parsing does not survive this
# skill's own domain: with default core.quotepath, Japanese file names
# arrive octal-escaped ("\346\227\245..." inside quotes) and names with
# spaces arrive double-quoted — both silently fail an extension filter
# (measured). -z is immune to both.
$raw = (git -C $repo status --porcelain=v1 -z) -join ''
[string[]]$entries = @(
    $raw -split "`0" | Where-Object { $_ }
)
$files = @()
for ($i = 0; $i -lt $entries.Count; $i++) {
    $status = $entries[$i].Substring(0, 2)
    $path = $entries[$i].Substring(3)
    if ($status -match 'R') { $i++; continue }   # rename: skip entry + its old-path token
    if ($status -match 'D') { continue }         # deleted: nothing left to normalize
    $files += Join-Path $repo $path
}
$files = $files | Where-Object { $_ -match '\.(md|txt|yml|yaml|json|py|js|ts)$' }

$skipped = @()
foreach ($path in $files) {
    try {
        # Strict decode: non-UTF-8 input throws instead of silently
        # corrupting. A leading BOM is stripped on read.
        $t = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false, $true))
    } catch [System.Text.DecoderFallbackException] {
        # Not UTF-8 (suspected ANSI/Shift_JIS). Do not touch; do not
        # convert; record for the report and continue with other files.
        $skipped += $path
        continue
    }
    $t = $t.Replace("`r`n", "`n")
    $t = ($t -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n"
    [System.IO.File]::WriteAllText($path, $t, [System.Text.UTF8Encoding]::new($false))  # no BOM
}
if ($skipped.Count -gt 0) {
    "Skipped (strict decode failed, report as open unknowns):"
    $skipped
}
```

Notes:

- The extension filter is a starting point — widen or narrow it to your
  repository. Never let it pull in binaries.
- The rewrite preserves the file's final-newline state (split/join keeps a
  trailing empty element); it does not add a missing final newline.
- The enumeration was exercised against a repository containing a
  Japanese-named file, a name with spaces, a staged rename, and a deleted
  file: the rename pair and the deletion are skipped, the non-ASCII and
  space-bearing names come through intact (measured).
- Run the loop under `pwsh` 7, whose console encoding defaults to UTF-8.
  Under Windows PowerShell 5.1, git's output with non-ASCII file names may
  be decoded as the ANSI code page and corrupt the list before it is used.
- Porcelain paths are repo-root-relative, so `$repo` must be the
  repository root for `Join-Path` to resolve them.

## The PowerShell 5.1 exception

For a `.ps1` that Windows PowerShell 5.1 executes, write the BOM variant
instead:

```powershell
[System.IO.File]::WriteAllText($path, $t, [System.Text.UTF8Encoding]::new($true))
```

Measured reason: 5.1 reads BOM-less files as the system ANSI code page
(CP932 on Japanese systems). A trailing multi-byte character whose last
byte falls in the CP932 lead-byte range consumes the next byte — the
newline after a comment (fusing the next statement into the comment,
which then silently never executes, exit 0), the closing quote of a string
(`TerminatorExpectedAtEndOfString`), or a structural token
(`UnexpectedToken`). The BOM removes the ambiguity; `pwsh` 7 needs no BOM.

## Verify afterwards

```bash
git -C <repo> diff --check
git -C <repo> diff --cached --check
rg -al '\x00' <changed-files>
git -C <repo> diff <file>       # confirm only intended changes
```

Then read back any appended Japanese lines
(see [inspection one-liners](inspection-one-liners.md)).
