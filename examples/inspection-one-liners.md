# Inspection One-Liners

Non-destructive detection commands for each contamination class. Every
command below was executed and its behavior confirmed on Windows 11
(PowerShell 7.x + Git Bash + ripgrep); notes call out the sharp edges.

Placeholders: `<repo>` is your repository path, `<file>` / `<dir>` the
target file or directory, `$path` a PowerShell variable holding one file
path.

## Trailing whitespace and CRLF in your pending changes (git)

```bash
git -C <repo> diff --check            # unstaged changes only
git -C <repo> diff --cached --check   # staged changes — required after git add
```

Sharp edge (measured): `git diff --check` inspects **only unstaged
changes**. Appending a CRLF line with trailing spaces produced warnings
(exit 2) while unstaged; after `git add`, the plain form passed silently
with exit 0 and only `--cached --check` caught the problem. Run both, every
time.

## BOM (UTF-8 byte order mark)

PowerShell, single file:

```powershell
$b = [System.IO.File]::ReadAllBytes($path)
$hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
```

PowerShell, sweep a directory tree (text files only, adjust the filter):

```powershell
Get-ChildItem <dir> -Recurse -File -Include *.md,*.ps1,*.yml,*.txt |
  Where-Object {
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
  } | ForEach-Object FullName
```

Git Bash, visual check of the first three bytes:

```bash
head -c 3 <file> | od -An -tx1    # "ef bb bf" = BOM present
```

## CRLF inside file content

ripgrep (lists files containing CR-before-EOL; measured — an LF-only file
is not listed):

```bash
rg -l '\r$' <dir-or-files>
```

PowerShell byte-level check (measured; catches CR anywhere, including a
file with no trailing newline):

```powershell
$hasCR = [System.IO.File]::ReadAllBytes($path) -contains 0x0D
```

## NUL bytes

ripgrep (measured):

```bash
rg -al '\x00' <dir-or-files>   # any file listed = NUL contamination
```

Sharp edge (measured): without `-a`, ripgrep refuses the pattern entirely —
`pattern contains "\0" but it is impossible to match` — and exits 2. The
same applies to grep: `grep -laP '\x00'` detects the file, while
`grep -lP '\x00'` treats it as binary and exits 1 with no output. A scan
that forgets `-a` reports a false all-clear (grep) or errors out (rg).

PowerShell alternative:

```powershell
$hasNul = [System.IO.File]::ReadAllBytes($path) -contains 0
```

## Control characters from backtick expansion (TAB / form feed in Markdown)

PowerShell (the pattern is deliberately double-quoted so `` `t `` and
`` `f `` expand into the actual characters being hunted; measured):

```powershell
Select-String -Path $path -Pattern "[`t`f]"
```

ripgrep equivalent (measured):

```bash
rg -l '[\t\f]' <dir-or-files>
```

Exclusion rule: skip files where TAB is syntactically required (Makefiles
and similar). A hit there is a false positive — exclude and continue.

## Mojibake readback after appending Japanese text

```powershell
Select-String -Path $path -Pattern '<part of the heading you appended>' -Encoding utf8
```

No hit for text you just appended = the write was mangled (wrong encoding,
mojibake) — inspect before appending anything else.
