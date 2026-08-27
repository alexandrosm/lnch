# Explicit, read-only Level Three transcript normalization.

function script:New-LnchTranscriptEvent {
    param(
        [string]$Id,
        [string]$ParentId,
        $Timestamp,
        [string]$Kind,
        [string]$Role,
        [string]$Text,
        [string]$ToolCallId,
        [string]$ToolName,
        $Arguments,
        $Result,
        [Nullable[bool]]$IsError,
        [string]$Model,
        [string]$SourceType,
        [int]$SourceLine
    )
    [pscustomobject][ordered]@{
        Id         = $Id
        ParentId   = $ParentId
        Timestamp  = $(if ($Timestamp) { $activity = ConvertTo-LnchActivityTime $Timestamp; if ($activity) { $activity.ToString('o') } else { $null } } else { $null })
        Kind       = $Kind
        Role       = $Role
        Text       = $Text
        ToolCallId = $ToolCallId
        ToolName   = $ToolName
        Arguments  = $Arguments
        Result     = $Result
        IsError    = $IsError
        Model      = $Model
        SourceType = $SourceType
        SourceLine = $SourceLine
    }
}

function script:Add-LnchTranscriptEvent {
    param([System.Collections.ArrayList]$Events, [object]$TranscriptEvent)
    if ($TranscriptEvent) { $Events.Add($TranscriptEvent) | Out-Null }
}

function script:Add-LnchTranscriptLoss {
    param([hashtable]$Losses, [string]$Code, [string]$Detail)
    if (-not $Losses.ContainsKey($Code)) { $Losses[$Code] = @{ Count = 0; Detail = $Detail } }
    $Losses[$Code].Count++
}

function script:ConvertFrom-LnchLossMap {
    param([hashtable]$Losses)
    @($Losses.GetEnumerator() | Sort-Object Name | ForEach-Object {
        [pscustomobject][ordered]@{ Code = $_.Name; Count = $_.Value.Count; Detail = $_.Value.Detail }
    })
}

function script:Add-LnchStructuredContentEvents {
    param(
        [System.Collections.ArrayList]$Events,
        [hashtable]$Losses,
        [object[]]$Blocks,
        [string]$BaseId,
        [string]$ParentId,
        $Timestamp,
        [string]$Role,
        [string]$Model,
        [string]$SourceType,
        [int]$SourceLine,
        [hashtable]$ToolNames
    )
    $textParts = @()
    $index = 0
    foreach ($block in @($Blocks)) {
        $index++
        if ($block -is [string]) { $textParts += $block; continue }
        $type = [string]$block.type
        switch ($type) {
            'text' { if ($block.text) { $textParts += [string]$block.text } }
            'input_text' { if ($block.text) { $textParts += [string]$block.text } }
            'output_text' { if ($block.text) { $textParts += [string]$block.text } }
            'thinking' {
                Add-LnchTranscriptEvent $Events (New-LnchTranscriptEvent "$BaseId-thinking-$index" $ParentId $Timestamp 'reasoning' 'assistant' ([string]$block.thinking) $null $null $null $null $null $Model $SourceType $SourceLine)
            }
            'reasoning' {
                $reasoningText = if ($block.text) { $block.text } elseif ($block.summary) { Get-LnchTextFromContent $block.summary } else { $null }
                if ($reasoningText) { Add-LnchTranscriptEvent $Events (New-LnchTranscriptEvent "$BaseId-reasoning-$index" $ParentId $Timestamp 'reasoning' 'assistant' ([string]$reasoningText) $null $null $null $null $null $Model $SourceType $SourceLine) }
            }
            'tool_use' {
                $callId = [string]$block.id; $name = [string]$block.name
                if ($callId) { $ToolNames[$callId] = $name }
                Add-LnchTranscriptEvent $Events (New-LnchTranscriptEvent "$BaseId-tool-$index" $ParentId $Timestamp 'tool-call' 'assistant' $null $callId $name $block.input $null $null $Model $SourceType $SourceLine)
            }
            'toolCall' {
                $callId = [string]$block.id; $name = [string]$block.name
                if ($callId) { $ToolNames[$callId] = $name }
                Add-LnchTranscriptEvent $Events (New-LnchTranscriptEvent "$BaseId-tool-$index" $ParentId $Timestamp 'tool-call' 'assistant' $null $callId $name $block.arguments $null $null $Model $SourceType $SourceLine)
            }
            'tool_result' {
                $callId = [string]$block.tool_use_id
                $toolName = if ($callId -and $ToolNames.ContainsKey($callId)) { $ToolNames[$callId] } else { 'unknown' }
                Add-LnchTranscriptEvent $Events (New-LnchTranscriptEvent "$BaseId-result-$index" $ParentId $Timestamp 'tool-result' 'tool' $null $callId $toolName $null (Get-LnchTextFromContent $block.content) ([bool]$block.is_error) $Model $SourceType $SourceLine)
            }
            'image' { Add-LnchTranscriptLoss $Losses 'image-reference' 'Image content is represented by provenance only in the normalized transcript.' }
            '' {
                if ($block.text) { $textParts += [string]$block.text }
                else { Add-LnchTranscriptLoss $Losses 'unknown-content-block' 'A content block without a recognized type was omitted.' }
            }
            default { Add-LnchTranscriptLoss $Losses "unsupported-block:$type" 'An agent-specific content block was not normalized.' }
        }
    }
    $text = ($textParts | Where-Object { $_ }) -join "`n"
    if ($text) { Add-LnchTranscriptEvent $Events (New-LnchTranscriptEvent "$BaseId-text" $ParentId $Timestamp 'message' $Role $text $null $null $null $null $null $Model $SourceType $SourceLine) }
}

function script:ConvertFrom-LnchOmpTranscript {
    param([object]$Session)
    $events = New-Object System.Collections.ArrayList; $losses = @{}; $tools = @{}
    foreach ($item in @(Read-LnchJsonlRecords $Session.TranscriptPath)) {
        $record = $item.Value; $type = [string]$record.type
        switch ($type) {
            'message' {
                $message = $record.message; $id = if ($record.id) { $record.id } else { "omp-$($item.Line)" }
                if ($message.role -eq 'toolResult') {
                    Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $record.parentId $record.timestamp 'tool-result' 'tool' $null $message.toolCallId $message.toolName $null (Get-LnchTextFromContent $message.content) ([bool]$message.isError) $message.model $type $item.Line)
                } elseif ($message.content -is [string]) {
                    Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $record.parentId $record.timestamp 'message' $message.role $message.content $null $null $null $null $null $message.model $type $item.Line)
                } else {
                    Add-LnchStructuredContentEvents $events $losses @($message.content) $id $record.parentId $record.timestamp $message.role $message.model $type $item.Line $tools
                }
            }
            'custom_message' { Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $record.id $record.parentId $record.timestamp 'system' 'system' (Get-LnchTextFromContent $record.content) $null $null $null $null $null $null $type $item.Line) }
            'model_change' { Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $record.id $record.parentId $record.timestamp 'model-change' 'system' $null $null $null $null $null $null $record.model $type $item.Line) }
            'compaction' { Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $record.id $record.parentId $record.timestamp 'compaction' 'system' $record.summary $null $null $null $null $null $null $type $item.Line) }
            'reset_boundary' { Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $record.id $record.parentId $record.timestamp 'reset' 'system' $null $null $null $null $null $null $null $type $item.Line) }
            { $_ -in @('title', 'session', 'thinking_level_change', 'service_tier_change', 'label', 'title_change', 'session_init', 'mode_change', 'credential_pin') } { }
            default { Add-LnchTranscriptLoss $losses "unsupported-record:$type" 'An OMP custom record was not normalized.' }
        }
    }
    [pscustomobject]@{ Events = $events.ToArray(); Losses = ConvertFrom-LnchLossMap $losses }
}

function script:ConvertFrom-LnchClaudeTranscript {
    param([object]$Session)
    $events = New-Object System.Collections.ArrayList; $losses = @{}; $tools = @{}
    foreach ($item in @(Read-LnchJsonlRecords $Session.TranscriptPath)) {
        $record = $item.Value; $type = [string]$record.type
        if ($record.isMeta -or $record.isSidechain) { Add-LnchTranscriptLoss $losses 'claude-meta-or-sidechain' 'Claude meta and sidechain records are excluded from the main transcript.'; continue }
        if ($type -in @('user', 'assistant') -and $record.message) {
            $id = if ($record.uuid) { $record.uuid } else { "claude-$($item.Line)" }
            $content = $record.message.content
            if ($content -is [string]) {
                Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $record.parentUuid $record.timestamp 'message' $type $content $null $null $null $null $null $record.message.model $type $item.Line)
            } else {
                Add-LnchStructuredContentEvents $events $losses @($content) $id $record.parentUuid $record.timestamp $type $record.message.model $type $item.Line $tools
            }
        } elseif ($type -eq 'system') {
            Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $(if ($record.uuid) { $record.uuid } else { "claude-$($item.Line)" }) $record.parentUuid $record.timestamp 'system' 'system' (Get-LnchTextFromContent $record.content) $null $null $null $null $null $null $record.subtype $item.Line)
        } elseif ($type -notin @('custom-title', 'ai-title', 'file-history-snapshot', 'queue-operation', 'attachment', 'last-prompt', 'mode', 'permission-mode')) {
            Add-LnchTranscriptLoss $losses "unsupported-record:$type" 'A Claude-specific record was not normalized.'
        }
    }
    [pscustomobject]@{ Events = $events.ToArray(); Losses = ConvertFrom-LnchLossMap $losses }
}

function script:ConvertFrom-LnchCodexTranscript {
    param([object]$Session)
    $events = New-Object System.Collections.ArrayList; $losses = @{}; $tools = @{}; $seenText = @{}
    $parent = $null
    foreach ($item in @(Read-LnchJsonlRecords $Session.TranscriptPath)) {
        $record = $item.Value; $payload = $record.payload; $recordType = [string]$record.type
        $id = "codex-$($item.Line)"; $timestamp = $record.timestamp
        if ($recordType -eq 'turn_context' -and $payload.model) {
            Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $parent $timestamp 'model-change' 'system' $null $null $null $null $null $null $payload.model $recordType $item.Line); $parent = $id; continue
        }
        if ($recordType -eq 'compacted') {
            Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $parent $timestamp 'compaction' 'system' $payload.message $null $null $null $null $null $null $recordType $item.Line); $parent = $id; continue
        }
        if ($recordType -eq 'response_item') {
            $type = [string]$payload.type
            if ($type -eq 'message') {
                $text = Get-LnchTextFromContent $payload.content
                if ($text) { $seenText["$($payload.role)|$text"] = $true; Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $parent $timestamp 'message' $payload.role $text $null $null $null $null $null $null $type $item.Line); $parent = $id }
            } elseif ($type -eq 'reasoning') {
                $text = Get-LnchTextFromContent $payload.summary
                if (-not $text) { $text = Get-LnchTextFromContent $payload.content }
                if ($text) { Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $parent $timestamp 'reasoning' 'assistant' $text $null $null $null $null $null $null $type $item.Line); $parent = $id }
            } elseif ($type -in @('function_call', 'custom_tool_call', 'web_search_call', 'tool_search_call')) {
                $callId = if ($payload.call_id) { $payload.call_id } else { $payload.id }; $name = if ($payload.name) { $payload.name } else { $type.Replace('_call', '') }
                if ($callId) { $tools[$callId] = $name }
                $arguments = if ($type -eq 'custom_tool_call') { $payload.input } elseif ($payload.arguments) { $payload.arguments } else { $payload.action }
                Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $parent $timestamp 'tool-call' 'assistant' $null $callId $name $arguments $null $null $null $type $item.Line); $parent = $id
            } elseif ($type -in @('function_call_output', 'custom_tool_call_output', 'tool_search_output')) {
                $callId = $payload.call_id; $result = if ($payload.output) { $payload.output } else { $payload.tools }
                $toolName = if ($callId -and $tools.ContainsKey($callId)) { $tools[$callId] } else { 'unknown' }
                Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $parent $timestamp 'tool-result' 'tool' $null $callId $toolName $null $result ($payload.status -eq 'failed') $null $type $item.Line); $parent = $id
            } else { Add-LnchTranscriptLoss $losses "unsupported-response-item:$type" 'A Codex response item was not normalized.' }
            continue
        }
        if ($recordType -eq 'event_msg') {
            $type = [string]$payload.type
            if ($type -in @('user_message', 'agent_message')) {
                $role = if ($type -eq 'user_message') { 'user' } else { 'assistant' }; $text = [string]$payload.message
                if ($text -and -not $seenText.ContainsKey("$role|$text")) { Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $parent $timestamp 'message' $role $text $null $null $null $null $null $null $type $item.Line); $parent = $id }
            } elseif ($type -eq 'agent_reasoning') {
                Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $parent $timestamp 'reasoning' 'assistant' $payload.text $null $null $null $null $null $null $type $item.Line); $parent = $id
            } elseif ($type -eq 'thread_rolled_back') {
                Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $parent $timestamp 'reset' 'system' "Rolled back $($payload.num_turns) turn(s)." $null $null $null $null $null $null $type $item.Line); $parent = $id
            }
        }
    }
    [pscustomobject]@{ Events = $events.ToArray(); Losses = ConvertFrom-LnchLossMap $losses }
}

function script:ConvertFrom-LnchGeminiMessages {
    param([object[]]$Messages, [object]$Session)
    $events = New-Object System.Collections.ArrayList; $losses = @{}; $tools = @{}; $index = 0; $parent = $null
    foreach ($message in @($Messages)) {
        $index++; $id = if ($message.id) { $message.id } else { "gemini-$index" }; $type = [string]$message.type
        if ($type -in @('user', 'gemini', 'info', 'error', 'warning')) {
            $role = if ($type -eq 'gemini') { 'assistant' } elseif ($type -eq 'user') { 'user' } else { 'system' }
            $text = Get-LnchTextFromContent $message.content
            if ($text) { Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $parent $message.timestamp 'message' $role $text $null $null $null $null ($type -eq 'error') $message.model $type $index); $parent = $id }
            foreach ($thought in @($message.thoughts)) { Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent "$id-thought" $parent $thought.timestamp 'reasoning' 'assistant' $thought.description $null $null $null $null $null $message.model 'thought' $index) }
            foreach ($tool in @($message.toolCalls | Where-Object { $_ })) {
                if (-not $tool.id) { Add-LnchTranscriptLoss $losses 'gemini-tool-without-id' 'A Gemini tool record without an id was omitted.'; continue }
                $tools[[string]$tool.id] = $tool.name
                Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent "$id-tool-$($tool.id)" $parent $tool.timestamp 'tool-call' 'assistant' $null $tool.id $tool.name $tool.args $null $null $message.model 'toolCall' $index)
                if ($null -ne $tool.result) { Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent "$id-result-$($tool.id)" "$id-tool-$($tool.id)" $tool.timestamp 'tool-result' 'tool' $null $tool.id $tool.name $null $tool.result ($tool.status -eq 'error') $message.model 'toolCall' $index) }
            }
        }
    }
    [pscustomobject]@{ Events = $events.ToArray(); Losses = ConvertFrom-LnchLossMap $losses }
}

function script:ConvertFrom-LnchGeminiTranscript {
    param([object]$Session)
    if ([System.IO.Path]::GetExtension($Session.TranscriptPath) -eq '.json') {
        $conversation = Get-Content -LiteralPath $Session.TranscriptPath -Raw | ConvertFrom-Json
        return ConvertFrom-LnchGeminiMessages @($conversation.messages) $Session
    }
    $records = @(Read-LnchJsonlRecords $Session.TranscriptPath)
    $messages = @($records.Value | Where-Object { $_.type -in @('user', 'gemini', 'info', 'error', 'warning') })
    $result = ConvertFrom-LnchGeminiMessages $messages $Session
    $events = New-Object System.Collections.ArrayList
    foreach ($transcriptEvent in $result.Events) { $events.Add($transcriptEvent) | Out-Null }
    foreach ($item in $records) {
        if ($item.Value.'$rewindTo') { Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent "gemini-rewind-$($item.Line)" $null $null 'reset' 'system' "Rewind to $($item.Value.'$rewindTo')" $null $null $null $null $null $null 'rewind' $item.Line) }
    }
    [pscustomobject]@{ Events = $events.ToArray(); Losses = $result.Losses }
}

function script:ConvertFrom-LnchAiderTranscript {
    param([object]$Session)
    $events = New-Object System.Collections.ArrayList; $losses = @{}; $role = 'assistant'; $buffer = @(); $index = 0; $parent = $null
    function script:Add-LnchAiderBuffer {
        param([System.Collections.ArrayList]$Target, [string]$CurrentRole, [string[]]$Lines, [ref]$Counter, [ref]$ParentRef)
        $text = ($Lines -join "`n").Trim()
        if (-not $text) { return }
        $Counter.Value++
        $id = "aider-$($Counter.Value)"
        Add-LnchTranscriptEvent $Target (New-LnchTranscriptEvent $id $ParentRef.Value $null $(if ($CurrentRole -eq 'tool') { 'tool-result' } else { 'message' }) $CurrentRole $text $null $null $null $null $null $null 'markdown' $Counter.Value)
        $ParentRef.Value = $id
    }
    foreach ($line in @(Get-Content -LiteralPath $Session.TranscriptPath -ErrorAction SilentlyContinue)) {
        if ($line.StartsWith('# ')) { continue }
        if ($line.StartsWith('#### ')) {
            Add-LnchAiderBuffer $events $role $buffer ([ref]$index) ([ref]$parent); $buffer = @($line.Substring(5)); $role = 'user'; continue
        }
        if ($line.StartsWith('> ')) {
            Add-LnchAiderBuffer $events $role $buffer ([ref]$index) ([ref]$parent); $buffer = @($line.Substring(2)); $role = 'tool'; continue
        }
        if ($role -ne 'assistant' -and $buffer.Count -gt 0 -and [string]::IsNullOrWhiteSpace($line)) {
            Add-LnchAiderBuffer $events $role $buffer ([ref]$index) ([ref]$parent); $buffer = @(); $role = 'assistant'; continue
        }
        $buffer += $line
    }
    Add-LnchAiderBuffer $events $role $buffer ([ref]$index) ([ref]$parent)
    Add-LnchTranscriptLoss $losses 'aider-markdown-fidelity' 'Aider Markdown does not retain structured tool schemas, model metadata, or reliable timestamps.'
    [pscustomobject]@{ Events = $events.ToArray(); Losses = ConvertFrom-LnchLossMap $losses }
}

function script:ConvertFrom-LnchOpenCodeData {
    param($Data)
    $events = New-Object System.Collections.ArrayList; $losses = @{}; $parent = $null
    foreach ($message in @($Data.messages)) {
        $info = $message.info; $messageId = if ($info.id) { $info.id } else { "opencode-$($events.Count + 1)" }; $textParts = @()
        foreach ($part in @($message.parts)) {
            $type = [string]$part.type
            if ($type -eq 'text') { if ($part.text) { $textParts += $part.text } }
            elseif ($type -eq 'reasoning') { Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent "$messageId-reasoning-$($events.Count)" $parent $part.time.start 'reasoning' 'assistant' $part.text $null $null $null $null $null $info.modelID $type 0) }
            elseif ($type -eq 'tool') {
                $callId = if ($part.callID) { $part.callID } else { $part.id }; $state = $part.state
                Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent "$messageId-tool-$callId" $parent $state.time.start 'tool-call' 'assistant' $null $callId $part.tool $state.input $null $null $info.modelID $type 0)
                if ($state.output -or $state.error) { Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent "$messageId-result-$callId" "$messageId-tool-$callId" $state.time.end 'tool-result' 'tool' $null $callId $part.tool $null $(if ($state.output) { $state.output } else { $state.error }) ([bool]$state.error) $info.modelID $type 0) }
            } elseif ($type -notin @('step-start', 'step-finish', 'snapshot', 'patch')) { Add-LnchTranscriptLoss $losses "unsupported-part:$type" 'An OpenCode message part was not normalized.' }
        }
        $text = ($textParts | Where-Object { $_ }) -join "`n"
        if ($text) { Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $messageId $parent $info.time.created 'message' $info.role $text $null $null $null $null $null $info.modelID 'message' 0); $parent = $messageId }
    }
    [pscustomobject]@{ Events = $events.ToArray(); Losses = ConvertFrom-LnchLossMap $losses }
}

function script:ConvertFrom-LnchOpenCodeTranscript {
    param([object]$Session)
    if ($Session.Source -eq 'native-session-list') {
        $state = Get-LnchAgentDatastores | Where-Object Agent -eq 'opencode' | Select-Object -First 1
        if (-not $state.Executable) { throw 'OpenCode transcript export requires an installed opencode CLI.' }
        $raw = (& $state.Executable export $Session.NativeId 2>$null) -join [Environment]::NewLine
        return ConvertFrom-LnchOpenCodeData ($raw | ConvertFrom-Json)
    }
    $sessionInfo = Get-Content -LiteralPath $Session.TranscriptPath -Raw | ConvertFrom-Json
    $storageRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Session.TranscriptPath))
    $messageRoots = @((Join-Path $storageRoot "message\$($Session.NativeId)"), (Join-Path $storageRoot "session\message\$($Session.NativeId)"))
    $messages = @()
    foreach ($messageRoot in $messageRoots) {
        if (-not (Test-Path -LiteralPath $messageRoot -PathType Container)) { continue }
        foreach ($messageFile in @(Get-ChildItem -LiteralPath $messageRoot -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
            try {
                $info = Get-Content -LiteralPath $messageFile.FullName -Raw | ConvertFrom-Json; $parts = @()
                foreach ($partRoot in @((Join-Path $storageRoot "part\$($info.id)"), (Join-Path $storageRoot "session\part\$($Session.NativeId)\$($info.id)"))) {
                    if (Test-Path -LiteralPath $partRoot -PathType Container) {
                        foreach ($partFile in @(Get-ChildItem -LiteralPath $partRoot -File -Filter '*.json' -ErrorAction SilentlyContinue)) { try { $parts += Get-Content -LiteralPath $partFile.FullName -Raw | ConvertFrom-Json } catch { } }
                    }
                }
                $messages += [pscustomobject]@{ info = $info; parts = $parts }
            } catch { }
        }
    }
    ConvertFrom-LnchOpenCodeData ([pscustomobject]@{ info = $sessionInfo; messages = $messages })
}

function script:ConvertFrom-LnchQwenTranscript {
    param([object]$Session)
    $events = New-Object System.Collections.ArrayList; $losses = @{}; $tools = @{}
    foreach ($item in @(Read-LnchJsonlRecords $Session.TranscriptPath)) {
        $record = $item.Value; $id = if ($record.uuid) { $record.uuid } else { "qwen-$($item.Line)" }
        if ($record.type -in @('user', 'assistant', 'tool_result')) {
            $role = if ($record.type -eq 'tool_result') { 'tool' } else { $record.type }
            $parts = @($record.message.parts)
            $textParts = @(); $index = 0
            foreach ($part in $parts) {
                $index++
                if ($part.thought -and $part.text) {
                    Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent "$id-thought-$index" $record.parentUuid $record.timestamp 'reasoning' 'assistant' $part.text $null $null $null $null $null $record.model 'thought' $item.Line)
                } elseif ($part.text) { $textParts += $part.text }
                if ($part.functionCall) {
                    $callId = if ($part.functionCall.id) { $part.functionCall.id } else { "$id-$index" }; $name = $part.functionCall.name; $tools[$callId] = $name
                    Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent "$id-tool-$index" $record.parentUuid $record.timestamp 'tool-call' 'assistant' $null $callId $name $part.functionCall.args $null $null $record.model 'functionCall' $item.Line)
                }
                if ($part.functionResponse) {
                    $callId = if ($part.functionResponse.id) { $part.functionResponse.id } else { "$id-$index" }
                    Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent "$id-result-$index" $record.parentUuid $record.timestamp 'tool-result' 'tool' $null $callId $part.functionResponse.name $null $part.functionResponse.response $false $record.model 'functionResponse' $item.Line)
                }
            }
            $text = ($textParts | Where-Object { $_ }) -join "`n"
            if ($text) { Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $record.parentUuid $record.timestamp 'message' $role $text $null $null $null $null $null $record.model $record.type $item.Line) }
        } elseif ($record.type -eq 'system') {
            Add-LnchTranscriptEvent $events (New-LnchTranscriptEvent $id $record.parentUuid $record.timestamp $(if ($record.subtype -eq 'rewind') { 'reset' } else { 'system' }) 'system' (Get-LnchTextFromContent $record.systemPayload) $null $null $null $null $null $null $record.subtype $item.Line)
        }
    }
    [pscustomobject]@{ Events = $events.ToArray(); Losses = ConvertFrom-LnchLossMap $losses }
}

function global:Get-LnchSessionTranscript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reference, [string]$Agent)
    $agentFilter = $Agent
    $nativeReference = $Reference
    $colon = $Reference.IndexOf(':')
    if (-not $agentFilter -and $colon -gt 0) {
        $prefix = $Reference.Substring(0, $colon)
        if ($script:BuiltInAgentNames -contains $prefix) { $agentFilter = $prefix; $nativeReference = $Reference.Substring($colon + 1) }
    }
    $inventory = Get-LnchSessionInventory -Agent $(if ($agentFilter) { @($agentFilter) } else { $null })
    $sessionMatches = @($inventory.Sessions | Where-Object {
        (-not $agentFilter -or $_.Agent -eq $agentFilter) -and
        ($_.Ref -eq $Reference -or $_.NativeId -eq $nativeReference -or $_.TranscriptPath -eq $Reference)
    })
    if ($sessionMatches.Count -eq 0) { throw "Session not found: $Reference" }
    if ($sessionMatches.Count -gt 1) { throw "Session reference is ambiguous; prefix it with an agent name: $Reference" }
    $session = $sessionMatches[0]
    if (-not $session.TranscriptAvailable -and $session.Agent -ne 'opencode') { throw "Transcript is not locally available for $($session.Ref)" }
    $decoded = switch ($session.Agent) {
        'omp'      { ConvertFrom-LnchOmpTranscript $session }
        'claude'   { ConvertFrom-LnchClaudeTranscript $session }
        'codex'    { ConvertFrom-LnchCodexTranscript $session }
        'gemini'   { ConvertFrom-LnchGeminiTranscript $session }
        'aider'    { ConvertFrom-LnchAiderTranscript $session }
        'opencode' { ConvertFrom-LnchOpenCodeTranscript $session }
        'qwen'     { ConvertFrom-LnchQwenTranscript $session }
    }
    $events = @($decoded.Events)
    [pscustomobject][ordered]@{
        Schema      = 1
        GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
        Session     = $session
        Events      = $events
        Losses      = @($decoded.Losses)
        Stats       = [pscustomobject][ordered]@{
            Events      = $events.Count
            Messages    = @($events | Where-Object Kind -eq 'message').Count
            ToolCalls   = @($events | Where-Object Kind -eq 'tool-call').Count
            ToolResults = @($events | Where-Object Kind -eq 'tool-result').Count
            Reasoning   = @($events | Where-Object Kind -eq 'reasoning').Count
        }
    }
}

function global:Show-LnchSessionTranscript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reference, [string]$Agent, [switch]$Json)
    $transcript = Get-LnchSessionTranscript -Reference $Reference -Agent $Agent
    if ($Json) { ConvertTo-Json -InputObject $transcript -Depth 12; return }
    Write-Host ("== {0} | {1} events ==" -f $transcript.Session.Ref, $transcript.Events.Count)
    foreach ($transcriptEvent in $transcript.Events) {
        $label = if ($transcriptEvent.Role) { $transcriptEvent.Role } else { $transcriptEvent.Kind }
        if ($transcriptEvent.Kind -eq 'tool-call') { Write-Host ("[{0}] tool {1} ({2})" -f $transcriptEvent.Timestamp, $transcriptEvent.ToolName, $transcriptEvent.ToolCallId) }
        elseif ($transcriptEvent.Kind -eq 'tool-result') { Write-Host ("[{0}] result {1} error={2}" -f $transcriptEvent.Timestamp, $transcriptEvent.ToolName, $transcriptEvent.IsError) }
        elseif ($transcriptEvent.Text) { Write-Host ("[{0}] {1}: {2}" -f $transcriptEvent.Timestamp, $label, $transcriptEvent.Text) }
        else { Write-Host ("[{0}] {1}" -f $transcriptEvent.Timestamp, $transcriptEvent.Kind) }
    }
    foreach ($loss in $transcript.Losses) { Write-Host ("loss: {0} x{1} - {2}" -f $loss.Code, $loss.Count, $loss.Detail) }
}
