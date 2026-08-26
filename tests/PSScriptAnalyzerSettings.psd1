@{
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        'PSAvoidUsingWriteHost',          # console tool by design
        'PSAvoidUsingInvokeExpression',   # post-create hooks are user-supplied expressions
        'PSUseSingularNouns',             # Get-StarterPostCreateHooks returns a list; kept for symmetry
        'PSAvoidUsingEmptyCatchBlock',    # best-effort probes fail silent by design
        'PSAvoidUsingCmdletAliases',      # calling our own `start` function is the product
        'PSReviewUnusedParameter'         # completer signatures require unused params
    )
}
