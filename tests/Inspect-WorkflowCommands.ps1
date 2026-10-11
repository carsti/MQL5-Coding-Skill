#Requires -Version 5.1
param([Parameter(Mandatory)][string]$InputFile,[Parameter(Mandatory)][string]$OutputFile)
$ErrorActionPreference='Stop'
$text=[IO.File]::ReadAllText($InputFile)
if ($text.Length -gt 16777216 -or -not $text.TrimStart().StartsWith('{')) {throw 'Invalid command inspection input.'}
$request=ConvertFrom-Json -InputObject $text
if ($request.schema_version -ne 1 -or @($request.entries).Count -gt 1000) {throw 'Unsupported command inspection input.'}
$rows=@()
foreach ($entry in $request.entries) {
    if ($entry.script -isnot [string] -or $entry.script.Length -gt 1048576) {throw 'Unsupported command inspection size.'}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($entry.script,[ref]$tokens,[ref]$errors)
    $calls=@();$startExpressions=@();$residual=$entry.script.ToCharArray()
    foreach ($token in @($tokens | Where-Object {$_.Kind -eq 'Comment'})) {
        for ($offset=$token.Extent.StartOffset;$offset -lt $token.Extent.EndOffset;$offset++) {$residual[$offset]=' '}
    }
    if (@($errors).Count -eq 0) {
        $startExpressions=@($ast.FindAll({param($node)
            $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
            $node.Member.Value -imatch '\A(?:Start|CreateProcess|ShellExecute)\z'
        },$true))
        # Source and verification strings are data. Preserve active interpolation
        # and conservatively retain bindings when a native start expression exists.
        if ($startExpressions.Count -eq 0) {
            foreach ($string in @($ast.FindAll({param($node)
                $node -is [Management.Automation.Language.StringConstantExpressionAst] -or
                $node -is [Management.Automation.Language.ExpandableStringExpressionAst]
            },$true))) {
                for ($offset=$string.Extent.StartOffset;$offset -lt $string.Extent.EndOffset;$offset++) {$residual[$offset]=' '}
                if ($string -is [Management.Automation.Language.ExpandableStringExpressionAst]) {
                    foreach ($expression in $string.NestedExpressions) {
                        for ($offset=$expression.Extent.StartOffset;$offset -lt $expression.Extent.EndOffset;$offset++) {$residual[$offset]=$entry.script[$offset]}
                    }
                }
            }
        }
        foreach ($command in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true))) {
            if ($calls.Count -ge 1000) {throw 'Command inspection call limit exceeded.'}
            $parts=@();$literal=$true
            foreach ($element in $command.CommandElements) {
                if ($element -is [Management.Automation.Language.CommandParameterAst]) {
                    $parts+=@{kind='parameter';value=$element.ParameterName}
                    if ($null -ne $element.Argument) {
                        if ($element.Argument -is [Management.Automation.Language.StringConstantExpressionAst] -or $element.Argument -is [Management.Automation.Language.ConstantExpressionAst]) {$parts+=@{kind='literal';value=[string]$element.Argument.Value}}
                        else {$literal=$false;$parts+=@{kind='dynamic';value=$element.Argument.Extent.Text}}
                    }
                } elseif ($element -is [Management.Automation.Language.StringConstantExpressionAst] -or $element -is [Management.Automation.Language.ConstantExpressionAst]) {
                    $parts+=@{kind='literal';value=[string]$element.Value}
                } else {$literal=$false;$parts+=@{kind='dynamic';value=$element.Extent.Text}}
            }
            $top=$true;$parent=$command.Parent
            while ($null -ne $parent) {
                if ($parent -isnot [Management.Automation.Language.PipelineAst] -and $parent -isnot [Management.Automation.Language.NamedBlockAst] -and $parent -isnot [Management.Automation.Language.ScriptBlockAst] -and $parent -isnot [Management.Automation.Language.AssignmentStatementAst]) {$top=$false}
                $parent=$parent.Parent
            }
            $calls+=@{text=$command.Extent.Text;parts=@($parts);literal=$literal;top_level=$top;invocation_operator=[string]$command.InvocationOperator}
            for ($offset=$command.Extent.StartOffset;$offset -lt $command.Extent.EndOffset;$offset++) {$residual[$offset]=' '}
        }
    }
    $rows+=@{id=$entry.id;parse_errors=@($errors).Count;calls=@($calls);residual=(-join $residual);native_start_expression=(@($errors).Count -eq 0 -and $startExpressions.Count -gt 0)}
}
[IO.File]::WriteAllText($OutputFile,(@{schema_version=1;rows=@($rows)} | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
