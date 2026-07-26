# Contributing

Thanks for improving this skill. This repository is intentionally small:
changes should make the encoding-hygiene rules safer, clearer, or easier
to verify.

## Before You Start

- Read [SKILL.md](SKILL.md) and the examples under [examples](examples).
- `SKILL.md` (English) is canonical. When you change it, update
  [docs/SKILL.ja.md](docs/SKILL.ja.md) in the same pull request so the two
  stay in sync.
- Do not paste tokens, credentials, private keys, OAuth codes, raw logs,
  customer data, private repository names, or internal absolute paths into
  issues, pull requests, commits, or examples. No token or secret value ever
  belongs in this repository.
- Use synthetic placeholders such as `<repo>`, `<file>`, `<dir-or-files>`,
  and `$path` for examples. Mojibake samples must be synthetic
  (`日本語テスト`-class fixtures), never fragments of real private
  documents.
- Put personal or organization-specific scan markers in an untracked
  `.private-markers.local` file, not in repository source.

## Grounding Rules

This skill's value is that every behavior claim traces to observed
behavior. Keep it that way:

- Claims about encoder/decoder, PowerShell, ripgrep, or git behavior
  should be grounded in something observable (a reproducible command
  sequence with its output). The skill marks these with "measured" —
  follow that convention.
- Mark speculation and design-derived-but-unvalidated guidance explicitly
  as unverified.
- Do not remove existing honesty markers ("measured", "unverified")
  without evidence that changes their status.
- Encoding behavior is version- and locale-sensitive: state the
  environment you measured on (OS, PowerShell edition and version, system
  code page) when adding new measured claims.

## Repository Hygiene (dogfooding)

This repository follows its own convention: tracked text is UTF-8 without
BOM, LF, no trailing whitespace, and no NUL bytes. The documented
exception applies to `.ps1` files with Japanese comments that are executed
by Windows PowerShell 5.1: those files intentionally retain a UTF-8 BOM.
Before opening a pull request, run the skill's own inspection steps on
your changes — CI enforces the scanner scripts' BOM contract and the
whitespace checks.

## Development Workflow

1. Create a focused branch.
2. Make the smallest coherent change.
3. Update examples or README text when user-facing guidance changes.
4. Add or adjust validation when a safety rule should be machine-checkable.
5. Run the validation commands before opening a pull request.

## Validation

From the repository root, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
git diff --check
git diff --cached --check
```

If `pwsh` is available, it is also acceptable for the PowerShell scripts:

```powershell
pwsh -NoProfile -File .\scripts\validate-oss-readiness.ps1
pwsh -NoProfile -File .\scripts\test-scan-private-markers.ps1
pwsh -NoProfile -File .\scripts\scan-private-markers.ps1
```

On macOS, Linux, or any POSIX shell with PowerShell 7 (`pwsh`) installed,
use forward slashes:

```bash
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
```

Platform results are not interchangeable. Windows verifies PowerShell 7,
Windows PowerShell 5.1, and Job Object containment. Ubuntu verifies
PowerShell 7 with the external `setsid` path plus a forced native
`setsid(2)` case. The bounded macOS 15 job verifies PowerShell 7 and the
native POSIX session fallback only; it does not provide PowerShell 5.1
coverage. POSIX success requires the observed session gate, a zero target exit,
and descendant start/cleanup evidence to agree with the host contract. A
native gate failure may report only its fixed stage code; do not add raw paths
or child output to CI diagnostics. The current measured macOS evidence is
[run 30205393010](https://github.com/h8nc4y/windows-utf8-text-hygiene/actions/runs/30205393010):
PowerShell Core 7.6.3 on image `macos-15-arm64` version `20260715.0234.1`
passed the full contract. Treat a runner-image, PowerShell-version, resolver,
or timeout change as new evidence; do not generalize this result to an
unmeasured environment.

The scanner self-test includes a near-limit safe line and an adversarial
one-million-character no-match line. The safe control must pass, while a
regex timeout must finish inside the bounded process window, emit only the
fixed redacted `regex-timeout` line, and exit 2 without exposing fixture or
repository paths. Readiness parses the production scanner AST: it rejects
regex operators, casts and arrays, shortened or alternate Regex types,
`switch -Regex`, `Select-String`, and dynamic or Regex `New-Object` types.
It also pins the sole three-argument constructor to the timeout derived
from `Math.Min(250, scan-wide budget)`, with mutation fixtures for each
entry point and timeout-provenance replacement.

## Pull Request Expectations

- Explain the problem and the chosen fix.
- Include validation results.
- Call out any remaining unknowns.
- If the change alters the strict-decode guard, a safety condition, or the
  PowerShell 5.1 BOM exception, describe the corruption or data-loss mode
  it prevents (or the false refusal it removes) concretely.

## Maintainer Notes

Prefer documentation and validation that prevent irreversible text
corruption. Avoid adding broad dependencies or network-backed checks
unless they are clearly necessary for public safety.
