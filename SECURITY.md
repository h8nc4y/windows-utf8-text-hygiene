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

## Response Expectations

Maintainers should acknowledge actionable security reports when available,
remove or redact unsafe public material, and prefer guidance that reduces
data-exposure and text-destruction risk. If real exposure is possible,
rotate the affected secret outside this public repository and document
only the remediation status.
