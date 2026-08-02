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

- [ ] Every target is listed explicitly and already exists as a regular blob
  (`100644` or `100755`) in both HEAD and the stage-0 index. Paths absent from
  HEAD (including typical staged additions and new rename destinations),
  conflicts, symlinks (`120000`), and submodules (`160000`) are rejected.
- [ ] No Git routing/config/pathspec/trace environment variable is present,
  and the ordinal spelling of `git rev-parse --show-toplevel` matches the
  requested root.
- [ ] Run the snippet in a dedicated, single-threaded PowerShell process. No
  other runspace, thread, or child launch in that process may overlap its
  temporary `GIT_TRACE2`, `GIT_TRACE2_EVENT`, and `GIT_TRACE2_PERF` overrides.
- [ ] The host PATH and selected Git application are trusted. Alias/function
  shadowing is rejected, but this portable snippet does not authenticate the
  executable found on PATH.
- [ ] The repository root, target, and every existing parent between them
  are ordinary, non-reparse paths. A lexical path that escapes the
  repository, or a symlink / junction anywhere in that chain, is rejected.
- [ ] The original raw-byte digest is unchanged at the final guard, and all
  diagnostic labels escape control, format, surrogate, and line-separator
  characters before terminal output.
- [ ] Targets are existing HEAD-tracked text files you changed yourself — no
  new files, binaries, vendored code, or generated artifacts.
- [ ] No target `.ps1` is executed via Windows PowerShell 5.1 (hooks and
  Task Scheduler may run 5.1) — those must keep their BOM; see below.
- [ ] You are normalizing individual changed files, not bulk-converting
  the repository's line endings.
- [ ] The checkout has no untrusted concurrent writer. Hard links, Unix mount
  substitution, and the final digest-check/write race remain out of scope.

## The pattern

Normalize the files you changed in the current work (PowerShell; run from
anywhere, paths are explicit):

```powershell
$repo = [System.IO.Path]::GetFullPath('<repo>')

function Test-GitRoutingEnvironmentClean {
    # Routing/config/trace injection can redirect reads or append trace output
    # outside the checkout. Reject caller trace state before applying bounded
    # child-call Trace2 suppression below.
    $blockedNames = @(
        'GIT_DIR',
        'GIT_WORK_TREE',
        'GIT_COMMON_DIR',
        'GIT_INDEX_FILE',
        'GIT_OBJECT_DIRECTORY',
        'GIT_ALTERNATE_OBJECT_DIRECTORIES',
        'GIT_CONFIG',
        'GIT_CONFIG_COUNT',
        'GIT_CONFIG_PARAMETERS',
        'GIT_CONFIG_GLOBAL',
        'GIT_CONFIG_SYSTEM',
        'GIT_NAMESPACE',
        'GIT_REPLACE_REF_BASE',
        'GIT_SHALLOW_FILE',
        'GIT_GRAFT_FILE',
        'GIT_CEILING_DIRECTORIES',
        'GIT_DISCOVERY_ACROSS_FILESYSTEM',
        'GIT_GLOB_PATHSPECS',
        'GIT_NOGLOB_PATHSPECS',
        'GIT_LITERAL_PATHSPECS',
        'GIT_ICASE_PATHSPECS',
        'GIT_NO_LAZY_FETCH'
    )
    foreach ($nameObject in [Environment]::GetEnvironmentVariables().Keys) {
        $name = [string]$nameObject
        if ($blockedNames -icontains $name -or
            $name -like 'GIT_CONFIG_KEY_*' -or
            $name -like 'GIT_CONFIG_VALUE_*' -or
            $name -like 'GIT_TRACE*') {
            return $false
        }
    }
    return $true
}

function Get-NormalizedRootPath {
    param([string]$Path)

    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $volumeRoot = [System.IO.Path]::GetPathRoot($full)
        if ($full.Length -le $volumeRoot.Length) { return $full }
        return $full.TrimEnd([char[]]@(
                [System.IO.Path]::DirectorySeparatorChar,
                [System.IO.Path]::AltDirectorySeparatorChar
            ))
    } catch {
        return $null
    }
}

function Get-GitRegularMetadata {
    param(
        [string]$Raw,
        [ValidateSet('Index', 'Head')]
        [string]$Kind
    )

    [string[]]$records = @(
        $Raw.Split(
            [char[]]@([char]0),
            [System.StringSplitOptions]::RemoveEmptyEntries
        )
    )
    if ($records.Count -ne 1) { return $null }
    $tabIndex = $records[0].IndexOf("`t")
    if ($tabIndex -lt 0) { return $null }
    $metadata = $records[0].Substring(0, $tabIndex)
    [string[]]$fields = @(
        $metadata.Split(
            [char[]]@(' '),
            [System.StringSplitOptions]::RemoveEmptyEntries
        )
    )
    if ($Kind -eq 'Index') {
        if ($fields.Count -ne 3 -or $fields[2] -ne '0' -or
            $fields[0] -notin @('100644', '100755')) {
            return $null
        }
    } else {
        if ($fields.Count -ne 3 -or $fields[1] -cne 'blob' -or
            $fields[0] -notin @('100644', '100755')) {
            return $null
        }
    }
    return $metadata
}

function Get-GitTrackedRegularFileIdentity {
    param(
        [string]$RepoRoot,
        [string]$RelativePath
    )

    if (-not (Test-GitRoutingEnvironmentClean)) { return $null }
    $rootBoundary = Get-NormalizedRootPath -Path $RepoRoot
    if ([string]::IsNullOrEmpty([string]$rootBoundary)) { return $null }

    # Resolve only an application, so a caller-defined alias/function named
    # `git` cannot forge identity output. The host PATH remains a trust input.
    $gitApplications = @(
        Microsoft.PowerShell.Core\Get-Command `
            -Name git `
            -CommandType Application `
            -ErrorAction SilentlyContinue
    )
    if ($gitApplications.Count -lt 1) { return $null }
    $gitExecutable = $gitApplications[0].Source
    if ([string]::IsNullOrEmpty([string]$gitExecutable)) { return $null }

    # Trace2 targets from system/global config can append to an absolute path
    # or contact an AF_UNIX socket. Git ignores `-c trace2.*Target=0` for these
    # settings, so override only the three documented child-process variables
    # and remove them in finally. Caller-provided GIT_TRACE* is rejected above.
    $trace2OverrideNames = @('GIT_TRACE2', 'GIT_TRACE2_EVENT', 'GIT_TRACE2_PERF')
    try {
        foreach ($traceName in $trace2OverrideNames) {
            [Environment]::SetEnvironmentVariable($traceName, '0', 'Process')
        }
        # Bind `-C` to the exact requested top level. Ordinal comparison is
        # deliberately fail closed on case-sensitive Windows directories too.
        $topLevelOutput = @(
            & $gitExecutable --no-replace-objects --no-lazy-fetch -C $rootBoundary rev-parse --show-toplevel 2>$null
        )
        if ($LASTEXITCODE -ne 0 -or $topLevelOutput.Count -ne 1) { return $null }
        $actualTopLevel = Get-NormalizedRootPath -Path $topLevelOutput[0]
        if (-not [string]::Equals(
                $rootBoundary,
                $actualTopLevel,
                [System.StringComparison]::Ordinal
            )) { return $null }

        # The literal pathspec prevents wildcard/pathspec-magic expansion. A
        # regular stage-0 index entry is necessary, and the same path must also
        # be a regular blob in HEAD. The HEAD requirement rejects untracked,
        # intent-to-add, paths absent from HEAD (including typical staged additions
        # and new rename destinations), symlinks, and submodules.
        $literalPathSpec = ':(literal)' + $RelativePath
        $rawIndex = (
            & $gitExecutable --no-replace-objects --no-lazy-fetch -C $rootBoundary `
                ls-files --stage -z -- $literalPathSpec 2>$null
        ) -join ''
        if ($LASTEXITCODE -ne 0) { return $null }
        $indexMetadata = Get-GitRegularMetadata -Raw $rawIndex -Kind 'Index'
        if ([string]::IsNullOrEmpty([string]$indexMetadata)) { return $null }

        $rawHead = (
            & $gitExecutable --no-replace-objects --no-lazy-fetch -C $rootBoundary `
                ls-tree -z HEAD -- $literalPathSpec 2>$null
        ) -join ''
        if ($LASTEXITCODE -ne 0) { return $null }
        $headMetadata = Get-GitRegularMetadata -Raw $rawHead -Kind 'Head'
        if ([string]::IsNullOrEmpty([string]$headMetadata)) { return $null }
        return "index=$indexMetadata;head=$headMetadata"
    } finally {
        foreach ($traceName in $trace2OverrideNames) {
            Microsoft.PowerShell.Management\Remove-Item `
                -LiteralPath "Env:$traceName" `
                -ErrorAction Stop
        }
    }
}

function Test-RepositoryRegularFileBoundary {
    param(
        [string]$RepoRoot,
        [string]$RelativePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        return $false
    }
    try {
        $comparison = [System.StringComparison]::Ordinal
        $rootBoundary = Get-NormalizedRootPath -Path $RepoRoot
        if ([string]::IsNullOrEmpty([string]$rootBoundary)) { return $false }
        $candidateFull = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::Combine($rootBoundary, $RelativePath)
        )
    } catch {
        return $false
    }

    # Lexical containment comes first. The component walk below then rejects
    # every symlink/junction from the candidate through the repository root,
    # so the lexical path cannot resolve through a reparse point to outside.
    $rootPrefix = $rootBoundary
    if (-not $rootPrefix.EndsWith(
            [string][System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::Ordinal
        )) {
        $rootPrefix += [System.IO.Path]::DirectorySeparatorChar
    }
    if (-not $candidateFull.StartsWith($rootPrefix, $comparison)) {
        return $false
    }

    $current = $candidateFull
    $isCandidate = $true
    while ($true) {
        try {
            $attributes = [System.IO.File]::GetAttributes($current)
        } catch {
            return $false
        }
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        if ($isCandidate) {
            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                return $false
            }
            $isCandidate = $false
        } elseif (($attributes -band [System.IO.FileAttributes]::Directory) -eq 0) {
            return $false
        }
        if ([string]::Equals($current, $rootBoundary, $comparison)) {
            break
        }
        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent) { return $false }
        $current = $parent.FullName
    }

    return [System.IO.File]::Exists($candidateFull)
}

function Get-NormalizationCandidateIdentity {
    param(
        [string]$RepoRoot,
        [string]$RelativePath
    )

    if (-not (Test-RepositoryRegularFileBoundary `
            -RepoRoot $RepoRoot `
            -RelativePath $RelativePath)) {
        return $null
    }
    return Get-GitTrackedRegularFileIdentity `
        -RepoRoot $RepoRoot `
        -RelativePath $RelativePath
}

function Get-ByteDigest {
    param([byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToBase64String($sha256.ComputeHash($Bytes))
    } finally {
        $sha256.Dispose()
    }
}

function ConvertFrom-StrictUtf8Bytes {
    param([byte[]]$Bytes)

    # Strip every leading UTF-8 BOM sequence. Removing only the first would
    # decode a doubled BOM as U+FEFF and silently write one BOM back.
    $bomLength = 0
    while ($Bytes.Length - $bomLength -ge 3 -and
        $Bytes[$bomLength] -eq 0xEF -and
        $Bytes[$bomLength + 1] -eq 0xBB -and
        $Bytes[$bomLength + 2] -eq 0xBF) {
        $bomLength += 3
    }
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    return $strictUtf8.GetString(
        $Bytes,
        $bomLength,
        $Bytes.Length - $bomLength
    )
}

function ConvertTo-LfTrimmedText {
    param([AllowEmptyString()][string]$Text)

    # Normalize CRLF first, then any remaining lone CR. Preserve whether the
    # final logical line is empty while trimming trailing whitespace per line.
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    [string[]]$lines = @($normalized -split "`n")
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $lines[$index] = $lines[$index].TrimEnd()
    }
    return $lines -join "`n"
}

function ConvertTo-SafePathLabel {
    param([string]$RelativePath)

    $builder = [System.Text.StringBuilder]::new()
    $index = 0
    while ($index -lt $RelativePath.Length) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory(
            $RelativePath,
            $index
        )
        $scalarLength = 1
        $codePoint = [int]$RelativePath[$index]
        if ([char]::IsHighSurrogate($RelativePath[$index]) -and
            $index + 1 -lt $RelativePath.Length -and
            [char]::IsLowSurrogate($RelativePath[$index + 1])) {
            $scalarLength = 2
            $codePoint = [char]::ConvertToUtf32(
                $RelativePath[$index],
                $RelativePath[$index + 1]
            )
        }
        if ($category -in @(
                [System.Globalization.UnicodeCategory]::Control,
                [System.Globalization.UnicodeCategory]::Format,
                [System.Globalization.UnicodeCategory]::Surrogate,
                [System.Globalization.UnicodeCategory]::LineSeparator,
                [System.Globalization.UnicodeCategory]::ParagraphSeparator
            )) {
            if ($codePoint -le 0xFFFF) {
                [void]$builder.AppendFormat('\u{0:X4}', $codePoint)
            } else {
                [void]$builder.AppendFormat('\U{0:X8}', $codePoint)
            }
        } else {
            [void]$builder.Append($RelativePath.Substring($index, $scalarLength))
        }
        if ($builder.Length -ge 160) {
            [void]$builder.Append('...')
            break
        }
        $index += $scalarLength
    }
    return $builder.ToString()
}

# List only existing, HEAD-tracked files you selected for this change. Do not
# populate this list by capturing native `git ... -z` output as PowerShell
# text: embedded CR/LF bytes in a valid POSIX filename are lost by that path.
[string[]]$relativePaths = @(
    '<repo-relative-file.md>'
)

$skipped = @()
foreach ($relativePath in $relativePaths) {
    $safeLabel = ConvertTo-SafePathLabel -RelativePath $relativePath
    # Recheck Git identity and every path component immediately before read.
    $candidateIdentity = Get-NormalizationCandidateIdentity `
        -RepoRoot $repo `
        -RelativePath $relativePath
    if ([string]::IsNullOrEmpty([string]$candidateIdentity)) {
        $skipped += "$safeLabel (unsafe path, Git environment, or identity)"
        continue
    }
    $path = [System.IO.Path]::Combine($repo, $relativePath)
    try {
        $originalBytes = [System.IO.File]::ReadAllBytes($path)
        $originalDigest = Get-ByteDigest -Bytes $originalBytes
        $t = ConvertFrom-StrictUtf8Bytes -Bytes $originalBytes
    } catch [System.Text.DecoderFallbackException] {
        # Not UTF-8 (suspected ANSI/Shift_JIS). Do not touch; do not
        # convert; record for the report and continue with other files.
        $skipped += "$safeLabel (strict decode failed)"
        continue
    } catch {
        $skipped += "$safeLabel (read or digest failed)"
        continue
    }
    $t = ConvertTo-LfTrimmedText -Text $t

    # The path can change after the read. Reacquire the same boundary
    # immediately before the destructive write and fail closed on drift.
    $latestIdentity = Get-NormalizationCandidateIdentity `
        -RepoRoot $repo `
        -RelativePath $relativePath
    try {
        $latestDigest = Get-ByteDigest -Bytes (
            [System.IO.File]::ReadAllBytes($path)
        )
    } catch {
        $latestDigest = $null
    }
    if (-not [string]::Equals(
            [string]$candidateIdentity,
            [string]$latestIdentity,
            [System.StringComparison]::Ordinal
        ) -or
        -not [string]::Equals(
            [string]$originalDigest,
            [string]$latestDigest,
            [System.StringComparison]::Ordinal
        )) {
        $skipped += "$safeLabel (path, Git identity, or bytes changed before write)"
        continue
    }
    try {
        [System.IO.File]::WriteAllText($path, $t, [System.Text.UTF8Encoding]::new($false))  # no BOM
    } catch {
        # WriteAllText can fail after truncation. Stop immediately with fixed
        # text so possible partial content is never mislabeled as a safe skip.
        throw 'Normalization write failed; stop immediately and recover the guarded target before continuing.'
    }
}
if ($skipped.Count -gt 0) {
    "Skipped (unsafe boundary, drift, read failure, or strict decode failure):"
    $skipped
}
```

Notes:

- Keep `$relativePaths` explicit and limited to text files you selected.
  Automatic native `git ... -z` capture is deliberately absent because
  PowerShell text capture cannot preserve CR/LF inside POSIX filenames.
- `Get-GitTrackedRegularFileIdentity` rejects unsafe Git routing variables,
  a mismatched top level, paths absent from HEAD, conflicted index entries,
  symlinks, and submodules. This includes typical staged additions and new
  rename destinations because they are absent from HEAD; Git does not store a
  general "rename" bit, so an existing destination path is judged by its own
  HEAD/index identity. The path-boundary check rejects an escaping path and
  any symlink / junction from the file through the repository root, both
  before the read and immediately before the write.
- The original raw-byte digest is compared again before writing, so an
  ordinary same-path edit during decode/normalization is skipped. Diagnostic
  labels escape BMP and supplementary control/format characters, unpaired
  surrogates, and Unicode line/paragraph separators before display.
- `WriteAllText` is not atomic. A write exception is therefore a fatal,
  path-free fixed error rather than another skip: stop, inspect the target,
  and recover it from a trusted
  backup, HEAD, or the index as appropriate before continuing. The fixed fatal
  message does not reflect the raw target path.
- Git is resolved as an application rather than through a caller alias or
  function. The host PATH and the selected Git executable must still be
  trusted; this portable snippet does not authenticate executable provenance.
  `--no-lazy-fetch` also makes a partial clone fail closed instead of contacting
  a promisor remote or invoking a credential helper during identity checks.
  Caller `GIT_TRACE*` state is rejected. The three Trace2 override variables
  briefly change this PowerShell process while the synchronous Git queries
  run. Use a dedicated, single-threaded process: no other runspace, thread, or
  child launch in that process may overlap the override window.
- This is a fail-closed copy pattern, not a complete defense against a
  privileged concurrent attacker. A hard link, Unix mount substitution, or
  a path/content swap in the final digest-check/write window still requires
  an OS-specific no-follow handle and file-identity check; do not run
  normalization in an untrusted concurrently writable checkout.
- The rewrite preserves the file's final-newline state (split/join keeps a
  trailing empty element), converts CRLF and lone CR to LF, strips repeated
  leading UTF-8 BOM sequences, and does not add a missing final newline.
- `$repo` must be the repository's exact top-level spelling. An alternate
  case or redirected `core.worktree` fails the ordinal top-level check.
- Prefer `pwsh` 7 for non-ASCII path arguments. Windows PowerShell 5.1 may
  fail to encode such a native Git argument; the exact identity lookup then
  returns no record and skips the file rather than writing another target.

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
