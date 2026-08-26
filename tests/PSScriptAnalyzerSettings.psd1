@{
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        'PSAvoidUsingWriteHost',          # console tool by design
        'PSAvoidUsingEmptyCatchBlock',    # best-effort probes fail silent by design
        'PSAvoidUsingCmdletAliases',      # calling our own `start` function is the product
        'PSReviewUnusedParameter'         # completer signatures require unused params
    )
}
