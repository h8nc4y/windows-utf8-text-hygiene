# windows-utf8-text-hygiene

[![Validate](https://github.com/h8nc4y/windows-utf8-text-hygiene/actions/workflows/validate.yml/badge.svg)](https://github.com/h8nc4y/windows-utf8-text-hygiene/actions/workflows/validate.yml)

An agent skill for Claude Code and Codex: keep repository text files clean
on Windows — UTF-8 without BOM, LF line endings, no trailing whitespace, no
NUL bytes — with a strict-decode guard against irreversible CP932
(Shift_JIS) corruption, a deliberate BOM exception for Windows PowerShell
5.1 scripts, and defenses against PowerShell backtick-expansion accidents
in generated Markdown.

## What It Solves

Windows machines running agents on Japanese-language (or any non-ASCII)
repositories hit a recurring family of text-corruption incidents:

- A "normalize this file" pass reads an ANSI / CP932 file with a lenient
  UTF-8 decoder, silently replaces every Japanese character with U+FFFD,
  and writes the wreckage back — **the original text is gone**. Measured:
  a CP932 `日本語テスト` survives a strict decode as a clean
  `DecoderFallbackException`, but a lenient read-plus-write leaves
  unrecoverable `�`-junk.
- Windows PowerShell 5.1 reads a BOM-less UTF-8 `.ps1` as CP932. Measured
  failure modes go beyond parse errors: a Japanese comment line can
  **swallow the following newline**, fusing the next statement into the
  comment — the script exits 0 and the statement simply never ran.
- NUL-byte scans need `-a` on both major tools, with different failure
  shapes when it is missing: ripgrep refuses the `\x00` pattern outright
  (`pattern contains "\0" but it is impossible to match`, exit 2), while
  grep silently treats the file as binary and reports nothing — a true
  false all-clear.
- `git diff --check` sees only unstaged changes; once you `git add`, the
  same trailing-whitespace problems pass silently unless you also run
  `--cached --check`.
- PowerShell double-quoted strings expand `` `t `` / `` `f `` into TAB and
  form-feed characters, corrupting backtick code spans in generated
  Markdown.

The skill packages the working order of operations: inspect
non-destructively, normalize only what passes a strict UTF-8 decode,
prevent corruption at generation time, and verify after every append.

## Who It Is For

- Claude Code / Codex users whose agents write Japanese (or any non-ASCII)
  text into repositories on Windows.
- Anyone maintaining a "UTF-8 without BOM + LF" convention on Windows who
  wants the failure modes documented before hitting them.
- Script authors who still have Windows PowerShell 5.1 in the execution
  path (hooks, Task Scheduler) and need to know exactly when a BOM is
  mandatory.

## Install

Clone the repository:

```bash
git clone https://github.com/h8nc4y/windows-utf8-text-hygiene.git
cd windows-utf8-text-hygiene
```

### Claude Code

Claude Code auto-invokes the skill when a task matches the `description`
frontmatter. Install for your user account on shells with POSIX syntax:

```bash
dest="${HOME}/.claude/skills/windows-utf8-text-hygiene"
if [ -e "$dest" ]; then
  echo "Install target already exists: $dest"
else
  mkdir -p "$dest"
  cp SKILL.md "$dest/SKILL.md"
fi
```

Install for your user account from PowerShell:

```powershell
$dest = Join-Path $HOME '.claude\skills\windows-utf8-text-hygiene'
if (Test-Path -LiteralPath $dest) {
  Write-Host "Install target already exists: $dest"
} else {
  New-Item -ItemType Directory -Path $dest | Out-Null
  Copy-Item -LiteralPath .\SKILL.md -Destination (Join-Path $dest 'SKILL.md')
}
```

Notes:

- If you set `CLAUDE_CONFIG_DIR`, replace `~/.claude` with that directory.
- To scope the skill to a single project instead, copy `SKILL.md` to
  `.claude/skills/windows-utf8-text-hygiene/SKILL.md` inside that project's
  repository.

The existence guard is intentional: do not overwrite an already-installed
skill without reviewing the local copy first.

### Codex (agent skills)

Manual Codex-style skill install on shells with POSIX syntax:

```bash
dest="${HOME}/.agents/skills/windows-utf8-text-hygiene"
if [ -e "$dest" ]; then
  echo "Install target already exists: $dest"
else
  mkdir -p "$dest"
  cp SKILL.md "$dest/SKILL.md"
fi
```

Manual Codex-style skill install from PowerShell:

```powershell
$dest = Join-Path $HOME '.agents\skills\windows-utf8-text-hygiene'
if (Test-Path -LiteralPath $dest) {
  Write-Host "Install target already exists: $dest"
} else {
  New-Item -ItemType Directory -Path $dest | Out-Null
  Copy-Item -LiteralPath .\SKILL.md -Destination (Join-Path $dest 'SKILL.md')
}
```

To scope the skill to a single project instead, copy `SKILL.md` to
`.agents/skills/windows-utf8-text-hygiene/SKILL.md` inside that repository —
Codex scans `.agents/skills` from the working directory up to the
repository root (per the official skills documentation).

If your agent reads skills from a different directory, check its
documentation and copy `SKILL.md` into the matching
`skills/windows-utf8-text-hygiene/` folder.

## Manual Use

Reach for the skill when you see one of these symptoms:

- Japanese text renders as mojibake (`縺`, `?`, `譌･譛ｬ...`-style garbage).
- A UTF-8 BOM shows up in diffs or breaks a tool that expects plain UTF-8.
- CRLF creeps into a repository that standardizes on LF.
- `git diff --check` warns about trailing whitespace — or worse, stops
  warning after `git add` even though the problem is still there.
- ripgrep reports `binary file matches`, or errors with `pattern contains
  "\0" but it is impossible to match` when you search for NUL bytes.
- A BOM-less `.ps1` with Japanese comments fails under Windows PowerShell
  5.1 with `TerminatorExpectedAtEndOfString` / `UnexpectedToken` — or
  silently skips statements while exiting 0.
- Backtick code spans in PowerShell-generated Markdown arrive with literal
  TAB / form-feed characters in them.
- Japanese written to hook stdout is garbled on the reading side.

Follow the procedure in [SKILL.md](SKILL.md): inspect (whitespace/CRLF →
BOM → NUL), normalize only the files that pass the strict UTF-8 decode
guard, apply the prevention patterns for generated content, and re-verify
after every append.

## Synthetic Examples

- [Inspection one-liners](examples/inspection-one-liners.md) — verified
  detection commands for BOM, CRLF, NUL bytes, and control-character
  contamination, in PowerShell and Git Bash / POSIX form.
- [Guarded normalization](examples/guarded-normalization.md) — the
  strict-decode-guarded normalization loop with its safety checklist, plus
  the measured before/after of why the guard exists.
- [.gitattributes / .editorconfig sample](examples/gitattributes-editorconfig-sample.md)
  — a minimal pair of config files that prevent most of this document's
  problems from entering a new repository at all.

The examples use placeholders only. Do not replace them with secrets, real
repository paths you cannot publish, or customer data in public issues.

## Dogfooding

This repository follows its own convention: tracked text is UTF-8 without
BOM, LF, with no trailing whitespace and no NUL bytes. The deliberate
exception is the validation, scanner, self-test, and process-boundary
`.ps1` files with Japanese comments that Windows PowerShell 5.1 executes;
those files retain a UTF-8 BOM so 5.1 cannot misread them as CP932. CI
validates that exception and
the whitespace rules on every push and pull request
(`git diff-tree --check` against the empty tree), and the skill's own
inspection commands were run against the repository before publication.

## 日本語概要 (Japanese Overview)

Windows での（特に日本語）テキストファイルの encoding 正規化と検証の
skill です。規約は「repo テキスト = UTF-8 BOM なし + LF + 行末空白なし +
NUL バイトなし」。例外として、Windows PowerShell 5.1 で実行する日本語
入り `.ps1` だけは BOM 必須です（BOM なしだと 5.1 が CP932 として誤読し、
実測では構文エラーだけでなく「コメント行が直後の改行を飲み込み、次の文が
黙って実行されなくなる」exit 0 のサイレント破壊まで起きる）。

- 中核は strict UTF-8 デコード検査: `DecoderFallbackException` で
  ANSI / CP932 ファイルを検出し、lenient 読みの U+FFFD 置換による
  不可逆破壊（実測: CP932「日本語テスト」が復元不能に）を防ぐ。
- NUL 混入検査は `rg -al '\x00'`（`-a` なしは `pattern contains "\0" but
  it is impossible to match` エラーになる点に注意）。
- `git diff --check` は unstaged しか見ないため、`git add` 済みの変更は
  `git diff --cached --check` で別途検査する。
- PowerShell の backtick 展開事故（`` `t `` → TAB、`` `f `` → form feed）
  は single-quoted here-string + placeholder 置換で予防する。
- hook stdout の日本語は raw UTF-8 バイトで直書きする。

日本語の完全版は [docs/SKILL.ja.md](docs/SKILL.ja.md) にあります。
インストールは上記の手順どおり、`SKILL.md` を Claude Code なら
`~/.claude/skills/windows-utf8-text-hygiene/` へ、Codex なら
`~/.agents/skills/windows-utf8-text-hygiene/` へコピーしてください。

## Related Skills

Same series — Windows agent-operations skills by the same maintainer:

- [claude-code-devlog-hooks](https://github.com/h8nc4y/claude-code-devlog-hooks)
  — Claude Code hooks on Windows; its UTF-8-stdout guidance and this
  skill's hook-stdout rule (step 7) address the same failure from two
  sides.
- [windows-github-auth-diagnosis](https://github.com/h8nc4y/windows-github-auth-diagnosis)
  — diagnosing false-negative GitHub auth errors in Windows agent
  sandboxes.
- [isolated-worktree-pr-flow](https://github.com/h8nc4y/isolated-worktree-pr-flow)
  — shipping PRs from a temporary worktree when the main checkout is
  dirty or shared.

## Safety Notes

- Normalization is destructive: run it only on git-tracked files you can
  restore, only after the strict UTF-8 decode passes, and never as a bulk
  repository-wide CRLF→LF conversion (that belongs to `.gitattributes`
  policy, not to this skill).
- A file that fails the strict decode is evidence of ANSI / Shift_JIS
  content. Converting its encoding is a separate decision to surface in
  your report — not a side effect to apply silently.
- Never paste tokens, credentials, private logs, or customer data into
  issues, commits, or examples.

## Limitations

- The skill's commands are exercised on Windows 11 with PowerShell 7.x,
  Windows PowerShell 5.1, ripgrep, and Git Bash. The PowerShell snippets
  target .NET APIs available in both 5.1 and 7. The bounded
  [macOS compatibility run](https://github.com/h8nc4y/windows-utf8-text-hygiene/actions/runs/30205393010)
  measured `macos-15-arm64` image `20260715.0234.1` with PowerShell Core
  `7.6.3`: the complete self-test, private-marker scan, and whitespace check
  passed, with both automatic and forced gates reporting `native-setsid`.
  This evidence applies to that measured runner; Windows PowerShell 5.1
  remains a Windows-only contract and is not substituted by the macOS job.
- The mojibake examples are CP932 (Japanese Shift_JIS)-specific. The
  strict-decode guard itself is encoding-agnostic — any non-UTF-8 input
  throws — but the documented byte-level failure modes were measured
  against CP932 only.
- Character-encoding *conversion* (Shift_JIS → UTF-8 migration) is out of
  scope by design; the skill detects and refuses, it does not convert.

## Non-Goals

- No automation scripts that normalize files for you. This repository is a
  written discipline with copy-adaptable commands, not a tool.
- No general character-encoding tutorial; the focus is the specific
  Windows / PowerShell / git failure modes and their working defenses.
- No repository-wide line-ending migration playbook.

## Validation

Run the full local validation from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
```

If `pwsh` is available, the same checks can be run with:

```powershell
pwsh -NoProfile -File .\scripts\validate-oss-readiness.ps1
pwsh -NoProfile -File .\scripts\test-scan-private-markers.ps1
pwsh -NoProfile -File .\scripts\scan-private-markers.ps1
```

On macOS, Linux, or any POSIX shell with PowerShell 7 (`pwsh`) installed:

```bash
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
```

Also run Git whitespace checks on your working changes before publishing:

```bash
git diff --check
git diff --cached --check
```

The GitHub Actions workflow runs the same validation, scan self-test,
private-marker scan, and whitespace check on pull requests and pushes to
`main`. Windows runs the self-test separately under PowerShell 7 and
Windows PowerShell 5.1; Ubuntu 24.04 runs the PowerShell 7 self-test to
exercise both its normal external `setsid` path and the forced native
`setsid(2)` fallback. The macOS 15 job uses PowerShell 7 only and exercises
the native POSIX session fallback; it does not claim Windows PowerShell 5.1
coverage. The POSIX self-test also requires the process helper to report the
expected gate, return a zero target exit code, prove that the descendant
started, and prove that group cleanup stopped it. Native calls bind to `libc`
through the POSIX runtime resolver. Native gate failures expose only a fixed
stage code (`compile`, `setsid` call, or ready handshake); paths and child
output are not reflected. Each validation job has a finite timeout, and the
helper uses one deadline for launch, handshake, and target execution. The
self-test also rejects an already exited zero-code child when setup or stream
cleanup consumes that deadline. It always reuses the host that started it
instead of silently substituting `pwsh` for a 5.1 check. See
[the macOS PowerShell CI contract](docs/macos-pwsh-ci-contract.md).

Git-backed file enumeration is also hermetic and bounded. Each `git`
probe receives a sanitized child-only environment, empty global/system
configuration, and inert hook/attribute/exclude/template settings.
Its per-command deadline defaults to 15 seconds and cannot be raised
above that value; the self-test lowers it only for the synthetic hang
fixture.
On Windows, the requested executable is created suspended with only its
three standard-I/O handles inheritable, assigned to a kill-on-close Job,
and resumed only after assignment. An immediately spawning command
therefore cannot create a descendant outside the Job during assignment.
On POSIX, the requested executable starts in a dedicated session/process
group before its first instruction. Cleanup signals that whole group with
`kill(2)` and treats only success or `ESRCH` as a successful stop; permission
and other signal failures remain fail-closed.
Ambient `GIT_*`, home/config, prompt, filter, or trace settings cannot
redirect the scan to another repository or create trace artifacts. The
scanner also disables promisor-remote lazy fetches and replacement refs,
so a local scan neither retrieves a missing object nor substitutes another
blob for the OID recorded in the index. It never mutates the caller's
process environment. In a repository, one binary-safe `git cat-file
--batch` reads the unique staged blobs for recognized text candidates:
common source/config text extensions, extensionless names, `.env`,
`.env.*`, `*.env`, `.pem`, `.key`, and selected high-signal dotfiles such
as `.npmrc`. Differing regular worktree content is scanned as well. Unknown
extensions are skipped to avoid decoding binary files; this remains a
targeted marker scanner, not a universal content classifier. After all
index/worktree snapshots are collected and analyzed, the scanner repeats
the same hermetic `git ls-files -z --stage` and index-debug queries
immediately before its result and requires byte-identical raw output,
rejecting staged additions, replacements, or flag-only changes that
occurred mid-scan.
Text decoding, line length/count, regex matches, findings per file,
findings per scan, and diagnostic width are independently bounded.
Every regular expression in `scripts/scan-private-markers.ps1` that parses
scan targets or Git output uses the PowerShell 5.1-compatible three-argument
.NET constructor with a finite match timeout of at most 250 ms. Regex
operators and alternate construction paths are rejected by an AST readiness
gate. A timeout is held until Git isolation
cleanup has succeeded, then returns one fixed redacted `regex-timeout`
line and exit code 2 without replaying the input, pattern, or local path.
If Git-isolation cleanup or its integrity checks fail, that higher-priority
failure retains precedence and is not misreported as a regex timeout.
Diagnostics escape control/format characters (including bidi controls)
and Unicode line/paragraph separators instead of emitting them raw.
Process output limits are measured from the actual raw byte stream,
including prefixes and the platform newline; an exact limit is accepted
and the next byte fails closed. Unresolvable user-supplied paths are
reported with fixed diagnostics rather than replaying the path.
Same-line duplicate matches are collapsed, so adversarial input cannot
multiply the report without limit. In non-Git fallback, both `.git`
directories and leaf gitfiles are excluded from content scanning.
Conflicts, intent-to-add entries (including missing-worktree entries),
symlinks/reparse points (including a
dangling `.git` marker or a junction in a tracked file's parent chain),
gitlinks, malformed Git output, incomplete pipe reads, and Git failures
other than an explicit "not a repository" result fail closed instead of
silently switching scan scope. If Git is unavailable, a `.git` entry in
the target or its ancestry also blocks working-tree fallback.

## Contributing

Contributions are welcome when they make the hygiene rules safer, clearer,
or easier to verify. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening
a pull request.

Keep all examples synthetic. Do not include tokens, credentials, private
repository names, internal absolute paths, or customer data.

For local-only private markers, create an untracked `.private-markers.local`
file with one literal marker per line, or set
`WINDOWS_UTF8_TEXT_HYGIENE_PRIVATE_MARKERS` with newline-separated markers.
The scanner reads these values but does not print the matched marker. It
fails closed if `.private-markers.local` appears in the Git index.

## Security

If you find unsafe guidance or accidental private-data exposure, follow
[SECURITY.md](SECURITY.md) and use private reporting for sensitive details.

## License

MIT. See [LICENSE](LICENSE).
