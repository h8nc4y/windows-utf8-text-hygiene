[CmdletBinding()]
param(
    [string]$Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Split-Path -Parent $scriptRoot
}

$root = (Resolve-Path -LiteralPath $Path).Path
$scanner = Join-Path $root 'scripts/scan-private-markers.ps1'
if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
    throw "Missing scanner script: $scanner"
}
$processBoundary = Join-Path $root 'scripts/private-marker-process.ps1'
if (-not (Test-Path -LiteralPath $processBoundary -PathType Leaf)) {
    throw "Missing process boundary script: $processBoundary"
}
. $processBoundary

$currentPowerShellExecutable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if ([string]::IsNullOrWhiteSpace($currentPowerShellExecutable) -or
    -not (Test-Path -LiteralPath $currentPowerShellExecutable -PathType Leaf)) {
    $hostExecutableName = if ($PSVersionTable.PSVersion.Major -le 5) {
        'powershell.exe'
    } elseif (Test-PrivateMarkerWindowsHost) {
        'pwsh.exe'
    } else {
        'pwsh'
    }
    $currentPowerShellExecutable = Join-Path $PSHOME $hostExecutableName
}
if (-not (Test-Path -LiteralPath $currentPowerShellExecutable -PathType Leaf)) {
    throw "Cannot resolve the current PowerShell host executable: $currentPowerShellExecutable"
}

$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

function Test-ByteArrayContainsSequence {
    param(
        [byte[]]$Haystack,
        [byte[]]$Needle
    )

    if ($Needle.Length -eq 0) {
        return $true
    }
    if ($Haystack.Length -lt $Needle.Length) {
        return $false
    }
    for ($offset = 0;
        $offset -le ($Haystack.Length - $Needle.Length);
        $offset++) {
        $matched = $true
        for ($needleIndex = 0;
            $needleIndex -lt $Needle.Length;
            $needleIndex++) {
            if ($Haystack[$offset + $needleIndex] -ne $Needle[$needleIndex]) {
                $matched = $false
                break
            }
        }
        if ($matched) {
            return $true
        }
    }
    return $false
}

function Test-ByteArraysEqual {
    param(
        [byte[]]$Expected,
        [byte[]]$Actual
    )

    if ($Expected.Length -ne $Actual.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) {
            return $false
        }
    }
    return $true
}

function Get-ProcessEnvironmentSnapshot {
    $snapshot = @{}
    $environment = [Environment]::GetEnvironmentVariables('Process')
    foreach ($name in $environment.Keys) {
        $snapshot["$name"] = [string]$environment[$name]
    }
    return $snapshot
}

function Assert-ProcessEnvironmentUnchanged {
    param(
        [hashtable]$Expected,
        [string]$Context
    )

    $actual = Get-ProcessEnvironmentSnapshot
    $differentNames = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Expected.Keys + $actual.Keys) | Sort-Object -Unique) {
        if ($Expected.ContainsKey($name) -ne $actual.ContainsKey($name) -or
            ($Expected.ContainsKey($name) -and $Expected[$name] -cne $actual[$name])) {
            # 周辺環境には秘密値があり得るため、差分は変数名だけを報告する。
            $differentNames.Add("$name") | Out-Null
        }
    }
    if ($differentNames.Count -gt 0) {
        Add-Failure "$Context changed parent environment variables: $($differentNames -join ', ')."
    }
}

function Invoke-Scanner {
    param(
        [string]$ScanPath,
        [hashtable]$EnvironmentOverrides = @{},
        [string[]]$AdditionalArguments = @()
    )

    $arguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and
        (Test-PrivateMarkerWindowsHost)) {
        $arguments += @('-ExecutionPolicy', 'Bypass')
    }
    $arguments += @('-File', $scanner, '-Path', $ScanPath)
    $arguments += $AdditionalArguments
    $result = Invoke-PrivateMarkerProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments $arguments `
        -WorkingDirectory $root `
        -EnvironmentOverrides $EnvironmentOverrides `
        -MaximumStandardOutputBytes 4194304 `
        -TimeoutMilliseconds 30000
    return ConvertTo-TestProcessResult -Result $result
}

function Invoke-HermeticGit {
    param(
        [string]$WorkingDirectory,
        [string[]]$Arguments,
        [string]$IsolationRoot
    )

    $gitCommand = Get-Command git -ErrorAction Stop
    $result = Invoke-PrivateMarkerProcess `
        -FileName $gitCommand.Source `
        -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory `
        -SanitizeGitEnvironment `
        -IsolationRoot $IsolationRoot `
        -TimeoutMilliseconds 20000
    return ConvertTo-TestProcessResult -Result $result
}

function ConvertTo-TestProcessResult {
    param([pscustomobject]$Result)

    $stdout = [System.Text.UTF8Encoding]::new($false).GetString(
        $Result.StandardOutputBytes
    )
    $stderr = [System.Text.UTF8Encoding]::new($false).GetString(
        $Result.StandardErrorBytes
    )
    $healthyBoundary = $Result.StreamsCompleted -and
        $Result.TreeStopped -and
        -not $Result.TimedOut -and
        -not $Result.OutputLimitExceeded -and
        -not $Result.InputWriteFailed -and
        -not $Result.PipeLeakDetected
    $exitCode = if ($healthyBoundary) { $Result.ExitCode } else { -1 }
    $diagnostics = New-Object System.Collections.Generic.List[string]
    if (-not $Result.StreamsCompleted) { $diagnostics.Add('streams-incomplete') }
    if (-not $Result.TreeStopped) { $diagnostics.Add('tree-cleanup-failed') }
    if ($Result.TimedOut) { $diagnostics.Add('timed-out') }
    if ($Result.OutputLimitExceeded) { $diagnostics.Add('output-limit') }
    if ($Result.InputWriteFailed) { $diagnostics.Add('input-write') }
    if ($Result.PipeLeakDetected) { $diagnostics.Add('pipe-leak') }
    $output = (@($stdout, $stderr) -join [Environment]::NewLine).TrimEnd()
    if ($diagnostics.Count -gt 0) {
        $output += [Environment]::NewLine + (
            'bounded-process-failure: ' + ($diagnostics -join ',')
        )
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        RawExitCode = $Result.ExitCode
        Output = $output
        StandardOutputBytes = [byte[]]$Result.StandardOutputBytes
        StandardErrorBytes = [byte[]]$Result.StandardErrorBytes
        TimedOut = $Result.TimedOut
        OutputLimitExceeded = $Result.OutputLimitExceeded
        InputWriteFailed = $Result.InputWriteFailed
        PipeLeakDetected = $Result.PipeLeakDetected
        StreamsCompleted = $Result.StreamsCompleted
        TreeStopped = $Result.TreeStopped
    }
}

function Assert-FixedRegexTimeoutFailure {
    param(
        [pscustomobject]$Result,
        [string[]]$ForbiddenPaths
    )

    $expected =
        'Private marker scan failed closed (integrity: regex-timeout).'
    $expectedStderrBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
        $expected + [Environment]::NewLine
    )
    if ($Result.ExitCode -ne 2 -or
        $Result.Output.Trim() -cne $expected -or
        $Result.StandardOutputBytes.Length -ne 0 -or
        -not (Test-ByteArraysEqual `
            -Expected $expectedStderrBytes `
            -Actual $Result.StandardErrorBytes)) {
        Add-Failure (
            'Regex timeout must return fixed redacted stderr and exit 2. ' +
            "Exit: $($Result.ExitCode); " +
            "stdout bytes: $($Result.StandardOutputBytes.Length); " +
            "stderr bytes: $($Result.StandardErrorBytes.Length)."
        )
        return
    }

    $pathComparison = if (Test-PrivateMarkerWindowsHost) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    foreach ($forbiddenPath in $ForbiddenPaths) {
        if ([string]::IsNullOrWhiteSpace($forbiddenPath)) {
            continue
        }
        foreach ($pathForm in @(
            $forbiddenPath,
            $forbiddenPath.Replace('\', '/'),
            $forbiddenPath.Replace('/', '\')
        ) | Sort-Object -Unique) {
            if ($Result.Output.IndexOf($pathForm, $pathComparison) -ge 0) {
                Add-Failure 'Regex timeout leaked an absolute boundary path.'
                return
            }
        }
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("windows-utf8-text-hygiene-scan-test-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$emptyCommandPath = Join-Path $tempRoot 'empty-command-path'
New-Item -ItemType Directory -Path $emptyCommandPath | Out-Null
$preexistingScannerIsolationRoots = @(
    Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) `
        -Directory `
        -Filter 'windows-utf8-text-hygiene-git-*' `
        -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name }
)

try {
    # scanner自身のrecursive cleanupは、OS temp直下の専用GUID directoryだけを
    # 所有物として扱う。広いtemp root、wrong-name、nested pathは削除候補にしない。
    $cleanupTemporaryParent = [System.IO.Path]::GetTempPath()
    $validCleanupRoot = Join-Path `
        $cleanupTemporaryParent `
        ("windows-utf8-text-hygiene-git-" + [Guid]::NewGuid().ToString('N'))
    $wrongNameCleanupRoot = Join-Path `
        $cleanupTemporaryParent `
        'windows-utf8-text-hygiene-git-not-a-guid'
    $nestedCleanupRoot = Join-Path `
        $tempRoot `
        ("windows-utf8-text-hygiene-git-" + [Guid]::NewGuid().ToString('N'))
    if (-not (Test-PrivateMarkerGitIsolationRootBoundary `
            -Root $validCleanupRoot `
            -TemporaryParent $cleanupTemporaryParent)) {
        Add-Failure 'Expected the direct GUID-named Git isolation root to satisfy the cleanup boundary.'
    }
    if (Test-PrivateMarkerGitIsolationRootBoundary `
            -Root $cleanupTemporaryParent `
            -TemporaryParent $cleanupTemporaryParent) {
        Add-Failure 'Expected the OS temporary root itself to fail the Git isolation cleanup boundary.'
    }
    if (Test-PrivateMarkerGitIsolationRootBoundary `
            -Root $wrongNameCleanupRoot `
            -TemporaryParent $cleanupTemporaryParent) {
        Add-Failure 'Expected a wrong-name Git isolation root to fail the cleanup boundary.'
    }
    if (Test-PrivateMarkerGitIsolationRootBoundary `
            -Root $nestedCleanupRoot `
            -TemporaryParent $cleanupTemporaryParent) {
        Add-Failure 'Expected a nested Git isolation root to fail the direct-child cleanup boundary.'
    }

    $validCleanupOwnerId = [Guid]::NewGuid().ToString('N')
    New-PrivateMarkerGitIsolationRoot `
        -Root $validCleanupRoot `
        -TemporaryParent $cleanupTemporaryParent `
        -OwnerId $validCleanupOwnerId
    Set-Content `
        -LiteralPath (Join-Path $validCleanupRoot 'owned.txt') `
        -Value 'synthetic owned cleanup fixture' `
        -Encoding UTF8
    Remove-PrivateMarkerGitIsolationRoot `
        -Root $validCleanupRoot `
        -TemporaryParent $cleanupTemporaryParent `
        -OwnerId $validCleanupOwnerId
    if (Test-Path -LiteralPath $validCleanupRoot) {
        Add-Failure 'Expected the valid owned Git isolation root to be removed.'
    }

    # 最初のsnapshot後にroot自体が消えた場合は、別pathへ探索を広げず
    # 固定診断でfail closedし、無関係なexternal sentinelを保持する。
    $missingCleanupRoot = Join-Path `
        $cleanupTemporaryParent `
        ("windows-utf8-text-hygiene-git-" + [Guid]::NewGuid().ToString('N'))
    $missingCleanupOwnerId = [Guid]::NewGuid().ToString('N')
    $missingCleanupTarget = Join-Path $tempRoot 'missing root external target'
    $missingCleanupSentinel = Join-Path $missingCleanupTarget 'preserve.txt'
    New-Item -ItemType Directory -Path $missingCleanupTarget | Out-Null
    Set-Content `
        -LiteralPath $missingCleanupSentinel `
        -Value 'synthetic external target' `
        -Encoding UTF8
    New-PrivateMarkerGitIsolationRoot `
        -Root $missingCleanupRoot `
        -TemporaryParent $cleanupTemporaryParent `
        -OwnerId $missingCleanupOwnerId
    $missingOwnerMarker = Join-Path `
        $missingCleanupRoot `
        '.windows-utf8-text-hygiene-owner'
    $removeBeforeFinalValidation = {
        [System.IO.File]::Delete($missingOwnerMarker)
        [System.IO.Directory]::Delete($missingCleanupRoot)
    }.GetNewClosure()
    $missingRootRejected = $false
    try {
        Remove-PrivateMarkerGitIsolationRoot `
            -Root $missingCleanupRoot `
            -TemporaryParent $cleanupTemporaryParent `
            -OwnerId $missingCleanupOwnerId `
            -BeforeFinalValidation $removeBeforeFinalValidation
    }
    catch {
        $missingRootRejected = $_.Exception.Message -ceq
            'Git isolation root could not be inspected safely before cleanup.'
    }
    if (-not $missingRootRejected) {
        Add-Failure 'Expected a missing-root Git isolation root to fail with the fixed inspection diagnostic.'
    }
    if (-not (Test-Path -LiteralPath $missingCleanupSentinel -PathType Leaf)) {
        Add-Failure 'Expected rejected missing-root cleanup to preserve the external synthetic target.'
    }
    if (Test-Path -LiteralPath $missingCleanupRoot) {
        [System.IO.File]::Delete($missingOwnerMarker)
        [System.IO.Directory]::Delete($missingCleanupRoot)
    }

    # 最初のsnapshot後に別のregular directoryへ置換し、owner markerの
    # 再照合がraw recursive deleteより先に拒否することを固定する。
    $directoryReplacementRoot = Join-Path `
        $cleanupTemporaryParent `
        ("windows-utf8-text-hygiene-git-" + [Guid]::NewGuid().ToString('N'))
    $directoryReplacementOwnerId = [Guid]::NewGuid().ToString('N')
    New-PrivateMarkerGitIsolationRoot `
        -Root $directoryReplacementRoot `
        -TemporaryParent $cleanupTemporaryParent `
        -OwnerId $directoryReplacementOwnerId
    $directoryOwnerMarker = Join-Path `
        $directoryReplacementRoot `
        '.windows-utf8-text-hygiene-owner'
    $replaceWithDirectory = {
        [System.IO.File]::Delete($directoryOwnerMarker)
        [System.IO.Directory]::Delete($directoryReplacementRoot)
        [void][System.IO.Directory]::CreateDirectory($directoryReplacementRoot)
    }.GetNewClosure()
    try {
        $directoryReplacementRejected = $false
        try {
            Remove-PrivateMarkerGitIsolationRoot `
                -Root $directoryReplacementRoot `
                -TemporaryParent $cleanupTemporaryParent `
                -OwnerId $directoryReplacementOwnerId `
                -BeforeFinalValidation $replaceWithDirectory
        }
        catch {
            $directoryReplacementRejected =
                $_.Exception.Message -match 'ownership changed'
        }
        if (-not $directoryReplacementRejected) {
            Add-Failure 'Expected a check/use regular-directory replacement to fail owner validation.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $directoryReplacementRoot) {
            [System.IO.Directory]::Delete($directoryReplacementRoot)
        }
    }

    # 最初のsnapshot後にroot自体をjunction/symlinkへ置換した場合も、
    # 最終属性照合で再帰削除せず、external targetを保持する。
    $reparseCleanupRoot = Join-Path `
        $cleanupTemporaryParent `
        ("windows-utf8-text-hygiene-git-" + [Guid]::NewGuid().ToString('N'))
    $reparseCleanupOwnerId = [Guid]::NewGuid().ToString('N')
    $reparseCleanupTarget = Join-Path $tempRoot 'git isolation external target'
    $reparseCleanupSentinel = Join-Path $reparseCleanupTarget 'preserve.txt'
    New-Item -ItemType Directory -Path $reparseCleanupTarget | Out-Null
    Set-Content `
        -LiteralPath $reparseCleanupSentinel `
        -Value 'synthetic external target' `
        -Encoding UTF8
    New-PrivateMarkerGitIsolationRoot `
        -Root $reparseCleanupRoot `
        -TemporaryParent $cleanupTemporaryParent `
        -OwnerId $reparseCleanupOwnerId
    $reparseOwnerMarker = Join-Path `
        $reparseCleanupRoot `
        '.windows-utf8-text-hygiene-owner'
    try {
        $reparseType = if (Test-PrivateMarkerWindowsHost) {
            'Junction'
        } else {
            'SymbolicLink'
        }
        $replaceWithReparse = {
            [System.IO.File]::Delete($reparseOwnerMarker)
            [System.IO.Directory]::Delete($reparseCleanupRoot)
            New-Item `
                -ItemType $reparseType `
                -Path $reparseCleanupRoot `
                -Target $reparseCleanupTarget |
                Out-Null
        }.GetNewClosure()
        $reparseRejected = $false
        try {
            Remove-PrivateMarkerGitIsolationRoot `
                -Root $reparseCleanupRoot `
                -TemporaryParent $cleanupTemporaryParent `
                -OwnerId $reparseCleanupOwnerId `
                -BeforeFinalValidation $replaceWithReparse
        }
        catch {
            $reparseRejected =
                $_.Exception.Message -match 'leaf or reparse point'
        }
        if (-not $reparseRejected) {
            Add-Failure 'Expected a reparse-point Git isolation root to fail closed before recursive cleanup.'
        }
        if (-not (Test-Path -LiteralPath $reparseCleanupSentinel -PathType Leaf)) {
            Add-Failure 'Expected rejected Git isolation cleanup to preserve the external synthetic target.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $reparseCleanupRoot) {
            [System.IO.Directory]::Delete($reparseCleanupRoot)
        }
    }

    # Prefix・UTF-8 multibyte・実platform改行をすべて含めたraw byte数で、
    # exact limitは成功し、1 byte超過だけがbounded failureになることを確認する。
    $boundaryEmitterPath = Join-Path $tempRoot 'RawBoundaryEmitter.ps1'
    $boundaryEmitterSource = @'
param([int]$TotalBytes)
$prefixText = ([char]0x5883).ToString() + [char]0x754C + ':'
$prefixBytes = [System.Text.Encoding]::UTF8.GetBytes($prefixText)
$newlineBytes = [System.Text.Encoding]::UTF8.GetBytes(
    [Environment]::NewLine
)
if ($TotalBytes -lt ($prefixBytes.Length + $newlineBytes.Length)) {
    throw 'Requested payload is too small.'
}
$payload = New-Object byte[] $TotalBytes
[Array]::Copy($prefixBytes, 0, $payload, 0, $prefixBytes.Length)
for ($index = $prefixBytes.Length;
    $index -lt ($payload.Length - $newlineBytes.Length);
    $index++) {
    $payload[$index] = [byte][char]'x'
}
[Array]::Copy(
    $newlineBytes,
    0,
    $payload,
    $payload.Length - $newlineBytes.Length,
    $newlineBytes.Length
)
$stream = [Console]::OpenStandardOutput()
$stream.Write($payload, 0, $payload.Length)
$stream.Flush()
'@
    [System.IO.File]::WriteAllText(
        $boundaryEmitterPath,
        $boundaryEmitterSource,
        [System.Text.UTF8Encoding]::new($true)
    )
    $boundaryHostArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and
        (Test-PrivateMarkerWindowsHost)) {
        $boundaryHostArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $boundaryLimit = 65536
    $withinBoundaryResult = Invoke-PrivateMarkerProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments (
            $boundaryHostArguments +
            @('-File', $boundaryEmitterPath, $boundaryLimit)
        ) `
        -WorkingDirectory $tempRoot `
        -MaximumStandardOutputBytes $boundaryLimit `
        -MaximumStandardErrorBytes 8192 `
        -TimeoutMilliseconds 10000
    $expectedBoundaryPrefix = [System.Text.Encoding]::UTF8.GetBytes(
        ([char]0x5883).ToString() + [char]0x754C + ':'
    )
    $expectedBoundaryNewline = [System.Text.Encoding]::UTF8.GetBytes(
        [Environment]::NewLine
    )
    $boundaryPrefixMatches =
        $withinBoundaryResult.StandardOutputBytes.Length -ge
            $expectedBoundaryPrefix.Length
    if ($boundaryPrefixMatches) {
        for ($index = 0;
            $index -lt $expectedBoundaryPrefix.Length;
            $index++) {
            if ($withinBoundaryResult.StandardOutputBytes[$index] -ne
                $expectedBoundaryPrefix[$index]) {
                $boundaryPrefixMatches = $false
                break
            }
        }
    }
    $boundaryNewlineMatches =
        $withinBoundaryResult.StandardOutputBytes.Length -ge
            $expectedBoundaryNewline.Length
    if ($boundaryNewlineMatches) {
        $newlineOffset =
            $withinBoundaryResult.StandardOutputBytes.Length -
            $expectedBoundaryNewline.Length
        for ($index = 0;
            $index -lt $expectedBoundaryNewline.Length;
            $index++) {
            if ($withinBoundaryResult.StandardOutputBytes[
                    $newlineOffset + $index
                ] -ne $expectedBoundaryNewline[$index]) {
                $boundaryNewlineMatches = $false
                break
            }
        }
    }
    if ($withinBoundaryResult.ExitCode -ne 0 -or
        $withinBoundaryResult.OutputLimitExceeded -or
        -not $withinBoundaryResult.StreamsCompleted -or
        -not $withinBoundaryResult.TreeStopped -or
        $withinBoundaryResult.StandardOutputBytes.Length -ne $boundaryLimit -or
        -not $boundaryPrefixMatches -or
        -not $boundaryNewlineMatches) {
        Add-Failure 'Expected the exact raw UTF-8 output boundary, including prefix and platform newline, to pass.'
    }

    $overBoundaryResult = Invoke-PrivateMarkerProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments (
            $boundaryHostArguments +
            @('-File', $boundaryEmitterPath, ($boundaryLimit + 1))
        ) `
        -WorkingDirectory $tempRoot `
        -MaximumStandardOutputBytes $boundaryLimit `
        -MaximumStandardErrorBytes 8192 `
        -TimeoutMilliseconds 10000
    if (-not $overBoundaryResult.OutputLimitExceeded -or
        -not $overBoundaryResult.TreeStopped -or
        $overBoundaryResult.StandardOutputBytes.Length -gt $boundaryLimit) {
        Add-Failure 'Expected one raw UTF-8 byte beyond the output boundary to stop fail-closed.'
    }

    # Hostile user pathはResolve-Path前後のprovider例外からもraw出力しない。
    $hostilePathPrefix =
        'hostile-nonexistent-' + [System.Guid]::NewGuid().ToString('N')
    $hostilePathCharacters = @(
        [char]0x202E,
        [char]0x2028,
        [char]0x2029
    )
    $hostileMissingPath = Join-Path $tempRoot (
        $hostilePathPrefix +
        ($hostilePathCharacters -join '-') +
        '-spoof'
    )
    $hostileArguments = @('-NoProfile')
    if ($PSVersionTable.PSVersion.Major -le 5 -and
        (Test-PrivateMarkerWindowsHost)) {
        $hostileArguments += @('-ExecutionPolicy', 'Bypass')
    }
    $hostileArguments += @(
        '-File',
        $scanner,
        '-Path',
        $hostileMissingPath
    )
    $hostilePathResult = Invoke-PrivateMarkerProcess `
        -FileName $currentPowerShellExecutable `
        -Arguments $hostileArguments `
        -WorkingDirectory $root `
        -MaximumStandardOutputBytes 256 `
        -MaximumStandardErrorBytes 512 `
        -TimeoutMilliseconds 10000
    $hostileCombinedBytes = New-Object byte[] (
        $hostilePathResult.StandardOutputBytes.Length +
        $hostilePathResult.StandardErrorBytes.Length
    )
    [Array]::Copy(
        $hostilePathResult.StandardOutputBytes,
        0,
        $hostileCombinedBytes,
        0,
        $hostilePathResult.StandardOutputBytes.Length
    )
    [Array]::Copy(
        $hostilePathResult.StandardErrorBytes,
        0,
        $hostileCombinedBytes,
        $hostilePathResult.StandardOutputBytes.Length,
        $hostilePathResult.StandardErrorBytes.Length
    )
    $hostileFixedDiagnostic =
        'Private marker scan failed closed (integrity: scan-root-missing).'
    $expectedHostileStdout = New-Object byte[] 0
    $expectedHostileStderr = [System.Text.Encoding]::UTF8.GetBytes(
        $hostileFixedDiagnostic + [Environment]::NewLine
    )
    $hostileLeakDetected = $false
    # exact bytesだけでframing混入は検出できるが、絶対pathとUnicode制御の
    # 非出力契約も個別に残し、regressionの原因を一意にする。
    foreach ($sensitiveText in @(
        $scanner,
        $hostileMissingPath,
        $hostilePathPrefix
    )) {
        foreach ($encoding in @(
            [System.Text.Encoding]::UTF8,
            [System.Text.Encoding]::Unicode,
            [System.Text.Encoding]::BigEndianUnicode
        )) {
            if (Test-ByteArrayContainsSequence `
                    -Haystack $hostileCombinedBytes `
                    -Needle $encoding.GetBytes($sensitiveText)) {
                $hostileLeakDetected = $true
            }
        }
    }
    foreach ($hostileCharacter in $hostilePathCharacters) {
        if (Test-ByteArrayContainsSequence `
                -Haystack $hostileCombinedBytes `
                -Needle (
                    [System.Text.Encoding]::UTF8.GetBytes(
                        [string]$hostileCharacter
                    )
                )) {
            $hostileLeakDetected = $true
        }
    }
    if ($hostilePathResult.ExitCode -ne 2 -or
        $hostilePathResult.OutputLimitExceeded -or
        -not $hostilePathResult.StreamsCompleted -or
        -not $hostilePathResult.TreeStopped -or
        $hostilePathResult.StandardOutputBytes.Length -gt 256 -or
        $hostilePathResult.StandardErrorBytes.Length -gt 512 -or
        -not (Test-ByteArraysEqual `
            -Expected $expectedHostileStdout `
            -Actual $hostilePathResult.StandardOutputBytes) -or
        -not (Test-ByteArraysEqual `
            -Expected $expectedHostileStderr `
            -Actual $hostilePathResult.StandardErrorBytes) -or
        $hostileLeakDetected) {
        Add-Failure 'Expected hostile nonexistent scan paths to emit exactly one fixed stderr code plus the platform newline.'
    }

    # native wrapperはPowerShell 7のread-only `$IsMacOS` と
    # case-insensitiveに衝突する名前へ代入してはならない。
    $processBoundarySource = [System.IO.File]::ReadAllText($processBoundary)
    if ($processBoundarySource -cmatch '(?im)^\s*\$IsMacOS\s*=') {
        Add-Failure 'Expected the native POSIX wrapper to avoid the read-only IsMacOS automatic variable.'
    }

    # child statusは固定allowlistだけを親例外へ変換し、任意文字列やpathを
    # CI logへ反射しない。errnoも有限桁のdecimalだけを許可する。
    $posixGateFailureReasonCases = @(
        [pscustomobject]@{ Status = 'compile'; Expected = 'compile' },
        [pscustomobject]@{
            Status = 'setsid-library'
            Expected = 'setsid-library'
        },
        [pscustomobject]@{
            Status = 'setsid-entrypoint'
            Expected = 'setsid-entrypoint'
        },
        [pscustomobject]@{
            Status = 'setsid-call'
            Expected = 'setsid-call'
        },
        [pscustomobject]@{
            Status = 'setsid-error-1'
            Expected = 'setsid-error-1'
        },
        [pscustomobject]@{
            Status = 'ready-prepare'
            Expected = 'ready-prepare'
        },
        [pscustomobject]@{
            Status = 'ready-write'
            Expected = 'ready-write'
        },
        [pscustomobject]@{
            Status = 'setsid-error-123456'
            Expected = 'unknown'
        },
        [pscustomobject]@{
            Status = 'synthetic-sensitive-value'
            Expected = 'unknown'
        }
    )
    foreach ($reasonCase in $posixGateFailureReasonCases) {
        $actualReason = ConvertTo-PrivateMarkerPosixGateFailureReason `
            -Status $reasonCase.Status
        if ($actualReason -cne $reasonCase.Expected) {
            Add-Failure 'Expected POSIX gate status to map to its fixed allowlisted reason.'
        }
    }

    $posixStatusReadFixture =
        Join-Path $tempRoot 'synthetic-posix-gate-status'
    $posixStatusReadCases = @(
        [pscustomobject]@{
            Label = 'known'
            Bytes = [System.Text.Encoding]::UTF8.GetBytes('compile')
            ExpectedText = 'compile'
            ExpectedReason = 'compile'
        },
        [pscustomobject]@{
            Label = '65-byte-rejection'
            Bytes = [System.Text.Encoding]::UTF8.GetBytes(('x' * 65))
            ExpectedText = ''
            ExpectedReason = 'unknown'
        },
        [pscustomobject]@{
            Label = 'invalid-utf8'
            Bytes = [byte[]]@(0xC3, 0x28)
            ExpectedText = ''
            ExpectedReason = 'unknown'
        },
        [pscustomobject]@{
            Label = 'synthetic-sensitive-content'
            Bytes = [System.Text.Encoding]::UTF8.GetBytes(
                '<local-path>/synthetic-sensitive-value'
            )
            ExpectedText = '<local-path>/synthetic-sensitive-value'
            ExpectedReason = 'unknown'
        }
    )
    foreach ($statusReadCase in $posixStatusReadCases) {
        try {
            [System.IO.File]::WriteAllBytes(
                $posixStatusReadFixture,
                [byte[]]$statusReadCase.Bytes
            )
            $actualStatusText =
                Read-PrivateMarkerPosixGateStatus `
                    -Path $posixStatusReadFixture
            $actualStatusReason =
                ConvertTo-PrivateMarkerPosixGateFailureReason `
                    -Status $actualStatusText
            if ($actualStatusText -cne $statusReadCase.ExpectedText -or
                $actualStatusReason -cne $statusReadCase.ExpectedReason) {
                Add-Failure 'Expected bounded POSIX status input to produce only its fixed result.'
            }
        }
        finally {
            if ([System.IO.File]::Exists($posixStatusReadFixture)) {
                [System.IO.File]::Delete($posixStatusReadFixture)
            }
        }
    }

    # childは0で即時終了させ、終了確認後だけself-test seamでdeadlineを
    # 消費する。旧「未終了かつ期限超過」条件のfalse-greenを直接測る。
    $instantExitExecutable = if (Test-PrivateMarkerWindowsHost) {
        [Environment]::GetEnvironmentVariable('ComSpec', 'Process')
    } else {
        '/bin/sh'
    }
    if ([string]::IsNullOrWhiteSpace($instantExitExecutable) -or
        -not (Test-Path -LiteralPath $instantExitExecutable -PathType Leaf)) {
        Add-Failure 'Expected an absolute native shell for the post-exit deadline regression.'
    } else {
        $instantExitArguments = if (Test-PrivateMarkerWindowsHost) {
            @('/d', '/c', 'exit 0')
        } else {
            @('-c', 'exit 0')
        }
        $expiredCompletedProcessResult = Invoke-PrivateMarkerProcess `
            -FileName $instantExitExecutable `
            -Arguments $instantExitArguments `
            -WorkingDirectory $tempRoot `
            -TimeoutMilliseconds 5000 `
            -TestOnlyPostExitDelayMilliseconds 5100
        if (-not $expiredCompletedProcessResult.TimedOut -or
            $expiredCompletedProcessResult.ExitCode -ne 0 -or
            $expiredCompletedProcessResult.OutputLimitExceeded -or
            $expiredCompletedProcessResult.InputWriteFailed -or
            $expiredCompletedProcessResult.PipeLeakDetected -or
            -not $expiredCompletedProcessResult.StreamsCompleted -or
            -not $expiredCompletedProcessResult.TreeStopped) {
            Add-Failure 'Expected the post-exit setup deadline to reject an already exited zero-code child.'
        }

        # 初回検査を期限内に通し、stream回収後だけ残時間を消費する。
        # cleanup後のelapsed-only再検査が無い旧実装を独立に赤へする。
        $expiredAfterInitialCheckResult = Invoke-PrivateMarkerProcess `
            -FileName $instantExitExecutable `
            -Arguments $instantExitArguments `
            -WorkingDirectory $tempRoot `
            -TimeoutMilliseconds 5000 `
            -TestOnlyExpireDeadlineAfterInitialCheck
        if (-not $expiredAfterInitialCheckResult.TimedOut -or
            $expiredAfterInitialCheckResult.ExitCode -ne 0 -or
            $expiredAfterInitialCheckResult.OutputLimitExceeded -or
            $expiredAfterInitialCheckResult.InputWriteFailed -or
            $expiredAfterInitialCheckResult.PipeLeakDetected -or
            -not $expiredAfterInitialCheckResult.StreamsCompleted -or
            -not $expiredAfterInitialCheckResult.TreeStopped) {
            Add-Failure 'Expected the post-stream cleanup deadline to reject a zero-code child.'
        }
    }

    if (-not (Test-PrivateMarkerWindowsHost)) {
        # direct parentが終了済みでも、同じprocess groupの孫をsignalして
        # inherited pipeと遅延sentinelの両方を確実に閉じる。
        $posixFailureCountBefore = $failures.Count
        $externalSetsidPath = @('/usr/bin/setsid', '/bin/setsid') |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        $automaticGate = if (
            [string]::IsNullOrWhiteSpace($externalSetsidPath)
        ) {
            'native-setsid'
        } else {
            'external-setsid'
        }
        $posixSurvivedSentinels =
            New-Object System.Collections.Generic.List[string]
        $posixGateCases = @(
            [pscustomobject]@{
                Label = 'automatic'
                ForceNative = $false
                ExpectedGate = $automaticGate
            },
            [pscustomobject]@{
                Label = 'forced-native'
                ForceNative = $true
                ExpectedGate = 'native-setsid'
            }
        )
        foreach ($gateCase in $posixGateCases) {
            $gateLabel = $gateCase.Label
            $forceNativeGate = $gateCase.ForceNative
            $expectedGate = $gateCase.ExpectedGate
            $startedSentinel =
                Join-Path $tempRoot "posix-$gateLabel-started.txt"
            $survivedSentinel =
                Join-Path $tempRoot "posix-$gateLabel-survived.txt"
            $posixSurvivedSentinels.Add($survivedSentinel) | Out-Null
            $escapedStartedSentinel = $startedSentinel.Replace("'", "''")
            $escapedSurvivedSentinel = $survivedSentinel.Replace("'", "''")
            $posixGrandchildTemplate = @'
[System.IO.File]::WriteAllText(
    '__STARTED__',
    'started',
    [System.Text.UTF8Encoding]::new($false)
)
Start-Sleep -Milliseconds 1500
[System.IO.File]::WriteAllText(
    '__SURVIVED__',
    'survived',
    [System.Text.UTF8Encoding]::new($false)
)
[Console]::Out.Write('late-output')
'@
            $posixGrandchildScript = $posixGrandchildTemplate.Replace(
                '__STARTED__',
                $escapedStartedSentinel
            ).Replace(
                '__SURVIVED__',
                $escapedSurvivedSentinel
            )
            $posixGrandchildEncoded = [Convert]::ToBase64String(
                [System.Text.Encoding]::Unicode.GetBytes(
                    $posixGrandchildScript
                )
            )
            $escapedPowerShellExecutable =
                $currentPowerShellExecutable.Replace("'", "''")
            $posixParentTemplate = @'
$ErrorActionPreference = 'Stop'
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = '__HOST__'
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.ArgumentList.Add('-NoProfile')
$startInfo.ArgumentList.Add('-EncodedCommand')
$startInfo.ArgumentList.Add('__PAYLOAD__')
$child = [System.Diagnostics.Process]::Start($startInfo)
try {
    $started = $false
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        if ([System.IO.File]::Exists('__STARTED__')) {
            $started = $true
            break
        }
        Start-Sleep -Milliseconds 10
    }
    if (-not $started) {
        exit 125
    }
}
finally {
    $child.Dispose()
}
'@
            $posixParentScript = $posixParentTemplate.Replace(
                '__HOST__',
                $escapedPowerShellExecutable
            ).Replace(
                '__PAYLOAD__',
                $posixGrandchildEncoded
            ).Replace(
                '__STARTED__',
                $escapedStartedSentinel
            )
            $posixParentEncoded = [Convert]::ToBase64String(
                [System.Text.Encoding]::Unicode.GetBytes($posixParentScript)
            )
            $posixPipeResult = Invoke-PrivateMarkerProcess `
                -FileName $currentPowerShellExecutable `
                -Arguments @(
                    '-NoProfile',
                    '-EncodedCommand',
                    $posixParentEncoded
                ) `
                -WorkingDirectory $tempRoot `
                -IsolationRoot (
                    Join-Path $tempRoot "posix-$gateLabel-isolation"
                ) `
                -TimeoutMilliseconds 10000 `
                -StreamCompletionWaitMilliseconds 250 `
                -StreamCleanupWaitMilliseconds 2000 `
                -ForceNativePosixSessionGate:$forceNativeGate
            if ($posixPipeResult.PosixSessionGate -cne $expectedGate) {
                Add-Failure "Expected POSIX $gateLabel containment to report gate '$expectedGate', got '$($posixPipeResult.PosixSessionGate)'."
            }
            if ($posixPipeResult.ExitCode -ne 0 -or
                -not $posixPipeResult.PipeLeakDetected -or
                $posixPipeResult.StreamsCompleted -or
                -not $posixPipeResult.TreeStopped -or
                $posixPipeResult.TimedOut -or
                $posixPipeResult.OutputLimitExceeded -or
                $posixPipeResult.InputWriteFailed) {
                Add-Failure "Expected POSIX $gateLabel containment to detect the child-held pipe and stop the process group."
            }
            if (-not (Test-Path -LiteralPath $startedSentinel -PathType Leaf)) {
                Add-Failure "Expected POSIX $gateLabel containment fixture to prove that its descendant started."
            }
        }
        Start-Sleep -Milliseconds 1750
        foreach ($survivedSentinel in $posixSurvivedSentinels) {
            if (Test-Path -LiteralPath $survivedSentinel) {
                Add-Failure 'Expected POSIX process-group cleanup to stop every delayed descendant sentinel.'
                break
            }
        }

        # kill(2)の戻り値-1は同じでも、ESRCHだけを「既に停止済み」と
        # みなし、EPERM/EACCESをTreeStopped成功へ昇格させない。
        if (-not [PrivateMarker.PosixSignal]::IsSuccessfulResult(0, 0) -or
            -not [PrivateMarker.PosixSignal]::IsSuccessfulResult(-1, 3) -or
            [PrivateMarker.PosixSignal]::IsSuccessfulResult(-1, 1) -or
            [PrivateMarker.PosixSignal]::IsSuccessfulResult(-1, 13)) {
            Add-Failure 'Expected POSIX cleanup to accept success/ESRCH and reject EPERM/EACCES.'
        }
        if ($failures.Count -eq $posixFailureCountBefore) {
            Write-Host "POSIX containment evidence: automatic=$automaticGate; forced=native-setsid; target-exit=0; descendant-started=true; descendant-stopped=true."
        }
    }

    if (Test-PrivateMarkerWindowsHost) {
        # Git が存在して timeout した場合は working-tree fallback へ降格しない。
        $syntheticGitDirectory = Join-Path $tempRoot 'synthetic-git'
        $syntheticGitPath = Join-Path $syntheticGitDirectory 'git.exe'
        $slowGitSentinel = Join-Path $tempRoot 'slow-git-survived.txt'
        New-Item -ItemType Directory -Path $syntheticGitDirectory | Out-Null
        $syntheticGitSourcePath = Join-Path $syntheticGitDirectory 'SyntheticGit.cs'
        $syntheticGitCompilerPath = Join-Path $syntheticGitDirectory 'compile-synthetic-git.ps1'
        $syntheticGitSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class SyntheticGitProgram
{
    private static string QuoteArgument(string argument)
    {
        if (String.IsNullOrEmpty(argument))
        {
            return "\"\"";
        }
        if (argument.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
        {
            return argument;
        }

        var output = new StringBuilder("\"");
        var backslashes = 0;
        foreach (var character in argument)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                output.Append('\\', (backslashes * 2) + 1);
                output.Append('"');
                backslashes = 0;
                continue;
            }
            output.Append('\\', backslashes);
            backslashes = 0;
            output.Append(character);
        }
        output.Append('\\', backslashes * 2);
        output.Append('"');
        return output.ToString();
    }

    private static int Run(string fileName, string[] arguments, int timeoutMilliseconds)
    {
        var forwardsInput = Array.IndexOf(arguments, "cat-file") >= 0 &&
            Array.IndexOf(arguments, "--batch") >= 0;
        var startInfo = new ProcessStartInfo {
            FileName = fileName,
            Arguments = String.Join(" ", Array.ConvertAll(arguments, QuoteArgument)),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = forwardsInput,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        using (var process = Process.Start(startInfo))
        {
            var stdoutTask = process.StandardOutput.BaseStream.CopyToAsync(
                Console.OpenStandardOutput());
            var stderrTask = process.StandardError.BaseStream.CopyToAsync(
                Console.OpenStandardError());
            if (forwardsInput)
            {
                var inputTask = Console.OpenStandardInput().CopyToAsync(
                    process.StandardInput.BaseStream);
                if (!inputTask.Wait(5000))
                {
                    process.Kill();
                    process.WaitForExit(5000);
                    return 123;
                }
                process.StandardInput.Close();
            }
            if (!process.WaitForExit(timeoutMilliseconds))
            {
                process.Kill();
                process.WaitForExit(5000);
                return 124;
            }
            if (!Task.WaitAll(new[] { stdoutTask, stderrTask }, 5000))
            {
                return 125;
            }
            Console.Out.Flush();
            Console.Error.Flush();
            return process.ExitCode;
        }
    }

    private static bool IsStageListing(string[] arguments)
    {
        return Array.IndexOf(arguments, "ls-files") >= 0 &&
            Array.IndexOf(arguments, "--stage") >= 0 &&
            Array.IndexOf(arguments, "-z") >= 0 &&
            Array.IndexOf(arguments, "--debug") < 0;
    }

    private static bool IsDebugStageListing(string[] arguments)
    {
        return Array.IndexOf(arguments, "ls-files") >= 0 &&
            Array.IndexOf(arguments, "--stage") >= 0 &&
            Array.IndexOf(arguments, "-z") >= 0 &&
            Array.IndexOf(arguments, "--debug") >= 0;
    }

    private static int NextStageListingCount(string counterPath)
    {
        using (var stream = new FileStream(
            counterPath,
            FileMode.OpenOrCreate,
            FileAccess.ReadWrite,
            FileShare.None))
        {
            if (stream.Length > 32)
            {
                throw new InvalidDataException("Synthetic Git counter is invalid.");
            }
            var bytes = new byte[(int)stream.Length];
            var offset = 0;
            while (offset < bytes.Length)
            {
                var read = stream.Read(bytes, offset, bytes.Length - offset);
                if (read == 0)
                {
                    throw new EndOfStreamException();
                }
                offset += read;
            }

            var count = 0;
            if (bytes.Length > 0 &&
                !Int32.TryParse(Encoding.ASCII.GetString(bytes), out count))
            {
                throw new InvalidDataException("Synthetic Git counter is invalid.");
            }
            count++;
            var nextBytes = Encoding.ASCII.GetBytes(count.ToString());
            stream.Position = 0;
            stream.SetLength(0);
            stream.Write(nextBytes, 0, nextBytes.Length);
            stream.Flush(true);
            return count;
        }
    }

    public static int Main(string[] args)
    {
        if (String.Equals(
            Environment.GetEnvironmentVariable("PRIVATE_MARKER_SYNTHETIC_GIT_MODE"),
            "index-mutation",
            StringComparison.Ordinal))
        {
            var realGit = Environment.GetEnvironmentVariable("PRIVATE_MARKER_REAL_GIT");
            var counterPath = Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_COUNTER");
            if (IsStageListing(args) && NextStageListingCount(counterPath) == 2)
            {
                var mutationExit = Run(
                    realGit,
                    new[] {
                        "-C",
                        Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_REPO"),
                        "add",
                        "--",
                        Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_REPLACEMENT"),
                        Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_ADDITION")
                    },
                    5000);
                if (mutationExit != 0)
                {
                    return 90;
                }
                File.WriteAllText(
                    Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_MUTATION_SENTINEL"),
                    "mutated",
                    new UTF8Encoding(false));
            }
            return Run(realGit, args, 20000);
        }

        if (String.Equals(
            Environment.GetEnvironmentVariable("PRIVATE_MARKER_SYNTHETIC_GIT_MODE"),
            "flags-mutation",
            StringComparison.Ordinal))
        {
            var realGit = Environment.GetEnvironmentVariable("PRIVATE_MARKER_REAL_GIT");
            var counterPath = Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_COUNTER");
            if (IsDebugStageListing(args) && NextStageListingCount(counterPath) == 2)
            {
                var repository =
                    Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_REPO");
                var relativePath =
                    Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_REPLACEMENT");
                var removeExit = Run(
                    realGit,
                    new[] {
                        "-C",
                        repository,
                        "update-index",
                        "--force-remove",
                        "--",
                        relativePath
                    },
                    5000);
                var intentExit = removeExit == 0
                    ? Run(
                        realGit,
                        new[] {
                            "-C",
                            repository,
                            "add",
                            "-N",
                            "--",
                            relativePath
                        },
                        5000)
                    : removeExit;
                if (removeExit != 0 || intentExit != 0)
                {
                    return 91;
                }
                File.WriteAllText(
                    Environment.GetEnvironmentVariable("PRIVATE_MARKER_INDEX_MUTATION_SENTINEL"),
                    "flags-mutated",
                    new UTF8Encoding(false));
            }
            return Run(realGit, args, 20000);
        }

        if (String.Equals(
            Environment.GetEnvironmentVariable("PRIVATE_MARKER_SYNTHETIC_GIT_MODE"),
            "root-alias",
            StringComparison.Ordinal))
        {
            var realGit = Environment.GetEnvironmentVariable("PRIVATE_MARKER_REAL_GIT");
            if (Array.IndexOf(args, "rev-parse") >= 0 &&
                Array.IndexOf(args, "--show-toplevel") >= 0)
            {
                Console.Out.WriteLine(
                    Environment.GetEnvironmentVariable("PRIVATE_MARKER_ROOT_ALIAS"));
                return 0;
            }
            return Run(realGit, args, 20000);
        }

        if (String.Equals(
            Environment.GetEnvironmentVariable("PRIVATE_MARKER_SYNTHETIC_GIT_MODE"),
            "whitespace-prefix",
            StringComparison.Ordinal))
        {
            var realGit = Environment.GetEnvironmentVariable("PRIVATE_MARKER_REAL_GIT");
            if (Array.IndexOf(args, "rev-parse") >= 0 &&
                Array.IndexOf(args, "--show-prefix") >= 0)
            {
                Console.Out.WriteLine("\u2003");
                return 0;
            }
            return Run(realGit, args, 20000);
        }

        if (String.Equals(
            Environment.GetEnvironmentVariable("PRIVATE_MARKER_SYNTHETIC_GIT_MODE"),
            "bom-prefix",
            StringComparison.Ordinal))
        {
            var realGit = Environment.GetEnvironmentVariable("PRIVATE_MARKER_REAL_GIT");
            if (Array.IndexOf(args, "rev-parse") >= 0 &&
                Array.IndexOf(args, "--show-prefix") >= 0)
            {
                var output = Console.OpenStandardOutput();
                var bytes = new byte[] { 0xEF, 0xBB, 0xBF, 0x0A };
                output.Write(bytes, 0, bytes.Length);
                output.Flush();
                return 0;
            }
            return Run(realGit, args, 20000);
        }

        Thread.Sleep(5000);
        File.WriteAllText(
            Environment.GetEnvironmentVariable("PRIVATE_MARKER_SLOW_GIT_SENTINEL"),
            "survived");
        return 0;
    }
}
'@
        $immediateSpawnerPath = Join-Path $syntheticGitDirectory 'ImmediateSpawner.exe'
        $immediateSpawnerSourcePath = Join-Path $syntheticGitDirectory 'ImmediateSpawner.cs'
        $immediateSpawnerSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;

public static class ImmediateSpawnerProgram
{
    public static int Main(string[] args)
    {
        if (args.Length == 1 &&
            String.Equals(args[0], "--child", StringComparison.Ordinal))
        {
            File.WriteAllText(
                Environment.GetEnvironmentVariable("PRIVATE_MARKER_PIPE_STARTED_SENTINEL"),
                "started",
                new UTF8Encoding(false));
            Thread.Sleep(1000);
            File.WriteAllText(
                Environment.GetEnvironmentVariable("PRIVATE_MARKER_PIPE_SURVIVED_SENTINEL"),
                "survived",
                new UTF8Encoding(false));
            return 0;
        }

        // root process は意図的な猶予を置かず、最初の処理で pipe 継承 child を起動する。
        var startInfo = new ProcessStartInfo {
            FileName = Assembly.GetExecutingAssembly().Location,
            Arguments = "--child",
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using (var child = Process.Start(startInfo))
        {
            if (child == null)
            {
                return 20;
            }
        }
        Console.Out.WriteLine("parent-exit");
        return 0;
    }
}
'@
        $syntheticGitCompiler = @'
param(
    [string]$SourcePath,
    [string]$OutputPath
)
Add-Type `
    -Path $SourcePath `
    -OutputAssembly $OutputPath `
    -OutputType ConsoleApplication
'@
        [System.IO.File]::WriteAllText(
            $syntheticGitSourcePath,
            $syntheticGitSource,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::WriteAllText(
            $immediateSpawnerSourcePath,
            $immediateSpawnerSource,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::WriteAllText(
            $syntheticGitCompilerPath,
            $syntheticGitCompiler,
            [System.Text.UTF8Encoding]::new($true)
        )
        $windowsPowerShell = Get-Command powershell -ErrorAction Stop
        $compileResult = Invoke-PrivateMarkerProcess `
            -FileName $windowsPowerShell.Source `
            -Arguments @(
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                $syntheticGitCompilerPath,
                '-SourcePath',
                $syntheticGitSourcePath,
                '-OutputPath',
                $syntheticGitPath
            ) `
            -WorkingDirectory $syntheticGitDirectory `
            -TimeoutMilliseconds 30000
        if ($compileResult.ExitCode -ne 0 -or
            -not $compileResult.StreamsCompleted -or
            -not $compileResult.TreeStopped -or
            -not (Test-Path -LiteralPath $syntheticGitPath -PathType Leaf)) {
            Add-Failure 'Expected bounded synthetic Git compilation to succeed.'
        }
        $spawnerCompileResult = Invoke-PrivateMarkerProcess `
            -FileName $windowsPowerShell.Source `
            -Arguments @(
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                $syntheticGitCompilerPath,
                '-SourcePath',
                $immediateSpawnerSourcePath,
                '-OutputPath',
                $immediateSpawnerPath
            ) `
            -WorkingDirectory $syntheticGitDirectory `
            -TimeoutMilliseconds 30000
        if ($spawnerCompileResult.ExitCode -ne 0 -or
            -not $spawnerCompileResult.StreamsCompleted -or
            -not $spawnerCompileResult.TreeStopped -or
            -not (Test-Path -LiteralPath $immediateSpawnerPath -PathType Leaf)) {
            Add-Failure 'Expected bounded immediate-spawner compilation to succeed.'
        } else {
            # 目的 process が最初の処理で child を起動しても、direct target は
            # suspended 中にJob所属済みなのでkill-on-close境界から逃げられない。
            $pipeSurvivedSentinels = New-Object System.Collections.Generic.List[string]
            for ($attempt = 1; $attempt -le 10; $attempt++) {
                $pipeStartedSentinel = Join-Path `
                    $tempRoot `
                    "pipe-grandchild-started-$attempt.txt"
                $pipeSurvivedSentinel = Join-Path `
                    $tempRoot `
                    "pipe-grandchild-survived-$attempt.txt"
                $pipeSurvivedSentinels.Add($pipeSurvivedSentinel) | Out-Null
                $pipeResult = Invoke-PrivateMarkerProcess `
                    -FileName $immediateSpawnerPath `
                    -WorkingDirectory $tempRoot `
                    -EnvironmentOverrides @{
                        PRIVATE_MARKER_PIPE_STARTED_SENTINEL = $pipeStartedSentinel
                        PRIVATE_MARKER_PIPE_SURVIVED_SENTINEL = $pipeSurvivedSentinel
                    } `
                    -TimeoutMilliseconds 10000 `
                    -StreamCompletionWaitMilliseconds 500 `
                    -StreamCleanupWaitMilliseconds 1000
                if (-not $pipeResult.PipeLeakDetected -or
                    $pipeResult.StreamsCompleted -or
                    -not $pipeResult.TreeStopped) {
                    Add-Failure "Expected immediate-spawner attempt $attempt to detect and stop a child-held pipe."
                }
                if (-not (Test-Path -LiteralPath $pipeStartedSentinel)) {
                    Add-Failure "Expected immediate-spawner attempt $attempt to prove that its child started."
                }
            }

            # 全 attempt の child が artifact を書く期限を一度だけ bounded に待つ。
            Start-Sleep -Milliseconds 1250
            foreach ($pipeSurvivedSentinel in $pipeSurvivedSentinels) {
                if (Test-Path -LiteralPath $pipeSurvivedSentinel) {
                    Add-Failure 'Expected atomic Job assignment to stop every immediate child before artifact creation.'
                    break
                }
            }
        }

        $timeoutRoot = Join-Path $tempRoot 'timeout-root'
        New-Item -ItemType Directory -Path $timeoutRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $timeoutRoot 'README.md') -Value 'synthetic clean timeout fixture' -Encoding UTF8
        $timeoutResult = Invoke-Scanner `
            -ScanPath $timeoutRoot `
            -EnvironmentOverrides @{
                PATH = $syntheticGitDirectory
                PRIVATE_MARKER_SLOW_GIT_SENTINEL = $slowGitSentinel
            } `
            -AdditionalArguments @('-GitCommandTimeoutMilliseconds', '750')
        if ($timeoutResult.ExitCode -eq 0 -or
            $timeoutResult.Output -notmatch 'Git root probe') {
            Add-Failure "Expected a timed-out Git probe to fail closed. Output: $($timeoutResult.Output.Trim())"
        }
        if (Test-Path -LiteralPath $slowGitSentinel) {
            Add-Failure 'Expected the timed-out synthetic Git process tree to be stopped before artifact creation.'
        }
    }

    # success 側の規約例を 1 fixture へ集約し、各例を個別 process で再走査しない。
    $cleanRoot = Join-Path $tempRoot 'clean accepted examples'
    New-Item -ItemType Directory -Path $cleanRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $cleanRoot 'README.md') -Value @(
        '# Clean synthetic fixture'
        'A completion notice is a claim, not evidence. Verify artifacts first.'
        'Use a placeholder path such as C:\path\to\repo in examples.'
        'You can also write C:\Users\<name>\project to describe a user directory.'
        ('Own repo: ' + (('https://github' + '.com/') + 'h8nc4y/windows-utf8-text-hygiene'))
        ('Related skill: ' + (('https://github' + '.com/') + 'h8nc4y/claude-code-devlog-hooks'))
    ) -Encoding UTF8

    $cleanResult = Invoke-Scanner -ScanPath $cleanRoot
    if ($cleanResult.ExitCode -ne 0) {
        Add-Failure "Expected clean fixture to pass, but scanner exited $($cleanResult.ExitCode): $($cleanResult.Output.Trim())"
    }
    $noGitFallbackResult = Invoke-Scanner `
        -ScanPath $cleanRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    if ($noGitFallbackResult.ExitCode -ne 0 -or
        $noGitFallbackResult.Output -notmatch 'working-tree') {
        Add-Failure "Expected a true non-Git directory to retain fallback when Git is unavailable. Output: $($noGitFallbackResult.Output.Trim())"
    }

    # non-Git fallback は nested `.git` directory だけでなく leaf gitfile も読まない。
    $nestedGitLeafRoot = Join-Path $cleanRoot 'nested-git-leaf'
    New-Item -ItemType Directory -Path $nestedGitLeafRoot | Out-Null
    $nestedGitLeafPath = Join-Path $nestedGitLeafRoot '.git'
    $nestedGitLeafMarker = ('g' + 'hp_') + 'synthetic_gitfile_marker'
    Set-Content `
        -LiteralPath $nestedGitLeafPath `
        -Value $nestedGitLeafMarker `
        -Encoding UTF8
    $nestedGitLeafResult = Invoke-Scanner `
        -ScanPath $cleanRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    if ($nestedGitLeafResult.ExitCode -ne 0 -or
        $nestedGitLeafResult.Output -notmatch 'working-tree' -or
        $nestedGitLeafResult.Output.Contains($nestedGitLeafMarker)) {
        Add-Failure "Expected a nested .git leaf to remain excluded from fallback scanning. Output: $($nestedGitLeafResult.Output.Trim())"
    }
    [System.IO.File]::Delete($nestedGitLeafPath)
    [System.IO.Directory]::Delete($nestedGitLeafRoot)

    # OS は ambient 変数ではなく runtime API で判定する。unset/empty/forgedでも挙動を固定する。
    foreach ($osCase in @(
        @{ Label = 'unset'; Value = $null },
        @{ Label = 'present-empty'; Value = '' },
        @{ Label = 'forged-posix'; Value = 'forged-posix' },
        @{ Label = 'forged-windows'; Value = 'Windows_NT' }
    )) {
        $osEnvironment = @{
            PATH = $emptyCommandPath
            OS = $osCase.Value
        }
        $osResult = Invoke-Scanner `
            -ScanPath $cleanRoot `
            -EnvironmentOverrides $osEnvironment
        if ($osResult.ExitCode -ne 0 -or
            $osResult.Output -notmatch 'working-tree') {
            Add-Failure "Expected ambient OS case '$($osCase.Label)' not to change runtime detection. Output: $($osResult.Output.Trim())"
        }
    }

    # content byte数が0でも entry数で必ず停止し、空file群を無制限に保持しない。
    $zeroByteRoot = Join-Path $tempRoot 'zero-byte-entry-limit'
    New-Item -ItemType Directory -Path $zeroByteRoot | Out-Null
    for ($zeroIndex = 0; $zeroIndex -le 10000; $zeroIndex++) {
        $zeroPath = Join-Path $zeroByteRoot (
            'zero-{0:D5}' -f $zeroIndex
        )
        $zeroStream = [System.IO.File]::Create($zeroPath)
        $zeroStream.Dispose()
    }
    $zeroByteResult = Invoke-Scanner `
        -ScanPath $zeroByteRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    if ($zeroByteResult.ExitCode -eq 0 -or
        $zeroByteResult.Output -notmatch 'entry limit' -or
        $zeroByteResult.Output.Length -gt 16384) {
        Add-Failure "Expected zero-byte file amplification to hit the bounded entry limit. Output: $($zeroByteResult.Output.Trim())"
    }

    # Higher-recall cloud / PEM prefixes, with one redaction regression each.
    # finding 側も 1 directory へ集約するが、rule と固有 file 名を全件確認して
    # どれか 1 件だけの成功を matrix 全体の成功と誤認しない。
    $findingRoot = Join-Path $tempRoot 'combined findings'
    New-Item -ItemType Directory -Path $findingRoot | Out-Null
    $syntheticMarker = ('g' + 'hp_') + 'synthetic_placeholder_only'
    $adjacentContent = 'synthetic marker after UTF-8: ' + [char]0x30C8 + $syntheticMarker
    [System.IO.File]::WriteAllText(
        (Join-Path $findingRoot 'utf8-adjacent.md'),
        $adjacentContent,
        [System.Text.UTF8Encoding]::new($false)
    )
    $prefixCases = @(
        @{ Rule = 'openai-api-key-prefix';            Marker = ('s' + 'k-') + 'SyntheticOpenAI000000000000' }
        @{ Rule = 'aws-access-key-id';                Marker = ('A' + 'KIA') + 'EXAMPLE0000000000000' }
        @{ Rule = 'gcp-api-key-prefix';               Marker = ('AIza') + 'Synthetic0000000000000000000000000000' }
        @{ Rule = 'slack-user-token-prefix';          Marker = ('xo' + 'xp-') + 'synthetic-placeholder' }
        @{ Rule = 'slack-legacy-app-token-prefix';    Marker = ('xo' + 'xa-') + 'synthetic-placeholder' }
        @{ Rule = 'slack-app-level-token-prefix';     Marker = ('xa' + 'pp-') + 'synthetic-placeholder' }
        @{ Rule = 'stripe-live-secret-key';           Marker = ('s' + 'k') + '_live_SyntheticPlaceholder0000' }
        @{ Rule = 'pem-private-key-block';            Marker = '-----' + ('BEGIN ' + 'OPENSSH PRIVATE KEY') + '-----' }
    )

    foreach ($case in $prefixCases) {
        Set-Content `
            -LiteralPath (Join-Path $findingRoot ("$($case.Rule).txt")) `
            -Value "synthetic marker: $($case.Marker)" `
            -Encoding UTF8
    }

    # windows-absolute-path: private-looking paths should be findings.
    # Split the literal so this test file does not make the scanner flag itself.
    $realWinPath = 'C' + ':\Users\realperson\Secrets\config'
    Set-Content `
        -LiteralPath (Join-Path $findingRoot 'windows-path.md') `
        -Value "See $realWinPath for details." `
        -Encoding UTF8

    # non-allowlisted GitHub URL も同一 finding scan で検査する。
    # URLs are split so this test file does not make the scanner flag itself.
    $foreignUrl = ('https://github' + '.com/') + 'someone-else/private-repo'
    Set-Content `
        -LiteralPath (Join-Path $findingRoot 'github-url.md') `
        -Value "See $foreignUrl for details." `
        -Encoding UTF8

    # Cf/bidi と Unicode line/paragraph separator は terminal 上で必ず escape する。
    $diagnosticControlCharacters = @(
        [char]0x202E,
        [char]0x2028,
        [char]0x2029
    )
    $diagnosticControlName =
        'diagnostic-' +
        ($diagnosticControlCharacters -join '-') +
        '-spoof.md'
    Set-Content `
        -LiteralPath (Join-Path $findingRoot $diagnosticControlName) `
        -Value "synthetic marker: $syntheticMarker" `
        -Encoding UTF8

    $findingResult = Invoke-Scanner -ScanPath $findingRoot
    if ($findingResult.ExitCode -eq 0) {
        Add-Failure 'Expected the combined synthetic finding fixture to fail.'
    }
    $expectedRules = @(
        'github-classic-token-prefix'
        $prefixCases.Rule
        'windows-absolute-path'
        'non-allowlisted-github-repo-url'
    )
    foreach ($rule in $expectedRules) {
        if ($findingResult.Output -notmatch [regex]::Escape($rule)) {
            Add-Failure "Expected combined finding output to name $rule. Output: $($findingResult.Output.Trim())"
        }
    }
    if ($findingResult.Output -notmatch 'utf8-adjacent\.md') {
        Add-Failure 'Expected the BOM-less UTF-8 adjacent marker file to appear in findings.'
    }
    foreach ($rawValue in @(
        $syntheticMarker
        $prefixCases.Marker
        $realWinPath
        $foreignUrl
    )) {
        if ($findingResult.Output.Contains($rawValue)) {
            Add-Failure 'Expected every combined finding value to stay redacted.'
        }
    }
    if ($findingResult.Output -notmatch '<redacted>') {
        Add-Failure "Expected combined findings to report '<redacted>'. Output: $($findingResult.Output.Trim())"
    }
    foreach ($diagnosticCharacter in $diagnosticControlCharacters) {
        if ($findingResult.Output.Contains([string]$diagnosticCharacter)) {
            Add-Failure 'Expected diagnostic control characters not to appear raw in scanner output.'
        }
    }
    foreach ($escapedDiagnostic in @('\u202E', '\u2028', '\u2029')) {
        if (-not $findingResult.Output.Contains($escapedDiagnostic)) {
            Add-Failure "Expected scanner output to contain escaped diagnostic text $escapedDiagnostic."
        }
    }

    # 同一行のURL列挙は finding を1件へ畳み、出力サイズを URL 数で増幅させない。
    $urlAmplificationRoot = Join-Path $tempRoot 'url-amplification'
    New-Item -ItemType Directory -Path $urlAmplificationRoot | Out-Null
    $foreignUrls = (
        1..200 |
            ForEach-Object { "${foreignUrl}?fixture=$_" }
    ) -join ' '
    Set-Content `
        -LiteralPath (Join-Path $urlAmplificationRoot 'many-urls.md') `
        -Value $foreignUrls `
        -Encoding UTF8
    $urlAmplificationResult = Invoke-Scanner -ScanPath $urlAmplificationRoot
    $urlRuleCount = [regex]::Matches(
        $urlAmplificationResult.Output,
        'non-allowlisted-github-repo-url'
    ).Count
    if ($urlAmplificationResult.ExitCode -eq 0 -or
        $urlRuleCount -ne 1 -or
        $urlAmplificationResult.Output.Length -gt 16384) {
        Add-Failure "Expected same-line URL findings to stay deduplicated and bounded. Output length: $($urlAmplificationResult.Output.Length)"
    }

    # allowlisted URL だけでも NextMatch 回数を固定し、巨大な match 列挙を fail-closed にする。
    $allowedUrl = ('https://github' + '.com/') +
        'h8nc4y/windows-utf8-text-hygiene'
    $allowedUrlAmplificationRoot =
        Join-Path $tempRoot 'allowed-url-amplification'
    New-Item -ItemType Directory -Path $allowedUrlAmplificationRoot | Out-Null
    Set-Content `
        -LiteralPath (
            Join-Path $allowedUrlAmplificationRoot 'many-allowed-urls.md'
        ) `
        -Value ((1..300 | ForEach-Object { $allowedUrl }) -join ' ') `
        -Encoding UTF8
    $allowedUrlAmplificationResult =
        Invoke-Scanner -ScanPath $allowedUrlAmplificationRoot
    if ($allowedUrlAmplificationResult.ExitCode -eq 0 -or
        $allowedUrlAmplificationResult.Output -notmatch
            'per-line URL match limit' -or
        $allowedUrlAmplificationResult.Output.Length -gt 16384) {
        Add-Failure "Expected allowed-URL amplification to fail inside a bounded diagnostic. Output: $($allowedUrlAmplificationResult.Output.Trim())"
    }

    # 1行全体を split 配列へ複製せず、bounded substring の前に行長で拒否する。
    $overlongLineRoot = Join-Path $tempRoot 'overlong-line-limit'
    New-Item -ItemType Directory -Path $overlongLineRoot | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $overlongLineRoot 'overlong.txt'),
        [string]::new([char]'a', (1MB + 1)),
        [System.Text.UTF8Encoding]::new($false)
    )
    $overlongLineResult = Invoke-Scanner -ScanPath $overlongLineRoot
    if ($overlongLineResult.ExitCode -eq 0 -or
        $overlongLineResult.Output -notmatch 'overlong line' -or
        $overlongLineResult.Output.Length -gt 16384) {
        Add-Failure "Expected an overlong line to fail before unbounded line scanning. Output: $($overlongLineResult.Output.Trim())"
    }

    # 上限近傍でもregex開始候補を持たない安全な単一行はtimeout扱いにしない。
    # adversarial negativeだけでなく、false-positive側の対照も同じprocess境界で固定する。
    $regexSafeNearLimitRoot = Join-Path $tempRoot 'regex-safe-near-limit'
    New-Item -ItemType Directory -Path $regexSafeNearLimitRoot | Out-Null
    $regexSafeNearLimitPath =
        Join-Path $regexSafeNearLimitRoot 'safe-near-limit.txt'
    [System.IO.File]::WriteAllText(
        $regexSafeNearLimitPath,
        [string]::new([char]' ', 900000),
        [System.Text.UTF8Encoding]::new($false)
    )
    $regexSafeNearLimitClock = [System.Diagnostics.Stopwatch]::StartNew()
    $regexSafeNearLimitResult = Invoke-Scanner `
        -ScanPath $regexSafeNearLimitRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    $regexSafeNearLimitClock.Stop()
    if ($regexSafeNearLimitResult.ExitCode -ne 0 -or
        $regexSafeNearLimitResult.TimedOut -or
        -not $regexSafeNearLimitResult.StreamsCompleted -or
        -not $regexSafeNearLimitResult.TreeStopped -or
        $regexSafeNearLimitResult.Output -notmatch
            'Private marker scan passed' -or
        $regexSafeNearLimitClock.ElapsedMilliseconds -gt 10000) {
        Add-Failure (
            'Expected a safe near-limit line to pass inside the scanner ' +
            "boundary. Elapsed: " +
            "$($regexSafeNearLimitClock.ElapsedMilliseconds) ms."
        )
    }

    # 1MiB line上限を下回るno-matchでも、email regexは開始位置ごとの再走査で
    # scan-wide budgetを占有できる。regex自身の有限timeoutと固定診断を実測する。
    $regexTimeoutRoot = Join-Path $tempRoot 'regex-match-timeout'
    New-Item -ItemType Directory -Path $regexTimeoutRoot | Out-Null
    $regexTimeoutPath = Join-Path $regexTimeoutRoot 'adversarial.txt'
    [System.IO.File]::WriteAllText(
        $regexTimeoutPath,
        ('a.' * 500000),
        [System.Text.UTF8Encoding]::new($false)
    )
    $regexTimeoutClock = [System.Diagnostics.Stopwatch]::StartNew()
    $regexTimeoutResult = Invoke-Scanner `
        -ScanPath $regexTimeoutRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    $regexTimeoutClock.Stop()
    Assert-FixedRegexTimeoutFailure `
        -Result $regexTimeoutResult `
        -ForbiddenPaths @(
            $root,
            $tempRoot,
            $regexTimeoutRoot,
            $regexTimeoutPath,
            $scanner,
            $processBoundary
        )
    if ($regexTimeoutResult.TimedOut -or
        -not $regexTimeoutResult.StreamsCompleted -or
        -not $regexTimeoutResult.TreeStopped -or
        $regexTimeoutClock.ElapsedMilliseconds -gt 10000) {
        Add-Failure (
            'Expected adversarial regex no-match to fail inside the scanner ' +
            "boundary. Elapsed: $($regexTimeoutClock.ElapsedMilliseconds) ms."
        )
    }

    # finding は file 単位と scan 全体の双方で上限を持つ。
    $perFileFindingRoot = Join-Path $tempRoot 'per-file-finding-limit'
    New-Item -ItemType Directory -Path $perFileFindingRoot | Out-Null
    $perFileMarkerLines = (
        1..65 |
            ForEach-Object { "synthetic line $_ $syntheticMarker" }
    )
    Set-Content `
        -LiteralPath (Join-Path $perFileFindingRoot 'many-findings.md') `
        -Value $perFileMarkerLines `
        -Encoding UTF8
    $perFileFindingResult = Invoke-Scanner -ScanPath $perFileFindingRoot
    if ($perFileFindingResult.ExitCode -eq 0 -or
        $perFileFindingResult.Output -notmatch 'per-file finding limit' -or
        $perFileFindingResult.Output.Length -gt 16384 -or
        $perFileFindingResult.Output.Contains($syntheticMarker)) {
        Add-Failure "Expected per-file finding amplification to fail closed without exposing values. Output: $($perFileFindingResult.Output.Trim())"
    }

    $totalFindingRoot = Join-Path $tempRoot 'total-finding-limit'
    New-Item -ItemType Directory -Path $totalFindingRoot | Out-Null
    foreach ($fileIndex in 1..9) {
        $totalMarkerLines = (
            1..60 |
                ForEach-Object {
                    "synthetic file $fileIndex line $_ $syntheticMarker"
                }
        )
        Set-Content `
            -LiteralPath (
                Join-Path $totalFindingRoot ("findings-{0:D2}.md" -f $fileIndex)
            ) `
            -Value $totalMarkerLines `
            -Encoding UTF8
    }
    $totalFindingResult = Invoke-Scanner -ScanPath $totalFindingRoot
    if ($totalFindingResult.ExitCode -eq 0 -or
        $totalFindingResult.Output -notmatch 'total finding limit' -or
        $totalFindingResult.Output.Length -gt 16384 -or
        $totalFindingResult.Output.Contains($syntheticMarker)) {
        Add-Failure "Expected total finding amplification to fail closed without exposing values. Output: $($totalFindingResult.Output.Trim())"
    }

    $localMarkerRoot = Join-Path $tempRoot 'local-marker'
    New-Item -ItemType Directory -Path $localMarkerRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $localMarkerRoot '.private-markers.local') -Value 'local-only-marker' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $localMarkerRoot 'leak.txt') -Value 'synthetic local-only-marker fixture' -Encoding UTF8

    $localMarkerResult = Invoke-Scanner -ScanPath $localMarkerRoot
    if ($localMarkerResult.ExitCode -eq 0) {
        Add-Failure 'Expected local marker fixture to fail, but scanner exited 0.'
    }
    if ($localMarkerResult.Output -notmatch 'local-private-marker-1') {
        Add-Failure "Expected local marker output to name local-private-marker-1. Output: $($localMarkerResult.Output.Trim())"
    }

    if (Test-PrivateMarkerWindowsHost) {
        # Explicit scan root 自体が junction の場合も、外部 target を列挙する前に拒否する。
        $rootJunctionPath = Join-Path $tempRoot 'root junction'
        $rootJunctionTarget = Join-Path $tempRoot 'root junction external target'
        New-Item -ItemType Directory -Path $rootJunctionTarget | Out-Null
        Set-Content `
            -LiteralPath (Join-Path $rootJunctionTarget 'clean.md') `
            -Value 'synthetic clean root-junction content' `
            -Encoding UTF8
        try {
            New-Item `
                -ItemType Junction `
                -Path $rootJunctionPath `
                -Target $rootJunctionTarget |
                Out-Null
            $rootJunctionResult = Invoke-Scanner -ScanPath $rootJunctionPath
            if ($rootJunctionResult.ExitCode -eq 0 -or
                $rootJunctionResult.Output -notmatch 'Explicit scan root must not be') {
                Add-Failure "Expected an explicit root junction to fail closed. Output: $($rootJunctionResult.Output.Trim())"
            }
        }
        finally {
            if (Test-Path -LiteralPath $rootJunctionPath) {
                [System.IO.Directory]::Delete($rootJunctionPath)
            }
        }

        # Dangling .git junction は target 解決で消えたように見えても Git 境界として fail-closed にする。
        $danglingGitRoot = Join-Path $tempRoot 'dangling git marker'
        $danglingGitTarget = Join-Path $tempRoot 'deleted git marker target'
        $danglingGitMarker = Join-Path $danglingGitRoot '.git'
        New-Item -ItemType Directory -Path $danglingGitRoot | Out-Null
        New-Item -ItemType Directory -Path $danglingGitTarget | Out-Null
        try {
            New-Item -ItemType Junction -Path $danglingGitMarker -Target $danglingGitTarget | Out-Null
            [System.IO.Directory]::Delete($danglingGitTarget)
            $danglingGitResult = Invoke-Scanner -ScanPath $danglingGitRoot
            if ($danglingGitResult.ExitCode -eq 0 -or
                $danglingGitResult.Output -notmatch 'Git root probe failed closed') {
                Add-Failure "Expected a dangling .git junction to block fallback scanning. Output: $($danglingGitResult.Output.Trim())"
            }
            $danglingNoGitResult = Invoke-Scanner `
                -ScanPath $danglingGitRoot `
                -EnvironmentOverrides @{ PATH = $emptyCommandPath }
            if ($danglingNoGitResult.ExitCode -eq 0 -or
                $danglingNoGitResult.Output -notmatch 'Git executable is unavailable') {
                Add-Failure "Expected a dangling .git junction to block no-Git fallback. Output: $($danglingNoGitResult.Output.Trim())"
            }
        }
        finally {
            $danglingGitEntry = Get-ChildItem `
                -LiteralPath $danglingGitRoot `
                -Force `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ceq '.git' } |
                Select-Object -First 1
            if ($null -ne $danglingGitEntry) {
                $danglingGitEntry.Delete()
            }
        }
    }

    # 敵対的な Git 環境は scanner の子だけへ渡す。親の absent / present-empty は変更しない。
    $trackedRoot = Join-Path $tempRoot 'git tracked target'
    $decoyRoot = Join-Path $tempRoot 'git decoy'
    $fixtureIsolationRoot = Join-Path $tempRoot 'fixture-git-isolation'
    $ambientRoot = Join-Path $tempRoot 'ambient-git'
    foreach ($directory in @($trackedRoot, $decoyRoot, $fixtureIsolationRoot, $ambientRoot)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $targetInit = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('init', '--quiet') `
        -IsolationRoot $fixtureIsolationRoot
    if ($targetInit.ExitCode -ne 0 -or $targetInit.TimedOut -or -not $targetInit.TreeStopped) {
        Add-Failure "Expected bounded target git init to succeed. Output: $($targetInit.Output.Trim())"
    }

    # --show-prefix 単独では Git 管理 directory でも空を返せるため、
    # 先行する --show-toplevel の worktree 証明を削除できないよう固定する。
    $gitDirectoryResult = Invoke-Scanner `
        -ScanPath (Join-Path $trackedRoot '.git')
    if ($gitDirectoryResult.ExitCode -eq 0 -or
        $gitDirectoryResult.Output -notmatch 'Git root probe failed closed') {
        Add-Failure "Expected a Git administrative directory scan to fail closed. Output: $($gitDirectoryResult.Output.Trim())"
    }

    # Unicode 空白だけの directory 名も worktree root ではない。prefix の
    # Trim / whitespace 許容へ退行して部分 scan を通さない。
    $unicodeWhitespaceDirectory = Join-Path $trackedRoot ([string][char]0x2003)
    New-Item -ItemType Directory -Path $unicodeWhitespaceDirectory | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $unicodeWhitespaceDirectory 'clean.md') `
        -Value 'synthetic clean Unicode whitespace subdirectory' `
        -Encoding UTF8
    $unicodeWhitespaceAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '--', ([string][char]0x2003 + '/clean.md')) `
        -IsolationRoot $fixtureIsolationRoot
    if ($unicodeWhitespaceAdd.ExitCode -ne 0) {
        Add-Failure "Expected Unicode whitespace subdirectory setup to succeed. Output: $($unicodeWhitespaceAdd.Output.Trim())"
    } else {
        $unicodeWhitespaceResult = Invoke-Scanner `
            -ScanPath $unicodeWhitespaceDirectory
        if ($unicodeWhitespaceResult.ExitCode -eq 0 -or
            $unicodeWhitespaceResult.Output -notmatch 'exact Git worktree root') {
            Add-Failure "Expected a Unicode whitespace Git subdirectory scan to fail closed. Output: $($unicodeWhitespaceResult.Output.Trim())"
        }
    }

    if ((Test-PrivateMarkerWindowsHost) -and
        (Test-Path -LiteralPath $syntheticGitPath -PathType Leaf)) {
        # macOS の /var と /private/var のように、Git が同じ worktree root を
        # 別の物理 path 表記で返しても、文字列比較で subdirectory と誤判定しない。
        $rootAliasResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides @{
                PATH = $syntheticGitDirectory
                PRIVATE_MARKER_SYNTHETIC_GIT_MODE = 'root-alias'
                PRIVATE_MARKER_REAL_GIT = (Get-Command git -ErrorAction Stop).Source
                PRIVATE_MARKER_ROOT_ALIAS = (Join-Path $tempRoot 'reported root alias')
            }
        if ($rootAliasResult.ExitCode -ne 0 -or
            -not $rootAliasResult.StreamsCompleted -or
            -not $rootAliasResult.TreeStopped -or
            $rootAliasResult.TimedOut -or
            $rootAliasResult.OutputLimitExceeded -or
            $rootAliasResult.PipeLeakDetected) {
            Add-Failure "Expected a Git-reported physical root alias to remain accepted. Output: $($rootAliasResult.Output.Trim())"
        }

        # Prefix が Unicode 空白だけという不正応答も exact root とみなさない。
        # strict な LF / CRLF 比較を Trim / IsNullOrWhiteSpace へ弱める退行を検出する。
        $whitespacePrefixResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides @{
                PATH = $syntheticGitDirectory
                PRIVATE_MARKER_SYNTHETIC_GIT_MODE = 'whitespace-prefix'
                PRIVATE_MARKER_REAL_GIT = (Get-Command git -ErrorAction Stop).Source
            }
        if ($whitespacePrefixResult.ExitCode -eq 0 -or
            $whitespacePrefixResult.Output -notmatch 'exact Git worktree root') {
            Add-Failure "Expected a whitespace-only Git prefix to fail closed. Output: $($whitespacePrefixResult.Output.Trim())"
        }

        # UTF-8 decoder が BOM を除去しても、Git の raw prefix contract では
        # BOM + LF を root の LF と同一視しない。
        $bomPrefixResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides @{
                PATH = $syntheticGitDirectory
                PRIVATE_MARKER_SYNTHETIC_GIT_MODE = 'bom-prefix'
                PRIVATE_MARKER_REAL_GIT = (Get-Command git -ErrorAction Stop).Source
            }
        if ($bomPrefixResult.ExitCode -eq 0 -or
            $bomPrefixResult.Output -notmatch 'exact Git worktree root') {
            Add-Failure "Expected a BOM-prefixed Git prefix to fail closed. Output: $($bomPrefixResult.Output.Trim())"
        }

        # final raw stage listing の直前に、実 index へ replacement と addition を
        # 同時適用し、開始 snapshot との差分を fail-closed で検出する。
        $indexMutationRoot = Join-Path $tempRoot 'index mutation target'
        $indexMutationIsolationRoot = Join-Path `
            $tempRoot `
            'index-mutation-git-isolation'
        foreach ($directory in @(
            $indexMutationRoot,
            $indexMutationIsolationRoot
        )) {
            New-Item -ItemType Directory -Path $directory | Out-Null
        }
        $replacementRelative = 'race-replaced.env'
        $additionRelative = 'race-added.env'
        $replacementPath = Join-Path $indexMutationRoot $replacementRelative
        $additionPath = Join-Path $indexMutationRoot $additionRelative
        Set-Content `
            -LiteralPath $replacementPath `
            -Value 'synthetic baseline replacement' `
            -Encoding UTF8
        $mutationInit = Invoke-HermeticGit `
            -WorkingDirectory $indexMutationRoot `
            -Arguments @('init', '--quiet') `
            -IsolationRoot $indexMutationIsolationRoot
        $mutationBaselineAdd = Invoke-HermeticGit `
            -WorkingDirectory $indexMutationRoot `
            -Arguments @('add', '--', $replacementRelative) `
            -IsolationRoot $indexMutationIsolationRoot
        $oldReplacementOid = Invoke-HermeticGit `
            -WorkingDirectory $indexMutationRoot `
            -Arguments @('rev-parse', ":$replacementRelative") `
            -IsolationRoot $indexMutationIsolationRoot

        Set-Content `
            -LiteralPath $replacementPath `
            -Value 'synthetic changed replacement' `
            -Encoding UTF8
        Set-Content `
            -LiteralPath $additionPath `
            -Value 'synthetic added during scan' `
            -Encoding UTF8
        $expectedReplacementOid = Invoke-HermeticGit `
            -WorkingDirectory $indexMutationRoot `
            -Arguments @('hash-object', '--', $replacementRelative) `
            -IsolationRoot $indexMutationIsolationRoot

        if (@(
            $mutationInit,
            $mutationBaselineAdd,
            $oldReplacementOid,
            $expectedReplacementOid
        ) | Where-Object {
            $_.ExitCode -ne 0 -or
            -not $_.StreamsCompleted -or
            -not $_.TreeStopped
        }) {
            Add-Failure 'Expected index-mutation fixture setup to succeed.'
        } else {
            $indexMutationCounter = Join-Path $tempRoot 'index-mutation-counter.txt'
            $indexMutationSentinel = Join-Path $tempRoot 'index-mutation-complete.txt'
            $realGitPath = (Get-Command git -ErrorAction Stop).Source
            $indexMutationResult = Invoke-Scanner `
                -ScanPath $indexMutationRoot `
                -EnvironmentOverrides @{
                    PATH = $syntheticGitDirectory
                    PRIVATE_MARKER_SYNTHETIC_GIT_MODE = 'index-mutation'
                    PRIVATE_MARKER_REAL_GIT = $realGitPath
                    PRIVATE_MARKER_INDEX_COUNTER = $indexMutationCounter
                    PRIVATE_MARKER_INDEX_REPO = $indexMutationRoot
                    PRIVATE_MARKER_INDEX_REPLACEMENT = $replacementRelative
                    PRIVATE_MARKER_INDEX_ADDITION = $additionRelative
                    PRIVATE_MARKER_INDEX_MUTATION_SENTINEL = $indexMutationSentinel
                }
            if ($indexMutationResult.ExitCode -eq 0 -or
                -not $indexMutationResult.StreamsCompleted -or
                -not $indexMutationResult.TreeStopped -or
                $indexMutationResult.TimedOut -or
                $indexMutationResult.OutputLimitExceeded -or
                $indexMutationResult.PipeLeakDetected -or
                -not $indexMutationResult.Output.Contains(
                    'Git index changed during the private marker scan.'
                )) {
                Add-Failure "Expected raw index drift to fail through a healthy boundary. Output: $($indexMutationResult.Output.Trim())"
            }
            if (-not (Test-Path -LiteralPath $indexMutationCounter) -or
                (Get-Content -LiteralPath $indexMutationCounter -Raw).Trim() -cne '2') {
                Add-Failure 'Expected exactly two raw stage listings in the index-mutation fixture.'
            }
            if (-not (Test-Path -LiteralPath $indexMutationSentinel)) {
                Add-Failure 'Expected the real staged mutation to complete before final index verification.'
            }

            $addedIndexEntry = Invoke-HermeticGit `
                -WorkingDirectory $indexMutationRoot `
                -Arguments @(
                    'ls-files',
                    '--error-unmatch',
                    '--',
                    $additionRelative
                ) `
                -IsolationRoot $indexMutationIsolationRoot
            $newReplacementOid = Invoke-HermeticGit `
                -WorkingDirectory $indexMutationRoot `
                -Arguments @('rev-parse', ":$replacementRelative") `
                -IsolationRoot $indexMutationIsolationRoot
            if ($addedIndexEntry.ExitCode -ne 0) {
                Add-Failure 'Expected the mutation proxy to add a real index entry.'
            }
            if ($newReplacementOid.ExitCode -ne 0 -or
                $newReplacementOid.Output.Trim() -ceq $oldReplacementOid.Output.Trim() -or
                $newReplacementOid.Output.Trim() -cne $expectedReplacementOid.Output.Trim()) {
                Add-Failure 'Expected the mutation proxy to replace the staged blob with the changed worktree blob.'
            }
        }

        # mode/OID/pathが同一のまま CE_INTENT_TO_ADD flagだけ変わる race も、
        # final raw debug snapshot の byte比較で検出する。
        $flagsMutationRoot = Join-Path $tempRoot 'flags mutation target'
        $flagsMutationIsolationRoot =
            Join-Path $tempRoot 'flags-mutation-git-isolation'
        New-Item -ItemType Directory -Path $flagsMutationRoot | Out-Null
        New-Item `
            -ItemType Directory `
            -Path $flagsMutationIsolationRoot |
            Out-Null
        $flagsRelative = 'flags-only-empty.md'
        $flagsPath = Join-Path $flagsMutationRoot $flagsRelative
        [System.IO.File]::WriteAllBytes($flagsPath, [byte[]]@())
        $flagsInit = Invoke-HermeticGit `
            -WorkingDirectory $flagsMutationRoot `
            -Arguments @('init', '--quiet') `
            -IsolationRoot $flagsMutationIsolationRoot
        $flagsAdd = Invoke-HermeticGit `
            -WorkingDirectory $flagsMutationRoot `
            -Arguments @('add', '--', $flagsRelative) `
            -IsolationRoot $flagsMutationIsolationRoot
        $flagsStageArguments = @(
            '-c',
            'core.quotepath=false',
            'ls-files',
            '-z',
            '--stage',
            '--',
            $flagsRelative
        )
        $flagsDebugArguments = @(
            '-c',
            'core.quotepath=false',
            'ls-files',
            '-z',
            '--stage',
            '--debug',
            '--',
            $flagsRelative
        )
        $flagsStageBefore = Invoke-HermeticGit `
            -WorkingDirectory $flagsMutationRoot `
            -Arguments $flagsStageArguments `
            -IsolationRoot $flagsMutationIsolationRoot
        $flagsDebugBefore = Invoke-HermeticGit `
            -WorkingDirectory $flagsMutationRoot `
            -Arguments $flagsDebugArguments `
            -IsolationRoot $flagsMutationIsolationRoot
        if (@(
            $flagsInit,
            $flagsAdd,
            $flagsStageBefore,
            $flagsDebugBefore
        ) | Where-Object {
            $_.ExitCode -ne 0 -or
            -not $_.StreamsCompleted -or
            -not $_.TreeStopped
        }) {
            Add-Failure 'Expected flags-only mutation fixture setup to succeed.'
        } else {
            $flagsMutationCounter =
                Join-Path $tempRoot 'flags-mutation-counter.txt'
            $flagsMutationSentinel =
                Join-Path $tempRoot 'flags-mutation-complete.txt'
            $realGitPath = (Get-Command git -ErrorAction Stop).Source
            $flagsMutationResult = Invoke-Scanner `
                -ScanPath $flagsMutationRoot `
                -EnvironmentOverrides @{
                    PATH = $syntheticGitDirectory
                    PRIVATE_MARKER_SYNTHETIC_GIT_MODE = 'flags-mutation'
                    PRIVATE_MARKER_REAL_GIT = $realGitPath
                    PRIVATE_MARKER_INDEX_COUNTER = $flagsMutationCounter
                    PRIVATE_MARKER_INDEX_REPO = $flagsMutationRoot
                    PRIVATE_MARKER_INDEX_REPLACEMENT = $flagsRelative
                    PRIVATE_MARKER_INDEX_MUTATION_SENTINEL =
                        $flagsMutationSentinel
                }
            if ($flagsMutationResult.ExitCode -eq 0 -or
                -not $flagsMutationResult.StreamsCompleted -or
                -not $flagsMutationResult.TreeStopped -or
                $flagsMutationResult.TimedOut -or
                $flagsMutationResult.OutputLimitExceeded -or
                $flagsMutationResult.PipeLeakDetected -or
                -not $flagsMutationResult.Output.Contains(
                    'Git index metadata changed during the private marker scan.'
                )) {
                Add-Failure "Expected flags-only index drift to fail through a healthy boundary. Output: $($flagsMutationResult.Output.Trim())"
            }
            if (-not (Test-Path -LiteralPath $flagsMutationCounter) -or
                (Get-Content -LiteralPath $flagsMutationCounter -Raw).Trim() -cne
                    '2') {
                Add-Failure 'Expected exactly two raw debug listings in the flags-only mutation fixture.'
            }
            if (-not (Test-Path -LiteralPath $flagsMutationSentinel)) {
                Add-Failure 'Expected the real flags-only mutation to complete before final metadata verification.'
            }

            $flagsStageAfter = Invoke-HermeticGit `
                -WorkingDirectory $flagsMutationRoot `
                -Arguments $flagsStageArguments `
                -IsolationRoot $flagsMutationIsolationRoot
            $flagsDebugAfter = Invoke-HermeticGit `
                -WorkingDirectory $flagsMutationRoot `
                -Arguments $flagsDebugArguments `
                -IsolationRoot $flagsMutationIsolationRoot
            if ($flagsStageAfter.ExitCode -ne 0 -or
                $flagsStageAfter.Output -cne $flagsStageBefore.Output) {
                Add-Failure 'Expected flags-only mutation to preserve exact stage listing bytes.'
            }
            if ($flagsDebugAfter.ExitCode -ne 0 -or
                $flagsDebugAfter.Output -ceq $flagsDebugBefore.Output -or
                $flagsDebugAfter.Output -notmatch 'flags: 2000[0-9a-fA-F]{4}') {
                Add-Failure 'Expected flags-only mutation to change only the raw debug metadata snapshot.'
            }
        }
    }

    $trackedMarker = ('g' + 'hp_') + 'synthetic_tracked_placeholder'
    $untrackedMarker = ('xo' + 'xb-') + 'synthetic_untracked_placeholder'
    $trackedDirectory = Join-Path $trackedRoot 'nested'
    New-Item -ItemType Directory -Path $trackedDirectory | Out-Null
    $trackedLeakPath = Join-Path $trackedDirectory 'leak.md'
    Set-Content -LiteralPath $trackedLeakPath -Value "synthetic marker: $trackedMarker" -Encoding UTF8
    $trackedMarkerBytes = [System.IO.File]::ReadAllBytes($trackedLeakPath)
    Set-Content -LiteralPath (Join-Path $trackedRoot 'untracked.md') -Value "synthetic marker: $untrackedMarker" -Encoding UTF8
    $targetAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', 'nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($targetAdd.ExitCode -ne 0 -or $targetAdd.TimedOut -or -not $targetAdd.TreeStopped) {
        Add-Failure "Expected bounded target git add to succeed. Output: $($targetAdd.Output.Trim())"
    }
    # index にだけ marker を残し、clean な worktree で上書きして staged blob 検査を証明する。
    Set-Content `
        -LiteralPath (Join-Path $trackedDirectory 'leak.md') `
        -Value 'synthetic clean worktree content' `
        -Encoding UTF8

    $decoyInit = Invoke-HermeticGit `
        -WorkingDirectory $decoyRoot `
        -Arguments @('init', '--quiet') `
        -IsolationRoot $fixtureIsolationRoot
    if ($decoyInit.ExitCode -ne 0 -or $decoyInit.TimedOut -or -not $decoyInit.TreeStopped) {
        Add-Failure "Expected bounded decoy git init to succeed. Output: $($decoyInit.Output.Trim())"
    }

    $ambientHooks = Join-Path $ambientRoot 'hooks'
    $ambientTemplate = Join-Path $ambientRoot 'template'
    $ambientObjects = Join-Path $decoyRoot (Join-Path '.git' 'objects')
    foreach ($directory in @($ambientHooks, $ambientTemplate)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    $traceSentinel = Join-Path $ambientRoot 'git-trace.log'
    $trace2Sentinel = Join-Path $ambientRoot 'git-trace2.json'
    $hookSentinel = Join-Path $ambientRoot 'hook-fired.txt'
    $filterSentinel = Join-Path $ambientRoot 'filter-fired.txt'
    $ambientAttributes = Join-Path $ambientRoot 'attributes'
    $ambientExcludes = Join-Path $ambientRoot 'excludes'
    $ambientConfig = Join-Path $ambientRoot 'hostile.gitconfig'
    [System.IO.File]::WriteAllText($ambientAttributes, "*.md filter=synthetic`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($ambientExcludes, "nested/leak.md`n", [System.Text.UTF8Encoding]::new($false))
    $hookScript = @"
#!/bin/sh
printf '%s\n' 'hook-fired' > '$($hookSentinel.Replace([string][char]92, '/'))'
"@
    [System.IO.File]::WriteAllText(
        (Join-Path $ambientHooks 'post-index-change'),
        $hookScript,
        [System.Text.UTF8Encoding]::new($false)
    )
    $hostileConfigContent = @"
[core]
    hooksPath = $($ambientHooks.Replace([string][char]92, '/'))
    attributesFile = $($ambientAttributes.Replace([string][char]92, '/'))
    excludesFile = $($ambientExcludes.Replace([string][char]92, '/'))
[init]
    templateDir = $($ambientTemplate.Replace([string][char]92, '/'))
[filter "synthetic"]
    clean = sh -c "printf filter-fired > '$($filterSentinel.Replace([string][char]92, '/'))'; cat"
    required = true
"@
    [System.IO.File]::WriteAllText($ambientConfig, $hostileConfigContent, [System.Text.UTF8Encoding]::new($false))

    $decoyGitDirectory = Join-Path $decoyRoot '.git'
    $decoyIndex = Join-Path $decoyGitDirectory 'index'
    $adversarialEnvironment = @{
        GIT_DIR = $decoyGitDirectory
        GIT_WORK_TREE = $decoyRoot
        GIT_INDEX_FILE = $decoyIndex
        GIT_OBJECT_DIRECTORY = $ambientObjects
        GIT_ALTERNATE_OBJECT_DIRECTORIES = $ambientObjects
        GIT_CONFIG_GLOBAL = $ambientConfig
        GIT_CONFIG_SYSTEM = $ambientConfig
        GIT_CONFIG_NOSYSTEM = '0'
        GIT_CONFIG_COUNT = '2'
        GIT_CONFIG_KEY_0 = 'core.worktree'
        GIT_CONFIG_VALUE_0 = $decoyRoot
        GIT_CONFIG_KEY_1 = 'core.hooksPath'
        GIT_CONFIG_VALUE_1 = $ambientHooks
        GIT_TRACE = $traceSentinel
        GIT_TRACE2_EVENT = $trace2Sentinel
        GIT_TERMINAL_PROMPT = '1'
        GIT_NO_LAZY_FETCH = '0'
        GIT_NO_REPLACE_OBJECTS = '0'
        GIT_HYGIENE_PRESENT_EMPTY = ''
        HOME = $ambientRoot
        USERPROFILE = $ambientRoot
        XDG_CONFIG_HOME = $ambientRoot
    }

    $repositoryWithoutGitResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides @{ PATH = $emptyCommandPath }
    if ($repositoryWithoutGitResult.ExitCode -eq 0 -or
        $repositoryWithoutGitResult.Output -notmatch 'Git executable is unavailable') {
        Add-Failure "Expected a real .git marker to block no-Git fallback. Output: $($repositoryWithoutGitResult.Output.Trim())"
    }

    $beforeAdversarialScan = Get-ProcessEnvironmentSnapshot
    $adversarialFailure = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    Assert-ProcessEnvironmentUnchanged `
        -Expected $beforeAdversarialScan `
        -Context 'Adversarial failing scanner child'
    if (-not $adversarialEnvironment.ContainsKey('GIT_HYGIENE_PRESENT_EMPTY') -or
        $adversarialEnvironment['GIT_HYGIENE_PRESENT_EMPTY'] -cne '') {
        Add-Failure 'Expected the controlled present-empty Git variable to remain present-empty.'
    }
    if ($adversarialFailure.TimedOut -or -not $adversarialFailure.TreeStopped) {
        Add-Failure "Expected adversarial failing scanner child to finish within bounds. Output: $($adversarialFailure.Output.Trim())"
    }
    if ($adversarialFailure.ExitCode -eq 0) {
        Add-Failure 'Expected hostile Git variables not to empty or redirect the tracked-file scan.'
    }
    if ($adversarialFailure.Output -notmatch 'git-tracked') {
        Add-Failure "Expected adversarial fixture to retain git-tracked mode. Output: $($adversarialFailure.Output.Trim())"
    }
    if ($adversarialFailure.Output -notmatch 'nested/leak\.md') {
        Add-Failure "Expected adversarial fixture to report the target repository marker. Output: $($adversarialFailure.Output.Trim())"
    }
    if ($adversarialFailure.Output -notmatch '\bindex\b') {
        Add-Failure "Expected staged-only marker output to identify the index source. Output: $($adversarialFailure.Output.Trim())"
    }
    if ($adversarialFailure.Output -match 'untracked\.md') {
        Add-Failure 'Expected git-tracked mode not to scan an untracked marker.'
    }
    if ($adversarialFailure.Output.Contains($trackedMarker) -or
        $adversarialFailure.Output.Contains($untrackedMarker)) {
        Add-Failure 'Expected adversarial findings to stay redacted.'
    }

    # refs/replace が staged blob を clean blob へ差し替えても、index の実体を検査する。
    $markerOidResult = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('rev-parse', ':nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    $cleanOidResult = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('hash-object', '-w', '--', 'nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    $markerOid = $markerOidResult.Output.Trim()
    $cleanOid = $cleanOidResult.Output.Trim()
    if ($markerOidResult.ExitCode -ne 0 -or
        $cleanOidResult.ExitCode -ne 0 -or
        $markerOid -notmatch '^[0-9a-f]{40,64}$' -or
        $cleanOid -notmatch '^[0-9a-f]{40,64}$') {
        Add-Failure 'Expected replace-ref fixture object setup to succeed.'
    } else {
        $replaceAdd = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('replace', $markerOid, $cleanOid) `
            -IsolationRoot $fixtureIsolationRoot
        if ($replaceAdd.ExitCode -ne 0) {
            Add-Failure "Expected replace-ref fixture setup to succeed. Output: $($replaceAdd.Output.Trim())"
        } else {
            $replaceResult = Invoke-Scanner `
                -ScanPath $trackedRoot `
                -EnvironmentOverrides $adversarialEnvironment
            if ($replaceResult.ExitCode -eq 0 -or
                $replaceResult.Output -notmatch 'nested/leak\.md' -or
                $replaceResult.Output -notmatch '\bindex\b') {
                Add-Failure "Expected replace refs not to hide the staged marker. Output: $($replaceResult.Output.Trim())"
            }
            if ($replaceResult.Output.Contains($trackedMarker)) {
                Add-Failure 'Expected replace-ref finding to keep the staged marker redacted.'
            }
            $replaceDelete = Invoke-HermeticGit `
                -WorkingDirectory $trackedRoot `
                -Arguments @('replace', '-d', $markerOid) `
                -IsolationRoot $fixtureIsolationRoot
            if ($replaceDelete.ExitCode -ne 0) {
                Add-Failure "Expected replace-ref fixture cleanup to succeed. Output: $($replaceDelete.Output.Trim())"
            }
        }
    }

    # Partial clone の不足 blob は remote から補完せず、local-only 境界で即座に拒否する。
    if ($markerOid -match '^[0-9a-f]{40,64}$') {
        $promisorRemoteRoot = Join-Path $tempRoot 'promisor remote'
        $promisorRemoteDirectory = Join-Path $promisorRemoteRoot 'nested'
        New-Item -ItemType Directory -Path $promisorRemoteDirectory | Out-Null
        $promisorInit = Invoke-HermeticGit `
            -WorkingDirectory $promisorRemoteRoot `
            -Arguments @('init', '--quiet') `
            -IsolationRoot $fixtureIsolationRoot
        [System.IO.File]::WriteAllBytes(
            (Join-Path $promisorRemoteDirectory 'leak.md'),
            $trackedMarkerBytes
        )
        $promisorAdd = Invoke-HermeticGit `
            -WorkingDirectory $promisorRemoteRoot `
            -Arguments @('add', '--', 'nested/leak.md') `
            -IsolationRoot $fixtureIsolationRoot
        $fixtureEmail = 'synthetic' + '@example.invalid'
        $promisorCommit = Invoke-HermeticGit `
            -WorkingDirectory $promisorRemoteRoot `
            -Arguments @(
                '-c',
                'user.name=Synthetic Fixture',
                '-c',
                "user.email=$fixtureEmail",
                '-c',
                'commit.gpgSign=false',
                'commit',
                '--quiet',
                '-m',
                'synthetic promisor source'
            ) `
            -IsolationRoot $fixtureIsolationRoot
        $promisorOidResult = Invoke-HermeticGit `
            -WorkingDirectory $promisorRemoteRoot `
            -Arguments @('rev-parse', ':nested/leak.md') `
            -IsolationRoot $fixtureIsolationRoot
        if ($promisorInit.ExitCode -ne 0 -or
            $promisorAdd.ExitCode -ne 0 -or
            $promisorCommit.ExitCode -ne 0 -or
            $promisorOidResult.Output.Trim() -cne $markerOid) {
            Add-Failure 'Expected synthetic promisor remote setup to preserve the staged blob OID.'
        } else {
            $partialCloneConfigResults = @(
                Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', 'extensions.partialClone', 'origin') `
                    -IsolationRoot $fixtureIsolationRoot
                Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', 'remote.origin.promisor', 'true') `
                    -IsolationRoot $fixtureIsolationRoot
                Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', 'remote.origin.partialclonefilter', 'blob:none') `
                    -IsolationRoot $fixtureIsolationRoot
                Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', 'remote.origin.url', $promisorRemoteRoot) `
                    -IsolationRoot $fixtureIsolationRoot
            )
            if ($partialCloneConfigResults | Where-Object { $_.ExitCode -ne 0 }) {
                Add-Failure 'Expected synthetic partial-clone configuration to succeed.'
            } else {
                $objectRelativePath = Join-Path `
                    $markerOid.Substring(0, 2) `
                    $markerOid.Substring(2)
                $localMarkerObject = Join-Path `
                    (Join-Path (Join-Path $trackedRoot '.git') 'objects') `
                    $objectRelativePath
                if (-not [System.IO.File]::Exists($localMarkerObject)) {
                    Add-Failure 'Expected the staged marker fixture to use a removable loose object.'
                } else {
                    $localMarkerObjectBytes = [System.IO.File]::ReadAllBytes($localMarkerObject)
                    try {
                        # Git for Windows は loose object を read-only にする場合があるため、
                        # synthetic fixture の退避前だけ通常属性へ戻す。
                        [System.IO.File]::SetAttributes(
                            $localMarkerObject,
                            [System.IO.FileAttributes]::Normal
                        )
                        [System.IO.File]::Delete($localMarkerObject)
                        $partialCloneResult = Invoke-Scanner `
                            -ScanPath $trackedRoot `
                            -EnvironmentOverrides $adversarialEnvironment
                        if ($partialCloneResult.ExitCode -eq 0) {
                            Add-Failure 'Expected a missing promisor blob to fail closed without lazy fetch.'
                        }
                        if ($partialCloneResult.Output.Contains($trackedMarker)) {
                            Add-Failure 'Expected missing-promisor diagnostics not to expose marker content.'
                        }
                        $postScanMissingCheck = Invoke-HermeticGit `
                            -WorkingDirectory $trackedRoot `
                            -Arguments @('cat-file', '-e', "$markerOid`^{blob}") `
                            -IsolationRoot $fixtureIsolationRoot
                        if ($postScanMissingCheck.ExitCode -eq 0) {
                            Add-Failure 'Expected the scanner not to fetch the missing promisor blob.'
                        }
                    }
                    finally {
                        # 回帰で同一 OID が再取得済みなら上書きせず、未取得時だけ退避 bytes を戻す。
                        if (-not [System.IO.File]::Exists($localMarkerObject)) {
                            [System.IO.File]::WriteAllBytes(
                                $localMarkerObject,
                                $localMarkerObjectBytes
                            )
                        }
                    }
                }
            }
            foreach ($configKey in @(
                'extensions.partialClone',
                'remote.origin.promisor',
                'remote.origin.partialclonefilter',
                'remote.origin.url'
            )) {
                $configCleanup = Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('config', '--unset-all', $configKey) `
                    -IsolationRoot $fixtureIsolationRoot
                if ($configCleanup.ExitCode -ne 0) {
                    Add-Failure "Expected partial-clone fixture cleanup to remove $configKey."
                }
            }
        }
    }

    # 同じ敵対環境で成功経路も通し、失敗時だけの cleanup 漏れを見逃さない。
    Set-Content -LiteralPath (Join-Path $trackedDirectory 'leak.md') -Value 'synthetic clean tracked content' -Encoding UTF8
    $targetRestage = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', 'nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($targetRestage.ExitCode -ne 0 -or $targetRestage.TimedOut -or -not $targetRestage.TreeStopped) {
        Add-Failure "Expected bounded target git restage to succeed. Output: $($targetRestage.Output.Trim())"
    }

    $beforeAdversarialSuccess = Get-ProcessEnvironmentSnapshot
    $adversarialSuccess = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    Assert-ProcessEnvironmentUnchanged `
        -Expected $beforeAdversarialSuccess `
        -Context 'Adversarial successful scanner child'
    if ($adversarialSuccess.ExitCode -ne 0 -or
        $adversarialSuccess.TimedOut -or
        -not $adversarialSuccess.TreeStopped -or
        $adversarialSuccess.Output -notmatch 'git-tracked') {
        Add-Failure "Expected hostile Git variables not to break a clean tracked scan. Output: $($adversarialSuccess.Output.Trim())"
    }

    # Secretを含みやすい名前と拡張子を、index-only / worktree-only の
    # 両方向でまとめて固定する。各path/sourceを確認してmatrixの取りこぼしを防ぐ。
    $textCandidateCases = @(
        @{ Path = '.env';            Marker = ('g' + 'hp_') + 'synthetic_env_root' }
        @{ Path = '.env.local';      Marker = ('g' + 'hp_') + 'synthetic_env_variant' }
        @{ Path = 'production.env';  Marker = ('g' + 'hp_') + 'synthetic_env_suffix' }
        @{ Path = 'certificate.pem'; Marker = ('g' + 'hp_') + 'synthetic_pem' }
        @{ Path = 'private.key';     Marker = ('g' + 'hp_') + 'synthetic_key' }
        @{ Path = 'LICENSE';         Marker = ('g' + 'hp_') + 'synthetic_extensionless' }
        @{ Path = '.npmrc';          Marker = ('g' + 'hp_') + 'synthetic_dotfile' }
    )
    foreach ($case in $textCandidateCases) {
        Set-Content `
            -LiteralPath (Join-Path $trackedRoot $case.Path) `
            -Value "synthetic marker: $($case.Marker)" `
            -Encoding UTF8
    }
    $candidatePaths = @($textCandidateCases.Path)
    $candidateIndexAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments (@('add', '--') + $candidatePaths) `
        -IsolationRoot $fixtureIsolationRoot
    if ($candidateIndexAdd.ExitCode -ne 0) {
        Add-Failure "Expected text-candidate index fixture setup to succeed. Output: $($candidateIndexAdd.Output.Trim())"
    }
    foreach ($case in $textCandidateCases) {
        Set-Content `
            -LiteralPath (Join-Path $trackedRoot $case.Path) `
            -Value "synthetic clean worktree content: $($case.Path)" `
            -Encoding UTF8
    }
    $candidateIndexResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($candidateIndexResult.ExitCode -eq 0) {
        Add-Failure 'Expected index-only text-candidate markers to fail the scan.'
    }
    foreach ($case in $textCandidateCases) {
        $escapedPath = [regex]::Escape($case.Path)
        if ($candidateIndexResult.Output -notmatch "(?m)^\s*$escapedPath\s+index\s+") {
            Add-Failure "Expected index-only text candidate $($case.Path) to be reported from index. Output: $($candidateIndexResult.Output.Trim())"
        }
        if ($candidateIndexResult.Output.Contains($case.Marker)) {
            Add-Failure "Expected index-only text candidate $($case.Path) to stay redacted."
        }
    }

    $candidateCleanAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments (@('add', '--') + $candidatePaths) `
        -IsolationRoot $fixtureIsolationRoot
    if ($candidateCleanAdd.ExitCode -ne 0) {
        Add-Failure "Expected clean text-candidate baseline to be staged. Output: $($candidateCleanAdd.Output.Trim())"
    }
    foreach ($case in $textCandidateCases) {
        Set-Content `
            -LiteralPath (Join-Path $trackedRoot $case.Path) `
            -Value "synthetic marker: $($case.Marker)" `
            -Encoding UTF8
    }
    $candidateWorktreeResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($candidateWorktreeResult.ExitCode -eq 0) {
        Add-Failure 'Expected worktree-only text-candidate markers to fail the scan.'
    }
    foreach ($case in $textCandidateCases) {
        $escapedPath = [regex]::Escape($case.Path)
        if ($candidateWorktreeResult.Output -notmatch "(?m)^\s*$escapedPath\s+working-tree\s+") {
            Add-Failure "Expected worktree-only text candidate $($case.Path) to be reported from working-tree. Output: $($candidateWorktreeResult.Output.Trim())"
        }
        if ($candidateWorktreeResult.Output.Contains($case.Marker)) {
            Add-Failure "Expected worktree-only text candidate $($case.Path) to stay redacted."
        }
        Set-Content `
            -LiteralPath (Join-Path $trackedRoot $case.Path) `
            -Value "synthetic clean worktree content: $($case.Path)" `
            -Encoding UTF8
    }
    $candidateCleanup = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments (@('add', '--') + $candidatePaths) `
        -IsolationRoot $fixtureIsolationRoot
    if ($candidateCleanup.ExitCode -ne 0) {
        Add-Failure "Expected text-candidate fixture cleanup to succeed. Output: $($candidateCleanup.Output.Trim())"
    }

    $worktreeOnlyMarker = ('xo' + 'xb-') + 'synthetic_worktree_only'
    Set-Content `
        -LiteralPath (Join-Path $trackedDirectory 'leak.md') `
        -Value "synthetic marker: $worktreeOnlyMarker" `
        -Encoding UTF8
    $worktreeOnlyResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($worktreeOnlyResult.ExitCode -eq 0 -or
        $worktreeOnlyResult.Output -notmatch '\bworking-tree\b' -or
        $worktreeOnlyResult.Output -notmatch 'nested/leak\.md') {
        Add-Failure "Expected worktree-only marker to be scanned beside the clean index blob. Output: $($worktreeOnlyResult.Output.Trim())"
    }
    if ($worktreeOnlyResult.Output.Contains($worktreeOnlyMarker)) {
        Add-Failure 'Expected the worktree-only marker to stay redacted.'
    }
    Set-Content `
        -LiteralPath (Join-Path $trackedDirectory 'leak.md') `
        -Value 'synthetic clean tracked content' `
        -Encoding UTF8

    $subdirectoryResult = Invoke-Scanner `
        -ScanPath $trackedDirectory `
        -EnvironmentOverrides $adversarialEnvironment
    if ($subdirectoryResult.ExitCode -eq 0 -or
        $subdirectoryResult.Output -notmatch 'exact Git worktree root') {
        Add-Failure "Expected a Git subdirectory scan to fail closed instead of falling back. Output: $($subdirectoryResult.Output.Trim())"
    }

    # worktree から消えた tracked file も index blob から検査し、silent skip を防ぐ。
    $missingMarker = ('g' + 'hp_') + 'synthetic_missing_worktree'
    $missingPath = Join-Path $trackedRoot 'missing.md'
    Set-Content -LiteralPath $missingPath -Value "synthetic marker: $missingMarker" -Encoding UTF8
    $missingAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '--', 'missing.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($missingAdd.ExitCode -ne 0) {
        Add-Failure "Expected missing-worktree fixture add to succeed. Output: $($missingAdd.Output.Trim())"
    }
    [System.IO.File]::Delete($missingPath)
    $missingResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($missingResult.ExitCode -eq 0 -or
        $missingResult.Output -notmatch 'missing\.md' -or
        $missingResult.Output -notmatch '\bindex\b') {
        Add-Failure "Expected an index-only missing-worktree marker to fail the scan. Output: $($missingResult.Output.Trim())"
    }
    if ($missingResult.Output.Contains($missingMarker)) {
        Add-Failure 'Expected the missing-worktree index marker to stay redacted.'
    }
    $missingRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', 'missing.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($missingRemove.ExitCode -ne 0) {
        Add-Failure "Expected missing-worktree fixture cleanup to succeed. Output: $($missingRemove.Output.Trim())"
    }

    # local marker file は untracked 専用であり、index に現れた時点で内容を公開対象にしない。
    $trackedLocalMarkerPath = Join-Path $trackedRoot '.private-markers.local'
    $trackedLocalMarker = 'synthetic-tracked-local-marker'
    Set-Content `
        -LiteralPath $trackedLocalMarkerPath `
        -Value $trackedLocalMarker `
        -Encoding UTF8
    $trackedLocalAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '-f', '--', '.private-markers.local') `
        -IsolationRoot $fixtureIsolationRoot
    if ($trackedLocalAdd.ExitCode -ne 0) {
        Add-Failure "Expected tracked local-marker fixture setup to succeed. Output: $($trackedLocalAdd.Output.Trim())"
    } else {
        $trackedLocalResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($trackedLocalResult.ExitCode -eq 0 -or
            $trackedLocalResult.Output -notmatch 'must remain untracked') {
            Add-Failure "Expected a tracked .private-markers.local file to fail closed. Output: $($trackedLocalResult.Output.Trim())"
        }
        if ($trackedLocalResult.Output.Contains($trackedLocalMarker)) {
            Add-Failure 'Expected tracked local-marker diagnostics not to expose marker content.'
        }
    }
    $trackedLocalRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', '.private-markers.local') `
        -IsolationRoot $fixtureIsolationRoot
    if ($trackedLocalRemove.ExitCode -ne 0) {
        Add-Failure "Expected tracked local-marker fixture cleanup to succeed. Output: $($trackedLocalRemove.Output.Trim())"
    }
    [System.IO.File]::Delete($trackedLocalMarkerPath)

    # `ls-files --stage` では normal empty blob と同じOIDに見えるため、
    # CE_INTENT_TO_ADD flagを直接検査して present/missing worktree の双方を拒否する。
    $intentPath = Join-Path $trackedRoot 'intent.md'
    Set-Content -LiteralPath $intentPath -Value 'synthetic intent-to-add content' -Encoding UTF8
    $intentAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '-N', '--', 'intent.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($intentAdd.ExitCode -ne 0) {
        Add-Failure "Expected intent-to-add fixture setup to succeed. Output: $($intentAdd.Output.Trim())"
    }
    $intentResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($intentResult.ExitCode -eq 0 -or
        $intentResult.Output -notmatch 'intent-to-add') {
        Add-Failure "Expected present-worktree intent-to-add state to fail closed. Output: $($intentResult.Output.Trim())"
    }
    [System.IO.File]::Delete($intentPath)
    $missingIntentResult = Invoke-Scanner `
        -ScanPath $trackedRoot `
        -EnvironmentOverrides $adversarialEnvironment
    if ($missingIntentResult.ExitCode -eq 0 -or
        $missingIntentResult.Output -notmatch 'intent-to-add') {
        Add-Failure "Expected missing-worktree intent-to-add state to fail closed. Output: $($missingIntentResult.Output.Trim())"
    }
    $intentRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', 'intent.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($intentRemove.ExitCode -ne 0) {
        Add-Failure "Expected intent-to-add fixture cleanup to succeed. Output: $($intentRemove.Output.Trim())"
    }

    # CE_INTENT_TO_ADDを持たない通常の staged empty blob は正当なtextとして通す。
    $ordinaryEmptyRoot = Join-Path $tempRoot 'ordinary-empty-target'
    $ordinaryEmptyIsolationRoot =
        Join-Path $tempRoot 'ordinary-empty-git-isolation'
    New-Item -ItemType Directory -Path $ordinaryEmptyRoot | Out-Null
    New-Item -ItemType Directory -Path $ordinaryEmptyIsolationRoot | Out-Null
    $ordinaryEmptyRelative = 'ordinary-empty.md'
    $ordinaryEmptyPath = Join-Path $ordinaryEmptyRoot $ordinaryEmptyRelative
    [System.IO.File]::WriteAllBytes($ordinaryEmptyPath, [byte[]]@())
    $ordinaryEmptyInit = Invoke-HermeticGit `
        -WorkingDirectory $ordinaryEmptyRoot `
        -Arguments @('init', '--quiet') `
        -IsolationRoot $ordinaryEmptyIsolationRoot
    $ordinaryEmptyAdd = Invoke-HermeticGit `
        -WorkingDirectory $ordinaryEmptyRoot `
        -Arguments @('add', '--', $ordinaryEmptyRelative) `
        -IsolationRoot $ordinaryEmptyIsolationRoot
    if ($ordinaryEmptyInit.ExitCode -ne 0 -or
        $ordinaryEmptyAdd.ExitCode -ne 0) {
        Add-Failure "Expected ordinary empty-file fixture setup to succeed. Output: $($ordinaryEmptyAdd.Output.Trim())"
    } else {
        $ordinaryEmptyResult = Invoke-Scanner `
            -ScanPath $ordinaryEmptyRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($ordinaryEmptyResult.ExitCode -ne 0 -or
            $ordinaryEmptyResult.Output -match 'intent-to-add') {
            Add-Failure "Expected an ordinary staged empty blob to pass without intent-to-add classification. Output: $($ordinaryEmptyResult.Output.Trim())"
        }
    }

    # Index mode 120000 / 160000 は外部参照や別 repository へ進まず拒否する。
    $hashResult = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('hash-object', '-w', '--', 'nested/leak.md') `
        -IsolationRoot $fixtureIsolationRoot
    $fixtureOid = $hashResult.Output.Trim()
    if ($hashResult.ExitCode -ne 0 -or $fixtureOid -notmatch '^[0-9a-f]{40,64}$') {
        Add-Failure "Expected fixture blob hashing to succeed. Output: $($hashResult.Output.Trim())"
    } else {
        foreach ($modeCase in @(
            @{ Mode = '120000'; Path = 'synthetic-link.md'; Label = 'symlink' },
            @{ Mode = '160000'; Path = 'synthetic-gitlink'; Label = 'gitlink' }
        )) {
            $modeAdd = Invoke-HermeticGit `
                -WorkingDirectory $trackedRoot `
                -Arguments @(
                    'update-index',
                    '--add',
                    '--cacheinfo',
                    "$($modeCase.Mode),$fixtureOid,$($modeCase.Path)"
                ) `
                -IsolationRoot $fixtureIsolationRoot
            if ($modeAdd.ExitCode -ne 0) {
                Add-Failure "Expected $($modeCase.Label) index fixture setup to succeed. Output: $($modeAdd.Output.Trim())"
                continue
            }
            $modeResult = Invoke-Scanner `
                -ScanPath $trackedRoot `
                -EnvironmentOverrides $adversarialEnvironment
            if ($modeResult.ExitCode -eq 0 -or
                $modeResult.Output -notmatch 'unsupported mode') {
                Add-Failure "Expected $($modeCase.Label) index mode to fail closed. Output: $($modeResult.Output.Trim())"
            }
            $modeRemove = Invoke-HermeticGit `
                -WorkingDirectory $trackedRoot `
                -Arguments @('update-index', '--force-remove', '--', $modeCase.Path) `
                -IsolationRoot $fixtureIsolationRoot
            if ($modeRemove.ExitCode -ne 0) {
                Add-Failure "Expected $($modeCase.Label) fixture cleanup to succeed. Output: $($modeRemove.Output.Trim())"
            }
        }
    }

    # Regular index entryをplatform linkへ差し替え、外部targetをfollowしないことを確認する。
    $directoryLinkItemType = if (Test-PrivateMarkerWindowsHost) {
        'Junction'
    } else {
        'SymbolicLink'
    }
    $reparsePath = Join-Path $trackedRoot 'reparse.md'
    $reparseTarget = Join-Path $tempRoot 'reparse-external-target'
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    Set-Content -LiteralPath (Join-Path $reparseTarget 'outside.md') -Value "synthetic marker: $trackedMarker" -Encoding UTF8
    Set-Content -LiteralPath $reparsePath -Value 'synthetic regular index content' -Encoding UTF8
    $reparseAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '--', 'reparse.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($reparseAdd.ExitCode -ne 0) {
        Add-Failure "Expected reparse fixture add to succeed. Output: $($reparseAdd.Output.Trim())"
    }
    [System.IO.File]::Delete($reparsePath)
    try {
        New-Item `
            -ItemType $directoryLinkItemType `
            -Path $reparsePath `
            -Target $reparseTarget |
            Out-Null
        $reparseResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($reparseResult.ExitCode -eq 0 -or
            $reparseResult.Output -notmatch 'not a regular local file') {
            Add-Failure "Expected a tracked reparse path to fail closed without following it. Output: $($reparseResult.Output.Trim())"
        }
    }
    finally {
        if (Test-Path -LiteralPath $reparsePath) {
            (Get-Item -LiteralPath $reparsePath -Force).Delete()
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $reparseTarget 'outside.md'))) {
        Add-Failure 'Expected reparse cleanup not to alter the external synthetic target.'
    }
    $reparseRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', 'reparse.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($reparseRemove.ExitCode -ne 0) {
        Add-Failure "Expected reparse fixture cleanup to succeed. Output: $($reparseRemove.Output.Trim())"
    }

    # leaf がregular fileでもparent platform linkなら外部directoryを辿るため拒否する。
    $parentReparseDirectory = Join-Path $trackedRoot 'parent-reparse'
    $parentReparsePath = Join-Path $parentReparseDirectory 'inside.md'
    $parentReparseTarget = Join-Path $tempRoot 'parent-reparse-external-target'
    New-Item -ItemType Directory -Path $parentReparseDirectory | Out-Null
    New-Item -ItemType Directory -Path $parentReparseTarget | Out-Null
    Set-Content `
        -LiteralPath $parentReparsePath `
        -Value 'synthetic regular parent-chain content' `
        -Encoding UTF8
    $parentReparseAdd = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('add', '--', 'parent-reparse/inside.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($parentReparseAdd.ExitCode -ne 0) {
        Add-Failure "Expected parent-reparse fixture add to succeed. Output: $($parentReparseAdd.Output.Trim())"
    }
    [System.IO.File]::Delete($parentReparsePath)
    [System.IO.Directory]::Delete($parentReparseDirectory)
    Set-Content `
        -LiteralPath (Join-Path $parentReparseTarget 'inside.md') `
        -Value 'synthetic external parent-chain content' `
        -Encoding UTF8
    try {
        New-Item `
            -ItemType $directoryLinkItemType `
            -Path $parentReparseDirectory `
            -Target $parentReparseTarget |
            Out-Null
        $parentReparseResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($parentReparseResult.ExitCode -eq 0 -or
            $parentReparseResult.Output -notmatch 'parent directory is a symlink or reparse point') {
            Add-Failure "Expected a tracked parent junction to fail closed without following it. Output: $($parentReparseResult.Output.Trim())"
        }
    }
    finally {
        if (Test-Path -LiteralPath $parentReparseDirectory) {
            (Get-Item -LiteralPath $parentReparseDirectory -Force).Delete()
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $parentReparseTarget 'inside.md'))) {
        Add-Failure 'Expected parent-junction cleanup not to alter the external synthetic target.'
    }
    $parentReparseRemove = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('update-index', '--force-remove', '--', 'parent-reparse/inside.md') `
        -IsolationRoot $fixtureIsolationRoot
    if ($parentReparseRemove.ExitCode -ne 0) {
        Add-Failure "Expected parent-reparse fixture cleanup to succeed. Output: $($parentReparseRemove.Output.Trim())"
    }

    # Corrupt index は working-tree fallback に降格せず、Git present のまま拒否する。
    $targetIndexPath = Join-Path (Join-Path $trackedRoot '.git') 'index'
    $targetIndexBackup = [System.IO.File]::ReadAllBytes($targetIndexPath)
    try {
        [System.IO.File]::WriteAllBytes($targetIndexPath, [byte[]](1, 2, 3, 4))
        $malformedIndexResult = Invoke-Scanner `
            -ScanPath $trackedRoot `
            -EnvironmentOverrides $adversarialEnvironment
        if ($malformedIndexResult.ExitCode -eq 0 -or
            $malformedIndexResult.Output -notmatch 'Git index enumeration') {
            Add-Failure "Expected a malformed index to fail closed. Output: $($malformedIndexResult.Output.Trim())"
        }
    }
    finally {
        [System.IO.File]::WriteAllBytes($targetIndexPath, $targetIndexBackup)
    }

    # 実在する add/add conflict を作り、stage 1/2/3 のどれも blob scanへ進めない。
    $baseBranchResult = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments @('branch', '--show-current') `
        -IsolationRoot $fixtureIsolationRoot
    $baseBranch = $baseBranchResult.Output.Trim()
    $syntheticEmail = 'synthetic' + '@example.invalid'
    $identityArguments = @(
        '-c',
        'user.name=Synthetic Fixture',
        '-c',
        "user.email=$syntheticEmail",
        '-c',
        'commit.gpgSign=false'
    )
    $baseCommit = Invoke-HermeticGit `
        -WorkingDirectory $trackedRoot `
        -Arguments ($identityArguments + @('commit', '--quiet', '-m', 'synthetic base')) `
        -IsolationRoot $fixtureIsolationRoot
    if ($baseBranchResult.ExitCode -ne 0 -or
        [string]::IsNullOrWhiteSpace($baseBranch) -or
        $baseCommit.ExitCode -ne 0) {
        Add-Failure "Expected conflict fixture base commit to succeed. Output: $($baseCommit.Output.Trim())"
    } else {
        $sideSwitch = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('switch', '-c', 'synthetic-conflict-side') `
            -IsolationRoot $fixtureIsolationRoot
        $conflictPath = Join-Path $trackedRoot 'conflict.md'
        Set-Content -LiteralPath $conflictPath -Value 'synthetic side content' -Encoding UTF8
        $sideAdd = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('add', '--', 'conflict.md') `
            -IsolationRoot $fixtureIsolationRoot
        $sideCommit = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments ($identityArguments + @('commit', '--quiet', '-m', 'synthetic side')) `
            -IsolationRoot $fixtureIsolationRoot
        $baseSwitch = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('switch', $baseBranch) `
            -IsolationRoot $fixtureIsolationRoot
        Set-Content -LiteralPath $conflictPath -Value 'synthetic base content' -Encoding UTF8
        $baseAdd = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments @('add', '--', 'conflict.md') `
            -IsolationRoot $fixtureIsolationRoot
        $mainCommit = Invoke-HermeticGit `
            -WorkingDirectory $trackedRoot `
            -Arguments ($identityArguments + @('commit', '--quiet', '-m', 'synthetic main')) `
            -IsolationRoot $fixtureIsolationRoot
        if (@(
            $sideSwitch,
            $sideAdd,
            $sideCommit,
            $baseSwitch,
            $baseAdd,
            $mainCommit
        ) | Where-Object { $_.ExitCode -ne 0 }) {
            Add-Failure 'Expected conflict fixture branch setup to succeed.'
        } else {
            $mergeResult = Invoke-HermeticGit `
                -WorkingDirectory $trackedRoot `
                -Arguments ($identityArguments + @(
                    'merge',
                    '--no-edit',
                    'synthetic-conflict-side'
                )) `
                -IsolationRoot $fixtureIsolationRoot
            if ($mergeResult.ExitCode -eq 0 -or
                -not $mergeResult.StreamsCompleted -or
                -not $mergeResult.TreeStopped -or
                $mergeResult.Output -notmatch 'CONFLICT') {
                Add-Failure "Expected synthetic merge to produce a bounded conflict. Output: $($mergeResult.Output.Trim())"
            } else {
                $conflictResult = Invoke-Scanner `
                    -ScanPath $trackedRoot `
                    -EnvironmentOverrides $adversarialEnvironment
                if ($conflictResult.ExitCode -eq 0 -or
                    $conflictResult.Output -notmatch 'unresolved conflict') {
                    Add-Failure "Expected unresolved index stages to fail closed. Output: $($conflictResult.Output.Trim())"
                }
            }
            if (Test-Path -LiteralPath (Join-Path (Join-Path $trackedRoot '.git') 'MERGE_HEAD')) {
                $mergeAbort = Invoke-HermeticGit `
                    -WorkingDirectory $trackedRoot `
                    -Arguments @('merge', '--abort') `
                    -IsolationRoot $fixtureIsolationRoot
                if ($mergeAbort.ExitCode -ne 0) {
                    Add-Failure "Expected conflict fixture cleanup to succeed. Output: $($mergeAbort.Output.Trim())"
                }
            }
        }
    }

    foreach ($sentinel in @($traceSentinel, $trace2Sentinel, $hookSentinel, $filterSentinel)) {
        if (Test-Path -LiteralPath $sentinel) {
            Add-Failure "Expected scanner Git children not to create ambient artifact: $(Split-Path -Leaf $sentinel)"
        }
    }

    # scanner が fixture 外の system temp に残す isolation root も差分で検出する。
    $remainingScannerIsolationRoots = @(
        Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) `
            -Directory `
            -Filter 'windows-utf8-text-hygiene-git-*' `
            -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name }
    )
    $newScannerIsolationRoots = @(
        Compare-Object `
            -ReferenceObject $preexistingScannerIsolationRoots `
            -DifferenceObject $remainingScannerIsolationRoots |
            Where-Object { $_.SideIndicator -eq '=>' } |
            ForEach-Object { "$($_.InputObject)" }
    )
    if ($newScannerIsolationRoots.Count -gt 0) {
        Add-Failure "Expected scanner isolation roots to be cleaned: $($newScannerIsolationRoots -join ', ')."
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'Private marker scan self-test failed:'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host 'Private marker scan self-test passed.'
exit 0
