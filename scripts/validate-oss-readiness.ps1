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
        'Out-Null',
        'Read-StableWorktreeBytes',
        'Remove-Item',
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
    'LICENSE',
    'README.md',
    'SECURITY.md',
    'SKILL.md',
    'docs/SKILL.ja.md',
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
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'validate-oss-readiness\.ps1' -Description 'OSS readiness validation in CI'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'scan-private-markers\.ps1' -Description 'private marker scan in CI'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'test-scan-private-markers\.ps1' -Description 'private marker scan self-test in CI'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'timeout-minutes:\s*10' -Description 'bounded CI validation job'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern 'uses:\s*actions/checkout@[0-9a-f]{40}(?:\s*#\s*v5)?' -Description 'immutable checkout action revision'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern '(?ms)shell:\s*powershell\s+run:\s*\.\\scripts\\test-scan-private-markers\.ps1' -Description 'explicit Windows PowerShell 5.1 scanner self-test'
Assert-FileContains -RelativePath '.github/workflows/validate.yml' -Pattern '(?ms)validate-ubuntu:.*runs-on:\s*ubuntu-24\.04.*test-scan-private-markers\.ps1' -Description 'Ubuntu POSIX containment self-test'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'private-marker-process\.ps1' -Description 'shared bounded process boundary in scanner'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'private-marker-process\.ps1' -Description 'shared bounded process boundary in scanner self-test'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'PosixSignal.*IsSuccessfulResult' -Description 'POSIX errno cleanup regression coverage'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'New-PrivateMarkerBoundedRegex' -Description 'finite regex match-timeout constructor'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'RegexMatchTimeoutException' -Description 'regex timeout fail-closed handling'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern '\$maximumRegexMatchMilliseconds\s*=\s*250' -Description 'bounded regex match duration'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'regex-match-timeout' -Description 'adversarial regex no-match regression'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?ms)^## Dogfooding.*Windows PowerShell 5\.1.*UTF-8\s+BOM' -Description 'PowerShell 5.1 BOM exception in dogfooding guidance'

Assert-ScannerHasOnlyBoundedRegexOperations `
    -RelativePath 'scripts/scan-private-markers.ps1'
Assert-ScannerRegexPolicyValidatorRegressions `
    -RelativePath 'scripts/scan-private-markers.ps1'

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
