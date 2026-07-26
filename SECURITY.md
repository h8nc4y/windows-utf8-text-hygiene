# Security Policy

This repository documents an encoding normalization / verification
workflow. It should never contain secrets, but its guidance drives agents
through destructive file rewrites, so unsafe guidance is treated as a
security problem too.

## Supported Versions

The `main` branch is the supported version. Tagged releases receive fixes
through new tags on `main`.

## Reporting A Vulnerability

Use GitHub private vulnerability reporting for:

- A real secret, credential, or private identifier accidentally committed
  to this repository.
- Guidance that could cause agents to destroy user text irreversibly (for
  example a normalization path that skips the strict-decode guard, or a
  BOM rule that breaks scripts in a way that silently drops statements),
  leak private data, or run destructive commands outside the skill's
  scope.
- A validation gap that allows unsafe public examples.

Do not open a public issue containing tokens, credentials, private keys,
OAuth material, customer data, raw secret-bearing logs, or private
repository names and internal paths.

## Public Issue Safety

Public issues may include:

- Symptom class, such as "strict decode passed but the file was still
  corrupted" or "NUL detection missed a file".
- Sanitized command classes, such as `rg -al '\x00'` exit codes or
  `git diff --check` output shapes, without private paths.
- Placeholder file names and synthetic text samples (`日本語テスト`-class
  fixtures) — never fragments of real private documents, even garbled
  ones. Mojibake is transformed private data, not anonymized data.

Public issues must not include:

- Secret values or secret-display command output.
- Private repository names, internal absolute paths, hostnames, or
  customer data.
- Raw agent transcripts that contain any of the above.

## Scanner Coverage

The private-marker scanner (`scripts/scan-private-markers.ps1`) is a
best-effort safety net, not a guarantee. It scans git-tracked text files
for a curated set of secret prefixes (GitHub, OpenAI, AWS, GCP, Slack,
Stripe, PEM key blocks, and similar), private-looking absolute Windows
paths, non-allowlisted GitHub repository URLs, and configured local
markers, and it redacts any matched value. It does not detect every
possible secret format and is no substitute for keeping real credentials
out of the repository in the first place. Treat a passing scan as "no
known marker found," not "definitely safe."

When Git is available, tracked-file enumeration runs in finite-time child
processes with a sanitized environment and isolated configuration.
On Windows, the requested executable is created suspended with a
three-handle standard-I/O allowlist, assigned to a kill-on-close Job, and
resumed only after assignment. This closes the start-before-assignment
descendant race.
On POSIX, the requested executable starts in a dedicated session/process
group before its first instruction, and cleanup targets the whole group.
Ubuntu exercises both its external `setsid` path and a forced native
`setsid(2)` case. The macOS 15 job uses PowerShell 7 only and exercises the
native fallback; until its pull-request run succeeds, macOS behavior remains
unverified. The helper reports the selected POSIX gate, while the self-test
requires that report, a zero target exit, descendant-start evidence, and
post-cleanup absence. Native `setsid(2)` and `kill(2)` calls use the POSIX
runtime's `libc` resolver. A bounded, strict-UTF-8 status channel maps native
handshake failures to fixed stage codes; it never reflects a status path,
arbitrary child text, or raw stdout/stderr. Launch, handshake, and target
execution share the caller's timeout. Elapsed-only checks before tree stop and
after stream/handle cleanup reject a deadline overrun even when the direct
child already exited zero. Neither POSIX job substitutes for the Windows Job
Object or PowerShell 5.1 contracts.
Ambient repository redirects (`GIT_DIR`, worktree/index/object variables),
config injection, hooks, attributes, excludes, templates, filters, prompts,
and trace settings are not inherited by those Git children. Promisor-remote
lazy fetches and replacement refs are disabled, preventing a scan from
retrieving a missing object or substituting another blob for an index OID.
The scanner does not mutate the caller's environment. It scans staged
blobs and differing regular worktree files for common text/source/config
extensions, extensionless names, `.env`, `.env.*`, `*.env`, `.pem`, `.key`,
and selected high-signal dotfiles. Unknown extensions remain outside this
targeted text classifier. Unique staged blobs are read through one bounded
binary-safe batch, and byte-identical final raw stage/flag enumerations are
required after marker analysis and immediately before reporting.
Line length/count, per-rule match traversal, per-file/total findings, and
diagnostic width are separately bounded. Output escapes control/format,
bidi, and Unicode line/paragraph separator characters; matched values
remain redacted. Raw process-byte limits include prefixes and the actual
platform newline, and an unresolvable user path is replaced by a fixed
diagnostic. Non-Git fallback excludes `.git` whether it is a
directory or a leaf gitfile.
Conflicted, intent-to-add (present or missing worktree), mid-scan index
or flags-only mutation, symlink/reparse
(including dangling
`.git` markers and parent-directory junctions), gitlink, malformed,
timed-out, or incomplete-stream states fail closed. A tracked
`.private-markers.local` file is also rejected because that file is an
untracked-only input. Working-tree fallback is used only when Git is
unavailable and no `.git` entry exists in the target ancestry, or when Git
explicitly confirms the path is not a repository; other Git failures do
not silently broaden or change scope.

Every regular expression in `scripts/scan-private-markers.ps1` that parses
scan targets or Git output uses the PowerShell 5.1-compatible three-argument
.NET constructor and a finite match timeout capped at 250 ms and clamped to
the scan-wide budget. A timeout at `Match`, `IsMatch`, or `NextMatch` is
retained until Git isolation cleanup has succeeded, then emits only the
fixed redacted `regex-timeout` integrity diagnostic and
exits 2. Input, pattern, exception, and local-path content are not replayed
by that timeout diagnostic. A Git-isolation cleanup or boundary-integrity
failure retains precedence instead of being relabeled as a regex timeout.

## Response Expectations

Maintainers should acknowledge actionable security reports when available,
remove or redact unsafe public material, and prefer guidance that reduces
data-exposure and text-destruction risk. If real exposure is possible,
rotate the affected secret outside this public repository and document
only the remediation status.
