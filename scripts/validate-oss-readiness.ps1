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
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

function Get-RepoFilePath {
    param([string]$RelativePath)
    return Join-Path $root $RelativePath
}

function Assert-FileExists {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Missing required file: $RelativePath"
    }
}

function Assert-FileContains {
    param(
        [string]$RelativePath,
        [string]$Pattern,
        [string]$Description
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath ($Description)"
        return
    }

    $content = Get-Content -LiteralPath $filePath -Raw
    if ($content -notmatch $Pattern) {
        Add-Failure "$RelativePath is missing: $Description"
    }
}

function Assert-FilePatternCount {
    param(
        [string]$RelativePath,
        [string]$Pattern,
        [int]$ExpectedCount,
        [string]$Description
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath ($Description)"
        return
    }

    $content = Get-Content -LiteralPath $filePath -Raw
    $actualCount = [regex]::Matches($content, $Pattern).Count
    if ($actualCount -ne $ExpectedCount) {
        Add-Failure (
            "$RelativePath must contain exactly $ExpectedCount $Description " +
            "(actual: $actualCount)."
        )
    }
}

function Assert-FileDoesNotContain {
    param(
        [string]$RelativePath,
        [string]$Pattern,
        [string]$Description
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath ($Description)"
        return
    }

    $content = Get-Content -LiteralPath $filePath -Raw
    if ($content -match $Pattern) {
        Add-Failure "$RelativePath still contains: $Description"
    }
}

function Test-WorkflowJobBlockExactContent {
    param(
        [string[]]$Lines,
        [string]$JobName,
        [string]$ExpectedBlock
    )

    # root key をcanonicalな4行だけに固定する。jobsを別表記で重複定義し、
    # YAMLの後勝ち解釈で検証対象jobを無効化する形もfail closedにする。
    $expectedTopLevelLines = @(
        'name: Validate',
        'on:',
        'permissions:',
        'jobs:'
    )
    $actualTopLevelLines = @()
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line) -or
            $line.TrimStart().StartsWith('#')) {
            continue
        }
        if (-not $line.StartsWith(' ')) {
            $actualTopLevelLines += $line
        }
    }
    if ($actualTopLevelLines.Count -ne $expectedTopLevelLines.Count) {
        return $false
    }
    for ($index = 0; $index -lt $expectedTopLevelLines.Count; $index++) {
        if ($actualTopLevelLines[$index] -cne $expectedTopLevelLines[$index]) {
            return $false
        }
    }

    # canonical jobs mapping と job heading を各1件に固定する。block文字列が
    # 別のtop-level mapping配下へ移されても、非実行jobを受理しない。
    $jobsIndexes = @()
    $heading = "  ${JobName}:"
    $startIndexes = @()
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -ceq 'jobs:') {
            $jobsIndexes += $index
        }
        if ($Lines[$index] -ceq $heading) {
            $startIndexes += $index
        }
    }
    if ($jobsIndexes.Count -ne 1 -or $startIndexes.Count -ne 1) {
        return $false
    }

    $jobsIndex = $jobsIndexes[0]
    $jobsEndIndex = $Lines.Count - 1
    for ($index = $jobsIndex + 1; $index -lt $Lines.Count; $index++) {
        $line = $Lines[$index]
        if ([string]::IsNullOrWhiteSpace($line) -or
            $line.StartsWith('#')) {
            continue
        }
        if (-not [char]::IsWhiteSpace($line[0])) {
            $jobsEndIndex = $index - 1
            break
        }
    }

    # jobs mapping直下のjob IDもcanonicalな3行だけに固定する。引用符、
    # colon前空白、explicit key等の同値な重複jobを後置して、完全一致した
    # validate-macosをYAMLの後勝ちで無効化する形を受理しない。
    $expectedJobHeadings = @(
        '  validate:',
        '  validate-ubuntu:',
        '  validate-macos:'
    )
    $actualJobHeadings = @()
    for ($index = $jobsIndex + 1; $index -le $jobsEndIndex; $index++) {
        $line = $Lines[$index]
        if ([string]::IsNullOrWhiteSpace($line) -or
            $line.TrimStart().StartsWith('#')) {
            continue
        }
        if (-not $line.StartsWith('  ')) {
            return $false
        }
        if (-not $line.StartsWith('   ')) {
            $actualJobHeadings += $line
        }
    }
    if ($actualJobHeadings.Count -ne $expectedJobHeadings.Count) {
        return $false
    }
    for ($index = 0; $index -lt $expectedJobHeadings.Count; $index++) {
        if ($actualJobHeadings[$index] -cne $expectedJobHeadings[$index]) {
            return $false
        }
    }

    $startIndex = $startIndexes[0]
    if ($startIndex -le $jobsIndex -or $startIndex -gt $jobsEndIndex) {
        return $false
    }

    # jobs mapping 内の次の同階層job直前までを閉じた契約として比較する。
    $endIndex = $jobsEndIndex
    for ($index = $startIndex + 1; $index -le $jobsEndIndex; $index++) {
        $line = $Lines[$index]
        if ($line.StartsWith('  ') -and
            -not $line.StartsWith('   ') -and
            $line.EndsWith(':')) {
            $endIndex = $index - 1
            break
        }
    }

    $trimCharacters = [char[]]@("`r", "`n")
    $actualBlock = (
        @($Lines[$startIndex..$endIndex]) -join "`n"
    ).TrimEnd($trimCharacters)
    $normalizedExpected = $ExpectedBlock.Replace(
        "`r`n",
        "`n"
    ).TrimEnd($trimCharacters)
    return $actualBlock -ceq $normalizedExpected
}

function Assert-WorkflowJobBlockExact {
    param(
        [string]$RelativePath,
        [string]$JobName,
        [string]$ExpectedBlock
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (exact workflow job '$JobName')"
        return
    }

    $lines = @(Get-Content -LiteralPath $filePath)
    if (-not (Test-WorkflowJobBlockExactContent `
            -Lines $lines `
            -JobName $JobName `
            -ExpectedBlock $ExpectedBlock)) {
        Add-Failure "Workflow job '$JobName' failed its exact block contract."
    }
}

function Assert-WorkflowJobBlockValidatorRegressions {
    param(
        [string]$RelativePath,
        [string]$JobName,
        [string]$ExpectedBlock
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return
    }

    $lines = @(Get-Content -LiteralPath $filePath)
    if (-not (Test-WorkflowJobBlockExactContent `
            -Lines $lines `
            -JobName $JobName `
            -ExpectedBlock $ExpectedBlock)) {
        return
    }

    $trimCharacters = [char[]]@("`r", "`n")
    $workflowText = ($lines -join "`n").TrimEnd($trimCharacters)
    $normalizedExpected = $ExpectedBlock.Replace(
        "`r`n",
        "`n"
    ).TrimEnd($trimCharacters)
    $targetOffset = $workflowText.IndexOf(
        $normalizedExpected,
        [System.StringComparison]::Ordinal
    )
    $jobsMarker = "jobs:`n"
    $jobsOffset = $workflowText.IndexOf(
        $jobsMarker,
        [System.StringComparison]::Ordinal
    )
    if ($targetOffset -lt 0 -or
        $targetOffset -ne $workflowText.LastIndexOf(
            $normalizedExpected,
            [System.StringComparison]::Ordinal
        ) -or
        $jobsOffset -lt 0) {
        Add-Failure 'Workflow job membership mutation fixture could not be constructed.'
        return
    }

    $withoutTarget = $workflowText.Remove(
        $targetOffset,
        $normalizedExpected.Length
    )
    $relocatedBlock = (
        "ignored-contract-fixture:`n" +
        $normalizedExpected +
        "`n  sibling-delimiter:`n`n"
    )
    $relocatedText = $withoutTarget.Insert($jobsOffset, $relocatedBlock)
    $relocatedLines = $relocatedText.Split(
        [string[]]@("`n"),
        [System.StringSplitOptions]::None
    )
    if (Test-WorkflowJobBlockExactContent `
            -Lines $relocatedLines `
            -JobName $JobName `
            -ExpectedBlock $ExpectedBlock) {
        Add-Failure 'Workflow job validator accepted a block outside top-level jobs.'
    }

    $renamedJobsText = $workflowText.Replace(
        $jobsMarker,
        "ignored-jobs:`n"
    )
    if ($renamedJobsText -ceq $workflowText) {
        Add-Failure 'Workflow jobs-heading mutation was ineffective.'
    } elseif (Test-WorkflowJobBlockExactContent `
            -Lines $renamedJobsText.Split(
                [string[]]@("`n"),
                [System.StringSplitOptions]::None
            ) `
            -JobName $JobName `
            -ExpectedBlock $ExpectedBlock) {
        Add-Failure 'Workflow job validator accepted a missing top-level jobs mapping.'
    }

    # YAMLで同じroot keyを表せる別構文を追加し、後勝ちで有効なjobs mappingを
    # 空にできる形をすべて拒否する。文字列比較だけのjobs件数確認へ戻さない。
    $alternateJobsDefinitions = @(
        'jobs: {}',
        'jobs : {}',
        '"jobs": {}',
        "'jobs': {}",
        "? jobs`n: {}"
    )
    foreach ($alternateJobsDefinition in $alternateJobsDefinitions) {
        $duplicateJobsText = (
            $workflowText +
            "`n" +
            $alternateJobsDefinition
        )
        if ($duplicateJobsText -ceq $workflowText) {
            Add-Failure 'Workflow duplicate-jobs mutation was ineffective.'
            continue
        }
        $duplicateJobsLines = $duplicateJobsText.Split(
            [string[]]@("`n"),
            [System.StringSplitOptions]::None
        )
        if (Test-WorkflowJobBlockExactContent `
                -Lines $duplicateJobsLines `
                -JobName $JobName `
                -ExpectedBlock $ExpectedBlock) {
            Add-Failure 'Workflow job validator accepted an alternate top-level jobs definition.'
        }
    }

    # 対象jobのcanonical block直後に同値な別表記を置く。次jobの境界として
    # 単に除外する実装ではなく、jobs直下の見出し集合自体が拒否する必要がある。
    $alternateTargetDefinitions = @(
        "  ${JobName}: { if: false, runs-on: ubuntu-latest }",
        "  ${JobName} : { if: false, runs-on: ubuntu-latest }",
        "  `"${JobName}`":`n    if: false`n    runs-on: ubuntu-latest",
        "  '${JobName}':`n    if: false`n    runs-on: ubuntu-latest",
        "  ? ${JobName}`n  :`n    if: false`n    runs-on: ubuntu-latest"
    )
    foreach ($alternateTargetDefinition in $alternateTargetDefinitions) {
        $duplicateTargetText = (
            $workflowText +
            "`n" +
            $alternateTargetDefinition
        )
        if ($duplicateTargetText -ceq $workflowText) {
            Add-Failure 'Workflow duplicate-target mutation was ineffective.'
            continue
        }
        $duplicateTargetLines = $duplicateTargetText.Split(
            [string[]]@("`n"),
            [System.StringSplitOptions]::None
        )
        if (Test-WorkflowJobBlockExactContent `
                -Lines $duplicateTargetLines `
                -JobName $JobName `
                -ExpectedBlock $ExpectedBlock) {
            Add-Failure 'Workflow job validator accepted an alternate duplicate target job.'
        }
    }
}

function Get-OrdinalFragmentCount {
    param(
        [string]$Content,
        [string]$Fragment
    )

    if ([string]::IsNullOrEmpty($Fragment)) {
        return 0
    }

    $count = 0
    $offset = 0
    while ($offset -lt $Content.Length) {
        $index = $Content.IndexOf(
            $Fragment,
            $offset,
            [System.StringComparison]::Ordinal
        )
        if ($index -lt 0) {
            break
        }
        $count++
        $offset = $index + $Fragment.Length
    }
    return $count
}

function Get-GuardedNormalizationExpectedEnumerationBlock {
    # 公開exampleとvalidatorが同じcopy-adaptable blockを正本として共有できるよう、
    # scalar化を防ぐ型宣言を含む最小の列挙phaseをexact textで固定する。
    return @'
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
'@
}

function Get-GuardedNormalizationCandidatePaths {
    param(
        [string]$RepoPath,
        [AllowEmptyString()]
        [string]$Raw
    )

    # NUL splitが0件・1件でも必ずstring arrayを作る。PowerShell pipelineは
    # 1件だけをscalarへ展開するため、@(...)を外すとindexがcharを返してしまう。
    [string[]]$entries = @(
        $Raw -split "`0" | Where-Object { $_ }
    )
    $files = @()
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $status = $entries[$index].Substring(0, 2)
        $path = $entries[$index].Substring(3)

        # porcelain -zのrenameは新path recordの直後に旧path tokenが続く。
        # 両方を正規化対象から外し、旧pathをstatus recordとして再解釈しない。
        if ($status -match 'R') {
            $index++
            continue
        }
        if ($status -match 'D') {
            continue
        }
        $files += Join-Path $RepoPath $path
    }

    return @(
        $files |
            Where-Object {
                $_ -match '\.(md|txt|yml|yaml|json|py|js|ts)$'
            }
    )
}

function Test-StringSequenceExact {
    param(
        [object[]]$Actual,
        [object[]]$Expected
    )

    $actualValues = @($Actual)
    $expectedValues = @($Expected)
    if ($actualValues.Count -ne $expectedValues.Count) {
        return $false
    }
    for ($index = 0; $index -lt $expectedValues.Count; $index++) {
        if (-not [string]::Equals(
                [string]$actualValues[$index],
                [string]$expectedValues[$index],
                [System.StringComparison]::Ordinal
            )) {
            return $false
        }
    }
    return $true
}

function Test-GuardedNormalizationPorcelainSemantics {
    param([scriptblock]$Parser)

    $syntheticRepo = 'synthetic-root'
    $japaneseName = '日本語 file.md'
    $spaceName = 'space name.txt'
    $keepName = 'keep.json'
    $fixtures = @(
        [pscustomobject]@{
            Name = 'zero records'
            Raw = ''
            Expected = @()
        },
        [pscustomobject]@{
            Name = 'one Japanese and space-bearing record'
            Raw = " M $japaneseName`0"
            Expected = @(
                Join-Path $syntheticRepo $japaneseName
            )
        },
        [pscustomobject]@{
            Name = 'multiple records'
            Raw = " M $japaneseName`0A  $spaceName`0"
            Expected = @(
                Join-Path $syntheticRepo $japaneseName
                Join-Path $syntheticRepo $spaceName
            )
        },
        [pscustomobject]@{
            Name = 'rename pair and deletion'
            Raw = "R  renamed.md`0old.md`0 D deleted.txt`0"
            Expected = @()
        },
        [pscustomobject]@{
            Name = 'kept record around skipped records'
            Raw = "R  renamed.md`0old.md`0 M $keepName`0 D deleted.txt`0"
            Expected = @(
                Join-Path $syntheticRepo $keepName
            )
        }
    )

    foreach ($fixture in $fixtures) {
        try {
            $actual = @(
                & $Parser $syntheticRepo ([string]$fixture.Raw)
            )
        }
        catch {
            return $false
        }
        if (-not (Test-StringSequenceExact `
                -Actual $actual `
                -Expected @($fixture.Expected))) {
            return $false
        }
    }
    return $true
}

function Test-GuardedNormalizationExampleContract {
    param([string]$Source)

    if ([string]::IsNullOrWhiteSpace($Source)) {
        return $false
    }
    $normalizedSource = $Source.Replace("`r`n", "`n")
    $sectionMarker = '## The pattern' + "`n"
    $sectionStart = $normalizedSource.IndexOf(
        $sectionMarker,
        [System.StringComparison]::Ordinal
    )
    if ($sectionStart -lt 0) {
        return $false
    }
    $sectionEnd = $normalizedSource.IndexOf(
        "`n## ",
        $sectionStart + $sectionMarker.Length,
        [System.StringComparison]::Ordinal
    )
    if ($sectionEnd -lt 0) {
        return $false
    }
    $section = $normalizedSource.Substring(
        $sectionStart,
        $sectionEnd - $sectionStart
    )

    # exact blockをThe pattern内の唯一のPowerShell fenceへ閉じ込める。
    # 別sectionへ正しいdecoyを置き、実行例だけ弱める形も拒否する。
    $fenceMarker = '```powershell' + "`n"
    if ((Get-OrdinalFragmentCount `
            -Content $section `
            -Fragment $fenceMarker) -ne 1) {
        return $false
    }
    $fenceStart = $section.IndexOf(
        $fenceMarker,
        [System.StringComparison]::Ordinal
    )
    $codeStart = $fenceStart + $fenceMarker.Length
    $fenceEnd = $section.IndexOf(
        "`n" + '```',
        $codeStart,
        [System.StringComparison]::Ordinal
    )
    if ($fenceStart -lt 0 -or $fenceEnd -lt 0) {
        return $false
    }
    $fencedCode = $section.Substring(
        $codeStart,
        $fenceEnd - $codeStart
    )
    $expectedBlock = Get-GuardedNormalizationExpectedEnumerationBlock
    if ((Get-OrdinalFragmentCount `
            -Content $normalizedSource `
            -Fragment $expectedBlock) -ne 1 -or
        (Get-OrdinalFragmentCount `
            -Content $fencedCode `
            -Fragment $expectedBlock) -ne 1 -or
        (Get-OrdinalFragmentCount `
            -Content $fencedCode `
            -Fragment '$raw = (git -C $repo status --porcelain=v1 -z)') -ne 1 -or
        (Get-OrdinalFragmentCount `
            -Content $fencedCode `
            -Fragment '$entries =') -ne 1) {
        return $false
    }
    return $true
}

function Assert-GuardedNormalizationExampleValidatorRegressions {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (guarded-normalization contract)"
        return
    }
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $source = [System.IO.File]::ReadAllText($filePath, $strictUtf8)
    }
    catch {
        Add-Failure "$RelativePath must be strict UTF-8."
        return
    }

    if (-not (Test-GuardedNormalizationExampleContract -Source $source)) {
        Add-Failure "$RelativePath must keep the exact array-safe porcelain enumeration block."
        return
    }

    # 意味fixtureはfilesystemへ触れず、synthetic NUL recordsだけで
    # cardinality・Unicode path・rename/delete skipを同時に固定する。
    $canonicalParser = {
        param($RepoPath, $Raw)
        Get-GuardedNormalizationCandidatePaths `
            -RepoPath $RepoPath `
            -Raw $Raw
    }
    if (-not (Test-GuardedNormalizationPorcelainSemantics `
            -Parser $canonicalParser)) {
        Add-Failure 'Guarded-normalization porcelain semantics rejected canonical synthetic fixtures.'
    }

    # fixture自体が空配列の常時返却やskip漏れを見逃す形へ退行していないことを
    # adversarial parserで検証する。
    $semanticMutations = @(
        [pscustomobject]@{
            Name = 'always-empty parser'
            Parser = {
                param($RepoPath, $Raw)
                return @()
            }
        },
        [pscustomobject]@{
            Name = 'rename/delete inclusion'
            Parser = {
                param($RepoPath, $Raw)
                $values = @(
                    Get-GuardedNormalizationCandidatePaths `
                        -RepoPath $RepoPath `
                        -Raw $Raw
                )
                if ($Raw.Contains('R  ')) {
                    $values += Join-Path $RepoPath 'renamed.md'
                }
                if ($Raw.Contains(' D ')) {
                    $values += Join-Path $RepoPath 'deleted.txt'
                }
                return $values
            }
        }
    )
    foreach ($mutation in $semanticMutations) {
        if (Test-GuardedNormalizationPorcelainSemantics `
                -Parser $mutation.Parser) {
            Add-Failure (
                'Guarded-normalization semantic fixtures accepted mutation: ' +
                $mutation.Name
            )
        }
    }

    # source validatorへarray/scoping/skipの代表mutationを通し、
    # correct-looking decoyや重複blockでも合格しないことを固定する。
    $expectedBlock = Get-GuardedNormalizationExpectedEnumerationBlock
    $sourceMutations = @(
        [pscustomobject]@{
            Name = 'scalar entries assignment'
            Source = $source.Replace(
                '[string[]]$entries = @(',
                '$entries = ('
            )
        },
        [pscustomobject]@{
            Name = 'rename old-path token not skipped'
            Source = $source.Replace(
                '    if ($status -match ''R'') { $i++; continue }',
                '    if ($status -match ''R'') { continue }'
            )
        },
        [pscustomobject]@{
            Name = 'deleted entry included'
            Source = $source.Replace(
                '    if ($status -match ''D'') { continue }',
                '    if ($status -match ''D'') { $files += Join-Path $repo $path; continue }'
            )
        },
        [pscustomobject]@{
            Name = 'correct block relocated as decoy'
            Source = $source.Replace($expectedBlock, '') +
                "`n" + $expectedBlock
        },
        [pscustomobject]@{
            Name = 'duplicate enumeration block'
            Source = $source.Replace(
                $expectedBlock,
                $expectedBlock + "`n" + $expectedBlock
            )
        }
    )
    foreach ($mutation in $sourceMutations) {
        if ($mutation.Source -ceq $source) {
            Add-Failure (
                'Guarded-normalization source mutation setup made no change: ' +
                $mutation.Name
            )
        } elseif (Test-GuardedNormalizationExampleContract `
                -Source $mutation.Source) {
            Add-Failure (
                'Guarded-normalization source validator accepted mutation: ' +
                $mutation.Name
            )
        }
    }
}

function Test-PosixContainmentEvidenceContract {
    param(
        [string]$ProcessSource,
        [string]$SelfTestSource
    )

    $processFragments = @(
        @{ Text = 'PosixSessionGate = $posixSessionGate'; Count = 1 },
        @{ Text = '$posixSessionGate = ''external-setsid'''; Count = 1 },
        @{ Text = '$posixSessionGate = ''native-setsid'''; Count = 1 },
        @{
            Text = '[DllImport("libc", SetLastError = true)]'
            Count = 2
        },
        @{
            Text = 'function ConvertTo-PrivateMarkerPosixGateFailureReason'
            Count = 1
        },
        @{
            Text = 'function Read-PrivateMarkerPosixGateStatus'
            Count = 1
        },
        @{
            Text = 'Join-Path $gateRoot "private-marker-posix-status-$gateId"'
            Count = 1
        },
        @{ Text = 'Write-NativeGateStatus ''compile'''; Count = 1 },
        @{ Text = 'Write-NativeGateStatus ''setsid-call'''; Count = 2 },
        @{ Text = 'Write-NativeGateStatus ''ready-prepare'''; Count = 1 },
        @{ Text = 'Write-NativeGateStatus ''ready-write'''; Count = 1 },
        @{ Text = '-Path $posixGateStatusPath'; Count = 1 },
        @{ Text = '-Status $posixGateStatus'; Count = 1 },
        @{ Text = '[PrivateMarker.NativePosixSession]::Create()'; Count = 1 },
        @{ Text = 'New-Object byte[] 65'; Count = 1 },
        @{ Text = '$statusLength -gt 64'; Count = 1 },
        @{ Text = 'New-Object System.Text.UTF8Encoding($false, $true)'; Count = 1 },
        @{ Text = '$TestOnlyPostExitDelayMilliseconds = 0'; Count = 1 },
        @{ Text = '$TestOnlyExpireDeadlineAfterInitialCheck'; Count = 3 },
        @{
            Text = 'if ($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) {'
            Count = 2
        },
        @{
            Text = '$clock.ElapsedMilliseconds -lt $TimeoutMilliseconds'
            Count = 3
        }
    )
    foreach ($fragment in $processFragments) {
        if ((Get-OrdinalFragmentCount `
                -Content $ProcessSource `
                -Fragment $fragment.Text) -ne $fragment.Count) {
            return $false
        }
    }

    $clockStartOffset = $ProcessSource.IndexOf(
        '$clock = [System.Diagnostics.Stopwatch]::StartNew()',
        [System.StringComparison]::Ordinal
    )
    $windowsLaunchOffset = $ProcessSource.IndexOf(
        '$containedProcess = [PrivateMarker.ContainedProcess]::Start(',
        [System.StringComparison]::Ordinal
    )
    $posixLaunchOffset = $ProcessSource.IndexOf(
        '$processStarted = $process.Start()',
        [System.StringComparison]::Ordinal
    )
    $firstElapsedDeadlineOffset = $ProcessSource.IndexOf(
        'if ($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) {',
        [System.StringComparison]::Ordinal
    )
    $finalElapsedDeadlineOffset = $ProcessSource.LastIndexOf(
        'if ($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) {',
        [System.StringComparison]::Ordinal
    )
    $treeStopOffset = $ProcessSource.IndexOf(
        '$needsTreeStop = $timedOut -or',
        [System.StringComparison]::Ordinal
    )
    $streamsCompletedOffset = $ProcessSource.IndexOf(
        '$streamsCompleted = $null -ne $stdoutTask',
        [System.StringComparison]::Ordinal
    )
    if ($clockStartOffset -lt 0 -or
        $windowsLaunchOffset -lt 0 -or
        $posixLaunchOffset -lt 0 -or
        $firstElapsedDeadlineOffset -lt 0 -or
        $finalElapsedDeadlineOffset -le $firstElapsedDeadlineOffset -or
        $treeStopOffset -lt 0 -or
        $streamsCompletedOffset -lt 0 -or
        $clockStartOffset -ge $windowsLaunchOffset -or
        $clockStartOffset -ge $posixLaunchOffset -or
        $firstElapsedDeadlineOffset -ge $treeStopOffset -or
        $finalElapsedDeadlineOffset -ge $streamsCompletedOffset) {
        return $false
    }

    if ($ProcessSource -match '(?im)^\s*\$IsMacOS\s*=') {
        return $false
    }

    $selfTestFragments = @(
        @{
            Text = '$posixPipeResult.PosixSessionGate -cne $expectedGate'
            Count = 1
        },
        @{ Text = '$posixPipeResult.ExitCode -ne 0'; Count = 1 },
        @{ Text = 'ExpectedGate = $automaticGate'; Count = 1 },
        @{ Text = 'ExpectedGate = ''native-setsid'''; Count = 1 },
        @{
            Text = 'if ($failures.Count -eq $posixFailureCountBefore) {'
            Count = 1
        },
        @{ Text = '$posixGateFailureReasonCases = @('; Count = 1 },
        @{ Text = 'synthetic-sensitive-content'; Count = 1 },
        @{
            Text = 'post-exit setup deadline to reject an already exited zero-code child'
            Count = 1
        },
        @{
            Text = 'post-stream cleanup deadline to reject a zero-code child'
            Count = 1
        },
        @{
            Text = 'read-only IsMacOS automatic variable'
            Count = 1
        },
        @{
            Text = 'POSIX containment evidence: automatic=$automaticGate; forced=native-setsid; target-exit=0; descendant-started=true; descendant-stopped=true.'
            Count = 1
        }
    )
    foreach ($fragment in $selfTestFragments) {
        if ((Get-OrdinalFragmentCount `
                -Content $SelfTestSource `
                -Fragment $fragment.Text) -ne $fragment.Count) {
            return $false
        }
    }
    return $true
}

function Assert-PosixContainmentEvidenceValidatorRegressions {
    param(
        [string]$ProcessRelativePath,
        [string]$SelfTestRelativePath
    )

    $processPath = Get-RepoFilePath -RelativePath $ProcessRelativePath
    $selfTestPath = Get-RepoFilePath -RelativePath $SelfTestRelativePath
    if (-not (Test-Path -LiteralPath $processPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $selfTestPath -PathType Leaf)) {
        Add-Failure 'Cannot inspect missing POSIX containment contract source.'
        return
    }

    $processSource = Get-Content -LiteralPath $processPath -Raw
    $selfTestSource = Get-Content -LiteralPath $selfTestPath -Raw
    if (-not (Test-PosixContainmentEvidenceContract `
            -ProcessSource $processSource `
            -SelfTestSource $selfTestSource)) {
        Add-Failure 'POSIX containment gate provenance, exit evidence, diagnostic, or native resolver contract is incomplete.'
        return
    }

    $mutations = @(
        [pscustomobject]@{
            Name = 'returned gate provenance'
            ProcessSource = $processSource.Replace(
                'PosixSessionGate = $posixSessionGate',
                'GateEvidenceRemoved = $posixSessionGate'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'external gate provenance'
            ProcessSource = $processSource.Replace(
                '$posixSessionGate = ''external-setsid''',
                '$posixSessionGate = ''unknown-external-gate'''
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'native gate provenance'
            ProcessSource = $processSource.Replace(
                '$posixSessionGate = ''native-setsid''',
                '$posixSessionGate = ''unknown-native-gate'''
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'Linux native library'
            ProcessSource = $processSource.Replace(
                '"libc"',
                '"missing-linux-native-library"'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'automatic variable collision'
            ProcessSource = $processSource + (
                [Environment]::NewLine + '$IsMacOS = $true'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'fixed gate diagnostic mapper'
            ProcessSource = $processSource.Replace(
                'function ConvertTo-PrivateMarkerPosixGateFailureReason',
                'function ConvertTo-RemovedPosixGateFailureReason'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'bounded gate diagnostic reader'
            ProcessSource = $processSource.Replace(
                'function Read-PrivateMarkerPosixGateStatus',
                'function Read-RemovedPosixGateStatus'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'gate diagnostic status channel'
            ProcessSource = $processSource.Replace(
                'Join-Path $gateRoot "private-marker-posix-status-$gateId"',
                'Join-Path $gateRoot "removed-posix-status-$gateId"'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'compile stage diagnostic'
            ProcessSource = $processSource.Replace(
                'Write-NativeGateStatus ''compile''',
                'Write-NativeGateStatus ''removed-compile-stage'''
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'parent gate diagnostic read'
            ProcessSource = $processSource.Replace(
                '-Path $posixGateStatusPath',
                '-Path $null'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'shared handshake deadline'
            ProcessSource = $processSource.Replace(
                '$clock.ElapsedMilliseconds -lt $TimeoutMilliseconds',
                '$true'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'elapsed-only success deadlines'
            ProcessSource = $processSource.Replace(
                'if ($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) {',
                'if ($false) {'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'post-exit deadline regression seam'
            ProcessSource = $processSource.Replace(
                '$TestOnlyPostExitDelayMilliseconds = 0',
                '$RemovedPostExitDelayMilliseconds = 0'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'observed gate assertion'
            ProcessSource = $processSource
            SelfTestSource = $selfTestSource.Replace(
                '$posixPipeResult.PosixSessionGate -cne $expectedGate',
                '$false'
            )
        },
        [pscustomobject]@{
            Name = 'automatic gate expectation'
            ProcessSource = $processSource
            SelfTestSource = $selfTestSource.Replace(
                'ExpectedGate = $automaticGate',
                'ExpectedGate = ''unchecked-automatic-gate'''
            )
        },
        [pscustomobject]@{
            Name = 'forced native gate expectation'
            ProcessSource = $processSource
            SelfTestSource = $selfTestSource.Replace(
                'ExpectedGate = ''native-setsid''',
                'ExpectedGate = ''unchecked-forced-gate'''
            )
        },
        [pscustomobject]@{
            Name = 'target exit assertion'
            ProcessSource = $processSource
            SelfTestSource = $selfTestSource.Replace(
                '$posixPipeResult.ExitCode -ne 0',
                '$false'
            )
        },
        [pscustomobject]@{
            Name = 'evidence success guard'
            ProcessSource = $processSource
            SelfTestSource = $selfTestSource.Replace(
                'if ($failures.Count -eq $posixFailureCountBefore) {',
                'if ($true) {'
            )
        },
        [pscustomobject]@{
            Name = 'fixed POSIX evidence'
            ProcessSource = $processSource
            SelfTestSource = $selfTestSource.Replace(
                'POSIX containment evidence:',
                'POSIX evidence removed:'
            )
        }
    )
    foreach ($mutation in $mutations) {
        if ($mutation.ProcessSource -ceq $processSource -and
            $mutation.SelfTestSource -ceq $selfTestSource) {
            Add-Failure "POSIX containment validator mutation was ineffective: $($mutation.Name)"
            continue
        }
        if (Test-PosixContainmentEvidenceContract `
                -ProcessSource $mutation.ProcessSource `
                -SelfTestSource $mutation.SelfTestSource) {
            Add-Failure "POSIX containment validator accepted mutation: $($mutation.Name)"
        }
    }
}

function Test-ScannerGitExactRootContract {
    param(
        [string]$ScannerSource,
        [string]$SelfTestSource
    )

    $rawPrefixBlock = @(
        '            $reportedPrefixBytes = [byte[]]@(',
        '                $exactRootProbe.StandardOutputBytes',
        '            )',
        '            $isLfOnlyPrefix =',
        '                $reportedPrefixBytes.Length -eq 1 -and',
        '                $reportedPrefixBytes[0] -eq [byte]0x0A',
        '            $isCrLfOnlyPrefix =',
        '                $reportedPrefixBytes.Length -eq 2 -and',
        '                $reportedPrefixBytes[0] -eq [byte]0x0D -and',
        '                $reportedPrefixBytes[1] -eq [byte]0x0A',
        '            if (-not ($isLfOnlyPrefix -or $isCrLfOnlyPrefix)) {'
    ) -join "`n"
    $scannerFragments = @(
        @{ Text = '$rootProbe = Invoke-ScannerGit'; Count = 1 },
        @{
            Text = '-Arguments @(''-C'', $canonicalRoot, ''rev-parse'', ''--show-toplevel'')'
            Count = 1
        },
        @{ Text = '-Result $rootProbe'; Count = 1 },
        @{ Text = '$exactRootProbe = Invoke-ScannerGit'; Count = 1 },
        @{
            Text = '-Arguments @(''-C'', $canonicalRoot, ''rev-parse'', ''--show-prefix'')'
            Count = 1
        },
        @{ Text = '-MaximumStandardOutputBytes 4096'; Count = 1 },
        @{ Text = '-Result $exactRootProbe'; Count = 1 },
        @{ Text = $rawPrefixBlock; Count = 1 },
        @{
            Text = "throw 'Scan path must be the exact Git worktree root; subdirectories are rejected.'"
            Count = 1
        },
        @{ Text = '$indexProbe = Invoke-ScannerGit'; Count = 1 }
    )
    foreach ($fragment in $scannerFragments) {
        if ((Get-OrdinalFragmentCount `
                -Content $ScannerSource `
                -Fragment $fragment.Text) -ne $fragment.Count) {
            return $false
        }
    }

    # worktree 証明 -> Git-native exact-root probe -> raw byte比較 ->
    # index 列挙の順序も固定し、dead codeへの文字列退避を受理しにくくする。
    $orderedFragments = @(
        '$rootProbe = Invoke-ScannerGit',
        '-Result $rootProbe',
        '$exactRootProbe = Invoke-ScannerGit',
        '-Result $exactRootProbe',
        $rawPrefixBlock,
        "throw 'Scan path must be the exact Git worktree root; subdirectories are rejected.'",
        '$indexProbe = Invoke-ScannerGit'
    )
    $previousOffset = -1
    foreach ($fragment in $orderedFragments) {
        $offset = $ScannerSource.IndexOf(
            $fragment,
            $previousOffset + 1,
            [System.StringComparison]::Ordinal
        )
        if ($offset -le $previousOffset) {
            return $false
        }
        $previousOffset = $offset
    }

    $rootAliasFailurePredicate = @(
        '        if ($rootAliasResult.ExitCode -ne 0 -or',
        '            -not $rootAliasResult.StreamsCompleted -or',
        '            -not $rootAliasResult.TreeStopped -or',
        '            $rootAliasResult.TimedOut -or',
        '            $rootAliasResult.OutputLimitExceeded -or',
        '            $rootAliasResult.PipeLeakDetected) {'
    ) -join "`n"
    $selfTestFragments = @(
        @{ Text = 'PRIVATE_MARKER_ROOT_ALIAS'; Count = 2 },
        @{
            Text = 'PRIVATE_MARKER_SYNTHETIC_GIT_MODE = ''root-alias'''
            Count = 1
        },
        @{
            Text = 'PRIVATE_MARKER_SYNTHETIC_GIT_MODE = ''whitespace-prefix'''
            Count = 1
        },
        @{
            Text = 'PRIVATE_MARKER_SYNTHETIC_GIT_MODE = ''bom-prefix'''
            Count = 1
        },
        @{
            Text = 'var bytes = new byte[] { 0xEF, 0xBB, 0xBF, 0x0A };'
            Count = 1
        },
        @{ Text = $rootAliasFailurePredicate; Count = 1 },
        @{
            Text = '$gitDirectoryResult.Output -notmatch ''Git root probe failed closed'''
            Count = 1
        },
        @{
            Text = '$unicodeWhitespaceResult.Output -notmatch ''exact Git worktree root'''
            Count = 1
        },
        @{
            Text = '$whitespacePrefixResult.Output -notmatch ''exact Git worktree root'''
            Count = 1
        },
        @{
            Text = '$bomPrefixResult.Output -notmatch ''exact Git worktree root'''
            Count = 1
        },
        @{
            Text = '$subdirectoryResult.Output -notmatch ''exact Git worktree root'''
            Count = 1
        }
    )
    foreach ($fragment in $selfTestFragments) {
        if ((Get-OrdinalFragmentCount `
                -Content $SelfTestSource `
                -Fragment $fragment.Text) -ne $fragment.Count) {
            return $false
        }
    }

    $orderedSelfTestFragments = @(
        '$rootAliasResult = Invoke-Scanner',
        'PRIVATE_MARKER_SYNTHETIC_GIT_MODE = ''root-alias''',
        $rootAliasFailurePredicate,
        'Add-Failure "Expected a Git-reported physical root alias to remain accepted.',
        '$bomPrefixResult = Invoke-Scanner',
        'PRIVATE_MARKER_SYNTHETIC_GIT_MODE = ''bom-prefix''',
        '$bomPrefixResult.Output -notmatch ''exact Git worktree root'''
    )
    $previousOffset = -1
    foreach ($fragment in $orderedSelfTestFragments) {
        $offset = $SelfTestSource.IndexOf(
            $fragment,
            $previousOffset + 1,
            [System.StringComparison]::Ordinal
        )
        if ($offset -le $previousOffset) {
            return $false
        }
        $previousOffset = $offset
    }
    return $true
}

function Assert-ScannerGitExactRootValidatorRegressions {
    param(
        [string]$ScannerRelativePath,
        [string]$SelfTestRelativePath
    )

    $scannerPath = Get-RepoFilePath -RelativePath $ScannerRelativePath
    $selfTestPath = Get-RepoFilePath -RelativePath $SelfTestRelativePath
    if (-not (Test-Path -LiteralPath $scannerPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $selfTestPath -PathType Leaf)) {
        Add-Failure 'Cannot inspect missing Git exact-root contract source.'
        return
    }
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $scannerSource = [System.IO.File]::ReadAllText($scannerPath, $strictUtf8)
        $selfTestSource = [System.IO.File]::ReadAllText($selfTestPath, $strictUtf8)
    }
    catch {
        Add-Failure 'Git exact-root contract sources must be valid UTF-8.'
        return
    }

    if (-not (Test-ScannerGitExactRootContract `
            -ScannerSource $scannerSource `
            -SelfTestSource $selfTestSource)) {
        Add-Failure 'Git exact-root worktree proof, strict prefix check, or regressions are incomplete.'
        return
    }

    $rawPrefixGuard =
        'if (-not ($isLfOnlyPrefix -or $isCrLfOnlyPrefix)) {'
    $rootAliasFailurePredicate = @(
        '        if ($rootAliasResult.ExitCode -ne 0 -or',
        '            -not $rootAliasResult.StreamsCompleted -or',
        '            -not $rootAliasResult.TreeStopped -or',
        '            $rootAliasResult.TimedOut -or',
        '            $rootAliasResult.OutputLimitExceeded -or',
        '            $rootAliasResult.PipeLeakDetected) {'
    ) -join "`n"
    $bomNormalization = @(
        '            if ($reportedPrefixBytes.Length -ge 3 -and',
        '                $reportedPrefixBytes[0] -eq [byte]0xEF -and',
        '                $reportedPrefixBytes[1] -eq [byte]0xBB -and',
        '                $reportedPrefixBytes[2] -eq [byte]0xBF) {',
        '                $reportedPrefixBytes = $reportedPrefixBytes[3..($reportedPrefixBytes.Length - 1)]',
        '            }',
        '            $isLfOnlyPrefix ='
    ) -join "`n"
    $mutations = @(
        [pscustomobject]@{
            Name = 'worktree proof removal'
            ScannerSource = $scannerSource.Replace(
                '$rootProbe = Invoke-ScannerGit',
                '$removedRootProbe = Invoke-ScannerGit'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'Git-native prefix probe'
            ScannerSource = $scannerSource.Replace(
                '''--show-prefix''',
                '''--show-toplevel'''
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'exact-root healthy boundary'
            ScannerSource = $scannerSource.Replace(
                '-Result $exactRootProbe',
                '-Result $rootProbe'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'strict prefix guard removal'
            ScannerSource = $scannerSource.Replace(
                $rawPrefixGuard,
                'if ($false) {'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'exact-root fail-closed throw'
            ScannerSource = $scannerSource.Replace(
                "throw 'Scan path must be the exact Git worktree root; subdirectories are rejected.'",
                '$null = $reportedPrefixBytes'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'LF raw byte contract'
            ScannerSource = $scannerSource.Replace(
                '$reportedPrefixBytes[0] -eq [byte]0x0A',
                '$reportedPrefixBytes[0] -eq [byte]0x20'
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'BOM normalization before raw comparison'
            ScannerSource = $scannerSource.Replace(
                '            $isLfOnlyPrefix =',
                $bomNormalization
            )
            SelfTestSource = $selfTestSource
        },
        [pscustomobject]@{
            Name = 'root alias regression'
            ScannerSource = $scannerSource
            SelfTestSource = $selfTestSource.Replace(
                'PRIVATE_MARKER_SYNTHETIC_GIT_MODE = ''root-alias''',
                'PRIVATE_MARKER_SYNTHETIC_GIT_MODE = ''unchecked-root-alias'''
            )
        },
        [pscustomobject]@{
            Name = 'vacuous root alias success predicate'
            ScannerSource = $scannerSource
            SelfTestSource = $selfTestSource.Replace(
                $rootAliasFailurePredicate,
                '        if ($false) {'
            )
        },
        [pscustomobject]@{
            Name = 'Git administrative directory regression'
            ScannerSource = $scannerSource
            SelfTestSource = $selfTestSource.Replace(
                '$gitDirectoryResult.Output -notmatch ''Git root probe failed closed''',
                '$false'
            )
        },
        [pscustomobject]@{
            Name = 'Unicode whitespace subdirectory regression'
            ScannerSource = $scannerSource
            SelfTestSource = $selfTestSource.Replace(
                '$unicodeWhitespaceResult.Output -notmatch ''exact Git worktree root''',
                '$false'
            )
        },
        [pscustomobject]@{
            Name = 'whitespace-only prefix regression'
            ScannerSource = $scannerSource
            SelfTestSource = $selfTestSource.Replace(
                '$whitespacePrefixResult.Output -notmatch ''exact Git worktree root''',
                '$false'
            )
        },
        [pscustomobject]@{
            Name = 'BOM-prefixed raw output regression'
            ScannerSource = $scannerSource
            SelfTestSource = $selfTestSource.Replace(
                '$bomPrefixResult.Output -notmatch ''exact Git worktree root''',
                '$false'
            )
        },
        [pscustomobject]@{
            Name = 'normal subdirectory regression'
            ScannerSource = $scannerSource
            SelfTestSource = $selfTestSource.Replace(
                '$subdirectoryResult.Output -notmatch ''exact Git worktree root''',
                '$false'
            )
        }
    )
    foreach ($mutation in $mutations) {
        if ($mutation.ScannerSource -ceq $scannerSource -and
            $mutation.SelfTestSource -ceq $selfTestSource) {
            Add-Failure "Git exact-root validator mutation was ineffective: $($mutation.Name)"
            continue
        }
        if (Test-ScannerGitExactRootContract `
                -ScannerSource $mutation.ScannerSource `
                -SelfTestSource $mutation.SelfTestSource) {
            Add-Failure "Git exact-root validator accepted mutation: $($mutation.Name)"
        }
    }
}

function Test-PrivateMarkerRegexTypeText {
    param([AllowNull()][object]$Text)

    if ($null -eq $Text) {
        return $false
    }
    $normalized = ([string]$Text).Trim().TrimStart([char]92)
    if ($normalized.StartsWith('[') -and $normalized.EndsWith(']')) {
        $normalized = $normalized.Substring(1, $normalized.Length - 2)
    }
    # unresolved型名でもjagged/multidimensional array suffixを順に剥がし、
    # Regex[]経由の既定無限timeout object生成を見逃さない。
    while ($normalized.EndsWith(']')) {
        $arrayStart = $normalized.LastIndexOf('[')
        if ($arrayStart -lt 0) {
            break
        }
        $arrayShape = $normalized.Substring(
            $arrayStart + 1,
            $normalized.Length - $arrayStart - 2
        )
        $isArrayShape = $true
        foreach ($character in $arrayShape.ToCharArray()) {
            if ($character -ne [char]',') {
                $isArrayShape = $false
                break
            }
        }
        if (-not $isArrayShape) {
            break
        }
        $normalized = $normalized.Substring(0, $arrayStart)
    }
    if ($normalized.StartsWith(
            'System.',
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        $normalized = $normalized.Substring(7)
    }
    return (
        [string]::Equals(
            $normalized,
            'regex',
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        [string]::Equals(
            $normalized,
            'Text.RegularExpressions.Regex',
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )
}

function Test-PrivateMarkerTypeContainsRegex {
    param([AllowNull()][Type]$ResolvedType)

    if ($null -eq $ResolvedType) {
        return $false
    }
    if ($ResolvedType -eq [System.Text.RegularExpressions.Regex]) {
        return $true
    }
    if ($ResolvedType.HasElementType -and
        (Test-PrivateMarkerTypeContainsRegex `
            -ResolvedType ($ResolvedType.GetElementType()))) {
        return $true
    }
    if ($ResolvedType.IsGenericType) {
        foreach ($genericArgument in $ResolvedType.GetGenericArguments()) {
            if (Test-PrivateMarkerTypeContainsRegex `
                -ResolvedType $genericArgument) {
                return $true
            }
        }
    }
    return $false
}

function Test-PrivateMarkerRegexTypeName {
    param([AllowNull()][object]$TypeName)

    if ($null -eq $TypeName) {
        return $false
    }
    try {
        if (Test-PrivateMarkerTypeContainsRegex `
            -ResolvedType ($TypeName.GetReflectionType())) {
            return $true
        }
    }
    catch {
        # 未解決型も字面を正規化してfail closed判定へ渡す。
    }
    return (Test-PrivateMarkerRegexTypeText -Text $TypeName.FullName)
}

function Get-PrivateMarkerSafeStringValue {
    param([AllowNull()][object]$Expression)

    if (-not (
        $Expression -is
            [System.Management.Automation.Language.ExpressionAst]
    )) {
        return $null
    }
    try {
        $value = $Expression.SafeGetValue()
    }
    catch {
        return $null
    }
    if ($value -is [string]) {
        return [string]$value
    }
    return $null
}

function Get-PrivateMarkerAssignmentExpression {
    param([AllowNull()][object]$Assignment)

    if ($null -eq $Assignment) {
        return $null
    }
    $right = $Assignment.Right
    if ($right -is
            [System.Management.Automation.Language.CommandExpressionAst]) {
        return $right.Expression
    }
    return $right
}

function Get-PrivateMarkerVariableAssignments {
    param(
        [System.Management.Automation.Language.Ast]$Ast,
        [string]$Name
    )

    return @(
        $Ast.FindAll(
            {
                param($node)
                if (-not (
                    $node -is
                        [System.Management.Automation.Language.AssignmentStatementAst]
                ) -or -not (
                    $node.Left -is
                        [System.Management.Automation.Language.VariableExpressionAst]
                )) {
                    return $false
                }

                # script:/global:/local:/private: などのscopeを付けても同じ変数を
                # 上書きできるため、最後のcolonより後ろを比較して全scopeを数える。
                $userPath = [string]$node.Left.VariablePath.UserPath
                $separator = $userPath.LastIndexOf([char]58)
                $unqualifiedPath = if ($separator -ge 0) {
                    $userPath.Substring($separator + 1)
                }
                else {
                    $userPath
                }
                return [string]::Equals(
                    $unqualifiedPath,
                    $Name,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            },
            $true
        )
    )
}

function Test-PrivateMarkerVariableExpression {
    param(
        [AllowNull()][object]$Expression,
        [string]$Name
    )

    return (
        $Expression -is
            [System.Management.Automation.Language.VariableExpressionAst] -and
        [string]::Equals(
            $Expression.VariablePath.UserPath,
            $Name,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )
}

function Test-PrivateMarkerStaticCall {
    param(
        [AllowNull()][object]$Expression,
        [Type]$Type,
        [string]$Member,
        [int]$ArgumentCount
    )

    if (-not (
        $Expression -is
            [System.Management.Automation.Language.InvokeMemberExpressionAst]
    ) -or
        -not $Expression.Static -or
        -not (
            $Expression.Expression -is
                [System.Management.Automation.Language.TypeExpressionAst]
        ) -or
        -not [string]::Equals(
            [string]$Expression.Member.Value,
            $Member,
            [System.StringComparison]::Ordinal
        ) -or
        $Expression.Arguments.Count -ne $ArgumentCount) {
        return $false
    }
    try {
        return $Expression.Expression.TypeName.GetReflectionType() -eq $Type
    }
    catch {
        return $false
    }
}

function Test-ScannerHasOnlyBoundedRegexOperationsSource {
    param([string]$Source)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        return $false
    }

    # dot-source先の変数は単一代入とliteral Join-Path shapeを固定する。
    # 同名変数をScriptBlock等へ差し替えて検査対象外のcodeを実行させない。
    $processBoundaryAssignments = @(
        Get-PrivateMarkerVariableAssignments `
            -Ast $ast `
            -Name 'processBoundary'
    )
    if ($processBoundaryAssignments.Count -ne 1) {
        return $false
    }
    $processBoundaryExpression = $processBoundaryAssignments[0].Right
    if (-not (
        $processBoundaryExpression -is
            [System.Management.Automation.Language.PipelineAst]
    ) -or
        $processBoundaryExpression.PipelineElements.Count -ne 1 -or
        -not (
            $processBoundaryExpression.PipelineElements[0] -is
                [System.Management.Automation.Language.CommandAst]
        )) {
        return $false
    }
    $processBoundaryCommand = $processBoundaryExpression.PipelineElements[0]
    if (-not [string]::Equals(
            $processBoundaryCommand.GetCommandName(),
            'Join-Path',
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        $processBoundaryCommand.CommandElements.Count -ne 3 -or
        -not (Test-PrivateMarkerVariableExpression `
            -Expression $processBoundaryCommand.CommandElements[1] `
            -Name 'scriptRoot') -or
        -not [string]::Equals(
            (Get-PrivateMarkerSafeStringValue `
                -Expression $processBoundaryCommand.CommandElements[2]),
            'private-marker-process.ps1',
            [System.StringComparison]::Ordinal
        )) {
        return $false
    }

    # PowerShell regex operatorはMatchTimeoutを指定できないため全variantを拒否する。
    $unboundedOperatorKinds = @(
        'Match', 'Imatch', 'Cmatch',
        'NotMatch', 'Inotmatch', 'Cnotmatch',
        'Replace', 'Ireplace', 'Creplace',
        'Split', 'Isplit', 'Csplit'
    )
    foreach ($token in $tokens) {
        if ($unboundedOperatorKinds -contains [string]$token.Kind) {
            return $false
        }
    }

    # switch -Regex とSelect-Stringも暗黙に無限timeoutのRegexを作る。
    $regexSwitches = @(
        $ast.FindAll(
            {
                param($node)
                return (
                    $node -is
                        [System.Management.Automation.Language.SwitchStatementAst] -and
                    (
                        $node.Flags -band
                            [System.Management.Automation.Language.SwitchFlags]::Regex
                    ) -ne 0
                )
            },
            $true
        )
    )
    if ($regexSwitches.Count -gt 0) {
        return $false
    }

    $commands = @(
        $ast.FindAll(
            {
                param($node)
                return $node -is
                    [System.Management.Automation.Language.CommandAst]
            },
            $true
        )
    )
    # command surfaceを現行scannerのbuiltin/helperへ固定する。未知command、
    # external script、alias追加を既定拒否し、動的実行でRegexを隠す余地を狭める。
    $allowedCommandNames = @(
        'Add-BoundedFinding',
        'Add-LocalMarker',
        'Add-ScanRule',
        'Add-TextTarget',
        'Assert-HealthyGitBoundary',
        'Assert-PrivateMarkerScanDeadline',
        'ConvertFrom-PrivateMarkerUtf8Bytes',
        'ConvertTo-PrivateMarkerDiagnosticText',
        'Get-ChangedEnvironmentVariableNames',
        'Get-ChildItem',
        'Get-Command',
        'Get-Item',
        'Get-ProcessEnvironmentSnapshot',
        'Get-RemainingGitTimeoutMilliseconds',
        'Get-SafeFallbackFiles',
        'Invoke-BoundedLineAction',
        'Invoke-PrivateMarkerProcess',
        'Invoke-ScannerGit',
        'Join-Path',
        'New-Item',
        'New-Object',
        'New-PrivateMarkerBoundedRegex',
        'New-PrivateMarkerGitIsolationRoot',
        'Out-Null',
        'Read-StableWorktreeBytes',
        'Remove-PrivateMarkerGitIsolationRoot',
        'Resolve-Path',
        'Select-Object',
        'Set-StrictMode',
        'Sort-Object',
        'Split-Path',
        'Stop-PrivateMarkerRegexTimeout',
        'Test-ByteArraysEqual',
        'Test-GitMarkerInAncestry',
        'Test-IsTextFile',
        'Test-Path',
        'Test-PrivateMarkerWindowsHost',
        'Test-SafeWorktreeParentChain',
        'Where-Object',
        'Write-Host'
    )
    $allowedProcessBoundaryDotSources = 0
    foreach ($command in $commands) {
        $commandName = $command.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($commandName)) {
            # call operatorと式でcommand名を組み立てるとNew-Object等を隠せる。
            # 唯一必要な動的commandは、検証済みprocess boundaryのdot-sourceだけ。
            if ($command.InvocationOperator -eq
                    [System.Management.Automation.Language.TokenKind]::Dot -and
                $command.CommandElements.Count -eq 1 -and
                (Test-PrivateMarkerVariableExpression `
                    -Expression $command.CommandElements[0] `
                    -Name 'processBoundary')) {
                $allowedProcessBoundaryDotSources++
                continue
            }
            return $false
        }
        $leafCommandName = $commandName
        $moduleSeparator = $leafCommandName.LastIndexOf([char]92)
        if ($moduleSeparator -ge 0) {
            $leafCommandName =
                $leafCommandName.Substring($moduleSeparator + 1)
        }
        if ($leafCommandName -notin $allowedCommandNames) {
            return $false
        }
        # 動的評価とVariable provider経由の代入は、timeout変数の単一代入
        # provenanceをASTだけで追えなくする。scanner本体では不要なのでfail closed。
        if ($leafCommandName -iin @(
                'Invoke-Expression',
                'iex',
                'Set-Variable',
                'New-Variable',
                'Remove-Variable',
                'Clear-Variable',
                'Set-Item',
                'Clear-Item',
                'Set-Content',
                'Add-Content',
                'Clear-Content',
                'Set-Alias',
                'sal',
                'New-Alias',
                'nal',
                'Remove-Alias',
                'Import-Alias'
            )) {
            return $false
        }
        if ($leafCommandName -iin @('New-Item', 'Remove-Item', 'Get-Item')) {
            foreach ($commandElement in $command.CommandElements) {
                $providerPath = Get-PrivateMarkerSafeStringValue `
                    -Expression $commandElement
                if ($null -ne $providerPath -and
                    (
                        $providerPath.StartsWith(
                            'Variable:',
                            [System.StringComparison]::OrdinalIgnoreCase
                        ) -or
                        $providerPath.StartsWith(
                            'Alias:',
                            [System.StringComparison]::OrdinalIgnoreCase
                        )
                    )) {
                    return $false
                }
            }
        }
        if ($leafCommandName -iin @('Select-String', 'sls')) {
            return $false
        }
        if (-not [string]::Equals(
                $leafCommandName,
                'New-Object',
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            continue
        }

        # New-Objectの型引数はstatic stringだけを許可する。-TypeNameの
        # unambiguous abbreviation（-Type等）とparameter順序を正式に扱い、
        # positional typeより前に別parameterがある曖昧な形はfail closedにする。
        $typeElement = $null
        $explicitTypeCount = 0
        for ($index = 1;
            $index -lt $command.CommandElements.Count;
            $index++) {
            $element = $command.CommandElements[$index]
            if ($element -is
                    [System.Management.Automation.Language.CommandParameterAst] -and
                'TypeName'.StartsWith(
                    [string]$element.ParameterName,
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                $explicitTypeCount++
                if ($null -ne $element.Argument) {
                    $typeElement = $element.Argument
                }
                elseif (($index + 1) -lt $command.CommandElements.Count -and
                    -not (
                        $command.CommandElements[$index + 1] -is
                            [System.Management.Automation.Language.CommandParameterAst]
                    )) {
                    $typeElement = $command.CommandElements[$index + 1]
                }
            }
        }
        if ($explicitTypeCount -gt 1) {
            return $false
        }
        if ($explicitTypeCount -eq 0) {
            if ($command.CommandElements.Count -lt 2 -or
                $command.CommandElements[1] -is
                    [System.Management.Automation.Language.CommandParameterAst]) {
                return $false
            }
            $typeElement = $command.CommandElements[1]
        }
        $typeText = Get-PrivateMarkerSafeStringValue `
            -Expression $typeElement
        if ($null -eq $typeText -or
            (Test-PrivateMarkerRegexTypeText -Text $typeText)) {
            return $false
        }
    }
    if ($allowedProcessBoundaryDotSources -ne 1) {
        return $false
    }

    # cast / type constraint / shortened type nameもreflection解決後の型で拒否する。
    $regexTypeConstraints = @(
        $ast.FindAll(
            {
                param($node)
                return (
                    $node -is
                        [System.Management.Automation.Language.TypeConstraintAst] -and
                    (Test-PrivateMarkerRegexTypeName -TypeName $node.TypeName)
                )
            },
            $true
        )
    )
    if ($regexTypeConstraints.Count -gt 0) {
        return $false
    }
    $regexTypeExpressions = @(
        $ast.FindAll(
            {
                param($node)
                return (
                    $node -is
                        [System.Management.Automation.Language.TypeExpressionAst] -and
                    (Test-PrivateMarkerRegexTypeName -TypeName $node.TypeName)
                )
            },
            $true
        )
    )
    # `$typeValue::new()` のようなdynamic static receiverは型を隠せる。
    # またActivator/Typeを使うreflection factoryもRegex生成を迂回できるため、
    # scanner本体に不要な形を保守的に拒否する。
    $allStaticInvocations = @(
        $ast.FindAll(
            {
                param($node)
                return $node -is
                    [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $node.Static
            },
            $true
        )
    )
    foreach ($invocation in $allStaticInvocations) {
        if (-not (
            $invocation.Expression -is
                [System.Management.Automation.Language.TypeExpressionAst]
        )) {
            return $false
        }
        try {
            $receiverType =
                $invocation.Expression.TypeName.GetReflectionType()
        }
        catch {
            return $false
        }
        if ($receiverType -eq [System.Activator] -or
            $receiverType -eq [System.Type] -or
            $receiverType -eq [scriptblock]) {
            return $false
        }
    }
    $staticRegexInvocations = @(
        $allStaticInvocations | Where-Object {
            Test-PrivateMarkerRegexTypeName `
                -TypeName $_.Expression.TypeName
        }
    )
    if ($regexTypeExpressions.Count -ne 1 -or
        $staticRegexInvocations.Count -ne 1) {
        return $false
    }
    $constructor = $staticRegexInvocations[0]
    if (-not [string]::Equals(
            [string]$constructor.Member.Value,
            'new',
            [System.StringComparison]::Ordinal
        ) -or
        $constructor.Arguments.Count -ne 3 -or
        -not (Test-PrivateMarkerVariableExpression `
            -Expression $constructor.Arguments[2] `
            -Name 'regexMatchTimeout')) {
        return $false
    }

    # -asはdynamic RHSにRegex型を隠せるため、scanner本体で未使用のoperatorを
    # RHSの形にかかわらず拒否する。
    $regexAsExpressions = @(
        $ast.FindAll(
            {
                param($node)
                if (-not (
                    $node -is
                        [System.Management.Automation.Language.BinaryExpressionAst]
                ) -or [string]$node.Operator -ne 'As') {
                    return $false
                }
                return $true
            },
            $true
        )
    )
    if ($regexAsExpressions.Count -gt 0) {
        return $false
    }

    # timeout変数は単一代入とAST shapeを固定し、未使用の250定義を残した
    # 5秒化やconstructor第三引数の差替えを許さない。
    $scanMaximumAssignments = @(
        Get-PrivateMarkerVariableAssignments `
            -Ast $ast `
            -Name 'maximumScanMilliseconds'
    )
    $matchMaximumAssignments = @(
        Get-PrivateMarkerVariableAssignments `
            -Ast $ast `
            -Name 'maximumRegexMatchMilliseconds'
    )
    $timeoutMillisecondsAssignments = @(
        Get-PrivateMarkerVariableAssignments `
            -Ast $ast `
            -Name 'regexMatchTimeoutMilliseconds'
    )
    $timeoutAssignments = @(
        Get-PrivateMarkerVariableAssignments `
            -Ast $ast `
            -Name 'regexMatchTimeout'
    )
    if ($scanMaximumAssignments.Count -ne 1 -or
        $matchMaximumAssignments.Count -ne 1 -or
        $timeoutMillisecondsAssignments.Count -ne 1 -or
        $timeoutAssignments.Count -ne 1) {
        return $false
    }

    $scanMaximumExpression = Get-PrivateMarkerAssignmentExpression `
        -Assignment $scanMaximumAssignments[0]
    if (-not (
        $scanMaximumExpression -is
            [System.Management.Automation.Language.ConstantExpressionAst]
    ) -or [int]$scanMaximumExpression.Value -ne 120000) {
        return $false
    }
    $matchMaximumExpression = Get-PrivateMarkerAssignmentExpression `
        -Assignment $matchMaximumAssignments[0]
    if (-not (
        $matchMaximumExpression -is
            [System.Management.Automation.Language.ConstantExpressionAst]
    ) -or [int]$matchMaximumExpression.Value -ne 250) {
        return $false
    }

    $timeoutMillisecondsExpression =
        Get-PrivateMarkerAssignmentExpression `
            -Assignment $timeoutMillisecondsAssignments[0]
    if (-not (Test-PrivateMarkerStaticCall `
        -Expression $timeoutMillisecondsExpression `
        -Type ([Math]) `
        -Member 'Max' `
        -ArgumentCount 2) -or
        -not (
            $timeoutMillisecondsExpression.Arguments[0] -is
                [System.Management.Automation.Language.ConstantExpressionAst]
        ) -or
        [int]$timeoutMillisecondsExpression.Arguments[0].Value -ne 1) {
        return $false
    }
    $minimumExpression = $timeoutMillisecondsExpression.Arguments[1]
    if (-not (Test-PrivateMarkerStaticCall `
        -Expression $minimumExpression `
        -Type ([Math]) `
        -Member 'Min' `
        -ArgumentCount 2) -or
        -not (Test-PrivateMarkerVariableExpression `
            -Expression $minimumExpression.Arguments[0] `
            -Name 'maximumRegexMatchMilliseconds') -or
        -not (Test-PrivateMarkerVariableExpression `
            -Expression $minimumExpression.Arguments[1] `
            -Name 'maximumScanMilliseconds')) {
        return $false
    }

    $timeoutExpression = Get-PrivateMarkerAssignmentExpression `
        -Assignment $timeoutAssignments[0]
    if (-not (Test-PrivateMarkerStaticCall `
        -Expression $timeoutExpression `
        -Type ([TimeSpan]) `
        -Member 'FromMilliseconds' `
        -ArgumentCount 1) -or
        -not (Test-PrivateMarkerVariableExpression `
            -Expression $timeoutExpression.Arguments[0] `
            -Name 'regexMatchTimeoutMilliseconds')) {
        return $false
    }
    return $true
}

function Assert-ScannerHasOnlyBoundedRegexOperations {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure (
            "Cannot inspect missing file: $RelativePath " +
            '(bounded regex operation contract)'
        )
        return
    }
    try {
        $source = [System.IO.File]::ReadAllText(
            $filePath,
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
    }
    catch {
        Add-Failure (
            "$RelativePath must be valid UTF-8 for its bounded regex contract."
        )
        return
    }
    if (-not (Test-ScannerHasOnlyBoundedRegexOperationsSource `
        -Source $source)) {
        Add-Failure (
            "$RelativePath violates its bounded regex AST contract."
        )
    }
}

function Assert-ScannerRegexPolicyValidatorRegressions {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return
    }
    try {
        $source = [System.IO.File]::ReadAllText(
            $filePath,
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
    }
    catch {
        return
    }
    $newline = [Environment]::NewLine
    $mutations = @(
        [pscustomobject]@{
            Name = 'regex cast'
            Source = $source + $newline + "[regex]'x+'"
        },
        [pscustomobject]@{
            Name = 'regex array cast'
            Source = $source + $newline + "[regex[]]@('x+')"
        },
        [pscustomobject]@{
            Name = 'regex multidimensional cast'
            Source = $source + $newline +
                "[Text.RegularExpressions.Regex[,]]@('x+')"
        },
        [pscustomobject]@{
            Name = 'shortened static regex type'
            Source = $source + $newline +
                '[Text.RegularExpressions.Regex]::IsMatch($line, ''x'')'
        },
        [pscustomobject]@{
            Name = 'five-second maximum'
            Source = $source.Replace(
                '$maximumRegexMatchMilliseconds = 250',
                '$maximumRegexMatchMilliseconds = 5000'
            )
        },
        [pscustomobject]@{
            Name = 'constructor timeout replacement'
            Source = $source.Replace(
                '        $regexMatchTimeout',
                '        [TimeSpan]::FromSeconds(5)'
            )
        },
        [pscustomobject]@{
            Name = 'parenthesized New-Object regex'
            Source = $source + $newline + "New-Object -TypeName ('Regex')"
        },
        [pscustomobject]@{
            Name = 'module-qualified New-Object regex'
            Source = $source + $newline +
                'Microsoft.PowerShell.Utility\New-Object Regex'
        },
        [pscustomobject]@{
            Name = 'regex switch'
            Source = $source + $newline +
                'switch -Regex ($line) { ''x'' { break } }'
        },
        [pscustomobject]@{
            Name = 'Select-String'
            Source = $source + $newline +
                'Microsoft.PowerShell.Utility\Select-String x README.md'
        },
        [pscustomobject]@{
            Name = 'regex -as conversion'
            Source = $source + $newline + '$line -as ''regex'''
        },
        [pscustomobject]@{
            Name = 'dynamic regex -as conversion'
            Source = $source + $newline +
                '$dynamicRegexType = ''regex''; $line -as $dynamicRegexType'
        },
        [pscustomobject]@{
            Name = 'dynamic regex static receiver'
            Source = $source + $newline +
                '$dynamicRegexType = [type]::GetType(' +
                '''System.Text.RegularExpressions.Regex''); ' +
                '$dynamicRegexType::new(''x'')'
        },
        [pscustomobject]@{
            Name = 'Activator regex construction'
            Source = $source + $newline +
                '$dynamicRegexType = [type]::GetType(' +
                '''System.Text.RegularExpressions.Regex''); ' +
                '[Activator]::CreateInstance($dynamicRegexType, @(''x''))'
        },
        [pscustomobject]@{
            Name = 'scope-qualified timeout assignment'
            Source = $source + $newline +
                '$script:regexMatchTimeout = [TimeSpan]::FromSeconds(5)'
        },
        [pscustomobject]@{
            Name = 'Set-Variable timeout assignment'
            Source = $source + $newline +
                'Set-Variable -Name regexMatchTimeout ' +
                '-Value ([TimeSpan]::FromSeconds(5))'
        },
        [pscustomobject]@{
            Name = 'Set-Item timeout assignment'
            Source = $source + $newline +
                'Set-Item Variable:regexMatchTimeout ' +
                '([TimeSpan]::FromSeconds(5))'
        },
        [pscustomobject]@{
            Name = 'New-Variable timeout assignment'
            Source = $source + $newline +
                'New-Variable -Name regexMatchTimeout ' +
                '-Value ([TimeSpan]::FromSeconds(5)) -Force'
        },
        [pscustomobject]@{
            Name = 'Invoke-Expression timeout assignment'
            Source = $source + $newline +
                'Invoke-Expression ' +
                '''$regexMatchTimeout = [TimeSpan]::FromSeconds(5)'''
        },
        [pscustomobject]@{
            Name = 'abbreviated parameter New-Object regex'
            Source = $source + $newline +
                'New-Object -ArgumentList ''x'' -Type Regex'
        },
        [pscustomobject]@{
            Name = 'module-qualified abbreviated New-Object regex'
            Source = $source + $newline +
                'Microsoft.PowerShell.Utility\New-Object ' +
                '-ArgumentList ''x'' -Type Regex'
        },
        [pscustomobject]@{
            Name = 'dynamic New-Object invocation'
            Source = $source + $newline +
                '& (''New-'' + ''Object'') Regex ''x+'''
        },
        [pscustomobject]@{
            Name = 'dynamic Select-String invocation'
            Source = $source + $newline +
                '& (''Select-'' + ''String'') x README.md'
        },
        [pscustomobject]@{
            Name = 'New-Object alias invocation'
            Source = $source + $newline +
                'Set-Alias rxo New-Object; rxo Regex ''x+'''
        },
        [pscustomobject]@{
            Name = 'process boundary ScriptBlock reassignment'
            Source = $source.Replace(
                '. $processBoundary',
                '$processBoundary = [ScriptBlock]::Create(''param()'')' +
                    $newline + '. $processBoundary'
            )
        },
        [pscustomobject]@{
            Name = 'ScriptBlock.Create dynamic evaluation'
            Source = $source + $newline +
                '[ScriptBlock]::Create(''param()'')'
        },
        [pscustomobject]@{
            Name = 'raw recursive Git isolation-root removal'
            Source = $source + $newline +
                'Remove-Item -Recurse -Force -LiteralPath $gitIsolationRoot'
        },
        [pscustomobject]@{
            Name = 'unknown command surface'
            Source = $source + $newline + 'Write-Output ''x'''
        }
    )
    foreach ($mutation in $mutations) {
        if ($mutation.Source -ceq $source) {
            Add-Failure (
                "Bounded regex policy mutation did not change source: " +
                $mutation.Name
            )
        } elseif (Test-ScannerHasOnlyBoundedRegexOperationsSource `
            -Source $mutation.Source) {
            Add-Failure (
                "Bounded regex policy accepted mutation: $($mutation.Name)"
            )
        }
    }
}

function Assert-FileHasUtf8Bom {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (UTF-8 BOM contract)"
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    if ($bytes.Length -lt 3 -or
        $bytes[0] -ne 0xEF -or
        $bytes[1] -ne 0xBB -or
        $bytes[2] -ne 0xBF) {
        Add-Failure "$RelativePath must keep a UTF-8 BOM because Windows PowerShell 5.1 executes its Japanese comments."
    }
}

function Test-SkillFrontmatter {
    $skillPath = Get-RepoFilePath -RelativePath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        return
    }

    $lines = Get-Content -LiteralPath $skillPath
    if ($lines.Count -lt 4 -or $lines[0] -ne '---') {
        Add-Failure 'SKILL.md must start with YAML frontmatter.'
        return
    }

    $closingIndex = -1
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -eq '---') {
            $closingIndex = $index
            break
        }
    }

    if ($closingIndex -lt 0) {
        Add-Failure 'SKILL.md frontmatter must be closed with --- before content.'
        return
    }

    $frontmatter = $lines[1..($closingIndex - 1)] -join "`n"
    if ($frontmatter -notmatch '(?m)^name:\s*windows-utf8-text-hygiene\s*$') {
        Add-Failure 'SKILL.md frontmatter must declare name: windows-utf8-text-hygiene.'
    }
    if ($frontmatter -notmatch '(?m)^description:\s*\S') {
        Add-Failure 'SKILL.md frontmatter must include a non-empty description.'
    }
    if ($frontmatter.Length -gt 1024) {
        Add-Failure 'SKILL.md frontmatter must stay under 1024 characters.'
    }
}

$requiredFiles = @(
    '.editorconfig',
    '.gitattributes',
    '.gitignore',
    '.github/ISSUE_TEMPLATE/bug_report.yml',
    '.github/ISSUE_TEMPLATE/config.yml',
    '.github/pull_request_template.md',
    '.github/workflows/validate.yml',
    'CHANGELOG.md',
    'CODE_OF_CONDUCT.md',
    'CONTRIBUTING.md',
    'HANDOFF.md',
    'LICENSE',
    'README.md',
    'SECURITY.md',
    'SKILL.md',
    'docs/SKILL.ja.md',
    'docs/macos-pwsh-ci-contract.md',
    'examples/inspection-one-liners.md',
    'examples/guarded-normalization.md',
    'examples/gitattributes-editorconfig-sample.md',
    'scripts/private-marker-process.ps1',
    'scripts/scan-private-markers.ps1',
    'scripts/test-scan-private-markers.ps1',
    'scripts/validate-oss-readiness.ps1'
)

foreach ($requiredFile in $requiredFiles) {
    Assert-FileExists -RelativePath $requiredFile
}

Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Install' -Description 'installation instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Validation' -Description 'validation instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Contributing' -Description 'contribution guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Security' -Description 'security reporting guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern 'CONTRIBUTING\.md' -Description 'link to CONTRIBUTING.md'
Assert-FileContains -RelativePath 'README.md' -Pattern 'SECURITY\.md' -Description 'link to SECURITY.md'
Assert-FileContains -RelativePath 'README.md' -Pattern 'docs/SKILL\.ja\.md' -Description 'link to the Japanese skill version'
Assert-FileContains -RelativePath '.gitignore' -Pattern '\.private-markers\.local' -Description 'ignore local private marker files'
Assert-FileContains -RelativePath 'CONTRIBUTING.md' -Pattern '(?im)no token|never.*token|secret' -Description 'secret-safe contribution guidance'
Assert-FileContains -RelativePath 'SECURITY.md' -Pattern '(?im)do not.*public|private|security' -Description 'private vulnerability reporting guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern 'per-run owner marker' -Description 'documented Git isolation-root ownership contract'
Assert-FileContains -RelativePath 'SECURITY.md' -Pattern 'second root/marker lookup' -Description 'security cleanup check/use contract'
Assert-FileContains -RelativePath 'CHANGELOG.md' -Pattern 'deterministic regular-directory' -Description 'cleanup replacement regression changelog'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'validate-oss-readiness\.ps1' -Description 'OSS readiness validation in CI'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'scan-private-markers\.ps1' -Description 'private marker scan in CI'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'test-scan-private-markers\.ps1' -Description 'private marker scan self-test in CI'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'timeout-minutes:\s*10' -Description 'bounded CI validation job'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'uses:\s*actions/checkout@[0-9a-f]{40}(?:\s*#\s*v5)?' -Description 'immutable checkout action revision'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern '(?ms)shell:\s*powershell\s+run:\s*\.\\scripts\\test-scan-private-markers\.ps1' -Description 'explicit Windows PowerShell 5.1 scanner self-test'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern '(?ms)validate-ubuntu:.*runs-on:\s*ubuntu-24\.04.*test-scan-private-markers\.ps1' -Description 'Ubuntu POSIX containment self-test'
Assert-FileContains -RelativePath 'README.md' -Pattern 'macOS 15 job uses PowerShell 7 only' -Description 'macOS PowerShell-only platform distinction'
Assert-FileContains -RelativePath 'README.md' -Pattern 'macos-15-arm64' -Description 'measured macOS runner image'
Assert-FileContains -RelativePath 'README.md' -Pattern 'PowerShell Core\s+`7\.6\.3`' -Description 'measured macOS PowerShell version'
Assert-FileContains -RelativePath 'CONTRIBUTING.md' -Pattern 'Platform results are not interchangeable' -Description 'contributor platform evidence distinction'
Assert-FileContains -RelativePath 'CONTRIBUTING.md' -Pattern '30205393010' -Description 'contributor macOS evidence run'
Assert-FileContains -RelativePath 'SECURITY.md' -Pattern 'macOS 15 job uses PowerShell 7 only' -Description 'security platform containment distinction'
Assert-FileContains -RelativePath 'SECURITY.md' -Pattern 'automatic=native-setsid' -Description 'measured macOS automatic gate'
Assert-FileContains -RelativePath 'CHANGELOG.md' -Pattern '30205393010' -Description 'changelog macOS evidence run'
Assert-FileContains -RelativePath 'docs/macos-pwsh-ci-contract.md' -Pattern '(?im)^Status:\s*verified' -Description 'verified macOS evidence status'
Assert-FileContains -RelativePath 'docs/macos-pwsh-ci-contract.md' -Pattern 'macos-15-arm64.*20260715\.0234\.1' -Description 'documented macOS runner image evidence'
Assert-FileContains -RelativePath 'docs/macos-pwsh-ci-contract.md' -Pattern 'PowerShell Core\s+`7\.6\.3`' -Description 'documented macOS PowerShell evidence'
Assert-FileContains -RelativePath 'docs/macos-pwsh-ci-contract.md' -Pattern 'job/89802443609' -Description 'documented macOS job evidence'
Assert-FileContains -RelativePath 'docs/macos-pwsh-ci-contract.md' -Pattern '(?s)canonical top-level workflow shape.*direct child of that `jobs:`' -Description 'documented workflow shape and job membership contract'
Assert-FileContains -RelativePath 'docs/macos-pwsh-ci-contract.md' -Pattern '(?s)direct job headings.*`validate-ubuntu`.*`validate-macos`' -Description 'documented canonical direct job headings'
Assert-FileDoesNotContain -RelativePath 'README.md' -Pattern 'job is being added|macOS remains unverified until' -Description 'stale pre-CI macOS limitation'
Assert-FileDoesNotContain -RelativePath 'SECURITY.md' -Pattern 'until its pull-request run succeeds|macOS behavior remains\s+unverified' -Description 'stale pre-CI macOS security limitation'
Assert-FileDoesNotContain -RelativePath 'CONTRIBUTING.md' -Pattern 'Until that pull-request job is green' -Description 'stale pre-CI contributor limitation'
Assert-FileDoesNotContain -RelativePath 'CHANGELOG.md' -Pattern 'macOS execution remains unverified' -Description 'stale pre-CI changelog status'
Assert-FileDoesNotContain -RelativePath 'docs/macos-pwsh-ci-contract.md' -Pattern '(?im)^Status:.*unverified|Before the pull-request job is green' -Description 'stale pre-CI evidence status'
Assert-FileContains -RelativePath 'docs/macos-pwsh-ci-contract.md' -Pattern 'PosixSessionGate' -Description 'documented POSIX gate provenance'
Assert-FileContains -RelativePath 'docs/macos-pwsh-ci-contract.md' -Pattern 'DllImport\("libc"\)' -Description 'documented POSIX native resolver contract'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'private-marker-process\.ps1' -Description 'shared bounded process boundary in scanner'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'private-marker-process\.ps1' -Description 'shared bounded process boundary in scanner self-test'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'PosixSignal.*IsSuccessfulResult' -Description 'POSIX errno cleanup regression coverage'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'function\s+Test-PrivateMarkerGitIsolationRootBoundary' -Description 'owned Git isolation-root boundary'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'function\s+New-PrivateMarkerGitIsolationRoot' -Description 'owned Git isolation-root initializer'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern '\^windows-utf8-text-hygiene-git-\[0-9a-f\]\{32\}\$' -Description 'exact Git isolation-root prefix and GUID contract'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'FileAttributes\]::ReparsePoint' -Description 'Git isolation-root reparse-point rejection'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern '\.windows-utf8-text-hygiene-owner' -Description 'Git isolation-root owner marker'
Assert-FilePatternCount `
    -RelativePath 'scripts/private-marker-process.ps1' `
    -Pattern '(?m)^\s*Assert-PrivateMarkerGitIsolationRootState\b' `
    -ExpectedCount 2 `
    -Description 'pre-cleanup Git isolation-root state validations'
Assert-FilePatternCount `
    -RelativePath 'scripts/scan-private-markers.ps1' `
    -Pattern '(?m)^\s*Remove-PrivateMarkerGitIsolationRoot\b' `
    -ExpectedCount 3 `
    -Description 'guarded Git isolation-root cleanup callsites'
Assert-FileDoesNotContain `
    -RelativePath 'scripts/scan-private-markers.ps1' `
    -Pattern '(?m)^\s*Remove-Item\s+-LiteralPath\s+\$gitIsolationRoot\s+-Recurse\s+-Force\s*$' `
    -Description 'raw recursive Git isolation-root cleanup'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'wrong-name Git isolation root' -Description 'wrong-name Git isolation-root cleanup rejection'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'missing-root Git isolation root' -Description 'missing-root Git isolation-root cleanup rejection'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'reparse-point Git isolation root' -Description 'reparse-point Git isolation-root cleanup rejection'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'BeforeFinalValidation' -Description 'deterministic Git isolation-root check/use interleaving seam'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'regular-directory replacement' -Description 'regular-directory ownership replacement regression'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'New-PrivateMarkerBoundedRegex' -Description 'finite regex match-timeout constructor'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'RegexMatchTimeoutException' -Description 'regex timeout fail-closed handling'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern '\$maximumRegexMatchMilliseconds\s*=\s*250' -Description 'bounded regex match duration'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'regex-match-timeout' -Description 'adversarial regex no-match regression'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?ms)^## Dogfooding.*Windows PowerShell 5\.1.*UTF-8\s+BOM' -Description 'PowerShell 5.1 BOM exception in dogfooding guidance'

$expectedMacOsWorkflowJob = @'
  validate-macos:
    name: Validate macOS PowerShell 7
    runs-on: macos-15
    timeout-minutes: 10
    steps:
      - name: Check out repository
        uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5

      - name: Verify macOS and PowerShell Core
        shell: pwsh
        run: |
          if (-not $IsMacOS) {
            throw 'Expected a macOS host.'
          }
          if ($PSVersionTable.PSEdition -cne 'Core') {
            throw 'Expected PowerShell Core.'
          }
          if ($PSVersionTable.PSVersion.Major -ne 7) {
            throw 'Expected PowerShell 7.'
          }
          Write-Host "macOS compatibility canary: pwsh=$($PSVersionTable.PSVersion); edition=Core."

      - name: Validate OSS readiness
        shell: pwsh
        run: ./scripts/validate-oss-readiness.ps1

      - name: Test private marker scan (PowerShell 7 on macOS)
        shell: pwsh
        run: ./scripts/test-scan-private-markers.ps1

      - name: Scan for private markers
        shell: pwsh
        run: ./scripts/scan-private-markers.ps1

      - name: Check whitespace
        shell: pwsh
        run: git diff-tree --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD
'@
Assert-WorkflowJobBlockExact `
    -RelativePath '.github/workflows/validate.yml' `
    -JobName 'validate-macos' `
    -ExpectedBlock $expectedMacOsWorkflowJob
Assert-WorkflowJobBlockValidatorRegressions `
    -RelativePath '.github/workflows/validate.yml' `
    -JobName 'validate-macos' `
    -ExpectedBlock $expectedMacOsWorkflowJob

Assert-PosixContainmentEvidenceValidatorRegressions `
    -ProcessRelativePath 'scripts/private-marker-process.ps1' `
    -SelfTestRelativePath 'scripts/test-scan-private-markers.ps1'
Assert-ScannerGitExactRootValidatorRegressions `
    -ScannerRelativePath 'scripts/scan-private-markers.ps1' `
    -SelfTestRelativePath 'scripts/test-scan-private-markers.ps1'
Assert-ScannerHasOnlyBoundedRegexOperations `
    -RelativePath 'scripts/scan-private-markers.ps1'
Assert-ScannerRegexPolicyValidatorRegressions `
    -RelativePath 'scripts/scan-private-markers.ps1'
Assert-GuardedNormalizationExampleValidatorRegressions `
    -RelativePath 'examples/guarded-normalization.md'

Assert-FileHasUtf8Bom -RelativePath 'scripts/scan-private-markers.ps1'
Assert-FileHasUtf8Bom -RelativePath 'scripts/test-scan-private-markers.ps1'
Assert-FileHasUtf8Bom -RelativePath 'scripts/private-marker-process.ps1'
Assert-FileHasUtf8Bom -RelativePath 'scripts/validate-oss-readiness.ps1'

Test-SkillFrontmatter

if ($failures.Count -gt 0) {
    Write-Host 'OSS readiness validation failed:'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host "OSS readiness validation passed for $root"
exit 0
