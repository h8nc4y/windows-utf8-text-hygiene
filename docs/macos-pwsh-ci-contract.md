# macOS PowerShell CI Contract

Status: implemented; macOS execution remains unverified until the
pull-request job completes successfully.

## Objective

Add bounded, synthetic coverage for the repository's PowerShell 7 behavior on
a GitHub-hosted `macos-15` runner. The job closes the documented macOS evidence
gap without changing the skill's normalization guidance or using real files,
credentials, customer data, external APIs, or live repositories.

## Platform Contract

- Windows runs PowerShell 7 and Windows PowerShell 5.1. Its process boundary is
  the Windows suspended-process plus Job Object implementation, and it alone
  verifies the intentional UTF-8 BOM exception for Japanese-commented scripts
  executed by Windows PowerShell 5.1.
- Ubuntu runs PowerShell 7. Its normal POSIX process-boundary case uses the
  host's `setsid` executable, and a second synthetic case forces the native
  `setsid(2)` gate.
- macOS runs PowerShell 7 only. Windows PowerShell 5.1 is not available there.
  Because the standard runner has no required external `setsid` contract, the
  shared self-test must exercise the native `setsid(2)` fallback used by the
  scanner on that host.

Both POSIX paths retain the established .NET `DllImport("libc")` contract for
native `setsid(2)` and `kill(2)` resolution. This pull request's macOS job
verifies that resolver on its own runner.

The shared process helper returns `PosixSessionGate` as either
`external-setsid` or `native-setsid`. The self-test derives the automatic
expectation from the host's external `setsid` availability and requires the
forced case to report `native-setsid`. It also requires a zero direct-target
exit code, a descendant-start sentinel, successful process-group cleanup, and
absence of the delayed descendant sentinel. Only after every condition passes
does it emit the fixed, path-free `POSIX containment evidence:` record.

The native wrapper writes only an allowlisted stage into a bounded local status
channel. A failed handshake reports one of `compile`, `setsid-library`,
`setsid-entrypoint`, `setsid-call`, `setsid-error-N`, `ready-prepare`,
`ready-write`, or `unknown`. The parent reads no more than 65 bytes, accepts at
most 64 strict UTF-8 bytes, and never reflects the channel path, arbitrary
status text, or raw child stdout/stderr. Assigning the read-only PowerShell
automatic variable `$IsMacOS` in the wrapper is a regression.

Process launch, the native handshake, and target execution share the same
caller-owned deadline. The production default remains 15 seconds and the
synthetic POSIX containment case remains 10 seconds. CI failures must not be
hidden by increasing either timeout. Two synthetic zero-exit cases consume the
deadline after child exit and after stream collection. Both must return
`TimedOut = true`, so an elapsed setup or cleanup overrun cannot be accepted as
success merely because the direct child already exited.

Success on one platform does not substitute for another platform's job.

## Exact Job Contract

The `validate-macos` job must:

1. use the standard `macos-15` runner;
2. have a ten-minute job timeout;
3. use the pinned repository checkout revision already used by other jobs;
4. prove that the host is macOS and the shell is PowerShell Core 7;
5. run OSS readiness validation;
6. run the complete synthetic private-marker self-test with `pwsh`;
7. run the repository's private-marker scan; and
8. check committed whitespace against the empty tree.

The readiness validator compares the complete job block with this contract.
Unknown or additional steps, alternate runners, missing shell declarations,
or relaxed timeouts must fail validation.

The readiness mutation suite must also reject removal of the returned gate
provenance, the observed-gate or target-exit assertion, the fixed POSIX
evidence record, the native resolver, the bounded status channel, or the
shared handshake deadline. It must also reject an `$IsMacOS` assignment.

## Acceptance Evidence

Before the pull-request job is green, macOS support remains `unverified`.
After it is green, record the actual runner, PowerShell version, job result,
and run URL in the pull request and update the public limitation wording. Local
Windows or Linux success is not macOS evidence.

For one macOS failure class, make at most three bounded correction pushes. If
the third run still fails, stop with the fixed stage code and leave macOS
`unverified`; do not relax the timeout or substitute another platform's result.
