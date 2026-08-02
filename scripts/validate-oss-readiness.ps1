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

function Read-StrictUtf8Text {
    param(
        [string]$FilePath,
        [string]$Description
    )

    try {
        # PS5.1のGet-Content既定encodingへ依存せず、BOMなし日本語docsも
        # pwsh 7と同じbyte contractで読む。不正byteは置換せずfail closed。
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        return [System.IO.File]::ReadAllText($FilePath, $strictUtf8)
    }
    catch {
        Add-Failure "$Description must be strict UTF-8."
        return $null
    }
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

    $content = Read-StrictUtf8Text `
        -FilePath $filePath `
        -Description $RelativePath
    if ($null -eq $content) {
        return
    }
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

    $content = Read-StrictUtf8Text `
        -FilePath $filePath `
        -Description $RelativePath
    if ($null -eq $content) {
        return
    }
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

    $content = Read-StrictUtf8Text `
        -FilePath $filePath `
        -Description $RelativePath
    if ($null -eq $content) {
        return
    }
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

function Find-WorkflowQuotedScalarClosingIndex {
    param(
        [string]$Line,
        [int]$OpeningQuoteIndex,
        [char]$Quote
    )

    $index = $OpeningQuoteIndex + 1
    while ($index -lt $Line.Length) {
        $character = $Line[$index]
        if ($Quote -eq '"') {
            # double quote内のbackslashは直後の文字をescapeする。escaped quoteを
            # scalar終端として扱わず、次のphysical lineまで状態を維持する。
            if ($character -eq '\') {
                $index += 2
                continue
            }
            if ($character -eq '"') {
                return $index
            }
        } elseif ($character -eq "'") {
            # YAML single quoteはdoubled `''`でliteral quoteを表す。
            if (($index + 1) -lt $Line.Length -and
                $Line[$index + 1] -eq "'") {
                $index += 2
                continue
            }
            return $index
        }
        $index++
    }

    return -1
}

function Get-WorkflowActiveMappingLineMask {
    param(
        [string[]]$Lines
    )

    $activeLineMask = New-Object bool[] $Lines.Count
    $blockScalarHeaderIndent = $null
    $quotedScalarQuote = $null
    $plainScalarHeaderIndent = $null
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        $line = $Lines[$index]
        $trimmedLine = $line.TrimStart()
        $indentLength = $line.Length - $trimmedLine.Length

        # multiline quoted scalarの継続physical lineはmappingではない。閉じquoteを
        # 見つけた行までinactiveとし、その次行から通常のYAML検査へ戻す。
        if ($null -ne $quotedScalarQuote) {
            $closingQuoteIndex = Find-WorkflowQuotedScalarClosingIndex `
                -Line $line `
                -OpeningQuoteIndex -1 `
                -Quote $quotedScalarQuote
            if ($closingQuoteIndex -ge 0) {
                $quotedScalarQuote = $null
            }
            continue
        }

        # multiline plain scalarはblank/commentをまたいでも、最初のnon-comment
        # dedentまで継続する。深いphysical lineだけをinactiveにする。
        if ($null -ne $plainScalarHeaderIndent) {
            if ([string]::IsNullOrWhiteSpace($trimmedLine) -or
                $trimmedLine.StartsWith('#')) {
                continue
            }
            if ($indentLength -gt $plainScalarHeaderIndent) {
                continue
            }
            $plainScalarHeaderIndent = $null
        }

        # literal/folded block scalarはheaderより深いindentが続く間だけ本文になる。
        # chomp/indent indicator（|-, |2, >+ 等）もheaderとして認識し、dedentした
        # 行から通常のYAML mapping検査へ戻す。
        if ($null -ne $blockScalarHeaderIndent) {
            if ([string]::IsNullOrWhiteSpace($trimmedLine)) {
                continue
            }
            if ($indentLength -gt $blockScalarHeaderIndent) {
                continue
            }
            $blockScalarHeaderIndent = $null
        }

        if ($line -cmatch (
                '^(?<leading>\s*)-\s+[>|][0-9+-]*\s*(?:#.*)?$'
            )) {
            # bare sequence block scalarはsequenceの親indentを境界にする。本文の
            # `[`, `!`, `uses:`風文字列をactive YAML nodeとして誤認しない。
            $activeLineMask[$index] = $true
            $blockScalarHeaderIndent = $Matches['leading'].Length
            continue
        }

        if ($line -cmatch (
                '^(?<leading>\s*)(?<sequence>-\s+)?' +
                '(?:[A-Za-z0-9_.-]+|''[^'']+''|"[^"]+")' +
                '\s*:\s*[>|][0-9+-]*\s*(?:#.*)?$'
            )) {
            # headerはactive mappingとして検査する。uses: > のような非canonical
            # action参照を本文と同様にmaskしてcredential policyから逃がさない。
            $activeLineMask[$index] = $true
            # compact sequenceの`- `もmapping key columnに含める。raw先頭indentを
            # 境界にすると、同じstepのuses/withをscalar本文と誤認してしまう。
            $sequenceIndentLength = if ($Matches.ContainsKey('sequence')) {
                $Matches['sequence'].Length
            } else {
                0
            }
            $blockScalarHeaderIndent = (
                $Matches['leading'].Length + $sequenceIndentLength
            )
            continue
        }

        # mapping valueまたはsequence scalarがquoteで始まり同じphysical lineで
        # 閉じない場合だけcontinuation stateへ入る。header自体はactiveに残す。
        $mappingQuoteStart = [regex]::Match(
            $line,
            '^\s*(?:-\s+)?' +
            '(?:[A-Za-z0-9_.-]+|''[^'']+''|"[^"]+")\s*:\s*' +
            '(?<quote>["''])'
        )
        $sequenceQuoteStart = [regex]::Match(
            $line,
            '^\s*-\s+(?<quote>["''])'
        )
        $quoteStart = if ($mappingQuoteStart.Success) {
            $mappingQuoteStart
        } else {
            $sequenceQuoteStart
        }
        if ($quoteStart.Success) {
            $openingQuoteIndex = $quoteStart.Groups['quote'].Index
            $quote = [char]$quoteStart.Groups['quote'].Value
            $closingQuoteIndex = Find-WorkflowQuotedScalarClosingIndex `
                -Line $line `
                -OpeningQuoteIndex $openingQuoteIndex `
                -Quote $quote
            if ($closingQuoteIndex -lt 0) {
                $activeLineMask[$index] = $true
                $quotedScalarQuote = $quote
                continue
            }
        }

        # non-empty plain mapping valueだけをcontinuation候補にする。empty value、
        # quoted/block/flow/tag/anchor/alias presentationは既存policyへ委ねる。
        $plainScalarStart = [regex]::Match(
            $line,
            '^(?<leading>\s*)(?<sequence>-\s+)?' +
            '(?:[A-Za-z0-9_.-]+|''[^'']+''|"[^"]+")\s*:\s+' +
            '(?<value>[^\s"''>|\{\[!&*#].*)$'
        )
        if ($plainScalarStart.Success) {
            $activeLineMask[$index] = $true
            $plainScalarHeaderIndent = (
                $plainScalarStart.Groups['leading'].Length +
                $plainScalarStart.Groups['sequence'].Length
            )
            continue
        }

        # bare sequenceのplain scalarも複数physical lineへ継続できる。compact
        # mapping（`- key:`）はempty/comment valueを含めて先に除外し、そのchild
        # mappingをscalar本文として隠さない。
        $compactMappingStart = $line -match (
            '^\s*-\s+' +
            '(?:[A-Za-z0-9_.-]+|''[^'']+''|"[^"]+")\s*:(?:\s|$)'
        )
        $plainSequenceScalarStart = [regex]::Match(
            $line,
            '^(?<leading>\s*)-\s+' +
            '(?<value>(?!(?:[-?:](?:\s|$)))' +
            '[^\s"''>|\{\[!&*#].*)$'
        )
        if (-not $compactMappingStart -and
            $plainSequenceScalarStart.Success) {
            $activeLineMask[$index] = $true
            $plainScalarHeaderIndent = (
                $plainSequenceScalarStart.Groups['leading'].Length
            )
            continue
        }

        # single-line run valueは実行文字列であり、uses/anchor/escapeのYAML key
        # 構文ではない。一方でstep境界は保持し、child走査が次stepを越えない。
        if ($line -cmatch '^\s*(?:-\s+)?run\s*:') {
            $activeLineMask[$index] = $true
            continue
        }

        $activeLineMask[$index] = $true
    }

    return $activeLineMask
}

function Get-WorkflowCanonicalUsesLexicalResult {
    param(
        [string[]]$Lines
    )

    $activeLineMask = Get-WorkflowActiveMappingLineMask -Lines $Lines
    $canonicalUses = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if (-not $activeLineMask[$index]) {
            continue
        }
        $line = $Lines[$index]
        $trimmedLine = $line.TrimStart()
        if ([string]::IsNullOrWhiteSpace($trimmedLine) -or
            $trimmedLine.StartsWith('#')) {
            continue
        }

        # explicit document markerとdirectiveは、同一行のflow nodeやparser optionを
        # lexical policyの前へ持ち込めるため、このrepositoryでは全面unsupported。
        if ($line -match '^\s*(?:---|\.\.\.)(?:\s|$)' -or
            $line -match '^\s*%') {
            return [pscustomobject]@{ IsValid = $false; Uses = @() }
        }

        # explicit tagはstandard/customを問わずnodeのsemantic型を変え、flow
        # collection policyを迂回できるためpresentationごと拒否する。式内`!`、
        # quoted scalar、comment中の`!`はnode開始ではない。runでもvalue先頭が
        # tagならshell文字列ではなくYAML node propertyなので、skip前に拒否する。
        # custom tag suffixの文字集合はYAML URI escape（例: !%66oo）も許す。
        # suffixを列挙せず、node開始位置の`!` indicator自体を一律拒否する。
        $tagTokenPattern = '!'
        $nodeStartsExplicitTag = $line -match (
            '^\s*(?:---\s+)?(?:-\s+)?' + $tagTokenPattern
        )
        $mappingValueStartsExplicitTag = $line -match (
            '^\s*(?:-\s+)?' +
            '(?:[A-Za-z0-9_.-]+|''[^'']+''|"[^"]+")\s*:\s*' +
            $tagTokenPattern
        )
        if ($nodeStartsExplicitTag -or
            $mappingValueStartsExplicitTag) {
            return [pscustomobject]@{ IsValid = $false; Uses = @() }
        }

        # flow collectionはquoted scalar内の#やnested mapping/sequenceをlexicalに
        # 安全復元できない。collection自体またはmapping valueが[`{`/`[`]で始まる
        # 場合を拒否する。`${{ ... }}`・quoted value・commentは該当しない。
        # runのvalueがflowならshell scalarではなくcollectionなのでskip前に拒否する。
        $startsFlowCollection = $line -match '^\s*(?:-\s+)?[\{\[]'
        $mappingValueStartsFlowCollection = $line -match (
            '^\s*(?:-\s+)?' +
            '(?:[A-Za-z0-9_.-]+|''[^'']+''|"[^"]+")\s*:\s*[\{\[]'
        )
        if ($startsFlowCollection -or $mappingValueStartsFlowCollection) {
            return [pscustomobject]@{ IsValid = $false; Uses = @() }
        }

        # anchor/aliasはnode propertyまたはnodeそのものとして開始する位置だけを
        # 検査する。quoted scalarやinline comment中の`&` / `*`はYAML構造ではない。
        $nodeStartsAnchorOrAlias = $line -match '^\s*(?:-\s+)?[&*]'
        $mappingValueStartsAnchorOrAlias = $line -match (
            '^\s*(?:-\s+)?' +
            '(?:[A-Za-z0-9_.-]+|''[^'']+''|"[^"]+")\s*:\s*[&*]'
        )
        if ($nodeStartsAnchorOrAlias -or
            $mappingValueStartsAnchorOrAlias) {
            return [pscustomobject]@{ IsValid = $false; Uses = @() }
        }

        # run scalarのshell文字列はuses検査から除外する。ただし上でtag / flow /
        # anchor / alias presentationを先に拒否し、matrix等の任意`run` keyを使って
        # semantic action mappingを隠せない順序にする。
        if ($line -cmatch '^\s*(?:-\s+)?run\s*:') {
            continue
        }

        # explicit keyとescaped double-quoted mapping keyはsemanticなuses / with /
        # credential keyをraw textから隠せる。quoted valueやinline commentの
        # backslashは構造ではないため、mapping key部分だけを対象にする。
        $doubleQuotedMappingKey = [regex]::Match(
            $line,
            '^\s*(?:-\s+)?"(?<key>(?:[^"\\]|\\.)*)"\s*:'
        )
        $hasEscapedDoubleQuotedMappingKey = (
            $doubleQuotedMappingKey.Success -and
            $doubleQuotedMappingKey.Groups['key'].Value.Contains('\')
        )
        if ($line -match '^\s*(?:-\s+)?\?(?:\s|$)' -or
            $hasEscapedDoubleQuotedMappingKey) {
            return [pscustomobject]@{ IsValid = $false; Uses = @() }
        }

        $directUsesKey = [regex]::Match(
            $line,
            '^\s*(?:-\s+)?(?:(?<quoted>"uses"|''uses'')|uses)\s*:'
        )
        if (-not $directUsesKey.Success) {
            continue
        }

        # active usesはunquotedで一行完結し、external actionならfull SHAにpinした
        # canonical mappingだけを許可する。quoted/folded/flow表記をdecodeしない。
        if (-not [string]::IsNullOrEmpty(
                $directUsesKey.Groups['quoted'].Value
            )) {
            return [pscustomobject]@{ IsValid = $false; Uses = @() }
        }
        $canonicalUse = [regex]::Match(
            $line,
            '^\s*(?:-\s+)?uses: (?<reference>[^\s#]+)(?:[ \t]+#.*)?[ \t]*$'
        )
        if (-not $canonicalUse.Success) {
            return [pscustomobject]@{ IsValid = $false; Uses = @() }
        }
        $reference = $canonicalUse.Groups['reference'].Value
        if ($reference.StartsWith('./', [StringComparison]::Ordinal)) {
            $canonicalUses.Add([pscustomobject]@{
                LineIndex = $index
                Reference = $reference
            }) | Out-Null
            continue
        }
        if ($reference -cnotmatch (
                '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' +
                '(?:/[A-Za-z0-9_.-]+)*@[0-9a-f]{40}$'
            )) {
            return [pscustomobject]@{ IsValid = $false; Uses = @() }
        }
        $canonicalUses.Add([pscustomobject]@{
            LineIndex = $index
            Reference = $reference
        }) | Out-Null
    }

    return [pscustomobject]@{
        IsValid = $true
        Uses = @($canonicalUses | ForEach-Object { $_ })
    }
}

function Test-WorkflowUsesLexicalPolicyContent {
    param(
        [string[]]$Lines
    )

    return (Get-WorkflowCanonicalUsesLexicalResult -Lines $Lines).IsValid
}

function Test-WorkflowCheckoutCredentialPolicyContent {
    param(
        [string[]]$Lines
    )

    # checkout判定より先に全active usesをlexicalに固定する。escapeされた
    # actions/checkoutがraw substring検査をすり抜けることを許可しない。
    $lexicalResult = Get-WorkflowCanonicalUsesLexicalResult -Lines $Lines
    if (-not $lexicalResult.IsValid) {
        return $false
    }

    $canonicalCheckoutPattern = (
        '^(?<leading> *)(?<sequence>- )?' +
        'uses: actions/checkout@[0-9a-f]{40} # v5$'
    )
    $withKeyPattern = '(?i)^(?:with|''with''|"with")\s*:'
    $credentialKeyPattern = '(?i)^(?:persist-credentials|''persist-credentials''|"persist-credentials")\s*:'
    $activeLineMask = Get-WorkflowActiveMappingLineMask -Lines $Lines

    foreach ($canonicalUse in $lexicalResult.Uses) {
        # exact owner/repository参照だけをcheckout hardening対象にする。suffix名や
        # repository-local actionをsubstringで誤認しない。
        if ($canonicalUse.Reference -notmatch (
                '^actions/checkout@[0-9a-f]{40}$'
            )) {
            continue
        }
        # GitHub action参照はowner/repositoryの大小文字を同一視し得る。公式checkout
        # にcase-insensitiveで一致した場合は、lowercase canonical表記以外を拒否する。
        if ($canonicalUse.Reference -cnotmatch (
                '^actions/checkout@[0-9a-f]{40}$'
            )) {
            return $false
        }
        $index = $canonicalUse.LineIndex
        $line = $Lines[$index]

        if ($line -cnotmatch $canonicalCheckoutPattern) {
            return $false
        }

        $checkoutSequenceIndentLength = if ($Matches.ContainsKey('sequence')) {
            $Matches['sequence'].Length
        } else {
            0
        }
        $usesIndent = ' ' * (
            $Matches['leading'].Length + $checkoutSequenceIndentLength
        )
        $withIndent = $usesIndent + '  '
        if (($index + 2) -ge $Lines.Count -or
            $Lines[$index + 1] -cne "${usesIndent}with:" -or
            $Lines[$index + 2] -cne "${withIndent}persist-credentials: false") {
            return $false
        }

        # step境界まで同階層propertyを追跡する。後続の同階層withはYAMLで
        # 後勝ちになり得るため、最初の設定だけを確認して早期breakしない。
        $withKeyCount = 0
        $credentialKeyCount = 0
        $currentMappingKey = $null
        for ($childIndex = $index + 1; $childIndex -lt $Lines.Count; $childIndex++) {
            if (-not $activeLineMask[$childIndex]) {
                continue
            }
            $childLine = $Lines[$childIndex]
            if ([string]::IsNullOrWhiteSpace($childLine) -or
                $childLine.TrimStart().StartsWith('#')) {
                continue
            }
            $childIndentLength = $childLine.Length - $childLine.TrimStart().Length
            if ($childIndentLength -lt $usesIndent.Length) {
                break
            }
            if ($childIndentLength -eq $usesIndent.Length) {
                $stepKey = $childLine.Substring($usesIndent.Length)
                if ($stepKey -match $withKeyPattern) {
                    $withKeyCount++
                    $currentMappingKey = 'with'
                } else {
                    $currentMappingKey = $null
                }
                continue
            }
            if ($currentMappingKey -eq 'with' -and
                $childIndentLength -eq $withIndent.Length) {
                $childKey = $childLine.Substring($withIndent.Length)
                if ($childKey -match $credentialKeyPattern) {
                    $credentialKeyCount++
                }
            }
        }
        if ($withKeyCount -ne 1 -or $credentialKeyCount -ne 1) {
            return $false
        }
    }

    # checkoutを使わないworkflow自体は許容する。一方で参照が1件でもあれば、
    # 上のcanonical + same-step契約を必ず通過しなければならない。
    return $true
}

function Test-WorkflowCheckoutCredentialContractContent {
    param(
        [string[]]$Lines,
        [hashtable]$ExpectedJobs
    )

    # 固定3jobの完全block契約に加え、将来追加される全workflow/jobのcheckoutも
    # generic policyで検査する。既存jobの厳格さと拡張時の取りこぼしを両立する。
    if (-not (Test-WorkflowCheckoutCredentialPolicyContent -Lines $Lines)) {
        return $false
    }
    foreach ($jobName in @('validate', 'validate-ubuntu', 'validate-macos')) {
        if (-not (Test-WorkflowJobBlockExactContent `
                -Lines $Lines `
                -JobName $jobName `
                -ExpectedBlock $ExpectedJobs[$jobName])) {
            return $false
        }
    }

    return $true
}

function Assert-WorkflowCheckoutCredentialValidatorRegressions {
    param(
        [string]$RelativePath,
        [hashtable]$ExpectedJobs
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return
    }

    $lines = @(Get-Content -LiteralPath $filePath)
    if (-not (Test-WorkflowCheckoutCredentialContractContent `
            -Lines $lines `
            -ExpectedJobs $ExpectedJobs)) {
        return
    }

    $trimCharacters = [char[]]@("`r", "`n")
    $workflowText = ($lines -join "`n").TrimEnd($trimCharacters)
    $checkoutStep = @'
      - name: Check out repository
        uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
        with:
          persist-credentials: false
'@
    $checkoutStep = $checkoutStep.Replace("`r`n", "`n").TrimEnd($trimCharacters)
    $credentialBlock = @'
        with:
          persist-credentials: false
'@
    $credentialBlock = $credentialBlock.Replace("`r`n", "`n").TrimEnd($trimCharacters)

    # fixture生成前に、全checkoutが同じbare設定を持つ基準状態を確認する。
    if ((Get-OrdinalFragmentCount -Content $workflowText -Fragment $checkoutStep) -ne 3 -or
        (Get-OrdinalFragmentCount -Content $workflowText -Fragment $credentialBlock) -ne 3) {
        Add-Failure 'Workflow checkout credential mutation fixture could not be constructed.'
        return
    }

    $mutations = @()
    # 全設定を除去した場合と、3件中1件だけを除去した場合を分けて検査する。
    $mutations += @{ Name = 'missing credential persistence settings'; Text = $workflowText.Replace($credentialBlock, '') }
    $firstCredentialOffset = $workflowText.IndexOf(
        $credentialBlock,
        [System.StringComparison]::Ordinal
    )
    $mutations += @{
        Name = 'one checkout missing credential persistence setting'
        Text = $workflowText.Remove($firstCredentialOffset, $credentialBlock.Length)
    }

    # 値の有効化、誤インデント、後続stepへの借用をいずれも受理しない。
    $mutations += @{
        Name = 'enabled credential persistence'
        Text = $workflowText.Remove($firstCredentialOffset, $credentialBlock.Length).Insert(
            $firstCredentialOffset,
            "        with:`n          persist-credentials: true"
        )
    }
    $mutations += @{
        Name = 'misplaced credential persistence setting'
        Text = $workflowText.Remove($firstCredentialOffset, $credentialBlock.Length).Insert(
            $firstCredentialOffset,
            "          with:`n            persist-credentials: false"
        )
    }
    $withoutFirstCredential = $workflowText.Remove(
        $firstCredentialOffset,
        $credentialBlock.Length
    )
    $firstValidationStep = "      - name: Validate OSS readiness`n        shell: pwsh"
    $borrowedCredentialStep = "      - name: Validate OSS readiness`n        with:`n          persist-credentials: false`n        shell: pwsh"
    if ($withoutFirstCredential.IndexOf(
            $firstValidationStep,
            [System.StringComparison]::Ordinal
        ) -lt 0) {
        Add-Failure 'Workflow later-step credential mutation was ineffective.'
    } else {
        $mutations += @{
            Name = 'credential persistence borrowed by a later step'
            Text = $withoutFirstCredential.Replace(
                $firstValidationStep,
                $borrowedCredentialStep
            )
        }
    }

    # bare / 大小文字違い / 引用符付きの重複keyはYAML解釈差を生むため拒否する。
    foreach ($duplicateKey in @(
            'persist-credentials',
            'Persist-Credentials',
            "'persist-credentials'",
            '"persist-credentials"'
        )) {
        $mutations += @{
            Name = "duplicate credential persistence key ($duplicateKey)"
            Text = $workflowText.Remove(
                $firstCredentialOffset,
                $credentialBlock.Length
            ).Insert(
                $firstCredentialOffset,
                "        with:`n          persist-credentials: false`n          ${duplicateKey}: false"
            )
        }
    }

    foreach ($mutation in $mutations) {
        if ($mutation.Text -ceq $workflowText) {
            Add-Failure "Workflow $($mutation.Name) mutation was ineffective."
            continue
        }
        $mutatedLines = $mutation.Text.Split(
            [string[]]@("`n"),
            [System.StringSplitOptions]::None
        )
        if (Test-WorkflowCheckoutCredentialContractContent `
                -Lines $mutatedLines `
                -ExpectedJobs $ExpectedJobs) {
            Add-Failure "Workflow checkout validator accepted $($mutation.Name)."
        }
    }
}

function Assert-WorkflowCheckoutCredentialPolicy {
    $workflowDirectory = Get-RepoFilePath -RelativePath '.github/workflows'
    if (-not (Test-Path -LiteralPath $workflowDirectory -PathType Container)) {
        Add-Failure 'Cannot inspect missing workflow directory: .github/workflows'
        return
    }

    $workflowFiles = @(
        Get-ChildItem -LiteralPath $workflowDirectory -File |
            Where-Object { $_.Extension -in @('.yml', '.yaml') } |
            Sort-Object -Property Name
    )
    if ($workflowFiles.Count -eq 0) {
        Add-Failure 'No GitHub Actions workflow YAML files were found.'
        return
    }

    foreach ($workflowFile in $workflowFiles) {
        $lines = @(Get-Content -LiteralPath $workflowFile.FullName)
        if (-not (Test-WorkflowCheckoutCredentialPolicyContent -Lines $lines)) {
            Add-Failure "Workflow checkout credential policy failed: .github/workflows/$($workflowFile.Name)"
        }
    }
}

function Assert-WorkflowCheckoutCredentialPolicyRegressions {
    $canonicalCheckout = '        uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5'
    $credentialWith = '        with:'
    $credentialFalse = '          persist-credentials: false'
    $canonicalFixture = @(
        'jobs:',
        '  validate:',
        '    steps:',
        '      - name: Check out repository',
        $canonicalCheckout,
        $credentialWith,
        $credentialFalse
    )
    if (-not (Test-WorkflowCheckoutCredentialPolicyContent -Lines $canonicalFixture)) {
        Add-Failure 'Workflow checkout generic policy rejected its canonical fixture.'
        return
    }

    # single-line run headerはlexical value検査の対象外でも、step境界としてactiveに
    # 残す。この責務分離をmaskとlexical resultの双方から直接固定する。
    $singleRunMaskFixture = @(
        'steps:',
        '  - run: Write-Output "fixture\temp actions/checkout@v5"'
    )
    $singleRunMask = Get-WorkflowActiveMappingLineMask -Lines $singleRunMaskFixture
    if ($singleRunMask.Count -ne $singleRunMaskFixture.Count -or
        -not $singleRunMask[1]) {
        Add-Failure 'Workflow active-line mask hid a single-line run step boundary.'
    }
    if (-not (Test-WorkflowUsesLexicalPolicyContent `
            -Lines $singleRunMaskFixture)) {
        Add-Failure 'Workflow lexical policy inspected a single-line run value.'
    }
    $safeTagLikeFixture = @(
        'if: ${{ !cancelled() }}',
        "pattern: '!pattern'",
        '# !custom comment',
        'run: Write-Output "!custom run value"'
    )
    if (-not (Test-WorkflowUsesLexicalPolicyContent `
            -Lines $safeTagLikeFixture)) {
        Add-Failure 'Workflow lexical policy rejected a non-tag exclamation value.'
    }

    # inline commentとquoted scalar本文の`&` / `*` / backslashはYAML構造ではない。
    # canonical usesの末尾commentも含め、node開始位置だけをguardする責務を固定する。
    $safeStructuralTextFixtures = @(
        @{ Name = 'quoted anchor-like text'; Lines = @('name: "Build &release *alias"') },
        @{ Name = 'quoted escaped path text'; Lines = @('name: "fixture\\temp"') },
        @{ Name = 'uses inline anchor-like comment'; Lines = @('uses: owner/action@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # build &release') },
        @{ Name = 'inline escaped-path comment'; Lines = @('name: Build # path "fixture\temp"') },
        @{ Name = 'single-line run structural text'; Lines = @('run: Write-Output "&release [safe] *alias"') },
        @{ Name = 'dash-prefixed tag-like plain text'; Lines = @('-!important') },
        @{ Name = 'dash-prefixed flow-like plain text'; Lines = @('-[safe]') },
        @{ Name = 'dash-prefixed anchor-like plain text'; Lines = @('-&release') },
        @{ Name = 'dash-prefixed quoted-like plain text'; Lines = @('-"quoted"') },
        @{ Name = 'dash-prefixed run mapping key'; Lines = @('-run: plain text') },
        @{ Name = 'dash-prefixed uses mapping key'; Lines = @('-uses: plain text') }
    )
    foreach ($safeStructuralTextFixture in $safeStructuralTextFixtures) {
        if (-not (Test-WorkflowUsesLexicalPolicyContent `
                -Lines $safeStructuralTextFixture.Lines)) {
            Add-Failure "Workflow lexical policy rejected $($safeStructuralTextFixture.Name)."
        }
    }

    # multiline quoted scalarはheaderだけactive、閉じquoteを含むphysical lineまで
    # continuationをinactiveにする。double escapeとsingle doubled quoteも終端ではない。
    $multilineQuotedFixtures = @(
        @{ Name = 'multiline name with escaped quotes'; Lines = @('name: "Build', '  \"quoted\" [safe] {', '  !important actions/checkout@v5"', 'next: safe') },
        @{ Name = 'multiline run value'; Lines = @('run: "echo', '  [safe] { !important', '  actions/checkout@v5"', 'next: safe') },
        @{ Name = 'multiline single-quoted name'; Lines = @("name: 'Build", "  ''quoted'' { !important", "  actions/checkout@v5'", 'next: safe') }
    )
    foreach ($multilineQuotedFixture in $multilineQuotedFixtures) {
        $quotedMask = Get-WorkflowActiveMappingLineMask `
            -Lines $multilineQuotedFixture.Lines
        if (-not $quotedMask[0] -or
            $quotedMask[1] -or
            $quotedMask[2] -or
            -not $quotedMask[3]) {
            Add-Failure "Workflow quoted-scalar mask failed $($multilineQuotedFixture.Name)."
        }
        if (-not (Test-WorkflowUsesLexicalPolicyContent `
                -Lines $multilineQuotedFixture.Lines)) {
            Add-Failure "Workflow lexical policy rejected $($multilineQuotedFixture.Name)."
        }
    }

    # dotを含むbare mapping keyもYAML/GitHub envで有効。literal/folded/compact
    # sequenceの各headerを認識し、flow/tag風本文だけをinactiveにする。
    $dottedBlockScalarFixtures = @(
        @{ Name = 'dotted literal key'; Lines = @('env:', '  DOT.KEY: |', '    [safe] { !important', '  NEXT: safe') },
        @{ Name = 'dotted folded key'; Lines = @('env:', '  DOT.KEY: >-', '    actions/checkout@v5 [safe]', '  NEXT: safe') },
        @{ Name = 'dotted compact sequence key'; Lines = @('items:', '  - DOT.KEY: |2+', '      !important { [safe]', '    NEXT: safe') },
        @{ Name = 'bare sequence block scalar'; Lines = @('values:', '  - |2-', '    [safe] { !important uses: actions/checkout@v5', '  - next') }
    )
    foreach ($dottedBlockScalarFixture in $dottedBlockScalarFixtures) {
        $dottedMask = Get-WorkflowActiveMappingLineMask `
            -Lines $dottedBlockScalarFixture.Lines
        if (-not $dottedMask[1] -or
            $dottedMask[2] -or
            -not $dottedMask[3]) {
            Add-Failure "Workflow block-scalar mask failed $($dottedBlockScalarFixture.Name)."
        }
        if (-not (Test-WorkflowUsesLexicalPolicyContent `
                -Lines $dottedBlockScalarFixture.Lines)) {
            Add-Failure "Workflow lexical policy rejected $($dottedBlockScalarFixture.Name)."
        }
    }

    # multiline plain scalarはmapping/compact name/run/envのいずれでも、深い継続行を
    # blank/comment越しにinactive化し、equal-indent/dedent mappingへ復帰する。
    $plainScalarFixtures = @(
        @{ Name = 'plain mapping value'; Lines = @('name: Build', '', '  # continuation comment', '  [safe] { !important uses: actions/checkout@v5', 'next: safe'); Inactive = @(1, 2, 3); Active = @(0, 4) },
        @{ Name = 'plain hash without comment separation'; Lines = @('name: key:#not-comment', '  [safe]', 'next: safe'); Inactive = @(1); Active = @(0, 2) },
        @{ Name = 'plain compact name'; Lines = @('steps:', '  - name: Build', '      { !important uses: actions/checkout@v5', '    shell: pwsh'); Inactive = @(2); Active = @(1, 3) },
        @{ Name = 'plain bare sequence value'; Lines = @('values:', '  - alpha', '    [beta] { !important uses: actions/checkout@v5', '  - omega'); Inactive = @(2); Active = @(1, 3) },
        @{ Name = 'plain run value'; Lines = @('run: echo', '  !important { uses: actions/checkout@v5', 'next: safe'); Inactive = @(1); Active = @(0, 2) },
        @{ Name = 'plain env value'; Lines = @('env:', '  DOT.KEY: safe', '', '    # continuation comment', '    uses: actions/checkout@v5 [safe]', '  NEXT: safe'); Inactive = @(2, 3, 4); Active = @(1, 5) }
    )
    foreach ($plainScalarFixture in $plainScalarFixtures) {
        $plainMask = Get-WorkflowActiveMappingLineMask -Lines $plainScalarFixture.Lines
        foreach ($inactiveIndex in $plainScalarFixture.Inactive) {
            if ($plainMask[$inactiveIndex]) {
                Add-Failure "Workflow plain-scalar mask exposed $($plainScalarFixture.Name)."
            }
        }
        foreach ($activeIndex in $plainScalarFixture.Active) {
            if (-not $plainMask[$activeIndex]) {
                Add-Failure "Workflow plain-scalar mask hid dedent for $($plainScalarFixture.Name)."
            }
        }
        if (-not (Test-WorkflowUsesLexicalPolicyContent `
                -Lines $plainScalarFixture.Lines)) {
            Add-Failure "Workflow lexical policy rejected $($plainScalarFixture.Name)."
        }
    }

    # `key: # comment`はnon-empty plain scalarではなくnull valueとcommentである。
    # child checkoutをscalar本文として隠さず、通常のmappingとして全行を検査する。
    $nullCommentCheckoutFixture = @(
        'steps: # hidden',
        '  - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5',
        '    with:',
        '      persist-credentials: false'
    )
    $nullCommentMask = Get-WorkflowActiveMappingLineMask `
        -Lines $nullCommentCheckoutFixture
    if (@($nullCommentMask | Where-Object { -not $_ }).Count -ne 0) {
        Add-Failure 'Workflow plain-scalar mask hid null-comment mapping children.'
    }
    if (-not (Test-WorkflowCheckoutCredentialPolicyContent `
            -Lines $nullCommentCheckoutFixture)) {
        Add-Failure 'Workflow checkout policy rejected safe null-comment mapping children.'
    }
    $nullCommentSequenceCheckoutFixture = @(
        'steps:',
        '  - # hidden',
        '    uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5',
        '    with:',
        '      persist-credentials: false'
    )
    $nullCommentSequenceMask = Get-WorkflowActiveMappingLineMask `
        -Lines $nullCommentSequenceCheckoutFixture
    if (@($nullCommentSequenceMask | Where-Object { -not $_ }).Count -ne 0) {
        Add-Failure 'Workflow plain-scalar mask hid null-comment sequence children.'
    }
    if (-not (Test-WorkflowCheckoutCredentialPolicyContent `
            -Lines $nullCommentSequenceCheckoutFixture)) {
        Add-Failure 'Workflow checkout policy rejected safe null-comment sequence children.'
    }

    # run block scalar本文はYAML mappingではない。パス、PowerShell call演算子、
    # actions名らしい文字列を含んでもuses/anchor/escapeのpolicy対象にしない。
    $safeRunFixtures = @(
        @{ Name = 'literal run path'; Lines = @($canonicalFixture + @('      - name: Script', '        run: |', '          Write-Output "fixture\temp"')) },
        @{ Name = 'literal run call operator'; Lines = @($canonicalFixture + @('      - name: Script', '        run: |-', '          & ./scripts/build.ps1')) },
        @{ Name = 'literal run checkout text'; Lines = @($canonicalFixture + @('      - name: Script', '        run: >2-', "          Write-Output 'actions/checkout@v5'")) },
        @{ Name = 'single-line run value'; Lines = @($canonicalFixture + @('      - name: Script', '        run: Write-Output "fixture\temp uses: plain text"')) }
    )
    foreach ($safeRunFixture in $safeRunFixtures) {
        if (-not (Test-WorkflowCheckoutCredentialPolicyContent `
                -Lines $safeRunFixture.Lines)) {
            Add-Failure "Workflow checkout generic policy rejected $($safeRunFixture.Name)."
        }
    }

    # inline runはvalueをlexical検査しないが、activeなstep境界ではある。先行checkout
    # のchild走査がrunを越えて次actionのwithを借用しないことを固定する。
    $singleRunBoundaryFixture = @(
        $canonicalFixture +
        '      - run: Write-Output "fixture\temp actions/checkout@v5"' +
        '      - name: Next checkout' +
        $canonicalCheckout +
        $credentialWith +
        $credentialFalse
    )
    if (-not (Test-WorkflowCheckoutCredentialPolicyContent `
            -Lines $singleRunBoundaryFixture)) {
        Add-Failure 'Workflow checkout generic policy rejected a single-line run step boundary.'
    }

    # compact sequenceのscalar headerはraw indentではなくkey columnで閉じる。本文の
    # dedent後に同step siblingとして続くcheckoutを必ず再び検査対象へ戻す。
    $compactScalarPrefix = @(
        'jobs:',
        '  validate:',
        '    steps:',
        '      - name: >-',
        '          compact scalar display name'
    )
    $compactExplicitIndentPrefix = @(
        'jobs:',
        '  validate:',
        '    steps:',
        '      - name: |2+',
        '          compact explicit indent display name'
    )
    foreach ($compactScalarFixture in @(
            @{ Name = 'compact scalar then checkout'; Lines = @($compactScalarPrefix + $canonicalCheckout + $credentialWith + $credentialFalse) },
            @{ Name = 'compact explicit scalar then checkout'; Lines = @($compactExplicitIndentPrefix + $canonicalCheckout + $credentialWith + $credentialFalse) }
        )) {
        if (-not (Test-WorkflowCheckoutCredentialPolicyContent `
                -Lines $compactScalarFixture.Lines)) {
            Add-Failure "Workflow checkout generic policy rejected $($compactScalarFixture.Name)."
        }
    }

    # blank/content-indent commentはscalar本文に留まり、key-column commentでdedent
    # した後のcanonical mappingはactiveへ戻る。
    $scalarCommentRecoveryFixture = @(
        'jobs:',
        '  validate:',
        '    steps:',
        '      - name: >2-',
        '          scalar body',
        '',
        '          # content-indent comment',
        '        # key-column comment closes scalar body',
        $canonicalCheckout,
        $credentialWith,
        $credentialFalse
    )
    if (-not (Test-WorkflowCheckoutCredentialPolicyContent `
            -Lines $scalarCommentRecoveryFixture)) {
        Add-Failure 'Workflow checkout generic policy did not recover after scalar comments.'
    }
    $scalarCommentRecoveryMask = Get-WorkflowActiveMappingLineMask `
        -Lines $scalarCommentRecoveryFixture
    if ($scalarCommentRecoveryMask[5] -or
        $scalarCommentRecoveryMask[6] -or
        -not $scalarCommentRecoveryMask[7] -or
        -not $scalarCommentRecoveryMask[8]) {
        Add-Failure (
            'Workflow active-line mask did not distinguish blank/content comments ' +
            'from key-column comment and dedented checkout.'
        )
    }

    # scalar本文にescape/anchor風文字列を置き、本文maskが実際にlexical guardから
    # 隔離していることをchomp/explicit-indent双方で証明する。
    foreach ($maskedScalarFixture in @(
            @{ Name = 'folded escaped scalar body'; Lines = @('jobs:', '  validate:', '    steps:', '      - name: >2-', '          "actions/\u0063heckout@v5"', $canonicalCheckout, $credentialWith, $credentialFalse) },
            @{ Name = 'literal anchored scalar body'; Lines = @('jobs:', '  validate:', '    steps:', '      - name: |2+', '          &checkout_alias actions/checkout@v5', $canonicalCheckout, $credentialWith, $credentialFalse) }
        )) {
        if (-not (Test-WorkflowCheckoutCredentialPolicyContent `
                -Lines $maskedScalarFixture.Lines)) {
            Add-Failure "Workflow checkout generic policy inspected $($maskedScalarFixture.Name)."
        }
    }

    # path末尾だけがcheckoutのlocal/third-party actionは公式actionではない。
    # lexical pin policyを通す限り、公式checkout専用inputを要求しない。
    $nonOfficialCheckoutFixtures = @(
        @{ Name = 'local checkout-named action'; Lines = @('steps:', '  - uses: ./actions/checkout') },
        @{ Name = 'third-party checkout-named action'; Lines = @('steps:', '  - uses: my-actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09') }
    )
    foreach ($nonOfficialCheckoutFixture in $nonOfficialCheckoutFixtures) {
        if (-not (Test-WorkflowCheckoutCredentialPolicyContent `
                -Lines $nonOfficialCheckoutFixture.Lines)) {
            Add-Failure "Workflow checkout generic policy rejected $($nonOfficialCheckoutFixture.Name)."
        }
    }

    $compactCanonicalCheckoutFixture = @(
        'steps:',
        '  - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5',
        '    with:',
        '      persist-credentials: false'
    )
    if (-not (Test-WorkflowCheckoutCredentialPolicyContent `
            -Lines $compactCanonicalCheckoutFixture)) {
        Add-Failure 'Workflow checkout generic policy rejected compact canonical checkout.'
    }

    # 追加workflow/jobも同じpolicyで検査する。4つ目のcheckoutを含むfixtureで
    # missing/true/misplaced/later-step borrowing/duplicate/非canonical usesを拒否する。
    $fourthCheckout = @(
        '  future-validation:',
        '    steps:',
        '      - name: Check out future repository',
        $canonicalCheckout,
        $credentialWith,
        $credentialFalse
    )
    $plainScalarBoundaryPrefix = @(
        'jobs:',
        '  validate:',
        '    steps:',
        '      - name: Build',
        '          safe scalar continuation',
        '',
        '          # continuation comment'
    )
    $plainSequenceBoundaryPrefix = @(
        'steps:',
        '  - safe',
        '    scalar continuation'
    )
    $mutations = @(
        @{ Name = 'fourth checkout missing credential setting'; Lines = @($canonicalFixture + @($fourthCheckout | Where-Object { $_ -cne $credentialWith -and $_ -cne $credentialFalse })) },
        @{ Name = 'plain scalar dedent checkout missing credential setting'; Lines = @($plainScalarBoundaryPrefix + $canonicalCheckout) },
        @{ Name = 'plain scalar dedent checkout enabled credential setting'; Lines = @($plainScalarBoundaryPrefix + $canonicalCheckout + $credentialWith + '          persist-credentials: true') },
        @{ Name = 'plain scalar dedent tag'; Lines = @($plainScalarBoundaryPrefix + '        !custom unsafe') },
        @{ Name = 'plain scalar dedent flow checkout'; Lines = @($plainScalarBoundaryPrefix + '        { uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 }') },
        @{ Name = 'plain sequence dedent checkout missing credential setting'; Lines = @($plainSequenceBoundaryPrefix + '  - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5') },
        @{ Name = 'plain sequence dedent checkout enabled credential setting'; Lines = @($plainSequenceBoundaryPrefix + '  - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5' + '    with:' + '      persist-credentials: true') },
        @{ Name = 'null-comment checkout missing credential setting'; Lines = @('steps: # hidden', '  - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5') },
        @{ Name = 'null-comment checkout enabled credential setting'; Lines = @('steps: # hidden', '  - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5', '    with:', '      persist-credentials: true') },
        @{ Name = 'null-comment sequence checkout missing credential setting'; Lines = @('steps:', '  - # hidden', '    uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5') },
        @{ Name = 'null-comment sequence checkout enabled credential setting'; Lines = @('steps:', '  - # hidden', '    uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5', '    with:', '      persist-credentials: true') },
        @{ Name = 'run-key flow anchor alias checkout'; Lines = @('strategy:', '  matrix:', '    run: [ &unsafe { uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 } ]', 'steps:', '  - *unsafe') },
        @{ Name = 'alias step node'; Lines = @('steps:', '  - *unsafe') },
        @{ Name = 'anchor mapping value'; Lines = @('steps: &unsafe checkout') },
        @{ Name = 'compact scalar checkout missing credential setting'; Lines = @($compactScalarPrefix + $canonicalCheckout) },
        @{ Name = 'compact scalar checkout enabled credential setting'; Lines = @($compactScalarPrefix + $canonicalCheckout + $credentialWith + '          persist-credentials: true') },
        @{ Name = 'compact explicit scalar checkout missing credential setting'; Lines = @($compactExplicitIndentPrefix + $canonicalCheckout) },
        @{ Name = 'compact explicit scalar checkout enabled credential setting'; Lines = @($compactExplicitIndentPrefix + $canonicalCheckout + $credentialWith + '          persist-credentials: true') },
        @{ Name = 'enabled credential setting'; Lines = @($canonicalFixture[0..5] + '          persist-credentials: true') },
        @{ Name = 'misplaced credential setting'; Lines = @($canonicalFixture[0..4] + '          with:' + '            persist-credentials: false') },
        @{ Name = 'later-step borrowed credential setting'; Lines = @($canonicalFixture[0..4] + @('      - name: Later step', $credentialWith, $credentialFalse)) },
        @{ Name = 'bare duplicate credential setting'; Lines = @($canonicalFixture + $credentialFalse) },
        @{ Name = 'case-variant duplicate credential setting'; Lines = @($canonicalFixture + '          Persist-Credentials: false') },
        @{ Name = 'single-quoted duplicate credential setting'; Lines = @($canonicalFixture + "          'persist-credentials': false") },
        @{ Name = 'double-quoted duplicate credential setting'; Lines = @($canonicalFixture + '          "persist-credentials": false') },
        @{ Name = 'bare duplicate with setting'; Lines = @($canonicalFixture + $credentialWith + '          persist-credentials: true') },
        @{ Name = 'single-quoted duplicate with setting'; Lines = @($canonicalFixture + "        'with':" + '          persist-credentials: true') },
        @{ Name = 'double-quoted duplicate with setting'; Lines = @($canonicalFixture + '        "with":' + '          persist-credentials: true') },
        @{ Name = 'case-variant duplicate with setting'; Lines = @($canonicalFixture + '        With:' + '          persist-credentials: true') },
        @{ Name = 'quoted checkout uses'; Lines = @($canonicalFixture[0..3] + "        uses: 'actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09'" + $canonicalFixture[5..6]) },
        @{ Name = 'escaped checkout missing credential setting'; Lines = @($canonicalFixture[0..3] + '        uses: "actions/\u0063heckout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09"') },
        @{ Name = 'escaped checkout enabled credential setting'; Lines = @($canonicalFixture[0..3] + '        uses: "actions/\u0063heckout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09"' + $credentialWith + '          persist-credentials: true') },
        @{ Name = 'escaped duplicate with key'; Lines = @($canonicalFixture + '        "w\u0069th":' + '          persist-credentials: true') },
        @{ Name = 'escaped duplicate credential key'; Lines = @($canonicalFixture + '          "persist-\u0063redentials": true') },
        @{ Name = 'anchor alias checkout uses'; Lines = @($canonicalFixture + 'checkout-reference: &checkout_action actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09' + 'extra-uses: *checkout_action') },
        @{ Name = 'explicit checkout uses key'; Lines = @($canonicalFixture + '? uses' + ': actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09') },
        @{ Name = 'multiline explicit checkout uses key'; Lines = @('steps:', '  - ?', '      uses', '    : actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5') },
        @{ Name = 'root multiline explicit checkout uses key'; Lines = @('?', '  uses', ': actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5') },
        @{ Name = 'folded checkout uses value'; Lines = @($canonicalFixture + 'uses: >' + '  actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09') },
        @{ Name = 'flow checkout uses mapping'; Lines = @($canonicalFixture + '{ uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 }') },
        @{ Name = 'flow checkout after quoted hash'; Lines = @($canonicalFixture + '      - { name: "safe#label", uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09, with: { persist-credentials: true } }') },
        @{ Name = 'flow steps sequence after quoted hash'; Lines = @($canonicalFixture + 'steps: [{ name: "safe#label", uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09, with: { persist-credentials: true } }]') },
        @{ Name = 'flow jobs mapping'; Lines = @($canonicalFixture + 'jobs: { build: { steps: [{ uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 }] } }') },
        @{ Name = 'unsupported benign flow trigger sequence'; Lines = @($canonicalFixture + 'on: [push]') },
        @{ Name = 'explicit standard sequence tag'; Lines = @($canonicalFixture + 'steps: !!seq [{ uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09, with: { persist-credentials: true } }]') },
        @{ Name = 'explicit standard mapping tag'; Lines = @($canonicalFixture + 'jobs: !!map { build: { steps: [{ uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 }] } }') },
        @{ Name = 'bare sequence tag'; Lines = @($canonicalFixture + 'steps: ! [{ uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09, with: { persist-credentials: true } }]') },
        @{ Name = 'bare mapping tag'; Lines = @($canonicalFixture + 'jobs: ! { build: { steps: [{ uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 }] } }') },
        @{ Name = 'percent-escaped mapping-value tag'; Lines = @($canonicalFixture + 'steps: !%66oo [{ uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09, with: { persist-credentials: true } }]') },
        @{ Name = 'percent-escaped sequence tag'; Lines = @($canonicalFixture + '- !%66oo [{ uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 }]') },
        @{ Name = 'percent-escaped node tag'; Lines = @($canonicalFixture + '!%66oo [{ uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 }]') },
        @{ Name = 'explicit custom tag'; Lines = @($canonicalFixture + 'steps: !custom [{ uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 }]') },
        @{ Name = 'explicit verbatim tag'; Lines = @($canonicalFixture + 'steps: !<tag:example.com,2026:steps> [{ uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 }]') },
        @{ Name = 'custom tag directive'; Lines = @($canonicalFixture + '%TAG !e! tag:example.com,2026:' + '--- !e!workflow' + 'steps: [{ uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 }]') },
        @{ Name = 'yaml directive'; Lines = @($canonicalFixture + '%YAML 1.2' + '---' + 'steps:' + '  - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09') },
        @{ Name = 'document marker flow mapping'; Lines = @($canonicalFixture + '--- { on: push, jobs: { build: { steps: [{ uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09, with: { persist-credentials: true } }] } } }') },
        @{ Name = 'document marker tagged mapping'; Lines = @($canonicalFixture + '--- !!map' + 'jobs: { build: { steps: [{ uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 }] } }') },
        @{ Name = 'unsupported flow run mapping'; Lines = @($canonicalFixture + '      - { run: "Write-Output safe" }') },
        @{ Name = 'quoted checkout uses key'; Lines = @($canonicalFixture[0..3] + '        "uses": actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09' + $canonicalFixture[5..6]) },
        @{ Name = 'colon-spaced checkout uses'; Lines = @($canonicalFixture[0..3] + '        uses : actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09' + $canonicalFixture[5..6]) },
        @{ Name = 'case-variant checkout uses'; Lines = @($canonicalFixture[0..3] + '        uses: Actions/Checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09' + $canonicalFixture[5..6]) }
    )
    foreach ($mutation in $mutations) {
        if (Test-WorkflowCheckoutCredentialPolicyContent -Lines $mutation.Lines) {
            Add-Failure "Workflow checkout generic policy accepted $($mutation.Name)."
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

function Get-GuardedNormalizationExpectedPatternCode {
    # destructive example全体をexact oracleにする。安全helperのdecoy化、target sourceの
    # 差替え、guard外sink追加を、部分的な文字列検査だけで見逃さないためである。
    return @'
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
'@
}

function Get-GuardedNormalizationPatternCode {
    param([string]$Source)

    if ([string]::IsNullOrWhiteSpace($Source)) {
        return $null
    }
    $normalizedSource = $Source.Replace("`r`n", "`n")
    $sectionMarker = '## The pattern' + "`n"
    $sectionStart = $normalizedSource.IndexOf(
        $sectionMarker,
        [System.StringComparison]::Ordinal
    )
    if ($sectionStart -lt 0) {
        return $null
    }
    $sectionEnd = $normalizedSource.IndexOf(
        "`n## ",
        $sectionStart + $sectionMarker.Length,
        [System.StringComparison]::Ordinal
    )
    if ($sectionEnd -lt 0) {
        return $null
    }
    $section = $normalizedSource.Substring(
        $sectionStart,
        $sectionEnd - $sectionStart
    )

    # 実行例をThe pattern内の唯一のPowerShell fenceへ閉じ込める。
    $fenceMarker = '```powershell' + "`n"
    if ((Get-OrdinalFragmentCount -Content $section -Fragment $fenceMarker) -ne 1) {
        return $null
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
        return $null
    }
    return $section.Substring($codeStart, $fenceEnd - $codeStart)
}

function Test-GuardedNormalizationPatternAstSafety {
    param([string]$FencedCode)

    if ([string]::IsNullOrWhiteSpace($FencedCode)) {
        return $false
    }
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $FencedCode,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
        return $false
    }

    # using/#requires/advanced-function blocksはEndBlock inventoryの外でmodule
    # import等を起動できる。PS5.1共通propertyだけでroot envelopeを閉じる。
    $cleanBlockProperty = $ast.PSObject.Properties['CleanBlock']
    if ($ast.Attributes.Count -ne 0 -or
        $ast.UsingStatements.Count -ne 0 -or
        $null -ne $ast.ScriptRequirements -or
        $null -ne $ast.ParamBlock -or
        $null -ne $ast.DynamicParamBlock -or
        $null -ne $ast.BeginBlock -or
        $null -ne $ast.ProcessBlock -or
        $null -eq $ast.EndBlock -or
        ($null -ne $cleanBlockProperty -and
            $null -ne $cleanBlockProperty.Value) -or
        -not $ast.EndBlock.Unnamed) {
        return $false
    }

    # Script scopeのtrap等はfixed fatalを横取りできるため、top-level inventoryを
    # exact化し、nestedを含むTrapStatementAstも明示的に0件へ固定する。
    $topLevelStatements = @($ast.EndBlock.Statements)
    [string[]]$expectedTopLevelTypes = @(
        'AssignmentStatementAst',
        'FunctionDefinitionAst',
        'FunctionDefinitionAst',
        'FunctionDefinitionAst',
        'FunctionDefinitionAst',
        'FunctionDefinitionAst',
        'FunctionDefinitionAst',
        'FunctionDefinitionAst',
        'FunctionDefinitionAst',
        'FunctionDefinitionAst',
        'FunctionDefinitionAst',
        'AssignmentStatementAst',
        'AssignmentStatementAst',
        'ForEachStatementAst',
        'IfStatementAst'
    )
    if ($topLevelStatements.Count -ne $expectedTopLevelTypes.Count -or
        @(
            $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.TrapStatementAst]
                }, $true)
        ).Count -ne 0) {
        return $false
    }
    for ($index = 0; $index -lt $expectedTopLevelTypes.Count; $index++) {
        if ($topLevelStatements[$index].GetType().Name -cne
            $expectedTopLevelTypes[$index]) {
            return $false
        }
    }
    [string[]]$expectedTopLevelFunctionOrder = @(
        'Test-GitRoutingEnvironmentClean',
        'Get-NormalizedRootPath',
        'Get-GitRegularMetadata',
        'Get-GitTrackedRegularFileIdentity',
        'Test-RepositoryRegularFileBoundary',
        'Get-NormalizationCandidateIdentity',
        'Get-ByteDigest',
        'ConvertFrom-StrictUtf8Bytes',
        'ConvertTo-LfTrimmedText',
        'ConvertTo-SafePathLabel'
    )
    for ($index = 0; $index -lt $expectedTopLevelFunctionOrder.Count; $index++) {
        if ($topLevelStatements[$index + 1].Name -cne
            $expectedTopLevelFunctionOrder[$index]) {
            return $false
        }
    }
    $finalDiagnosticOutput = $topLevelStatements[14]
    if ($finalDiagnosticOutput.Clauses.Count -ne 1 -or
        $null -ne $finalDiagnosticOutput.ElseClause -or
        $finalDiagnosticOutput.Clauses[0].Item1.Extent.Text -cne
            '$skipped.Count -gt 0' -or
        $finalDiagnosticOutput.Clauses[0].Item2.Statements.Count -ne 2 -or
        $finalDiagnosticOutput.Clauses[0].Item2.Statements[0].Extent.Text -cne
            '"Skipped (unsafe boundary, drift, read failure, or strict decode failure):"' -or
        $finalDiagnosticOutput.Clauses[0].Item2.Statements[1].Extent.Text -cne
            '$skipped') {
        return $false
    }

    # denylistでは別名・short type・新しいsinkを取りこぼす。command、member、
    # resolved typeをcanonical例のexact allowlistへ閉じ、追加ASTをすべて拒否する。
    [string[]]$expectedNamedCommands = @(
        'ConvertFrom-StrictUtf8Bytes',
        'ConvertTo-LfTrimmedText',
        'ConvertTo-SafePathLabel',
        'Get-ByteDigest',
        'Get-ByteDigest',
        'Get-GitRegularMetadata',
        'Get-GitRegularMetadata',
        'Get-GitTrackedRegularFileIdentity',
        'Get-NormalizationCandidateIdentity',
        'Get-NormalizationCandidateIdentity',
        'Get-NormalizedRootPath',
        'Get-NormalizedRootPath',
        'Get-NormalizedRootPath',
        'Microsoft.PowerShell.Core\Get-Command',
        'Microsoft.PowerShell.Management\Remove-Item',
        'Test-GitRoutingEnvironmentClean',
        'Test-RepositoryRegularFileBoundary'
    )
    [Array]::Sort($expectedNamedCommands, [System.StringComparer]::Ordinal)
    $commandAsts = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst]
            }, $true)
    )
    $actualNamedCommands = [System.Collections.Generic.List[string]]::new()
    $dynamicGitCommandShapes = [System.Collections.Generic.List[string]]::new()
    $dynamicGitCommandCount = 0
    foreach ($commandAst in $commandAsts) {
        $commandName = $commandAst.GetCommandName()
        if ([string]::IsNullOrEmpty([string]$commandName)) {
            if ($commandAst.InvocationOperator -ne
                    [System.Management.Automation.Language.TokenKind]::Ampersand -or
                $commandAst.CommandElements.Count -lt 1 -or
                $commandAst.CommandElements[0].Extent.Text -cne '$gitExecutable') {
                return $false
            }
            $dynamicGitCommandCount++
            $dynamicGitCommandShapes.Add((@(
                        $commandAst.CommandElements |
                            ForEach-Object { $_.Extent.Text }
                    ) -join '|'))
        } else {
            $actualNamedCommands.Add($commandName)
        }
    }
    if ($dynamicGitCommandCount -ne 3) {
        return $false
    }
    [string[]]$expectedDynamicGitCommandShapes = @(
        '$gitExecutable|--no-replace-objects|--no-lazy-fetch|-C|$rootBoundary|ls-files|--stage|-z|--|$literalPathSpec',
        '$gitExecutable|--no-replace-objects|--no-lazy-fetch|-C|$rootBoundary|ls-tree|-z|HEAD|--|$literalPathSpec',
        '$gitExecutable|--no-replace-objects|--no-lazy-fetch|-C|$rootBoundary|rev-parse|--show-toplevel'
    )
    [Array]::Sort($expectedDynamicGitCommandShapes, [System.StringComparer]::Ordinal)
    [string[]]$actualDynamicGitCommandShapeArray = @($dynamicGitCommandShapes)
    [Array]::Sort($actualDynamicGitCommandShapeArray, [System.StringComparer]::Ordinal)
    for ($index = 0; $index -lt $expectedDynamicGitCommandShapes.Count; $index++) {
        if ($actualDynamicGitCommandShapeArray[$index] -cne
            $expectedDynamicGitCommandShapes[$index]) {
            return $false
        }
    }

    # Trace2 suppression must dominate every dynamic Git query, and cleanup
    # must be the sole finally statement. Exact command counts aloneでは、
    # safe setupをquery後へ移すcontrol-flow driftを検出できない。
    $identityFunctions = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq 'Get-GitTrackedRegularFileIdentity'
            }, $true)
    )
    if ($identityFunctions.Count -ne 1) {
        return $false
    }
    $identityStatements = @($identityFunctions[0].Body.EndBlock.Statements)
    [string[]]$expectedIdentityStatementTypes = @(
        'IfStatementAst',
        'AssignmentStatementAst',
        'IfStatementAst',
        'AssignmentStatementAst',
        'IfStatementAst',
        'AssignmentStatementAst',
        'IfStatementAst',
        'AssignmentStatementAst',
        'TryStatementAst'
    )
    if ($identityStatements.Count -ne $expectedIdentityStatementTypes.Count -or
        $identityStatements[0].Extent.Text -cne
            'if (-not (Test-GitRoutingEnvironmentClean)) { return $null }') {
        return $false
    }
    for ($index = 0; $index -lt $expectedIdentityStatementTypes.Count; $index++) {
        if ($identityStatements[$index].GetType().Name -cne
            $expectedIdentityStatementTypes[$index]) {
            return $false
        }
    }
    $traceTry = $identityStatements[8]
    if ($traceTry.CatchClauses.Count -ne 0 -or $null -eq $traceTry.Finally -or
        $traceTry.Body.Statements.Count -ne 15 -or
        $traceTry.Finally.Statements.Count -ne 1 -or
        $traceTry.Body.Statements[0] -isnot
            [System.Management.Automation.Language.ForEachStatementAst] -or
        $traceTry.Finally.Statements[0] -isnot
            [System.Management.Automation.Language.ForEachStatementAst]) {
        return $false
    }
    $traceSetLoop = $traceTry.Body.Statements[0]
    $traceCleanupLoop = $traceTry.Finally.Statements[0]
    foreach ($traceLoop in @($traceSetLoop, $traceCleanupLoop)) {
        if ($traceLoop.Variable.Extent.Text -cne '$traceName' -or
            $traceLoop.Condition.Extent.Text -cne '$trace2OverrideNames') {
            return $false
        }
    }
    # foreach bodyを単一のdirect statementへ固定する。子孫に正しいcallがあっても、
    # その前のcontinue/returnや常偽分岐で到達不能ならTrace2抑止にならない。
    if ($traceSetLoop.Body.Statements.Count -ne 1 -or
        $traceSetLoop.Body.Statements[0].Extent.Text -cne
            "[Environment]::SetEnvironmentVariable(`$traceName, '0', 'Process')" -or
        $traceCleanupLoop.Body.Statements.Count -ne 1) {
        return $false
    }
    $traceSetLoopMembers = @(
        $traceSetLoop.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $node.Expression.Extent.Text -ceq '[Environment]' -and
                    $node.Member.Extent.Text -ceq 'SetEnvironmentVariable'
            }, $true)
    )
    $traceCleanupCommands = @(
        $traceCleanupLoop.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -ceq
                        'Microsoft.PowerShell.Management\Remove-Item'
            }, $true)
    )
    if ($traceSetLoopMembers.Count -ne 1 -or $traceCleanupCommands.Count -ne 1) {
        return $false
    }
    foreach ($dynamicGitCommand in @(
            $commandAsts | Where-Object {
                [string]::IsNullOrEmpty([string]$_.GetCommandName())
            }
        )) {
        $ancestor = $dynamicGitCommand.Parent
        while ($null -ne $ancestor -and
            -not [object]::ReferenceEquals($ancestor, $traceTry.Body)) {
            $ancestor = $ancestor.Parent
        }
        if ($null -eq $ancestor -or
            $dynamicGitCommand.Extent.StartOffset -le
                $traceSetLoop.Extent.EndOffset -or
            $dynamicGitCommand.Extent.EndOffset -ge
                $traceCleanupLoop.Extent.StartOffset) {
            return $false
        }
    }
    [string[]]$actualNamedCommandArray = @($actualNamedCommands)
    [Array]::Sort($actualNamedCommandArray, [System.StringComparer]::Ordinal)
    if ($actualNamedCommandArray.Count -ne $expectedNamedCommands.Count) {
        return $false
    }
    for ($index = 0; $index -lt $expectedNamedCommands.Count; $index++) {
        if ($actualNamedCommandArray[$index] -cne $expectedNamedCommands[$index]) {
            return $false
        }
    }
    # Named commandもname/countだけでなく全argument shapeをdigest固定する。
    # RelativePath等を別literalへ差し替えてpath guardとactual writeを分離させない。
    [string[]]$expectedNamedCommandSignatures = @(
        'ConvertFrom-StrictUtf8Bytes|fG6RE4+ATmPI/tmz3kjbqCS2rDr/7PJ1p3A237dq850=',
        'ConvertTo-LfTrimmedText|qKYCCxvpwTstqY8SVZgHQ6iYkQEC8pjsKMQyczNTVIM=',
        'ConvertTo-SafePathLabel|lpNYesc1DST1EcDX600j/pZ3kdYRPdkR04x9fYqytl0=',
        'Get-ByteDigest|ikGkSdLSsfVdSuSjg4sSZcgEHdxceOOOsMJ/SqlAxR8=',
        'Get-ByteDigest|t0lpmATRNW/WNFgRUDvld3ponyal6IyYMbXgNMQ8mME=',
        'Get-GitRegularMetadata|b22Zs+4KO/cN04U55K1I3O/BJetudIpzYoS0j9t+5AE=',
        'Get-GitRegularMetadata|J8bnqigQ8tnoJIyzbr4r/na7pL+363ho8ujXZIwR8d8=',
        'Get-GitTrackedRegularFileIdentity|hPj5h6OZ+lGjyNc7fgLRwDNUDpmLFwPmMFbQpfuo5OQ=',
        'Get-NormalizationCandidateIdentity|dTua/HYLDt3tB/+1/qeQGzttsa7PnWGKnSoUPRmuDgY=',
        'Get-NormalizationCandidateIdentity|dTua/HYLDt3tB/+1/qeQGzttsa7PnWGKnSoUPRmuDgY=',
        'Get-NormalizedRootPath|D0s2q7o/RFnbbbwmP/yN6dZ3UPy4VKy/wlBi8kK05Ko=',
        'Get-NormalizedRootPath|ISq4DN8tJOq/FmDQd2aQ9429lUeCrY1VlK8E5rrURBE=',
        'Get-NormalizedRootPath|ISq4DN8tJOq/FmDQd2aQ9429lUeCrY1VlK8E5rrURBE=',
        'Microsoft.PowerShell.Core\Get-Command|6gUiT6yOjpAn4TAb23grGHiIkhHhVuHepNhz8QKNuvE=',
        'Microsoft.PowerShell.Management\Remove-Item|ic6Q8WESYv9PE6vihYfWo9TqzB0iHc6NhcZAUu/4UwQ=',
        'Test-GitRoutingEnvironmentClean|k2ZYm6fsZ5QS8g85ITQJNXcb1ACLPFf0bBnmqnHpTNM=',
        'Test-RepositoryRegularFileBoundary|AD/A41/Eu/aWmqGnfFLe1i5OaFdQs1dcqq7M78NwCFM='
    )
    $namedCommandHasher = [System.Security.Cryptography.SHA256]::Create()
    $namedCommandUtf8 = [System.Text.UTF8Encoding]::new($false)
    $actualNamedCommandSignatures = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($namedCommandAst in @(
                $commandAsts | Where-Object {
                    -not [string]::IsNullOrEmpty([string]$_.GetCommandName())
                }
            )) {
            $namedCommandShape = @(
                $namedCommandAst.CommandElements |
                    ForEach-Object { $_.Extent.Text }
            ) -join '|'
            $namedCommandDigest = [Convert]::ToBase64String(
                $namedCommandHasher.ComputeHash(
                    $namedCommandUtf8.GetBytes($namedCommandShape)
                )
            )
            $actualNamedCommandSignatures.Add(
                $namedCommandAst.GetCommandName() + '|' + $namedCommandDigest
            )
        }
    }
    finally {
        $namedCommandHasher.Dispose()
    }
    [Array]::Sort($expectedNamedCommandSignatures, [System.StringComparer]::Ordinal)
    [string[]]$actualNamedCommandSignatureArray = @($actualNamedCommandSignatures)
    [Array]::Sort($actualNamedCommandSignatureArray, [System.StringComparer]::Ordinal)
    if ($actualNamedCommandSignatureArray.Count -ne
        $expectedNamedCommandSignatures.Count) {
        return $false
    }
    for ($index = 0; $index -lt $expectedNamedCommandSignatures.Count; $index++) {
        if ($actualNamedCommandSignatureArray[$index] -cne
            $expectedNamedCommandSignatures[$index]) {
            return $false
        }
    }

    # Candidate helperのdirect control flowを2 statementsへ固定し、early-return
    # decoyでboundary/Git identity callをunreachableにする同期変更を拒否する。
    $candidateFunctions = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq 'Get-NormalizationCandidateIdentity'
            }, $true)
    )
    $expectedCandidateBoundaryStatement = @'
if (-not (Test-RepositoryRegularFileBoundary `
            -RepoRoot $RepoRoot `
            -RelativePath $RelativePath)) {
        return $null
    }
'@
    $expectedCandidateIdentityStatement = @'
return Get-GitTrackedRegularFileIdentity `
        -RepoRoot $RepoRoot `
        -RelativePath $RelativePath
'@
    if ($candidateFunctions.Count -ne 1 -or
        $candidateFunctions[0].Body.EndBlock.Statements.Count -ne 2 -or
        $candidateFunctions[0].Body.EndBlock.Statements[0].Extent.Text -cne
            $expectedCandidateBoundaryStatement -or
        $candidateFunctions[0].Body.EndBlock.Statements[1].Extent.Text -cne
            $expectedCandidateIdentityStatement) {
        return $false
    }

    # 全critical helperのfunction extentを独立digest inventoryへ閉じる。個別の
    # count/fixtureが未観測inputだけで分岐するearly returnやunary driftを見逃しても、
    # helper sourceの同期変更にはこの第三oracleの明示更新が必要になる。
    [string[]]$expectedFunctionDigests = @(
        'ConvertFrom-StrictUtf8Bytes|tsBa0J2o/sshVVuta1sF2MVTtdXKVGgwTXiMDRAtHAU=',
        'ConvertTo-LfTrimmedText|43JlyNcQrAHycigoq64eVyaRj6EPv2EoEg9JaeNsFNU=',
        'ConvertTo-SafePathLabel|IxB/SDF4ht4bjjM26OargepX+a26VLxlbL91ylqJbgE=',
        'Get-ByteDigest|VHxELR05D24VYoz4m6ol1QqDNGjZ94/pG7n9LSKZwpM=',
        'Get-GitRegularMetadata|x4iq2of1ceS5DZ2khAYfw3T/atIWLXfaGz0ELPYLCoI=',
        'Get-GitTrackedRegularFileIdentity|ExriN+q60xle2mXeguLL2RNvrKWq2sEO4tDeYfk166A=',
        'Get-NormalizationCandidateIdentity|fJ59cGleCYdsqkQNoxkRPYSy4AuJxhc0V7Y3lcJGEG8=',
        'Get-NormalizedRootPath|zp9N+RjNQJSW3KpxMm9X1h2epYA+n8cy/uD6p3ILick=',
        'Test-GitRoutingEnvironmentClean|L2qaTQyQhJxyJdkzQXfUj26OcpcG+avlqobA+rI+6jE=',
        'Test-RepositoryRegularFileBoundary|mYCOrdF3u9VSG2gnBQpdNDp7AtIoSAlGjVO06V8K8Bk='
    )
    $functionHasher = [System.Security.Cryptography.SHA256]::Create()
    $functionUtf8 = [System.Text.UTF8Encoding]::new($false)
    $actualFunctionDigests = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($functionAst in @(
                $ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                    }, $true)
            )) {
            $functionDigest = [Convert]::ToBase64String(
                $functionHasher.ComputeHash(
                    $functionUtf8.GetBytes($functionAst.Extent.Text)
                )
            )
            $actualFunctionDigests.Add($functionAst.Name + '|' + $functionDigest)
        }
    }
    finally {
        $functionHasher.Dispose()
    }
    [Array]::Sort($expectedFunctionDigests, [System.StringComparer]::Ordinal)
    [string[]]$actualFunctionDigestArray = @($actualFunctionDigests)
    [Array]::Sort($actualFunctionDigestArray, [System.StringComparer]::Ordinal)
    if ($actualFunctionDigestArray.Count -ne $expectedFunctionDigests.Count) {
        return $false
    }
    for ($index = 0; $index -lt $expectedFunctionDigests.Count; $index++) {
        if ($actualFunctionDigestArray[$index] -cne
            $expectedFunctionDigests[$index]) {
            return $false
        }
    }
    $traceRemoveCommands = @(
        $commandAsts | Where-Object {
            $_.GetCommandName() -ceq 'Microsoft.PowerShell.Management\Remove-Item'
        }
    )
    if ($traceRemoveCommands.Count -ne 1 -or
        $traceRemoveCommands[0].CommandElements.Count -ne 5 -or
        $traceCleanupLoop.Body.Statements[0].Extent.Text -cne
            $traceRemoveCommands[0].Extent.Text) {
        return $false
    }
    [string[]]$expectedTraceRemoveElements = @(
        'Microsoft.PowerShell.Management\Remove-Item',
        '-LiteralPath',
        '"Env:$traceName"',
        '-ErrorAction',
        'Stop'
    )
    for ($index = 0; $index -lt $expectedTraceRemoveElements.Count; $index++) {
        if ($traceRemoveCommands[0].CommandElements[$index].Extent.Text -cne
            $expectedTraceRemoveElements[$index]) {
            return $false
        }
    }

    $expectedMemberCounts = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($entry in @(
            @{ Signature = '[char]|ConvertToUtf32|True'; Count = 1 },
            @{ Signature = '[char]|IsHighSurrogate|True'; Count = 1 },
            @{ Signature = '[char]|IsLowSurrogate|True'; Count = 1 },
            @{ Signature = '[Convert]|ToBase64String|True'; Count = 1 },
            @{ Signature = '[Environment]|GetEnvironmentVariables|True'; Count = 1 },
            @{ Signature = '[Environment]|SetEnvironmentVariable|True'; Count = 1 },
            @{ Signature = '[string]|Equals|True'; Count = 4 },
            @{ Signature = '[string]|IsNullOrEmpty|True'; Count = 6 },
            @{ Signature = '[System.Globalization.CharUnicodeInfo]|GetUnicodeCategory|True'; Count = 1 },
            @{ Signature = '[System.IO.Directory]|GetParent|True'; Count = 1 },
            @{ Signature = '[System.IO.File]|Exists|True'; Count = 1 },
            @{ Signature = '[System.IO.File]|GetAttributes|True'; Count = 1 },
            @{ Signature = '[System.IO.File]|ReadAllBytes|True'; Count = 2 },
            @{ Signature = '[System.IO.File]|WriteAllText|True'; Count = 1 },
            @{ Signature = '[System.IO.Path]|Combine|True'; Count = 2 },
            @{ Signature = '[System.IO.Path]|GetFullPath|True'; Count = 3 },
            @{ Signature = '[System.IO.Path]|GetPathRoot|True'; Count = 1 },
            @{ Signature = '[System.IO.Path]|IsPathRooted|True'; Count = 1 },
            @{ Signature = '[System.Security.Cryptography.SHA256]|Create|True'; Count = 1 },
            @{ Signature = '[System.Text.StringBuilder]|new|True'; Count = 1 },
            @{ Signature = '[System.Text.UTF8Encoding]|new|True'; Count = 2 },
            @{ Signature = '$builder|Append|False'; Count = 2 },
            @{ Signature = '$builder|AppendFormat|False'; Count = 2 },
            @{ Signature = '$builder|ToString|False'; Count = 1 },
            @{ Signature = '$candidateFull|StartsWith|False'; Count = 1 },
            @{ Signature = '$full|TrimEnd|False'; Count = 1 },
            @{ Signature = '$lines[$index]|TrimEnd|False'; Count = 1 },
            @{ Signature = '$metadata|Split|False'; Count = 1 },
            @{ Signature = '$Raw|Split|False'; Count = 1 },
            @{ Signature = '$records[0]|IndexOf|False'; Count = 1 },
            @{ Signature = '$records[0]|Substring|False'; Count = 1 },
            @{ Signature = '$RelativePath|Substring|False'; Count = 1 },
            @{ Signature = '$rootPrefix|EndsWith|False'; Count = 1 },
            @{ Signature = '$sha256|ComputeHash|False'; Count = 1 },
            @{ Signature = '$sha256|Dispose|False'; Count = 1 },
            @{ Signature = '$strictUtf8|GetString|False'; Count = 1 },
            @{ Signature = '$Text.Replace("`r`n", "`n")|Replace|False'; Count = 1 },
            @{ Signature = '$Text|Replace|False'; Count = 1 }
        )) {
        $expectedMemberCounts.Add($entry.Signature, $entry.Count)
    }
    $actualMemberCounts = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::Ordinal
    )
    $memberAsts = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
            }, $true)
    )
    foreach ($memberAst in $memberAsts) {
        $signature = (
            $memberAst.Expression.Extent.Text + '|' +
            $memberAst.Member.Extent.Text + '|' +
            [string]$memberAst.Static
        )
        if (-not $expectedMemberCounts.ContainsKey($signature)) {
            return $false
        }
        if (-not $actualMemberCounts.ContainsKey($signature)) {
            $actualMemberCounts.Add($signature, 0)
        }
        $actualMemberCounts[$signature]++
    }
    foreach ($signature in $expectedMemberCounts.Keys) {
        if (-not $actualMemberCounts.ContainsKey($signature) -or
            $actualMemberCounts[$signature] -ne $expectedMemberCounts[$signature]) {
            return $false
        }
    }
    $traceSetMembers = @(
        $memberAsts | Where-Object {
            $_.Expression.Extent.Text -ceq '[Environment]' -and
                $_.Member.Extent.Text -ceq 'SetEnvironmentVariable'
        }
    )
    if ($traceSetMembers.Count -ne 1 -or
        $traceSetMembers[0].Extent.Text -cne
            "[Environment]::SetEnvironmentVariable(`$traceName, '0', 'Process')") {
        return $false
    }

    $expectedTypeCounts = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($entry in @(
            @{ Name = 'System.Char'; Count = 3 },
            @{ Name = 'System.Convert'; Count = 1 },
            @{ Name = 'System.Environment'; Count = 2 },
            @{ Name = 'System.String'; Count = 10 },
            @{ Name = 'System.Globalization.CharUnicodeInfo'; Count = 1 },
            @{ Name = 'System.Globalization.UnicodeCategory'; Count = 5 },
            @{ Name = 'System.IO.Directory'; Count = 1 },
            @{ Name = 'System.IO.File'; Count = 5 },
            @{ Name = 'System.IO.FileAttributes'; Count = 3 },
            @{ Name = 'System.IO.Path'; Count = 11 },
            @{ Name = 'System.Security.Cryptography.SHA256'; Count = 1 },
            @{ Name = 'System.StringComparison'; Count = 5 },
            @{ Name = 'System.StringSplitOptions'; Count = 2 },
            @{ Name = 'System.Text.StringBuilder'; Count = 1 },
            @{ Name = 'System.Text.UTF8Encoding'; Count = 2 }
        )) {
        $expectedTypeCounts.Add($entry.Name, $entry.Count)
    }
    $actualTypeCounts = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::Ordinal
    )
    $typeAsts = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.TypeExpressionAst]
            }, $true)
    )
    foreach ($typeAst in $typeAsts) {
        $resolvedType = $typeAst.TypeName.GetReflectionType()
        if ($null -eq $resolvedType -or
            -not $expectedTypeCounts.ContainsKey($resolvedType.FullName)) {
            return $false
        }
        if (-not $actualTypeCounts.ContainsKey($resolvedType.FullName)) {
            $actualTypeCounts.Add($resolvedType.FullName, 0)
        }
        $actualTypeCounts[$resolvedType.FullName]++
    }
    foreach ($typeName in $expectedTypeCounts.Keys) {
        if (-not $actualTypeCounts.ContainsKey($typeName) -or
            $actualTypeCounts[$typeName] -ne $expectedTypeCounts[$typeName]) {
            return $false
        }
    }

    $traceAssignments = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text.EndsWith(
                        '$trace2OverrideNames',
                        [System.StringComparison]::Ordinal
                    )
            }, $true)
    )
    if ($traceAssignments.Count -ne 1 -or
        $traceAssignments[0].Right.Extent.Text -cne
            "@('GIT_TRACE2', 'GIT_TRACE2_EVENT', 'GIT_TRACE2_PERF')") {
        return $false
    }

    # LHSだけのallowlistでは既存変数への再代入を見逃す。全assignmentの
    # exact LHSとRHS source digestを独立oracleとして固定する。
    [string[]]$expectedAssignmentSignatures = @(
        '[string[]]$fields|rVo4Q3B1kHhBioFD+7btV1byBfDA5C7tzzE1QEXTWPY=',
        '[string[]]$lines|Xsgabj7H2HurJyzglW0P9gFD440DdH/MBYWnByWqOA0=',
        '[string[]]$records|jC9Q5x+X3xnnPDXJTVbAs8acA+5bVzyMhf/0qWp0fyA=',
        '[string[]]$relativePaths|oJ+xUZh44QFU2OPB7d0CTsChVnmMzCkdNOfNyZo3H18=',
        '$actualTopLevel|SIe7JNo5Pj0oFD4Tif3Vl5GoGA4/p7xNWJu0600T7wg=',
        '$attributes|34VvIK2PefX72tbqWUrCSRbbf4W/CA5K8IRf6IFAaiY=',
        '$blockedNames|pfQK5aJHufDA4SQ7HtOAmSAZF5UOD86kcpFecr/hsY8=',
        '$bomLength|TgdAhWK+24tgzgXB3s/jrRa3IjCWfeAfZAt+Rym0n84=',
        '$bomLength|X+zrZv/IbzjZUnhsbWlsecLbwjndTpG0ZynXOif7V+k=',
        '$builder|V3HU81fCnJ1zHtNbx8sB4Crb9eAFRKuQcdiRRB57Szg=',
        '$candidateFull|8aGMVu9w7ffTy1aroLQwZf4JpSoQ2ts/ZS0EIrFeQkc=',
        '$candidateIdentity|myf+6gLWVnO5dvalV74FOhvM7iGgRIDe+HjrJw/zlU4=',
        '$category|7HzGPWsNwlKUVOONIDc38uGQXyooco+xrGWSfAuYCHc=',
        '$codePoint|ckcZR2PIqC3LLxXba/LQcfGOkPAvmQRqRqFmwAIcjwI=',
        '$codePoint|DIlwdmxOAuAHJznuqLhSlb9cAtQ5d2q+uc7r4DwWRaw=',
        '$comparison|79K+KeGsxDnh/tuepKixAnxslRTUOOS/hamXZT1MoQg=',
        '$current|3QVoO7tcwgl8Hlmd/DUPW6uI0GIHgDI55iRfxed6tbI=',
        '$current|NQIj+LUUlwZuQITYiYVPDDva6qEQfaBDUjgRlTzR78Y=',
        '$full|OX5F/k9EQSMynrYaUBNmYUZjooTfnaOOM9l6AujzCuE=',
        '$gitApplications|4KEigmzrTtXIRN+vviAaxlkLXwOmDGTAyDcFyEToWIY=',
        '$gitExecutable|Ck1bg9+ZyNgGVGE62oLKDf5E58pDa02QSEAx77aHIRQ=',
        '$headMetadata|wnuXGNEMQCIF2AKr7Y+Cybo0H+/iZOuTuGirXlv3VZI=',
        '$index|lIzB2k/Dx17dqAAoy2l3cEo/cp8v+kVWzDyjUBvyYZQ=',
        '$index|X+zrZv/IbzjZUnhsbWlsecLbwjndTpG0ZynXOif7V+k=',
        '$index|X+zrZv/IbzjZUnhsbWlsecLbwjndTpG0ZynXOif7V+k=',
        '$indexMetadata|ZFc8mQFIjuYlHuYDkQfzfer4W+Qpyg8zz1kjjV0BtZs=',
        '$isCandidate|85Hx1L7pTkr/QhDigxE6q4maT35T32ZciwJSzE8PsIg=',
        '$isCandidate|pocBIs/VGusjp6CNgWh2Er/c84gXaPJ8PefBktugXYk=',
        '$latestDigest|119n8rn0jMr2q3PcXko/UM6n17hA07CR7uPb/ufZQu4=',
        '$latestDigest|TnSWt7KKmeADNSz9C52oaG88MYTm4fQXsN8uHbRCb7U=',
        '$latestIdentity|myf+6gLWVnO5dvalV74FOhvM7iGgRIDe+HjrJw/zlU4=',
        '$lines[$index]|7eYW0zZALPQDGv9pORDNWa75TDKzQmzAYAvlqrDf+Xs=',
        '$literalPathSpec|laJwGMiv4FFppw7tpDYHXXEG/4nHfwihxhZpmk5KX8o=',
        '$metadata|TICol9Sd7yFwFcCkBHDLfQ1I1HAEs6ET3EVHPT760kU=',
        '$name|sUQh4VdBfCFJQZ47almfxB/xS3q5Fs5tKjwH5SWL3n8=',
        '$normalized|38KE9UyHNXEAWeFB6DPt2cO7U3Y1lO0snkm++KRxfJs=',
        '$originalBytes|VARFc7StuBGtXq8iDvkx8fXbPmfk9+zuP+Koy8MIqh8=',
        '$originalDigest|h5T9tHfvI2R+/KBO99/8RAm6F80UM74cbotmIrG5Gs0=',
        '$parent|aaJUAhkz4tyu9ab6fCx43HEHuaeLg8g23f8qZEUV6dc=',
        '$path|g+Ww8h+uLgtHy7CWlc4oyeOiAuZWOnZU2aaFoiJ/OcE=',
        '$rawHead|5TIes8miZX96VzGO1muolEhTAKTOHNNfFwFzE8d9ivo=',
        '$rawIndex|wXS7c9cDwEu+FsQfQ7nZXQ8ZnFBS8VCEQZLPR2bsfDw=',
        '$repo|ur+US5CCILxwdtjCW/V1FseVGuBOoPS9oeIKv8hUVw4=',
        '$rootBoundary|UGMdL68SiE0HFADHDV6HVm9lWduQmaAAYdFayfgUWPk=',
        '$rootBoundary|UGMdL68SiE0HFADHDV6HVm9lWduQmaAAYdFayfgUWPk=',
        '$rootPrefix|qfJTd7XNfrbjskaFXhCUcHzofghU5Zs53YrPminl27c=',
        '$rootPrefix|qGM6ma8SXpCgwl+lq8hlD7mPOPWkSxK/x4I8LoKvtI4=',
        '$safeLabel|o+BD9vB/hvY7NGck142KiWm3Ht9xQRNIJifbE6dohGE=',
        '$scalarLength|1HNeOiZeFu7gP1lxi5tdAwGcB9i2xR+Q2jpmbuwTqzU=',
        '$scalarLength|a4ayc/80/OGda4BO/1o/V0etpOqiLx1JwB5S3beHW0s=',
        '$sha256|BV7jSBs1i1OBHJnxV90QETz4gBCvX0fByGwtZgel6Es=',
        '$skipped|1GgNRgrf5nEVNOZhyGFKoLcj5py4jdJ/lpMss/hWtvA=',
        '$skipped|fYpD8GQDXC12a30f/ADV92UMI3TpQFNm6o2+C1BDlT4=',
        '$skipped|ix9MotUP9aZIUAnze2fsw/duT3NhGCXD0qgsFacnriA=',
        '$skipped|MwkfZfOXiuVYxgD8vw/2Mg9J//Dys5Un4Oqp6dWtTsw=',
        '$skipped|Ok85whIY0jl4BJjKbAmEXdxIIoi7v3NSKWwwB5l6TLQ=',
        '$strictUtf8|U1yxA5x99gzfu8sJkaILJN9CmUdM+muVYrFbH2lYjDc=',
        '$t|BY6SCgRuQPCvpMNH1+EGbJbK/YjLvkvBCRgBOACMJ2k=',
        '$t|U4KzLe7ND1QLE3oMIHMvdII/EIoNA1zWSpZUoqq1Xgk=',
        '$tabIndex|cEDc5oVLO/Vu9Yz95MYm8KLNa0hnmaoqCMwUK4ObpjA=',
        '$topLevelOutput|VPtnlKIRGxBbonG/8lZUNrT9uX1JeOkIo6HX/S6Cw1c=',
        '$trace2OverrideNames|ecn42PjxdK/JuktFjEV9bh52k91kihDxzWptQYTs8P8=',
        '$volumeRoot|Xg1ASR20AEOqfbP8WJJ8PoM/r/te/m2Gnu4sHp0OVto='
    )
    $assignmentHasher = [System.Security.Cryptography.SHA256]::Create()
    $assignmentUtf8 = [System.Text.UTF8Encoding]::new($false)
    $actualAssignmentSignatures = [System.Collections.Generic.List[string]]::new()
    try {
        $assignmentAsts = @(
            $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst]
                }, $true)
        )
        foreach ($assignmentAst in $assignmentAsts) {
            $rightBytes = $assignmentUtf8.GetBytes($assignmentAst.Right.Extent.Text)
            $rightDigest = [Convert]::ToBase64String(
                $assignmentHasher.ComputeHash($rightBytes)
            )
            $actualAssignmentSignatures.Add(
                $assignmentAst.Left.Extent.Text + '|' + $rightDigest
            )
        }
    }
    finally {
        $assignmentHasher.Dispose()
    }
    [Array]::Sort($expectedAssignmentSignatures, [System.StringComparer]::Ordinal)
    [string[]]$actualAssignmentSignatureArray = @($actualAssignmentSignatures)
    [Array]::Sort($actualAssignmentSignatureArray, [System.StringComparer]::Ordinal)
    if ($actualAssignmentSignatureArray.Count -ne $expectedAssignmentSignatures.Count) {
        return $false
    }
    for ($index = 0; $index -lt $expectedAssignmentSignatures.Count; $index++) {
        if ($actualAssignmentSignatureArray[$index] -cne
            $expectedAssignmentSignatures[$index]) {
            return $false
        }
    }
    [string[]]$expectedPlusAssignmentSignatures = @(
        '$bomLength|TgdAhWK+24tgzgXB3s/jrRa3IjCWfeAfZAt+Rym0n84=',
        '$index|lIzB2k/Dx17dqAAoy2l3cEo/cp8v+kVWzDyjUBvyYZQ=',
        '$rootPrefix|qfJTd7XNfrbjskaFXhCUcHzofghU5Zs53YrPminl27c=',
        '$skipped|1GgNRgrf5nEVNOZhyGFKoLcj5py4jdJ/lpMss/hWtvA=',
        '$skipped|fYpD8GQDXC12a30f/ADV92UMI3TpQFNm6o2+C1BDlT4=',
        '$skipped|ix9MotUP9aZIUAnze2fsw/duT3NhGCXD0qgsFacnriA=',
        '$skipped|Ok85whIY0jl4BJjKbAmEXdxIIoi7v3NSKWwwB5l6TLQ='
    )
    $actualPlusAssignmentSignatures = [System.Collections.Generic.List[string]]::new()
    foreach ($assignmentAst in $assignmentAsts) {
        if ($assignmentAst.Operator -notin @(
                [System.Management.Automation.Language.TokenKind]::Equals,
                [System.Management.Automation.Language.TokenKind]::PlusEquals
            )) {
            return $false
        }
        if ($assignmentAst.Operator -eq
            [System.Management.Automation.Language.TokenKind]::PlusEquals) {
            $rightBytes = $assignmentUtf8.GetBytes($assignmentAst.Right.Extent.Text)
            $rightHasher = [System.Security.Cryptography.SHA256]::Create()
            try {
                $rightDigest = [Convert]::ToBase64String(
                    $rightHasher.ComputeHash($rightBytes)
                )
            }
            finally {
                $rightHasher.Dispose()
            }
            $actualPlusAssignmentSignatures.Add(
                $assignmentAst.Left.Extent.Text + '|' + $rightDigest
            )
        }
    }
    [Array]::Sort($expectedPlusAssignmentSignatures, [System.StringComparer]::Ordinal)
    [string[]]$actualPlusAssignmentSignatureArray = @(
        $actualPlusAssignmentSignatures
    )
    [Array]::Sort(
        $actualPlusAssignmentSignatureArray,
        [System.StringComparer]::Ordinal
    )
    if ($actualPlusAssignmentSignatureArray.Count -ne
        $expectedPlusAssignmentSignatures.Count) {
        return $false
    }
    for ($index = 0; $index -lt $expectedPlusAssignmentSignatures.Count; $index++) {
        if ($actualPlusAssignmentSignatureArray[$index] -cne
            $expectedPlusAssignmentSignatures[$index]) {
            return $false
        }
    }

    # Canonical native stderr redirectionは3個の2>$nullだけ。他pathへの
    # redirectionを追加して別sinkを作る変更は拒否する。
    $redirections = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FileRedirectionAst]
            }, $true)
    )
    if ($redirections.Count -ne 3) {
        return $false
    }
    foreach ($redirection in $redirections) {
        if ($redirection.Extent.Text -cne '2>$null') {
            return $false
        }
    }

    $targetAssignments = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text.EndsWith(
                        '$relativePaths',
                        [System.StringComparison]::Ordinal
                    )
            }, $true)
    )
    if ($targetAssignments.Count -ne 1) {
        return $false
    }
    $rewriteLoops = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
                    $node.Extent.Text.Contains(
                        '[System.IO.File]::WriteAllText($path, $t,'
                    )
            }, $true)
    )
    if ($rewriteLoops.Count -ne 1 -or
        $rewriteLoops[0].Parent -isnot
            [System.Management.Automation.Language.NamedBlockAst] -or
        $rewriteLoops[0].Variable.Extent.Text -cne '$relativePath' -or
        $rewriteLoops[0].Condition.Extent.Text -cne '$relativePaths') {
        return $false
    }
    # Final identity/digest guard must remain immediately before the sole write.
    # Allowlisted descendants/countsだけでは、writeをguard前へ移すreorderを見逃す。
    $rewriteStatements = @($rewriteLoops[0].Body.Statements)
    [string[]]$expectedRewriteStatementTypes = @(
        'AssignmentStatementAst',
        'AssignmentStatementAst',
        'IfStatementAst',
        'AssignmentStatementAst',
        'TryStatementAst',
        'AssignmentStatementAst',
        'AssignmentStatementAst',
        'TryStatementAst',
        'IfStatementAst',
        'TryStatementAst'
    )
    if ($rewriteStatements.Count -ne $expectedRewriteStatementTypes.Count) {
        return $false
    }
    for ($index = 0; $index -lt $expectedRewriteStatementTypes.Count; $index++) {
        if ($rewriteStatements[$index].GetType().Name -cne
            $expectedRewriteStatementTypes[$index]) {
            return $false
        }
    }
    # Top-level rewrite phaseは順序付きstatement digestでも固定する。sortedな
    # assignment oracleだけではcandidate/path等の同型statement swapを検出できない。
    [string[]]$expectedRewriteStatementDigests = @(
        'Lmlzr4ZejNEoQaJu2MMNRBt0p5RciH+aJ+l7mflglJw=',
        'E7PrK13dme92upbr+BBGCMlpcJwE5cXeE3dAvvOVtSo=',
        'mtUNeVA6gz1KL2gbKytM8eujYLY2wSBwmsKFcPNUVuY=',
        'aqpF7bzViaNCLpq5RIl8F9Y6lhR1SFLwLZflCHU1RFU=',
        'Eggbhq5iPzrYOLigSZo/2aL+QFmgK+bTYueEO31Yi3Y=',
        '2kpfwoFHiMo3LyB5EeywrFq14XkbxpT6NNVT3sLnp2c=',
        'raEmT0jRJ+JQvegYT7/nOO3/51VqcpM3v1QMuuVg8VI=',
        'j8LBP8LtmSUMVoOv36ilMCMfYeJbow8k45zjtpv/mp8=',
        'mSApJbcT6f1C66aJCpi76VlDajRAg6P+oESOAlmqP68=',
        'sue4ltC+TK/btkNKBF4Q91MA2IfTKEBKQhdwPupn5+4='
    )
    $rewriteHasher = [System.Security.Cryptography.SHA256]::Create()
    $rewriteUtf8 = [System.Text.UTF8Encoding]::new($false)
    try {
        for ($index = 0; $index -lt $rewriteStatements.Count; $index++) {
            $rewriteDigest = [Convert]::ToBase64String(
                $rewriteHasher.ComputeHash(
                    $rewriteUtf8.GetBytes($rewriteStatements[$index].Extent.Text)
                )
            )
            if ($rewriteDigest -cne $expectedRewriteStatementDigests[$index]) {
                return $false
            }
        }
    }
    finally {
        $rewriteHasher.Dispose()
    }
    $initialGuard = $rewriteStatements[2]
    if ($initialGuard.Clauses.Count -ne 1 -or
        $null -ne $initialGuard.ElseClause -or
        $initialGuard.Clauses[0].Item1.Extent.Text -cne
            '[string]::IsNullOrEmpty([string]$candidateIdentity)' -or
        $initialGuard.Clauses[0].Item2.Statements.Count -ne 2 -or
        $initialGuard.Clauses[0].Item2.Statements[0].Extent.Text -cne
            '$skipped += "$safeLabel (unsafe path, Git environment, or identity)"' -or
        $initialGuard.Clauses[0].Item2.Statements[1] -isnot
            [System.Management.Automation.Language.ContinueStatementAst] -or
        $initialGuard.Clauses[0].Item2.Statements[1].Extent.Text -cne 'continue') {
        return $false
    }

    # Full exampleのread失敗も必ずcurrent targetをcontinueする。short guideだけを
    # 固定しても、canonical loopがstale/uninitialized $tへfall throughできてしまう。
    $guardedReadTry = $rewriteStatements[4]
    [string[]]$expectedFullReadLeft = @('$originalBytes', '$originalDigest', '$t')
    [string[]]$expectedFullReadRight = @(
        '[System.IO.File]::ReadAllBytes($path)',
        'Get-ByteDigest -Bytes $originalBytes',
        'ConvertFrom-StrictUtf8Bytes -Bytes $originalBytes'
    )
    if ($guardedReadTry.Body.Statements.Count -ne 3 -or
        $guardedReadTry.CatchClauses.Count -ne 2 -or
        $null -ne $guardedReadTry.Finally -or
        $guardedReadTry.CatchClauses[0].CatchTypes.Count -ne 1 -or
        $guardedReadTry.CatchClauses[0].CatchTypes[0].TypeName.FullName -cne
            'System.Text.DecoderFallbackException' -or
        $guardedReadTry.CatchClauses[1].CatchTypes.Count -ne 0) {
        return $false
    }
    for ($index = 0; $index -lt 3; $index++) {
        $readStatement = $guardedReadTry.Body.Statements[$index]
        if ($readStatement -isnot
                [System.Management.Automation.Language.AssignmentStatementAst] -or
            $readStatement.Operator -ne
                [System.Management.Automation.Language.TokenKind]::Equals -or
            $readStatement.Left.Extent.Text -cne $expectedFullReadLeft[$index] -or
            $readStatement.Right.Extent.Text -cne $expectedFullReadRight[$index]) {
            return $false
        }
    }
    [string[]]$expectedReadFailureAssignments = @(
        '$skipped += "$safeLabel (strict decode failed)"',
        '$skipped += "$safeLabel (read or digest failed)"'
    )
    for ($catchIndex = 0; $catchIndex -lt 2; $catchIndex++) {
        $catchStatements = @(
            $guardedReadTry.CatchClauses[$catchIndex].Body.Statements
        )
        if ($catchStatements.Count -ne 2 -or
            $catchStatements[0].Extent.Text -cne
                $expectedReadFailureAssignments[$catchIndex] -or
            $catchStatements[1] -isnot
                [System.Management.Automation.Language.ContinueStatementAst] -or
            $catchStatements[1].Extent.Text -cne 'continue') {
            return $false
        }
    }

    $finalGuard = $rewriteStatements[8]
    $finalWriteTry = $rewriteStatements[9]
    $expectedFinalGuardCondition = @'
-not [string]::Equals(
            [string]$candidateIdentity,
            [string]$latestIdentity,
            [System.StringComparison]::Ordinal
        ) -or
        -not [string]::Equals(
            [string]$originalDigest,
            [string]$latestDigest,
            [System.StringComparison]::Ordinal
        )
'@
    if ($finalGuard.Clauses.Count -ne 1 -or
        $null -ne $finalGuard.ElseClause -or
        $finalGuard.Clauses[0].Item1.Extent.Text -cne
            $expectedFinalGuardCondition -or
        $finalGuard.Clauses[0].Item2.Statements.Count -ne 2 -or
        $finalGuard.Clauses[0].Item2.Statements[0].Extent.Text -cne
            '$skipped += "$safeLabel (path, Git identity, or bytes changed before write)"' -or
        $finalGuard.Clauses[0].Item2.Statements[1] -isnot
            [System.Management.Automation.Language.ContinueStatementAst] -or
        $finalGuard.Clauses[0].Item2.Statements[1].Extent.Text -cne 'continue' -or
        $finalGuard.Extent.EndOffset -ge $finalWriteTry.Extent.StartOffset -or
        $finalWriteTry.Body.Statements.Count -ne 1 -or
        $finalWriteTry.Body.Statements[0].Extent.Text -cne
            '[System.IO.File]::WriteAllText($path, $t, [System.Text.UTF8Encoding]::new($false))' -or
        $finalWriteTry.CatchClauses.Count -ne 1 -or
        $null -ne $finalWriteTry.Finally -or
        $finalWriteTry.CatchClauses[0].Body.Statements.Count -ne 1 -or
        $finalWriteTry.CatchClauses[0].Body.Statements[0] -isnot
            [System.Management.Automation.Language.ThrowStatementAst] -or
        $finalWriteTry.CatchClauses[0].Body.Statements[0].Extent.Text -cne
            "throw 'Normalization write failed; stop immediately and recover the guarded target before continuing.'") {
        return $false
    }
    $writeMembers = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $node.Expression.Extent.Text -ceq '[System.IO.File]' -and
                    $node.Member.Extent.Text -ceq 'WriteAllText'
            }, $true)
    )
    if ($writeMembers.Count -ne 1) {
        return $false
    }
    $writeAncestor = $writeMembers[0].Parent
    while ($null -ne $writeAncestor -and
        -not [object]::ReferenceEquals($writeAncestor, $finalWriteTry.Body)) {
        $writeAncestor = $writeAncestor.Parent
    }
    if ($null -eq $writeAncestor) {
        return $false
    }
    return $true
}

function Test-GuardedNormalizationExampleContract {
    param([string]$Source)

    $fencedCode = Get-GuardedNormalizationPatternCode -Source $Source
    if ([string]::IsNullOrWhiteSpace([string]$fencedCode) -or
        -not (Test-GuardedNormalizationPatternAstSafety -FencedCode $fencedCode)) {
        return $false
    }
    $expectedCode = Get-GuardedNormalizationExpectedPatternCode
    if (
        -not [string]::Equals(
            $fencedCode,
            $expectedCode,
            [System.StringComparison]::Ordinal
        )) {
        return $false
    }

    # exact oracleに加えて、上の独立AST allowlistと構造検査を重ねる。
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $fencedCode,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
        return $false
    }

    $requiredFunctions = @(
        'Test-GitRoutingEnvironmentClean',
        'Get-NormalizedRootPath',
        'Get-GitRegularMetadata',
        'Get-GitTrackedRegularFileIdentity',
        'Test-RepositoryRegularFileBoundary',
        'Get-NormalizationCandidateIdentity',
        'Get-ByteDigest',
        'ConvertFrom-StrictUtf8Bytes',
        'ConvertTo-LfTrimmedText',
        'ConvertTo-SafePathLabel'
    )
    $functionDefinitions = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)
    )
    foreach ($requiredFunction in $requiredFunctions) {
        if (@(
                $functionDefinitions |
                    Where-Object { $_.Name -ceq $requiredFunction }
            ).Count -ne 1) {
            return $false
        }
    }
    if ($functionDefinitions.Count -ne $requiredFunctions.Count) {
        return $false
    }

    $assignments = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst]
            }, $true)
    )
    $targetAssignments = @(
        $assignments | Where-Object {
            $_.Left.Extent.Text.EndsWith(
                '$relativePaths',
                [System.StringComparison]::Ordinal
            )
        }
    )
    if ($targetAssignments.Count -ne 1) {
        return $false
    }

    $candidateCalls = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -ceq 'Get-NormalizationCandidateIdentity'
            }, $true)
    )
    if ($candidateCalls.Count -ne 2) {
        return $false
    }

    $unsafeWriteCommands = @(
        $ast.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.CommandAst]) {
                    return $false
                }
                return $node.GetCommandName() -cin @(
                    'Set-Content',
                    'Add-Content',
                    'Out-File',
                    'Copy-Item',
                    'Move-Item',
                    'Remove-Item',
                    'New-Item'
                )
            }, $true)
    )
    if ($unsafeWriteCommands.Count -ne 0) {
        return $false
    }

    $fileWriteMembers = @(
        $ast.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                    return $false
                }
                if ($node.Expression.Extent.Text -cne '[System.IO.File]') {
                    return $false
                }
                return $node.Member.Extent.Text -cin @(
                    'WriteAllText',
                    'WriteAllBytes',
                    'WriteAllLines',
                    'AppendAllText',
                    'AppendAllLines',
                    'OpenWrite',
                    'CreateText',
                    'Create'
                )
            }, $true)
    )
    if ($fileWriteMembers.Count -ne 1 -or
        $fileWriteMembers[0].Member.Extent.Text -cne 'WriteAllText') {
        return $false
    }

    $rewriteLoops = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
                    $node.Extent.Text.Contains(
                        '$candidateIdentity = Get-NormalizationCandidateIdentity'
                    ) -and
                    $node.Extent.Text.Contains(
                        '[System.IO.File]::WriteAllText($path, $t,'
                    )
            }, $true)
    )
    if ($rewriteLoops.Count -ne 1 -or
        $rewriteLoops[0].Parent -isnot
            [System.Management.Automation.Language.NamedBlockAst] -or
        -not $rewriteLoops[0].Extent.Text.Contains(
            '$latestDigest = Get-ByteDigest -Bytes ('
        )) {
        return $false
    }

    $requiredFragments = @(
        '[Environment]::GetEnvironmentVariables().Keys',
        "'GIT_INDEX_FILE'",
        "'GIT_ICASE_PATHSPECS'",
        "'GIT_NO_LAZY_FETCH'",
        "`$name -like 'GIT_CONFIG_KEY_*'",
        "`$name -like 'GIT_TRACE*'",
        'Microsoft.PowerShell.Core\Get-Command',
        "[Environment]::SetEnvironmentVariable(`$traceName, '0', 'Process')",
        'Microsoft.PowerShell.Management\Remove-Item',
        '& $gitExecutable --no-replace-objects --no-lazy-fetch -C $rootBoundary rev-parse --show-toplevel',
        "':(literal)' + `$RelativePath",
        'ls-files --stage -z -- $literalPathSpec',
        'ls-tree -z HEAD -- $literalPathSpec',
        "`$fields[0] -notin @('100644', '100755')",
        "`$fields[2] -ne '0'",
        "`$fields[1] -cne 'blob'",
        '[System.StringComparison]::Ordinal',
        '[System.IO.FileAttributes]::ReparsePoint',
        '[System.IO.File]::ReadAllBytes($path)',
        'Get-ByteDigest -Bytes $originalBytes',
        'ConvertFrom-StrictUtf8Bytes -Bytes $originalBytes',
        'ConvertTo-LfTrimmedText -Text $t',
        'ConvertTo-SafePathLabel -RelativePath $relativePath',
        '[System.Globalization.UnicodeCategory]::Format',
        '[char]::ConvertToUtf32('
    )
    foreach ($fragment in $requiredFragments) {
        if ((Get-OrdinalFragmentCount -Content $fencedCode -Fragment $fragment) -lt 1) {
            return $false
        }
    }
    foreach ($forbiddenFragment in @(
            'status --porcelain',
            '$entries =',
            '$files ='
        )) {
        if ((Get-OrdinalFragmentCount `
                -Content $fencedCode `
                -Fragment $forbiddenFragment) -ne 0) {
            return $false
        }
    }
    if ((Get-OrdinalFragmentCount `
            -Content $fencedCode `
            -Fragment '[System.IO.File]::ReadAllBytes($path)') -ne 2 -or
        (Get-OrdinalFragmentCount `
            -Content $fencedCode `
            -Fragment '[System.IO.File]::WriteAllText($path, $t,') -ne 1) {
        return $false
    }
    return $true
}

function Test-NormalizationSkillReadCatchContract {
    param([string]$Source)

    if ([string]::IsNullOrWhiteSpace($Source)) {
        return $false
    }

    # step 4のnormalization region自体をsource位置でanchorする。別sectionやHTML
    # commentへcanonical decoy fenceを置いてactual手順のunsafe sinkを隠せない。
    $normalizedSource = $Source.Replace("`r`n", "`n")
    if ($normalizedSource.Contains('<!--') -or
        $normalizedSource.Contains('-->')) {
        return $false
    }
    $normalizationHeadings = [regex]::Matches(
        $normalizedSource,
        '(?m)^### (?:Normalization|正規化)[^\n]*$'
    )
    if ($normalizationHeadings.Count -ne 1) {
        return $false
    }
    $normalizationTail = $normalizedSource.Substring(
        $normalizationHeadings[0].Index
    )
    $stepFive = [regex]::Match($normalizationTail, '(?m)^5\. ')
    if (-not $stepFive.Success) {
        return $false
    }
    $normalizationRegion = $normalizationTail.Substring(0, $stepFive.Index)
    $anchoredFences = [regex]::Matches(
        $normalizationRegion,
        '(?ms)^[ \t]*```powershell[ \t]*\n(?<code>.*?)^[ \t]*```[ \t]*$'
    )
    if ($anchoredFences.Count -ne 1) {
        return $false
    }
    $anchoredFenceCode = $anchoredFences[0].Groups['code'].Value

    # Markdown内のPowerShell fenceを個別にparseする。sole WriteAllTextから
    # destructive short snippetを逆引きし、comment/string内のdead decoy tryを
    # contract対象として誤認しない。
    $fences = [regex]::Matches(
        $Source,
        '(?ms)^[ \t]*```powershell[ \t]*\r?\n(?<code>.*?)^[ \t]*```[ \t]*$'
    )
    if ($fences.Count -eq 0) {
        return $false
    }

    # 英日guide内の全PowerShell fenceを順序付きaggregate digestで固定する。
    # 個別contract外のstdout helper等に新しいfilesystem provenanceを混ぜない。
    $fenceAggregate = @(
        $fences | ForEach-Object {
            $_.Groups['code'].Value.Replace("`r`n", "`n")
        }
    ) -join "`n---CODEX-FENCE---`n"
    $fenceHasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fenceDigest = [Convert]::ToBase64String(
            $fenceHasher.ComputeHash(
                ([System.Text.UTF8Encoding]::new($false)).GetBytes(
                    $fenceAggregate
                )
            )
        )
    }
    finally {
        $fenceHasher.Dispose()
    }
    if (@(
            'mzBEmrAxtrs+LHigtwW/HtFy52HbvN/wjwDmr44+UY8=',
            '/FgVJjoIIjqm2KadpTp6KMzIiWKPEAeNSV2dJXmZqsE='
        ) -cnotcontains $fenceDigest) {
        return $false
    }

    $writeContracts = [System.Collections.Generic.List[object]]::new()
    $bomWriteCount = 0
    foreach ($fence in $fences) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $fence.Groups['code'].Value,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if (@($parseErrors).Count -ne 0) {
            return $false
        }
        $cleanBlockProperty = $ast.PSObject.Properties['CleanBlock']
        if ($ast.Attributes.Count -ne 0 -or
            $ast.UsingStatements.Count -ne 0 -or
            $null -ne $ast.ScriptRequirements -or
            $null -ne $ast.ParamBlock -or
            $null -ne $ast.DynamicParamBlock -or
            $null -ne $ast.BeginBlock -or
            $null -ne $ast.ProcessBlock -or
            $null -eq $ast.EndBlock -or
            ($null -ne $cleanBlockProperty -and
                $null -ne $cleanBlockProperty.Value) -or
            -not $ast.EndBlock.Unnamed) {
            return $false
        }
        if (@(
                $ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.TrapStatementAst]
                    }, $true)
            ).Count -ne 0) {
            return $false
        }
        # 全PowerShell fenceのmutation sinkを列挙する。actual snippetをunsafe
        # sinkへ変え、正しいblockをdead functionへ置くdecoyもfail closedにする。
        foreach ($commandAst in @(
                $ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst]
                    }, $true)
            )) {
            if ($commandAst.GetCommandName() -cin @(
                    'Set-Content',
                    'Add-Content',
                    'Out-File',
                    'Copy-Item',
                    'Move-Item',
                    'Remove-Item',
                    'New-Item',
                    'New-Object',
                    'Start-Process',
                    'Invoke-Expression',
                    'Tee-Object'
                )) {
                return $false
            }
        }
        if (@(
                $ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.FileRedirectionAst]
                    }, $true)
            ).Count -ne 0) {
            return $false
        }
        foreach ($memberAst in @(
                $ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
                    }, $true)
            )) {
            if (-not $memberAst.Static -and
                $memberAst.Member.Extent.Text -cin @(
                    'Write',
                    'WriteLine',
                    'WriteAsync',
                    'Flush',
                    'FlushAsync',
                    'SetLength'
                ) -and
                $memberAst.Extent.Text -cnotin @(
                    '$stream.Write($bytes, 0, $bytes.Length)',
                    '$stream.Flush()'
                )) {
                return $false
            }
            if ($memberAst.Expression -isnot
                [System.Management.Automation.Language.TypeExpressionAst]) {
                continue
            }
            $resolvedType = $memberAst.Expression.TypeName.GetReflectionType()
            if ($null -eq $resolvedType) {
                continue
            }
            if ($resolvedType.FullName -ceq 'System.IO.File' -and
                $memberAst.Member.Extent.Text -ceq 'WriteAllText') {
                if ($memberAst.Extent.Text -ceq
                    '[System.IO.File]::WriteAllText($path, $t, [System.Text.UTF8Encoding]::new($false))') {
                    $writeContracts.Add([pscustomobject]@{
                            Member = $memberAst
                            RootEndBlock = $ast.EndBlock
                            FenceCode = $fence.Groups['code'].Value.Replace("`r`n", "`n")
                        })
                    continue
                }
                if ($memberAst.Extent.Text -ceq
                    '[System.IO.File]::WriteAllText($path, $t, [System.Text.UTF8Encoding]::new($true))') {
                    $bomWriteCount++
                    continue
                }
                return $false
            }
            if (($resolvedType.FullName -ceq 'System.IO.File' -and
                    $memberAst.Member.Extent.Text -cin @(
                        'WriteAllBytes',
                        'WriteAllLines',
                        'AppendAllText',
                        'AppendAllLines',
                        'Open',
                        'OpenWrite',
                        'Create',
                        'CreateText',
                        'Delete',
                        'Move',
                        'Copy',
                        'Replace',
                        'Encrypt',
                        'Decrypt'
                    )) -or
                ($resolvedType.FullName -ceq 'System.IO.Directory' -and
                    $memberAst.Member.Extent.Text -cin @(
                        'CreateDirectory',
                        'Delete',
                        'Move'
                    )) -or
                ($resolvedType.FullName -cin @(
                        'System.IO.FileStream',
                        'System.IO.StreamWriter'
                    ) -and $memberAst.Member.Extent.Text -ceq 'new')) {
                return $false
            }
        }
    }
    if ($writeContracts.Count -ne 1 -or
        $bomWriteCount -ne 1 -or
        $writeContracts[0].FenceCode -cne $anchoredFenceCode) {
        return $false
    }

    $snippetBlock = $writeContracts[0].Member.Parent
    while ($null -ne $snippetBlock -and
        $snippetBlock -isnot [System.Management.Automation.Language.NamedBlockAst]) {
        $snippetBlock = $snippetBlock.Parent
    }
    [string[]]$expectedSnippetStatementTypes = @(
        'AssignmentStatementAst',
        'IfStatementAst',
        'AssignmentStatementAst',
        'TryStatementAst',
        'AssignmentStatementAst',
        'AssignmentStatementAst',
        'TryStatementAst',
        'IfStatementAst',
        'TryStatementAst'
    )
    if ($null -eq $snippetBlock -or
        -not [object]::ReferenceEquals(
            $snippetBlock,
            $writeContracts[0].RootEndBlock
        ) -or
        $snippetBlock.Parent -isnot
            [System.Management.Automation.Language.ScriptBlockAst] -or
        $snippetBlock.Statements.Count -ne $expectedSnippetStatementTypes.Count) {
        return $false
    }
    for ($index = 0; $index -lt $expectedSnippetStatementTypes.Count; $index++) {
        if ($snippetBlock.Statements[$index].GetType().Name -cne
            $expectedSnippetStatementTypes[$index]) {
            return $false
        }
    }

    # Typed decode failureと直後のcatch-allは、どちらもdirect unconditional return
    # だけに固定する。read失敗後に未初期化/前値の$tでwriteへ進ませない。
    $guardedReadTry = $snippetBlock.Statements[3]
    [string[]]$expectedReadLeft = @('$originalBytes', '$originalDigest', '$t')
    [string[]]$expectedReadRight = @(
        '[System.IO.File]::ReadAllBytes($path)',
        'Get-ByteDigest -Bytes $originalBytes',
        'ConvertFrom-StrictUtf8Bytes -Bytes $originalBytes'
    )
    if ($guardedReadTry.Body.Statements.Count -ne 3 -or
        $guardedReadTry.CatchClauses.Count -ne 2 -or
        $null -ne $guardedReadTry.Finally -or
        $guardedReadTry.CatchClauses[0].CatchTypes.Count -ne 1 -or
        $guardedReadTry.CatchClauses[0].CatchTypes[0].TypeName.FullName -cne
            'System.Text.DecoderFallbackException' -or
        $guardedReadTry.CatchClauses[1].CatchTypes.Count -ne 0) {
        return $false
    }
    for ($index = 0; $index -lt 3; $index++) {
        $readStatement = $guardedReadTry.Body.Statements[$index]
        if ($readStatement -isnot
                [System.Management.Automation.Language.AssignmentStatementAst] -or
            $readStatement.Operator -ne
                [System.Management.Automation.Language.TokenKind]::Equals -or
            $readStatement.Left.Extent.Text -cne $expectedReadLeft[$index] -or
            $readStatement.Right.Extent.Text -cne $expectedReadRight[$index]) {
            return $false
        }
    }
    foreach ($catchClause in $guardedReadTry.CatchClauses) {
        if ($catchClause.Body.Statements.Count -ne 1 -or
            $catchClause.Body.Statements[0] -isnot
                [System.Management.Automation.Language.ReturnStatementAst] -or
            $null -ne $catchClause.Body.Statements[0].Pipeline -or
            $catchClause.Body.Statements[0].Extent.Text -cne 'return') {
            return $false
        }
    }

    # 同じshort snippetのpre/post guardとwrite catchも固定する。read catchだけが
    # safeでも、initial/final returnやfixed fatalを弱めればunsafe writeへfall throughする。
    $initialGuard = $snippetBlock.Statements[1]
    if ($initialGuard.Clauses.Count -ne 1 -or
        $null -ne $initialGuard.ElseClause -or
        $initialGuard.Clauses[0].Item1.Extent.Text -cne
            '[string]::IsNullOrEmpty([string]$candidateIdentity)' -or
        $initialGuard.Clauses[0].Item2.Statements.Count -ne 1 -or
        $initialGuard.Clauses[0].Item2.Statements[0] -isnot
            [System.Management.Automation.Language.ReturnStatementAst] -or
        $null -ne $initialGuard.Clauses[0].Item2.Statements[0].Pipeline) {
        return $false
    }
    $expectedCandidateAssignment = @'
$candidateIdentity = Get-NormalizationCandidateIdentity `
       -RepoRoot $repo `
       -RelativePath $relativePath
'@
    $expectedLatestIdentityAssignment = @'
$latestIdentity = Get-NormalizationCandidateIdentity `
       -RepoRoot $repo `
       -RelativePath $relativePath
'@
    if ($snippetBlock.Statements[0].Extent.Text -cne
            $expectedCandidateAssignment -or
        $snippetBlock.Statements[2].Extent.Text -cne
            '$path = [System.IO.Path]::Combine($repo, $relativePath)' -or
        $snippetBlock.Statements[4].Extent.Text -cne
            '$t = ConvertTo-LfTrimmedText -Text $t' -or
        $snippetBlock.Statements[5].Extent.Text -cne
            $expectedLatestIdentityAssignment) {
        return $false
    }

    $latestDigestTry = $snippetBlock.Statements[6]
    $expectedLatestDigestAssignment = @'
$latestDigest = Get-ByteDigest -Bytes (
           [System.IO.File]::ReadAllBytes($path)
       )
'@
    if ($latestDigestTry.Body.Statements.Count -ne 1 -or
        $latestDigestTry.Body.Statements[0].Extent.Text -cne
            $expectedLatestDigestAssignment -or
        $latestDigestTry.CatchClauses.Count -ne 1 -or
        $latestDigestTry.CatchClauses[0].CatchTypes.Count -ne 0 -or
        $latestDigestTry.CatchClauses[0].Body.Statements.Count -ne 1 -or
        $latestDigestTry.CatchClauses[0].Body.Statements[0] -isnot
            [System.Management.Automation.Language.ReturnStatementAst] -or
        $null -ne $latestDigestTry.CatchClauses[0].Body.Statements[0].Pipeline -or
        $null -ne $latestDigestTry.Finally) {
        return $false
    }

    $finalGuard = $snippetBlock.Statements[7]
    $finalGuardCondition = $finalGuard.Clauses[0].Item1.Extent.Text -replace '\s', ''
    $expectedFinalGuardCondition =
        '-not[string]::Equals([string]$candidateIdentity,' +
        '[string]$latestIdentity,[System.StringComparison]::Ordinal)-or-' +
        'not[string]::Equals([string]$originalDigest,[string]$latestDigest,' +
        '[System.StringComparison]::Ordinal)'
    if ($finalGuard.Clauses.Count -ne 1 -or
        $null -ne $finalGuard.ElseClause -or
        $finalGuardCondition -cne $expectedFinalGuardCondition -or
        $finalGuard.Clauses[0].Item2.Statements.Count -ne 1 -or
        $finalGuard.Clauses[0].Item2.Statements[0] -isnot
            [System.Management.Automation.Language.ReturnStatementAst] -or
        $null -ne $finalGuard.Clauses[0].Item2.Statements[0].Pipeline) {
        return $false
    }

    $finalWriteTry = $snippetBlock.Statements[8]
    if ($finalWriteTry.Body.Statements.Count -ne 1 -or
        $finalWriteTry.Body.Statements[0].Extent.Text -cne
            '[System.IO.File]::WriteAllText($path, $t, [System.Text.UTF8Encoding]::new($false))' -or
        $finalWriteTry.CatchClauses.Count -ne 1 -or
        $finalWriteTry.CatchClauses[0].CatchTypes.Count -ne 0 -or
        $finalWriteTry.CatchClauses[0].Body.Statements.Count -ne 1 -or
        $finalWriteTry.CatchClauses[0].Body.Statements[0] -isnot
            [System.Management.Automation.Language.ThrowStatementAst] -or
        @(
            "'Normalization write failed; stop immediately and recover the guarded target before continuing.'",
            "'正規化のwriteに失敗した。直ちに停止し、guard対象を復旧してから続行すること。'"
        ) -cnotcontains
            $finalWriteTry.CatchClauses[0].Body.Statements[0].Pipeline.Extent.Text -or
        $null -ne $finalWriteTry.Finally) {
        return $false
    }
    return $true
}

function Assert-NormalizationSkillReadCatchValidatorRegressions {
    param(
        [string]$Source,
        [string]$Description
    )

    if (-not (Test-NormalizationSkillReadCatchContract -Source $Source)) {
        Add-Failure "$Description must keep the short normalization AST contract."
        return
    }
    $pathThrowSource = $Source.Replace(
        "throw 'Normalization write failed; stop immediately and recover the guarded target before continuing.'",
        'throw $path'
    ).Replace(
        "throw '正規化のwriteに失敗した。直ちに停止し、guard対象を復旧してから続行すること。'",
        'throw $path'
    )
    $skillFences = [regex]::Matches(
        $Source,
        '(?ms)^[ \t]*```powershell[ \t]*\r?\n(?<code>.*?)^[ \t]*```[ \t]*$'
    )
    $destructiveFences = @(
        $skillFences | Where-Object {
            $_.Groups['code'].Value.Contains(
                '[System.IO.File]::WriteAllText($path, $t, [System.Text.UTF8Encoding]::new($false))'
            )
        }
    )
    if ($destructiveFences.Count -ne 1) {
        Add-Failure "$Description nested-decoy mutation setup is invalid."
        return
    }
    $destructiveCode = $destructiveFences[0].Groups['code'].Value
    $nestedDeadCode =
        "function Invoke-DeadNormalizationExample {`n" +
        ($destructiveCode -replace '(?m)^', '    ') +
        "`n}`nSet-Content -LiteralPath `$path -Value `$t"
    $nestedDeadSource = $Source.Replace($destructiveCode, $nestedDeadCode)
    $usingNamespaceSource = $Source.Replace(
        $destructiveCode,
        "using namespace System`n" + $destructiveCode
    )
    $requiresVersionSource = $Source.Replace(
        $destructiveCode,
        "#requires -Version 5.1`n" + $destructiveCode
    )
    $trapSource = $Source.Replace(
        $destructiveCode,
        "trap { continue }`n" + $destructiveCode
    )
    $mutations = @(
        @{
            Name = 'using namespace added outside short EndBlock inventory'
            Source = $usingNamespaceSource
        },
        @{
            Name = 'requires version added outside short EndBlock inventory'
            Source = $requiresVersionSource
        },
        @{
            Name = 'short script-scope trap swallows fatal write failure'
            Source = $trapSource
        },
        @{
            Name = 'bare returns changed to return expressions'
            Source = $Source.Replace('return', 'return $path')
        },
        @{
            Name = 'bare returns removed'
            Source = $Source.Replace('return', '$null')
        },
        @{
            Name = 'final identity and digest OR changed to AND'
            Source = $Source.Replace(') -or -not [string]::Equals(', ') -and -not [string]::Equals(')
        },
        @{
            Name = 'fatal write catch leaks path'
            Source = $pathThrowSource
        },
        @{
            Name = 'strict byte read changed to lenient text read'
            Source = $Source.Replace(
                '$originalBytes = [System.IO.File]::ReadAllBytes($path)',
                '$originalBytes = [System.IO.File]::ReadAllText($path)'
            )
        },
        @{
            Name = 'unsafe top-level sink plus nested canonical decoy'
            Source = $nestedDeadSource
        },
        @{
            Name = 'short type alias used for destructive write'
            Source = $Source.Replace(
                '[System.IO.File]::WriteAllText($path, $t, [System.Text.UTF8Encoding]::new($false))',
                '[IO.File]::WriteAllText($path, $t, [System.Text.UTF8Encoding]::new($false))'
            )
        }
    )
    foreach ($mutation in $mutations) {
        if ($mutation.Source -ceq $Source) {
            Add-Failure (
                "$Description short-snippet mutation setup is invalid: " +
                $mutation.Name
            )
        } elseif (Test-NormalizationSkillReadCatchContract -Source $mutation.Source) {
            Add-Failure (
                "$Description short-snippet validator accepted mutation: " +
                $mutation.Name
            )
        }
    }
}

function New-GuardedNormalizationHelperRunner {
    param([string]$Source)

    $fencedCode = Get-GuardedNormalizationPatternCode -Source $Source
    if ([string]::IsNullOrWhiteSpace([string]$fencedCode)) {
        return $null
    }
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $fencedCode,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
        return $null
    }
    $requiredFunctions = @(
        'Test-GitRoutingEnvironmentClean',
        'Get-NormalizedRootPath',
        'Get-GitRegularMetadata',
        'Get-GitTrackedRegularFileIdentity',
        'Test-RepositoryRegularFileBoundary',
        'Get-NormalizationCandidateIdentity',
        'Get-ByteDigest',
        'ConvertFrom-StrictUtf8Bytes',
        'ConvertTo-LfTrimmedText',
        'ConvertTo-SafePathLabel'
    )
    $definitions = @(
        $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) |
            Where-Object { $_.Name -cin $requiredFunctions } |
            Sort-Object { $_.Extent.StartOffset }
    )
    if ($definitions.Count -ne $requiredFunctions.Count) {
        return $null
    }
    $functionSource = (@($definitions | ForEach-Object { $_.Extent.Text }) -join "`n`n")
    $runnerTemplate = @'
param(
    [string]$Operation,
    [string]$RepoRoot,
    [string]$RelativePath,
    [AllowEmptyString()]
    [string]$Raw,
    [string]$Kind,
    [byte[]]$Bytes,
    [AllowEmptyString()]
    [string]$Text
)

__FUNCTION_SOURCE__

switch ($Operation) {
    'Boundary' {
        return Test-RepositoryRegularFileBoundary `
            -RepoRoot $RepoRoot `
            -RelativePath $RelativePath
    }
    'GitMetadata' {
        return Get-GitRegularMetadata -Raw $Raw -Kind $Kind
    }
    'GitIdentity' {
        return Get-GitTrackedRegularFileIdentity `
            -RepoRoot $RepoRoot `
            -RelativePath $RelativePath
    }
    'CandidateIdentity' {
        return Get-NormalizationCandidateIdentity `
            -RepoRoot $RepoRoot `
            -RelativePath $RelativePath
    }
    'RoutingEnvironment' {
        return Test-GitRoutingEnvironmentClean
    }
    'SafeLabel' {
        return ConvertTo-SafePathLabel -RelativePath $RelativePath
    }
    'Digest' {
        return Get-ByteDigest -Bytes $Bytes
    }
    'Decode' {
        return ConvertFrom-StrictUtf8Bytes -Bytes $Bytes
    }
    'NormalizeText' {
        return ConvertTo-LfTrimmedText -Text $Text
    }
    default {
        throw "Unknown guarded-normalization helper operation: $Operation"
    }
}
'@
    try {
        return [scriptblock]::Create(
            $runnerTemplate.Replace('__FUNCTION_SOURCE__', $functionSource)
        )
    }
    catch {
        return $null
    }
}

function Get-NormalizationFixtureBoundaryRoot {
    param([string]$Path)

    # drive rootや`/`では、末尾separator自体がvolume rootの一部である。
    # rootだけはそのまま保ち、通常directoryだけ余分な末尾separatorを除く。
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $volumeRoot = [System.IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrEmpty([string]$volumeRoot)) { return $null }
        if ($full.Length -le $volumeRoot.Length) { return $full }
        return $full.TrimEnd([char[]]@(
                [System.IO.Path]::DirectorySeparatorChar,
                [System.IO.Path]::AltDirectorySeparatorChar
            ))
    }
    catch {
        return $null
    }
}

function Test-NormalizationFixtureCleanupBoundary {
    param(
        [string]$FixtureRoot,
        [string]$FixtureId,
        [string]$OwnerPath,
        [string[]]$DirectoryPaths,
        [string[]]$FilePaths
    )

    # cleanup直前に所有marker、OS temp直下のexact root、全parent属性を再検査する。
    try {
        $tempRoot = Get-NormalizationFixtureBoundaryRoot `
            -Path ([System.IO.Path]::GetTempPath())
        if ([string]::IsNullOrEmpty([string]$tempRoot)) { return $false }
        $actualRoot = [System.IO.Path]::GetFullPath($FixtureRoot)
        $expectedName = "windows-utf8-normalization-boundary-$FixtureId"
        $tempAttributes = [System.IO.File]::GetAttributes($tempRoot)
        if ([System.IO.Path]::GetFileName($actualRoot) -cne $expectedName -or
            [System.IO.Directory]::GetParent($actualRoot).FullName -cne $tempRoot -or
            ($tempAttributes -band [System.IO.FileAttributes]::Directory) -eq 0 -or
            ($tempAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not [System.IO.File]::Exists($OwnerPath) -or
            [System.IO.File]::ReadAllText($OwnerPath) -cne $FixtureId) {
            return $false
        }
        foreach ($directoryPath in $DirectoryPaths) {
            $attributes = [System.IO.File]::GetAttributes($directoryPath)
            if (($attributes -band [System.IO.FileAttributes]::Directory) -eq 0 -or
                ($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $false
            }
        }
        foreach ($filePath in $FilePaths) {
            $attributes = [System.IO.File]::GetAttributes($filePath)
            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0 -or
                ($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $false
            }
        }
        $expectedList = [System.Collections.Generic.List[string]]::new()
        foreach ($directoryPath in $DirectoryPaths) {
            $fullDirectoryPath = [System.IO.Path]::GetFullPath($directoryPath)
            if (-not [string]::Equals(
                    $fullDirectoryPath,
                    $actualRoot,
                    [System.StringComparison]::Ordinal
                )) {
                $expectedList.Add($fullDirectoryPath)
            }
        }
        foreach ($filePath in $FilePaths) {
            $expectedList.Add([System.IO.Path]::GetFullPath($filePath))
        }
        [string[]]$expectedChildren = @($expectedList)
        [Array]::Sort($expectedChildren, [System.StringComparer]::Ordinal)

        # AllDirectoriesは未知reparseを辿り得る。root直下と、属性確認済みの
        # 既知directory直下だけを列挙し、未知directoryへは降りない。
        $actualList = [System.Collections.Generic.List[string]]::new()
        foreach ($entryPath in [System.IO.Directory]::EnumerateFileSystemEntries($actualRoot)) {
            $actualList.Add([System.IO.Path]::GetFullPath($entryPath))
        }
        foreach ($directoryPath in $DirectoryPaths) {
            if ([string]::Equals(
                    [System.IO.Path]::GetFullPath($directoryPath),
                    $actualRoot,
                    [System.StringComparison]::Ordinal
                )) {
                continue
            }
            foreach ($entryPath in [System.IO.Directory]::EnumerateFileSystemEntries($directoryPath)) {
                $actualList.Add([System.IO.Path]::GetFullPath($entryPath))
            }
        }
        [string[]]$actualChildren = @($actualList)
        [Array]::Sort($actualChildren, [System.StringComparer]::Ordinal)
        if ($expectedChildren.Count -ne $actualChildren.Count) {
            return $false
        }
        for ($index = 0; $index -lt $expectedChildren.Count; $index++) {
            if ($expectedChildren[$index] -cne $actualChildren[$index]) {
                return $false
            }
        }
        return $true
    }
    catch {
        return $false
    }
}

function Assert-GuardedNormalizationBoundarySemantics {
    param([string]$Source)

    $runner = New-GuardedNormalizationHelperRunner -Source $Source
    if ($null -eq $runner) {
        Add-Failure 'Guarded-normalization helper extraction or compilation failed.'
        return
    }

    # TEMP/TMPDIRがvolume rootを直接指す構成でもcleanup境界を壊さない。
    $currentTempPath = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::GetTempPath()
    )
    $volumeRoot = [System.IO.Path]::GetPathRoot($currentTempPath)
    $normalizedVolumeRoot = Get-NormalizationFixtureBoundaryRoot -Path $volumeRoot
    if ([string]::IsNullOrEmpty([string]$normalizedVolumeRoot) -or
        -not [string]::Equals(
            [System.IO.Path]::GetFullPath($volumeRoot),
            $normalizedVolumeRoot,
            [System.StringComparison]::Ordinal
        )) {
        Add-Failure 'Guarded-normalization cleanup changed an exact volume root.'
    }

    # 実repositoryではread-only queryだけを行い、HEAD/index/top-level合成を確認する。
    $trackedIdentity = & $runner `
        -Operation 'GitIdentity' `
        -RepoRoot $root `
        -RelativePath 'examples/guarded-normalization.md'
    if ([string]::IsNullOrEmpty([string]$trackedIdentity)) {
        Add-Failure 'Guarded-normalization rejected a HEAD/index regular file.'
    }
    $candidateIdentity = & $runner `
        -Operation 'CandidateIdentity' `
        -RepoRoot $root `
        -RelativePath 'examples/guarded-normalization.md'
    if ([string]::IsNullOrEmpty([string]$candidateIdentity)) {
        Add-Failure 'Guarded-normalization rejected a contained HEAD/index regular file.'
    }
    foreach ($invalidIdentityCase in @(
            @{ RepoRoot = $root; RelativePath = 'synthetic-untracked-normalization.md' },
            @{ RepoRoot = (Join-Path $root 'examples'); RelativePath = 'guarded-normalization.md' }
        )) {
        $identity = & $runner `
            -Operation 'GitIdentity' `
            -RepoRoot $invalidIdentityCase.RepoRoot `
            -RelativePath $invalidIdentityCase.RelativePath
        if (-not [string]::IsNullOrEmpty([string]$identity)) {
            Add-Failure 'Guarded-normalization accepted missing HEAD identity or a mismatched top level.'
        }
    }

    # alternate indexとcase-insensitive pathspecは大小文字variantも存在だけで拒否する。
    $routingFixtures = @(
        @{
            Name = 'Git_Index_File'
            Value = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                ('blocked-normalization-index-' + [guid]::NewGuid().ToString('N'))
            )
        },
        @{ Name = 'git_icase_pathspecs'; Value = '1' }
    )
    foreach ($routingFixture in $routingFixtures) {
        $savedValue = [Environment]::GetEnvironmentVariable($routingFixture.Name)
        $hadValue = $null -ne $savedValue
        try {
            [Environment]::SetEnvironmentVariable(
                $routingFixture.Name,
                $routingFixture.Value,
                [EnvironmentVariableTarget]::Process
            )
            if (& $runner -Operation 'RoutingEnvironment') {
                Add-Failure "Guarded-normalization accepted Git routing: $($routingFixture.Name)"
            }
            $redirectedIdentity = & $runner `
                -Operation 'GitIdentity' `
                -RepoRoot $root `
                -RelativePath 'examples/guarded-normalization.md'
            if (-not [string]::IsNullOrEmpty([string]$redirectedIdentity)) {
                Add-Failure "Guarded-normalization queried with Git routing: $($routingFixture.Name)"
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable(
                $routingFixture.Name,
                $(if ($hadValue) { $savedValue } else { $null }),
                [EnvironmentVariableTarget]::Process
            )
        }
    }

    # pure metadata fixturesは実index/object databaseを書き換えずmode/stage/HEADを固定する。
    $metadataFixtures = @(
        @{ Name = 'regular index'; Raw = "100644 abcdef 0`texample.md`0"; Kind = 'Index'; Accepted = $true },
        @{ Name = 'executable index'; Raw = "100755 abcdef 0`texample.md`0"; Kind = 'Index'; Accepted = $true },
        @{ Name = 'index symlink'; Raw = "120000 abcdef 0`texample.md`0"; Kind = 'Index'; Accepted = $false },
        @{ Name = 'index submodule'; Raw = "160000 abcdef 0`texample.md`0"; Kind = 'Index'; Accepted = $false },
        @{ Name = 'conflict stage'; Raw = "100644 abcdef 1`texample.md`0"; Kind = 'Index'; Accepted = $false },
        @{ Name = 'multiple index records'; Raw = "100644 abcdef 0`ta.md`0100644 fedcba 0`tb.md`0"; Kind = 'Index'; Accepted = $false },
        @{ Name = 'regular HEAD blob'; Raw = "100644 blob abcdef`texample.md`0"; Kind = 'Head'; Accepted = $true },
        @{ Name = 'HEAD symlink'; Raw = "120000 blob abcdef`texample.md`0"; Kind = 'Head'; Accepted = $false },
        @{ Name = 'HEAD tree'; Raw = "040000 tree abcdef`texample`0"; Kind = 'Head'; Accepted = $false },
        @{ Name = 'multiple HEAD records'; Raw = "100644 blob abcdef`ta.md`0100644 blob fedcba`tb.md`0"; Kind = 'Head'; Accepted = $false }
    )
    foreach ($fixture in $metadataFixtures) {
        $metadata = & $runner `
            -Operation 'GitMetadata' `
            -Raw $fixture.Raw `
            -Kind $fixture.Kind
        $accepted = -not [string]::IsNullOrEmpty([string]$metadata)
        if ($accepted -ne $fixture.Accepted) {
            Add-Failure "Guarded-normalization metadata fixture failed: $($fixture.Name)"
        }
    }

    # byte drift、重複BOM、lone CR、diagnostic spoofingをpure fixtureで確認する。
    [byte[]]$bytesA = @(0x61, 0x0A)
    [byte[]]$bytesB = @(0x61, 0x0D, 0x0A)
    $digestA1 = & $runner -Operation 'Digest' -Bytes $bytesA
    $digestA2 = & $runner -Operation 'Digest' -Bytes $bytesA
    $digestB = & $runner -Operation 'Digest' -Bytes $bytesB
    if ([string]::IsNullOrEmpty([string]$digestA1) -or
        $digestA1 -cne $digestA2 -or
        $digestA1 -ceq $digestB) {
        Add-Failure 'Guarded-normalization byte digest is not stable and discriminating.'
    }

    [byte[]]$doubleBomUtf8 = @(
        0xEF, 0xBB, 0xBF,
        0xEF, 0xBB, 0xBF,
        0x61
    )
    $decoded = & $runner -Operation 'Decode' -Bytes $doubleBomUtf8
    if ($decoded -cne 'a') {
        Add-Failure 'Guarded-normalization did not strip repeated leading UTF-8 BOM sequences.'
    }
    $invalidUtf8Rejected = $false
    try {
        [void](& $runner -Operation 'Decode' -Bytes ([byte[]]@(0x80)))
    }
    catch [System.Text.DecoderFallbackException] {
        $invalidUtf8Rejected = $true
    }
    if (-not $invalidUtf8Rejected) {
        Add-Failure 'Guarded-normalization strict decoder accepted invalid UTF-8.'
    }
    $normalizedText = & $runner `
        -Operation 'NormalizeText' `
        -Text "a  `r`nb`t `rc `n"
    if ($normalizedText -cne "a`nb`nc`n") {
        Add-Failure 'Guarded-normalization did not normalize CRLF/lone-CR and trailing whitespace.'
    }

    $supplementaryFormat = [char]::ConvertFromUtf32(0xE0020)
    $emoji = [char]::ConvertFromUtf32(0x1F600)
    $unsafeName = "line`n$([char]0x1B)[31m$([char]0x202E)$([char]0x2028)$supplementaryFormat$emoji.md"
    $safeLabel = & $runner -Operation 'SafeLabel' -RelativePath $unsafeName
    if (-not $safeLabel.Contains('\u000A') -or
        -not $safeLabel.Contains('\u001B') -or
        -not $safeLabel.Contains('\u202E') -or
        -not $safeLabel.Contains('\u2028') -or
        -not $safeLabel.Contains('\U000E0020') -or
        -not $safeLabel.Contains($emoji)) {
        Add-Failure 'Guarded-normalization diagnostic label did not escape unsafe Unicode scalars.'
    }
    $labelIndex = 0
    while ($labelIndex -lt $safeLabel.Length) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory(
            $safeLabel,
            $labelIndex
        )
        if ($category -in @(
                [System.Globalization.UnicodeCategory]::Control,
                [System.Globalization.UnicodeCategory]::Format,
                [System.Globalization.UnicodeCategory]::Surrogate,
                [System.Globalization.UnicodeCategory]::LineSeparator,
                [System.Globalization.UnicodeCategory]::ParagraphSeparator
            )) {
            Add-Failure 'Guarded-normalization diagnostic label retained an unsafe Unicode scalar.'
            break
        }
        if ([char]::IsHighSurrogate($safeLabel[$labelIndex]) -and
            $labelIndex + 1 -lt $safeLabel.Length -and
            [char]::IsLowSurrogate($safeLabel[$labelIndex + 1])) {
            $labelIndex += 2
        } else {
            $labelIndex++
        }
    }
    $boundaryLabel = & $runner `
        -Operation 'SafeLabel' `
        -RelativePath (('a' * 159) + $emoji)
    if (-not $boundaryLabel.Contains($emoji)) {
        Add-Failure 'Guarded-normalization diagnostic truncation split a surrogate pair.'
    }

    # OS temp直下に所有fixtureを作り、outside/reparse拒否を実pathで検証する。
    $fixtureId = [guid]::NewGuid().ToString('N')
    $fixtureRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        "windows-utf8-normalization-boundary-$fixtureId"
    $fixtureRepo = Join-Path $fixtureRoot 'repo'
    $fixtureSibling = Join-Path $fixtureRoot 'repo2'
    $outsideRoot = Join-Path $fixtureRoot 'outside'
    $regularPath = Join-Path $fixtureRepo 'regular.md'
    $siblingPath = Join-Path $fixtureSibling 'sibling.md'
    $outsidePath = Join-Path $outsideRoot 'outside.md'
    $linkPath = Join-Path $fixtureRepo 'linked'
    $ownerPath = Join-Path $fixtureRoot '.owner'
    $traceArtifactPath = Join-Path $fixtureRoot 'trace-output.log'
    $sentinel = 'outside sentinel must remain unchanged'
    $linkCreated = $false
    $linkRemoved = $false
    try {
        foreach ($directory in @(
                $fixtureRoot,
                $fixtureRepo,
                $fixtureSibling,
                $outsideRoot
            )) {
            [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        }
        [System.IO.File]::WriteAllText($ownerPath, $fixtureId)
        [System.IO.File]::WriteAllText($regularPath, 'regular')
        [System.IO.File]::WriteAllText($siblingPath, 'sibling')
        [System.IO.File]::WriteAllText($outsidePath, $sentinel)

        # Caller trace routing must fail before Git starts and therefore must
        # not append even one byte to an outside diagnostic target.
        $previousTrace2Event = [Environment]::GetEnvironmentVariable(
            'GIT_TRACE2_EVENT',
            'Process'
        )
        try {
            [Environment]::SetEnvironmentVariable(
                'GIT_TRACE2_EVENT',
                $traceArtifactPath,
                'Process'
            )
            $traceRoutedIdentity = & $runner `
                -Operation 'GitIdentity' `
                -RepoRoot $root `
                -RelativePath 'examples/guarded-normalization.md'
            if (-not [string]::IsNullOrEmpty([string]$traceRoutedIdentity)) {
                Add-Failure 'Guarded-normalization accepted caller Git trace routing.'
            }
        }
        finally {
            if ($null -eq $previousTrace2Event) {
                Microsoft.PowerShell.Management\Remove-Item `
                    -LiteralPath 'Env:GIT_TRACE2_EVENT' `
                    -ErrorAction Stop
            } else {
                [Environment]::SetEnvironmentVariable(
                    'GIT_TRACE2_EVENT',
                    $previousTrace2Event,
                    'Process'
                )
            }
            $restoredTrace2Event = [Environment]::GetEnvironmentVariable(
                'GIT_TRACE2_EVENT',
                'Process'
            )
            if (($null -eq $previousTrace2Event -and
                    [Environment]::GetEnvironmentVariables().Contains(
                        'GIT_TRACE2_EVENT'
                    )) -or
                ($null -ne $previousTrace2Event -and
                    -not [string]::Equals(
                        $previousTrace2Event,
                        $restoredTrace2Event,
                        [System.StringComparison]::Ordinal
                    ))) {
                Add-Failure 'Guarded-normalization could not restore caller Trace2 state.'
            }
        }
        if ([System.IO.File]::Exists($traceArtifactPath)) {
            Add-Failure 'Guarded-normalization created a caller-routed Git trace artifact.'
            # pathは直前に作ったowned fixture直下のexact child。削除失敗時は
            # cleanup boundaryがunknown childを検出してrootを保持する。
            try {
                [System.IO.File]::Delete($traceArtifactPath)
            }
            catch {
                Add-Failure 'Guarded-normalization could not remove its trace probe artifact.'
            }
        }

        if (-not (& $runner `
                -Operation 'Boundary' `
                -RepoRoot $fixtureRepo `
                -RelativePath 'regular.md')) {
            Add-Failure 'Guarded-normalization rejected a contained regular file.'
        }
        foreach ($outsideCandidate in @(
                $outsidePath,
                (Join-Path '..' (Join-Path 'outside' 'outside.md')),
                (Join-Path '..' (Join-Path 'repo2' 'sibling.md'))
            )) {
            if (& $runner `
                    -Operation 'Boundary' `
                    -RepoRoot $fixtureRepo `
                    -RelativePath $outsideCandidate) {
                Add-Failure 'Guarded-normalization accepted an outside candidate.'
            }
        }

        $isWindowsHost = (
            [System.Environment]::OSVersion.Platform -eq
            [System.PlatformID]::Win32NT
        )
        if ($isWindowsHost) {
            New-Item `
                -ItemType Junction `
                -Path $linkPath `
                -Target $outsideRoot `
                -ErrorAction Stop | Out-Null
        } else {
            New-Item `
                -ItemType SymbolicLink `
                -Path $linkPath `
                -Target $outsideRoot `
                -ErrorAction Stop | Out-Null
        }
        $linkCreated = $true
        if (& $runner `
                -Operation 'Boundary' `
                -RepoRoot $fixtureRepo `
                -RelativePath (Join-Path 'linked' 'outside.md')) {
            Add-Failure 'Guarded-normalization accepted a reparse/symlink parent.'
        }
        if ([System.IO.File]::ReadAllText($outsidePath) -cne $sentinel) {
            Add-Failure 'Guarded-normalization changed the outside sentinel.'
        }
    }
    catch {
        Add-Failure "Guarded-normalization boundary fixture failed: $($_.Exception.Message)"
    }
    finally {
        # linkを最初にunlinkし、所有境界の再検証後だけ既知file/空directoryを個別削除する。
        if ($linkCreated -and
            ([System.IO.Directory]::Exists($linkPath) -or
                [System.IO.File]::Exists($linkPath))) {
            try {
                if ([System.Environment]::OSVersion.Platform -eq
                    [System.PlatformID]::Win32NT) {
                    ([System.IO.DirectoryInfo]::new($linkPath)).Delete()
                } else {
                    [System.IO.File]::Delete($linkPath)
                }
                $linkRemoved = $true
            }
            catch {
                Add-Failure "Guarded-normalization link cleanup failed: $($_.Exception.Message)"
            }
        } elseif (-not $linkCreated) {
            $linkRemoved = $true
        }

        $directories = @(
            $fixtureRoot,
            $fixtureRepo,
            $fixtureSibling,
            $outsideRoot
        )
        $files = @(
            $ownerPath,
            $regularPath,
            $siblingPath,
            $outsidePath
        )
        if ($linkRemoved -and
            (Test-NormalizationFixtureCleanupBoundary `
                -FixtureRoot $fixtureRoot `
                -FixtureId $fixtureId `
                -OwnerPath $ownerPath `
                -DirectoryPaths $directories `
                -FilePaths $files)) {
            $childCleanupSucceeded = $true
            try {
                foreach ($filePath in @(
                        $regularPath,
                        $siblingPath,
                        $outsidePath
                    )) {
                    [System.IO.File]::Delete($filePath)
                }
                foreach ($directoryPath in @(
                        $fixtureRepo,
                        $fixtureSibling,
                        $outsideRoot
                    )) {
                    [System.IO.Directory]::Delete($directoryPath)
                }
            }
            catch {
                $childCleanupSucceeded = $false
                Add-Failure "Guarded-normalization child cleanup failed; owner marker retained: $fixtureRoot"
            }
            if ($childCleanupSucceeded) {
                try {
                    # owner markerを最後まで残し、root削除の直前だけ外す。
                    [System.IO.File]::Delete($ownerPath)
                    [System.IO.Directory]::Delete($fixtureRoot)
                }
                catch {
                    # root削除だけが失敗した場合は、exact通常rootを再確認して
                    # CreateNewでmarkerを復元する。既存fileは上書きしない。
                    try {
                        if ([System.IO.Directory]::Exists($fixtureRoot) -and
                            -not [System.IO.File]::Exists($ownerPath)) {
                            $actualRoot = [System.IO.Path]::GetFullPath($fixtureRoot)
                            $tempRoot = Get-NormalizationFixtureBoundaryRoot `
                                -Path ([System.IO.Path]::GetTempPath())
                            $attributes = [System.IO.File]::GetAttributes($actualRoot)
                            if (-not [string]::IsNullOrEmpty([string]$tempRoot) -and
                                [System.IO.Path]::GetFileName($actualRoot) -ceq
                                    "windows-utf8-normalization-boundary-$fixtureId" -and
                                [System.IO.Directory]::GetParent($actualRoot).FullName -ceq
                                    $tempRoot -and
                                ($attributes -band [System.IO.FileAttributes]::Directory) -ne 0 -and
                                ($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                                $markerBytes = [System.Text.Encoding]::UTF8.GetBytes($fixtureId)
                                $markerStream = [System.IO.File]::Open(
                                    $ownerPath,
                                    [System.IO.FileMode]::CreateNew,
                                    [System.IO.FileAccess]::Write,
                                    [System.IO.FileShare]::None
                                )
                                try {
                                    $markerStream.Write($markerBytes, 0, $markerBytes.Length)
                                } finally {
                                    $markerStream.Dispose()
                                }
                            }
                        }
                    }
                    catch {
                        # Cleanup failure is already fatal; avoid masking it with recovery detail.
                    }
                    Add-Failure "Guarded-normalization root cleanup failed; residue retained: $fixtureRoot"
                }
            }
        } else {
            Add-Failure "Guarded-normalization fixture cleanup boundary failed; residue retained: $fixtureRoot"
        }
    }
}

function Assert-GuardedNormalizationExampleValidatorRegressions {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (guarded-normalization contract)"
        return
    }
    $source = Read-StrictUtf8Text `
        -FilePath $filePath `
        -Description $RelativePath
    if ($null -eq $source) {
        return
    }

    if (-not (Test-GuardedNormalizationExampleContract -Source $source)) {
        Add-Failure "$RelativePath must keep the guarded normalization source contract."
        return
    }
    Assert-GuardedNormalizationBoundarySemantics -Source $source

    # 代表的なweakeningがexact source contractを必ず破ることを自己testする。
    $patternCode = Get-GuardedNormalizationPatternCode -Source $source
    $mutationTokens = $null
    $mutationParseErrors = $null
    $mutationAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $patternCode,
        [ref]$mutationTokens,
        [ref]$mutationParseErrors
    )
    $mutationRewriteLoops = @(
        $mutationAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
                    $node.Extent.Text.Contains(
                        '[System.IO.File]::WriteAllText($path, $t,'
                    )
            }, $true)
    )
    if (@($mutationParseErrors).Count -ne 0 -or
        $mutationRewriteLoops.Count -ne 1 -or
        $mutationRewriteLoops[0].Body.Statements.Count -ne 10) {
        Add-Failure 'Guarded-normalization reorder mutation setup is invalid.'
        return
    }
    $mutationGuardText = $mutationRewriteLoops[0].Body.Statements[8].Extent.Text
    $mutationWriteText = $mutationRewriteLoops[0].Body.Statements[9].Extent.Text
    $orderedGuardedWriteTail =
        '    ' + $mutationGuardText + "`n    " + $mutationWriteText
    $movedWriteBeforeGuardTail =
        '    ' + $mutationWriteText + "`n    " + $mutationGuardText
    $movedWriteBeforeGuardCode = $patternCode.Replace(
        $orderedGuardedWriteTail,
        $movedWriteBeforeGuardTail
    )
    $mutationStatements = @($mutationRewriteLoops[0].Body.Statements)
    $mutationInitialGuard = $mutationStatements[2]
    $mutationReadTry = $mutationStatements[4]
    $mutationFinalGuard = $mutationStatements[8]
    $mutationFinalWriteTry = $mutationStatements[9]
    $candidatePathSwapCode = $patternCode.Replace(
        $mutationStatements[1].Extent.Text,
        '__CODEX_CANDIDATE_ASSIGNMENT_PLACEHOLDER__'
    ).Replace(
        $mutationStatements[3].Extent.Text,
        $mutationStatements[1].Extent.Text
    ).Replace(
        '__CODEX_CANDIDATE_ASSIGNMENT_PLACEHOLDER__',
        $mutationStatements[3].Extent.Text
    )
    $initialGuardWithoutContinueCode = $patternCode.Replace(
        $mutationInitialGuard.Extent.Text,
        $mutationInitialGuard.Extent.Text.Replace("`n        continue", '')
    )
    $typedReadCatchWithoutContinueCode = $patternCode.Replace(
        $mutationReadTry.CatchClauses[0].Extent.Text,
        $mutationReadTry.CatchClauses[0].Extent.Text.Replace("`n        continue", '')
    )
    $catchAllReadWithoutContinueCode = $patternCode.Replace(
        $mutationReadTry.CatchClauses[1].Extent.Text,
        $mutationReadTry.CatchClauses[1].Extent.Text.Replace("`n        continue", '')
    )
    $orderedReadBody =
        '        ' + $mutationReadTry.Body.Statements[0].Extent.Text + "`n        " +
        $mutationReadTry.Body.Statements[1].Extent.Text + "`n        " +
        $mutationReadTry.Body.Statements[2].Extent.Text
    $decodeBeforeReadBody =
        '        ' + $mutationReadTry.Body.Statements[2].Extent.Text + "`n        " +
        $mutationReadTry.Body.Statements[0].Extent.Text + "`n        " +
        $mutationReadTry.Body.Statements[1].Extent.Text
    $decodeBeforeReadCode = $patternCode.Replace(
        $orderedReadBody,
        $decodeBeforeReadBody
    )
    $finalGuardWithoutContinueCode = $patternCode.Replace(
        $mutationFinalGuard.Extent.Text,
        $mutationFinalGuard.Extent.Text.Replace("`n        continue", '')
    )
    $finalGuardFalseConditionCode = $patternCode.Replace(
        $mutationFinalGuard.Clauses[0].Item1.Extent.Text,
        '$false -and (' +
            $mutationFinalGuard.Clauses[0].Item1.Extent.Text +
            ')'
    )
    $throwPathCode = $patternCode.Replace(
        $mutationFinalWriteTry.CatchClauses[0].Body.Statements[0].Extent.Text,
        'throw $path'
    )
    $mutationCandidateFunctions = @(
        $mutationAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq 'Get-NormalizationCandidateIdentity'
            }, $true)
    )
    if ($mutationCandidateFunctions.Count -ne 1) {
        Add-Failure 'Guarded-normalization candidate mutation setup is invalid.'
        return
    }
    $mutationCandidateText = $mutationCandidateFunctions[0].Extent.Text
    $candidateEarlyReturnCode = $patternCode.Replace(
        $mutationCandidateText,
        $mutationCandidateText.Replace(
            'function Get-NormalizationCandidateIdentity {',
            "function Get-NormalizationCandidateIdentity {`n    return 'constant'"
        )
    )
    $candidateLiteralIdentityCode = $patternCode.Replace(
        $mutationCandidateText,
        $mutationCandidateText.Replace(
            '-RelativePath $RelativePath',
            "-RelativePath 'examples/guarded-normalization.md'"
        )
    )
    $mutationFinalDiagnostic = $mutationAst.EndBlock.Statements[14]
    $rawDiagnosticOutputCode = $patternCode.Replace(
        $mutationFinalDiagnostic.Extent.Text,
        $mutationFinalDiagnostic.Extent.Text.Replace(
            "`n    `$skipped",
            "`n    `$path"
        )
    )
    $astSafetyMutations = @(
        @{
            Name = 'using namespace added outside EndBlock inventory'
            Code = "using namespace System`n" + $patternCode
        },
        @{
            Name = 'requires version added outside EndBlock inventory'
            Code = "#requires -Version 5.1`n" + $patternCode
        },
        @{
            Name = 'script-scope trap swallows fatal write failure'
            Code = "trap { continue }`n" + $patternCode
        },
        @{
            Name = 'System.IO.File Open create sink'
            Code = $patternCode.Replace(
                '$skipped = @()',
                "[System.IO.File]::Open('unguarded.md', [System.IO.FileMode]::Create).Dispose()`n`$skipped = @()"
            )
        },
        @{
            Name = 'short IO.File Open create sink'
            Code = $patternCode.Replace(
                '$skipped = @()',
                "[IO.File]::Open('unguarded.md', [IO.FileMode]::Create).Dispose()`n`$skipped = @()"
            )
        },
        @{
            Name = 'case-varied System.IO.File Open create sink'
            Code = $patternCode.Replace(
                '$skipped = @()',
                "[system.io.file]::Open('unguarded.md', [system.io.filemode]::Create).Dispose()`n`$skipped = @()"
            )
        },
        @{
            Name = 'New-Object StreamWriter instance sink'
            Code = $patternCode.Replace(
                '$skipped = @()',
                ('$writer = New-Object System.IO.StreamWriter ''unguarded.md''' + "`n" +
                    '$writer.Write(''x'')' + "`n" +
                    '$writer.Dispose()' + "`n" +
                    '$skipped = @()')
            )
        },
        @{
            Name = 'Trace2 cleanup target broadened'
            Code = $patternCode.Replace('"Env:$traceName"', '$traceName')
        },
        @{
            Name = 'Trace2 cleanup allowlist broadened'
            Code = $patternCode.Replace(
                "@('GIT_TRACE2', 'GIT_TRACE2_EVENT', 'GIT_TRACE2_PERF')",
                "@('GIT_TRACE2', 'GIT_TRACE2_EVENT', 'GIT_TRACE2_PERF', 'HOME')"
            )
        },
        @{
            Name = 'Trace2 allowlist inherited with compound assignment'
            Code = $patternCode.Replace(
                '$trace2OverrideNames = @(',
                '$trace2OverrideNames += @('
            )
        },
        @{
            Name = 'Trace2 setup no longer first in try'
            Code = $patternCode.Replace(
                "    try {`n        foreach (`$traceName in `$trace2OverrideNames) {",
                "    try {`n        if (`$false) { }`n        foreach (`$traceName in `$trace2OverrideNames) {"
            )
        },
        @{
            Name = 'Trace2 set unreachable inside loop'
            Code = $patternCode.Replace(
                "        foreach (`$traceName in `$trace2OverrideNames) {`n            [Environment]::SetEnvironmentVariable",
                "        foreach (`$traceName in `$trace2OverrideNames) {`n            continue`n            [Environment]::SetEnvironmentVariable"
            )
        },
        @{
            Name = 'Trace2 cleanup unreachable inside loop'
            Code = $patternCode.Replace(
                "        foreach (`$traceName in `$trace2OverrideNames) {`n            Microsoft.PowerShell.Management\Remove-Item",
                "        foreach (`$traceName in `$trace2OverrideNames) {`n            continue`n            Microsoft.PowerShell.Management\Remove-Item"
            )
        },
        @{
            Name = 'write moved before final identity and digest guard'
            Code = $movedWriteBeforeGuardCode
        },
        @{
            Name = 'rewrite loop adds an unrequested tracked path'
            Code = $patternCode.Replace(
                'foreach ($relativePath in $relativePaths)',
                "foreach (`$relativePath in @(`$relativePaths; 'README.md'))"
            )
        },
        @{
            Name = 'candidate and path assignments swapped'
            Code = $candidatePathSwapCode
        },
        @{
            Name = 'initial candidate guard continue removed'
            Code = $initialGuardWithoutContinueCode
        },
        @{
            Name = 'typed read catch continue removed'
            Code = $typedReadCatchWithoutContinueCode
        },
        @{
            Name = 'catch-all read continue removed'
            Code = $catchAllReadWithoutContinueCode
        },
        @{
            Name = 'strict decode moved before byte read'
            Code = $decodeBeforeReadCode
        },
        @{
            Name = 'final identity and digest guard continue removed'
            Code = $finalGuardWithoutContinueCode
        },
        @{
            Name = 'final identity and digest guard forced false'
            Code = $finalGuardFalseConditionCode
        },
        @{
            Name = 'fatal write catch leaks path'
            Code = $throwPathCode
        },
        @{
            Name = 'candidate helper early constant return'
            Code = $candidateEarlyReturnCode
        },
        @{
            Name = 'candidate helper checks another tracked literal'
            Code = $candidateLiteralIdentityCode
        },
        @{
            Name = 'digest helper returns constant for unmeasured prefix'
            Code = $patternCode.Replace(
                'function Get-ByteDigest {',
                "function Get-ByteDigest {`n    if (`$Bytes.Length -gt 0 -and `$Bytes[0] -eq 0x78) { return 'constant' }"
            )
        },
        @{
            Name = 'strict decoder strips an extra unmeasured byte'
            Code = $patternCode.Replace(
                '    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)',
                "    if (`$bomLength -eq 6 -and `$Bytes.Length -gt 6 -and `$Bytes[6] -eq 0x78) { `$bomLength++ }`n    `$strictUtf8 = [System.Text.UTF8Encoding]::new(`$false, `$true)"
            )
        },
        @{
            Name = 'final diagnostics emit raw absolute path'
            Code = $rawDiagnosticOutputCode
        },
        @{
            Name = 'dynamic Git command changed to clean'
            Code = $patternCode.Replace(
                'rev-parse --show-toplevel',
                'clean -fd'
            )
        },
        @{
            Name = 'environment trace assignment injected'
            Code = $patternCode.Replace(
                '$skipped = @()',
                "`$env:GIT_TRACE2_EVENT = 'outside'`n`$skipped = @()"
            )
        },
        @{
            Name = 'guarded path reassigned'
            Code = $patternCode.Replace(
                '$skipped = @()',
                "`$path = 'outside'`n`$skipped = @()"
            )
        },
        @{
            Name = 'Git executable reassigned'
            Code = $patternCode.Replace(
                '$gitExecutable = $gitApplications[0].Source',
                '$gitExecutable = ''git'''
            )
        },
        @{
            Name = 'System.IO.Directory create sink'
            Code = $patternCode.Replace(
                '$skipped = @()',
                "[System.IO.Directory]::CreateDirectory('unguarded')`n`$skipped = @()"
            )
        },
        @{
            Name = 'Start-Process command sink'
            Code = $patternCode.Replace(
                '$skipped = @()',
                "Start-Process pwsh`n`$skipped = @()"
            )
        }
    )
    foreach ($mutation in $astSafetyMutations) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput(
            $mutation.Code,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null
        if ($mutation.Code -ceq $patternCode -or @($parseErrors).Count -ne 0) {
            Add-Failure (
                'Guarded-normalization AST mutation setup is invalid: ' +
                $mutation.Name
            )
        } elseif (Test-GuardedNormalizationPatternAstSafety `
                -FencedCode $mutation.Code) {
            Add-Failure (
                'Guarded-normalization AST safety accepted mutation: ' +
                $mutation.Name
            )
        }
    }

    $sourceMutations = @(
        @{ Name = 'Git routing check bypassed'; Source = $source.Replace('if (-not (Test-GitRoutingEnvironmentClean)) { return $null }', 'if ($false) { return $null }') },
        @{ Name = 'case-insensitive pathspec routing allowed'; Source = $source.Replace("        'GIT_ICASE_PATHSPECS'", "        'GIT_UNUSED_PLACEHOLDER'") },
        @{ Name = 'lazy-fetch environment guard removed'; Source = $source.Replace("        'GIT_NO_LAZY_FETCH'", "        'GIT_UNUSED_LAZY_PLACEHOLDER'") },
        @{ Name = 'lazy fetch allowed'; Source = $source.Replace(' --no-lazy-fetch', '') },
        @{ Name = 'Git trace environment accepted'; Source = $source.Replace("            `$name -like 'GIT_TRACE*')", "            `$name -like 'GIT_UNUSED_TRACE*')") },
        @{ Name = 'Trace2 suppression removed'; Source = $source.Replace("[Environment]::SetEnvironmentVariable(`$traceName, '0', 'Process')", "[Environment]::SetEnvironmentVariable(`$traceName, `$null, 'Process')") },
        @{ Name = 'Git application resolution bypassed'; Source = $source.Replace('& $gitExecutable --no-replace-objects', '& git --no-replace-objects') },
        @{ Name = 'Git symlink mode accepted'; Source = $source.Replace("@('100644', '100755')", "@('100644', '100755', '120000')") },
        @{ Name = 'HEAD identity query removed'; Source = $source.Replace('ls-tree -z HEAD -- $literalPathSpec', 'ls-tree -z HEAD^{tree} -- $literalPathSpec') },
        @{ Name = 'case-insensitive boundary'; Source = $source.Replace('$comparison = [System.StringComparison]::Ordinal', '$comparison = [System.StringComparison]::OrdinalIgnoreCase') },
        @{ Name = 'lexical containment bypassed'; Source = $source.Replace('if (-not $candidateFull.StartsWith($rootPrefix, $comparison)) {', 'if ($false) {') },
        @{ Name = 'reparse rejection removed'; Source = $source.Replace('if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {', 'if ($false) {') },
        @{ Name = 'candidate composition bypassed'; Source = $source.Replace('if (-not (Test-RepositoryRegularFileBoundary `', 'if ($false -and -not (Test-RepositoryRegularFileBoundary `') },
        @{ Name = 'write-time identity recheck removed'; Source = $source.Replace('$latestIdentity = Get-NormalizationCandidateIdentity `', '$latestIdentity = $candidateIdentity # guard removed`n#') },
        @{ Name = 'byte digest mismatch ignored'; Source = $source.Replace('[string]$originalDigest,', '[string]$latestDigest,') },
        @{ Name = 'only one leading BOM stripped'; Source = $source.Replace('    while ($Bytes.Length - $bomLength -ge 3 -and', '    if ($Bytes.Length - $bomLength -ge 3 -and') },
        @{ Name = 'lone CR normalization removed'; Source = $source.Replace('.Replace("`r", "`n")', '') },
        @{ Name = 'supplementary-safe label loop removed'; Source = $source.Replace('$category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory(', '$category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($RelativePath[$index]) #') },
        @{ Name = 'raw diagnostic path restored'; Source = $source.Replace('$skipped += "$safeLabel (strict decode failed)"', '$skipped += "$relativePath (strict decode failed)"') },
        @{ Name = 'write exception handling weakened'; Source = $source.Replace('    } catch {', '    } finally {') },
        @{ Name = 'automatic status parser restored'; Source = $source.Replace('[string[]]$relativePaths = @(', '$raw = git status --porcelain=v1 -z`n[string[]]$relativePaths = @(') },
        @{ Name = 'second target assignment'; Source = $source.Replace('$skipped = @()', '$relativePaths = @(''other.md'')`n$skipped = @()') },
        @{ Name = 'unguarded write sink added'; Source = $source.Replace('$skipped = @()', '[System.IO.File]::WriteAllText(''unguarded.md'', ''x'')`n$skipped = @()') },
        @{ Name = 'canonical fence relocated as decoy'; Source = $source.Replace($patternCode, '# removed from executable fence') + "`n" + $patternCode }
    )
    foreach ($mutation in $sourceMutations) {
        if ($mutation.Source -ceq $source) {
            Add-Failure (
                'Guarded-normalization source mutation setup made no change: ' +
                $mutation.Name
            )
        } elseif (Test-GuardedNormalizationExampleContract -Source $mutation.Source) {
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

function Test-EditorConfigUtf8BomAllowlistContent {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $false
    }

    # PS5.1対象だけをallowlist化する。wildcard sectionは将来追加される
    # pwsh-only scriptへ不要なBOMを波及させるため、同値扱いにしない。
    $allowlist = @(
        [pscustomobject]@{
            Path = 'scripts/private-marker-process.ps1'
            SectionCount = 0
            BomAssignmentCount = 0
        },
        [pscustomobject]@{
            Path = 'scripts/scan-private-markers.ps1'
            SectionCount = 0
            BomAssignmentCount = 0
        },
        [pscustomobject]@{
            Path = 'scripts/test-scan-private-markers.ps1'
            SectionCount = 0
            BomAssignmentCount = 0
        },
        [pscustomobject]@{
            Path = 'scripts/validate-oss-readiness.ps1'
            SectionCount = 0
            BomAssignmentCount = 0
        }
    )
    $globalSectionCount = 0
    $globalUtf8AssignmentCount = 0
    $normalizedContent = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = $normalizedContent.Split(
        [string[]]@("`n"),
        [System.StringSplitOptions]::None
    )
    $currentSection = $null

    foreach ($rawLine in $lines) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or
            $line.StartsWith('#') -or
            $line.StartsWith(';')) {
            continue
        }

        # section headerを厳密に切り出す。allowlist pathはcase-sensitiveな
        # repository相対pathとして比較し、別OSで異なる対象へ展開させない。
        if ($line.StartsWith('[')) {
            $sectionMatch = [regex]::Match(
                $line,
                '^\[(?<name>[^\[\]]+)\]$',
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
            )
            if (-not $sectionMatch.Success) {
                return $false
            }
            $currentSection = $sectionMatch.Groups['name'].Value
            if ($currentSection -ceq '*') {
                $globalSectionCount++
            }
            foreach ($entry in $allowlist) {
                if ($entry.Path -ceq $currentSection) {
                    $entry.SectionCount++
                }
            }
            continue
        }

        # EditorConfig/INIで使われる「=」「:」の両assignmentを認識し、
        # 表記を変えたbroad overrideも検査外へ逃がさない。
        $assignmentMatch = [regex]::Match(
            $line,
            '^(?<key>[^=:#\s][^=:]*?)\s*(?:=|:)\s*(?<value>.*)$',
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
        )
        if (-not $assignmentMatch.Success -or
            $assignmentMatch.Groups['key'].Value.Trim() -ine 'charset') {
            continue
        }

        $value = $assignmentMatch.Groups['value'].Value.Trim()
        $matchedAllowlistEntry = $null
        foreach ($entry in $allowlist) {
            if ($entry.Path -ceq $currentSection) {
                $matchedAllowlistEntry = $entry
                break
            }
        }

        if ($null -ne $matchedAllowlistEntry) {
            if ($value -ine 'utf-8-bom') {
                return $false
            }
            $matchedAllowlistEntry.BomAssignmentCount++
        } elseif ($currentSection -ceq '*') {
            # global defaultはBOMなしUTF-8の1件だけを許可する。後置のunsetや
            # 別値でexact overrideを打ち消すEditorConfigの後勝ちも拒否する。
            if ($value -ine 'utf-8') {
                return $false
            }
            $globalUtf8AssignmentCount++
        } else {
            # 任意globの包含判定を部分実装せず、allowlist外charsetをfail closedにする。
            # これによりexact section後のwildcard overrideもfalse-greenにしない。
            return $false
        }
    }

    # global defaultと4 exceptionを各1件へ固定し、欠落・重複を同時に拒否する。
    if ($globalSectionCount -ne 1 -or
        $globalUtf8AssignmentCount -ne 1) {
        return $false
    }
    foreach ($entry in $allowlist) {
        if ($entry.SectionCount -ne 1 -or
            $entry.BomAssignmentCount -ne 1) {
            return $false
        }
    }
    return $true
}

function Assert-EditorConfigUtf8BomAllowlist {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (UTF-8 BOM allowlist contract)"
        return
    }
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $content = [System.IO.File]::ReadAllText($filePath, $strictUtf8)
    }
    catch {
        Add-Failure "$RelativePath must be strict UTF-8."
        return
    }

    if (-not (Test-EditorConfigUtf8BomAllowlistContent -Content $content)) {
        Add-Failure (
            "$RelativePath must define one global utf-8 default and assign " +
            'utf-8-bom exactly once to each Windows PowerShell 5.1 script, ' +
            'with no other charset assignments.'
        )
    }
}

function Assert-EditorConfigUtf8BomAllowlistValidatorRegressions {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return
    }
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $content = [System.IO.File]::ReadAllText($filePath, $strictUtf8)
    }
    catch {
        return
    }
    $normalizedContent = $content.Replace("`r`n", "`n").Replace("`r", "`n")
    if (-not (Test-EditorConfigUtf8BomAllowlistContent `
            -Content $normalizedContent)) {
        return
    }

    $firstOverride = @'
[scripts/private-marker-process.ps1]
charset = utf-8-bom
'@
    $missingOverride = $normalizedContent.Replace(
        $firstOverride + "`n`n",
        ''
    )
    $duplicateSection = (
        $normalizedContent.TrimEnd([char[]]@("`r", "`n")) +
        "`n`n" +
        $firstOverride +
        "`n"
    )
    $duplicateAssignment = $normalizedContent.Replace(
        $firstOverride,
        $firstOverride + "`ncharset = utf-8-bom"
    )
    $externalCharsetOverrides = @(
        [pscustomobject]@{
            Name = 'repository-wide PowerShell BOM override'
            Section = '*.ps1'
            Value = 'utf-8-bom'
        },
        [pscustomobject]@{
            Name = 'scripts-directory wildcard BOM override'
            Section = 'scripts/*.ps1'
            Value = 'utf-8-bom'
        },
        [pscustomobject]@{
            Name = 'later scripts-directory non-BOM override'
            Section = 'scripts/*.ps1'
            Value = 'utf-8'
        },
        [pscustomobject]@{
            Name = 'later global charset reset'
            Section = '*'
            Value = 'unset'
        }
    )
    $mutations = @(
        [pscustomobject]@{
            Name = 'missing exact override'
            Content = $missingOverride
        },
        [pscustomobject]@{
            Name = 'duplicate exact section'
            Content = $duplicateSection
        },
        [pscustomobject]@{
            Name = 'duplicate charset assignment'
            Content = $duplicateAssignment
        }
    )
    foreach ($externalOverride in $externalCharsetOverrides) {
        $mutations += [pscustomobject]@{
            Name = $externalOverride.Name
            Content = (
                $normalizedContent.TrimEnd([char[]]@("`r", "`n")) +
                "`n`n[$($externalOverride.Section)]`n" +
                "charset = $($externalOverride.Value)`n"
            )
        }
    }

    # synthetic textだけをvalidatorへ通し、実scriptや利用者fileは変更しない。
    foreach ($mutation in $mutations) {
        if ($mutation.Content -ceq $normalizedContent) {
            Add-Failure (
                'EditorConfig BOM allowlist mutation setup made no change: ' +
                $mutation.Name
            )
        } elseif (Test-EditorConfigUtf8BomAllowlistContent `
                -Content $mutation.Content) {
            Add-Failure (
                'EditorConfig BOM allowlist validator accepted mutation: ' +
                $mutation.Name
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

    $content = Read-StrictUtf8Text `
        -FilePath $skillPath `
        -Description 'SKILL.md frontmatter source'
    if ($null -eq $content) {
        return
    }
    [string[]]$lines = @($content.Replace("`r`n", "`n") -split "`n")
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
Assert-FileContains -RelativePath 'README.md' -Pattern '(?s)canonical checkout step.*credential\s+persistence' -Description 'documented checkout credential non-persistence'
Assert-FileContains -RelativePath 'SECURITY.md' -Pattern 'credential persistence' -Description 'documented checkout credential boundary'
Assert-FileContains -RelativePath 'CHANGELOG.md' -Pattern 'credential-persistence' -Description 'changelog checkout credential boundary'
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

$expectedWindowsWorkflowJob = @'
  validate:
    name: Validate skill repository
    # windows-latest is intentional and left unpinned: this job only needs
    # pwsh + git, so runner image migrations do not affect it. Pin to a dated
    # label only if a future step depends on image-specific tooling.
    runs-on: windows-latest
    timeout-minutes: 10
    steps:
      - name: Check out repository
        uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
        with:
          persist-credentials: false

      - name: Validate OSS readiness
        shell: pwsh
        run: ./scripts/validate-oss-readiness.ps1

      - name: Test private marker scan (PowerShell 7)
        shell: pwsh
        run: ./scripts/test-scan-private-markers.ps1

      - name: Test private marker scan (Windows PowerShell 5.1)
        shell: powershell
        run: .\scripts\test-scan-private-markers.ps1

      - name: Scan for private markers
        shell: pwsh
        run: ./scripts/scan-private-markers.ps1

      - name: Check whitespace
        shell: pwsh
        # A fresh checkout has no worktree/index diff, so `git diff --check`
        # would be vacuous here. Diff the committed tree against the empty
        # tree (the SHA-1 empty-tree constant) so whitespace errors in
        # committed content actually fail the job (exit 2 on findings).
        run: git diff-tree --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD
'@
$expectedUbuntuWorkflowJob = @'
  validate-ubuntu:
    name: Validate POSIX process containment
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - name: Check out repository
        uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
        with:
          persist-credentials: false

      - name: Validate OSS readiness
        shell: pwsh
        run: ./scripts/validate-oss-readiness.ps1

      - name: Test private marker scan (PowerShell 7 on Ubuntu)
        shell: pwsh
        run: ./scripts/test-scan-private-markers.ps1

      - name: Scan for private markers
        shell: pwsh
        run: ./scripts/scan-private-markers.ps1

      - name: Check whitespace
        shell: pwsh
        run: git diff-tree --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD
'@
$expectedMacOsWorkflowJob = @'
  validate-macos:
    name: Validate macOS PowerShell 7
    runs-on: macos-15
    timeout-minutes: 10
    steps:
      - name: Check out repository
        uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
        with:
          persist-credentials: false

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
$expectedWorkflowJobs = @{
    'validate' = $expectedWindowsWorkflowJob
    'validate-ubuntu' = $expectedUbuntuWorkflowJob
    'validate-macos' = $expectedMacOsWorkflowJob
}
foreach ($workflowJobName in @('validate', 'validate-ubuntu', 'validate-macos')) {
    Assert-WorkflowJobBlockExact `
        -RelativePath '.github/workflows/validate.yml' `
        -JobName $workflowJobName `
        -ExpectedBlock $expectedWorkflowJobs[$workflowJobName]
    Assert-WorkflowJobBlockValidatorRegressions `
        -RelativePath '.github/workflows/validate.yml' `
        -JobName $workflowJobName `
        -ExpectedBlock $expectedWorkflowJobs[$workflowJobName]
}
Assert-WorkflowCheckoutCredentialPolicy
Assert-WorkflowCheckoutCredentialPolicyRegressions
Assert-WorkflowCheckoutCredentialValidatorRegressions `
    -RelativePath '.github/workflows/validate.yml' `
    -ExpectedJobs $expectedWorkflowJobs

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
Assert-FileContains `
    -RelativePath 'examples/guarded-normalization.md' `
    -Pattern 'function\s+Get-GitTrackedRegularFileIdentity' `
    -Description 'git index regular-file mode guard before normalization'
Assert-FileContains `
    -RelativePath 'examples/guarded-normalization.md' `
    -Pattern 'FileAttributes\]::ReparsePoint' `
    -Description 'normalization reparse-point rejection'
Assert-FileContains `
    -RelativePath 'examples/guarded-normalization.md' `
    -Pattern 'function\s+Get-NormalizationCandidateIdentity' `
    -Description 'combined tracked-file and repository-boundary guard'
foreach ($normalizationGuide in @(
        'README.md',
        'SKILL.md',
        'docs/SKILL.ja.md',
        'examples/guarded-normalization.md'
    )) {
    Assert-FileContains `
        -RelativePath $normalizationGuide `
        -Pattern '(?is)(explicit.{0,160}target|target.{0,160}explicit|明示.{0,160}対象|対象.{0,160}明示)' `
        -Description 'explicit normalization target-list contract'
    Assert-FileContains `
        -RelativePath $normalizationGuide `
        -Pattern '(?is)HEAD.{0,200}index|index.{0,200}HEAD' `
        -Description 'HEAD and index normalization identity contract'
    Assert-FileContains `
        -RelativePath $normalizationGuide `
        -Pattern '(?is)(Git.{0,80}routing|routing.{0,80}Git)' `
        -Description 'Git routing-environment rejection contract'
    Assert-FileContains `
        -RelativePath $normalizationGuide `
        -Pattern '(?i)Git\s+routing/config/pathspec/trace' `
        -Description 'Git routing/config/pathspec/trace rejection contract'
    Assert-FileContains `
        -RelativePath $normalizationGuide `
        -Pattern '(?is)(raw[- ]byte|raw bytes|raw-byte).{0,120}digest|digest.{0,120}(raw[- ]byte|raw bytes|raw-byte)' `
        -Description 'raw-byte digest recheck contract'
    Assert-FileContains `
        -RelativePath $normalizationGuide `
        -Pattern '(?i)reparse' `
        -Description 'normalization reparse-point rejection contract'
    Assert-FileContains `
        -RelativePath $normalizationGuide `
        -Pattern '(?i)hard link|hardlink' `
        -Description 'normalization hard-link residual risk'
    Assert-FileContains `
        -RelativePath $normalizationGuide `
        -Pattern '(?is)(diagnostic|表示).{0,160}(control|format)' `
        -Description 'normalization diagnostic escaping contract'
    Assert-FileContains `
        -RelativePath $normalizationGuide `
        -Pattern '(?i)--no-lazy-fetch|GIT_NO_LAZY_FETCH' `
        -Description 'normalization lazy-fetch rejection contract'
    foreach ($trace2OverrideName in @(
            'GIT_TRACE2',
            'GIT_TRACE2_EVENT',
            'GIT_TRACE2_PERF'
        )) {
        Assert-FileContains `
            -RelativePath $normalizationGuide `
            -Pattern (
                '(?<![A-Z0-9_])' +
                [regex]::Escape($trace2OverrideName) +
                '(?![A-Z0-9_])'
            ) `
            -Description (
                'normalization Trace2 target suppression contract: ' +
                $trace2OverrideName
            )
    }
    Assert-FileContains `
        -RelativePath $normalizationGuide `
        -Pattern '(?is)(dedicated.{0,80}single-threaded|専用.{0,80}single-threaded)' `
        -Description 'dedicated single-threaded PowerShell process contract'
    Assert-FileContains `
        -RelativePath $normalizationGuide `
        -Pattern '(?is)runspace.{0,120}thread.{0,120}child' `
        -Description 'same-process runspace/thread/child exclusion contract'
    Assert-FileContains `
        -RelativePath $normalizationGuide `
        -Pattern '(?is)(application.{0,160}trusted|trusted.{0,160}application)' `
        -Description 'normalization Git application trust contract'
    Assert-FileContains `
        -RelativePath $normalizationGuide `
        -Pattern '(?is)(fatal.{0,320}path-free|固定.{0,180}即時停止)' `
        -Description 'normalization fatal write contract'
}
foreach ($normalizationSkillGuide in @('SKILL.md', 'docs/SKILL.ja.md')) {
    Assert-FileContains `
        -RelativePath $normalizationSkillGuide `
        -Pattern '\[System\.IO\.Path\]::Combine\(\$repo, \$relativePath\)' `
        -Description 'fully qualified guarded-normalization target composition'
    Assert-FileDoesNotContain `
        -RelativePath $normalizationSkillGuide `
        -Pattern '\$path\s*=\s*Join-Path\s+\$repo\s+\$relativePath' `
        -Description 'unqualified guarded-normalization target composition'
    $normalizationSkillSource = Read-StrictUtf8Text `
        -FilePath (Get-RepoFilePath -RelativePath $normalizationSkillGuide) `
        -Description $normalizationSkillGuide
    if ($null -ne $normalizationSkillSource) {
        Assert-NormalizationSkillReadCatchValidatorRegressions `
            -Source $normalizationSkillSource `
            -Description $normalizationSkillGuide
    }
}

Assert-EditorConfigUtf8BomAllowlist -RelativePath '.editorconfig'
Assert-EditorConfigUtf8BomAllowlistValidatorRegressions `
    -RelativePath '.editorconfig'
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
