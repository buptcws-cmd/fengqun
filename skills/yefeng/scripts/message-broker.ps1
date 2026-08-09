<#
.SYNOPSIS
Runs the yefeng single-writer runtime message broker.

.DESCRIPTION
The broker owns only ignored runtime communication state under
.yefeng/broker/<scope_id>. It validates assignment-bound role outboxes,
appends a durable journal, and materializes recipient inbox and sender receipt
projections. It never wakes roles or modifies tracked governance.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('Once', 'Run', 'Start', 'Status', 'Stop')]
  [string] $Mode,

  [Parameter(Mandatory = $true)]
  [string] $ControlRoot,

  [Parameter(Mandatory = $true)]
  [string] $ScopeId,

  [ValidateRange(50, 60000)]
  [int] $PollIntervalMilliseconds = 1000,

  [ValidateRange(1, 1000)]
  [int] $MaximumBatchSize = 100,

  [ValidateRange(1, 60)]
  [int] $StopTimeoutSeconds = 15,

  [string] $InstanceId = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'message-common.ps1')
[Console]::InputEncoding = $script:YefengUtf8NoBom
[Console]::OutputEncoding = $script:YefengUtf8NoBom
$OutputEncoding = $script:YefengUtf8NoBom

function ConvertTo-BrokerJson([object] $Value, [switch] $Compress) {
  if ($Compress) {
    return $Value | ConvertTo-Json -Depth 30 -Compress
  }
  return $Value | ConvertTo-Json -Depth 30
}

function Append-BrokerJournal([string] $Path, [object] $Event) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $line = (ConvertTo-BrokerJson $Event -Compress) + "`n"
  $bytes = $script:YefengUtf8NoBom.GetBytes($line)
  if ($bytes.Length -gt $script:YefengMaximumMessageBytes) {
    throw 'Broker journal event exceeds the 64 KiB event limit.'
  }
  $stream = $null
  try {
    $stream = [System.IO.File]::Open(
      $Path,
      [System.IO.FileMode]::Append,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::Read
    )
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    if ($null -ne $stream) {
      $stream.Dispose()
    }
  }
}

function Read-BrokerJournal([string] $Path) {
  $acceptedById = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
  $senderSequences = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
  $events = New-Object System.Collections.Generic.List[object]
  $maximumSequence = [int64] 0
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($Path, $script:YefengUtf8Strict)) {
      $lineNumber += 1
      if ([string]::IsNullOrWhiteSpace($line)) {
        continue
      }
      try {
        $event = ConvertFrom-YefengJson $line
      } catch {
        throw "Broker journal line $lineNumber is invalid: $($_.Exception.Message)"
      }
      Assert-YefengRequiredProperties "Broker journal line $lineNumber" $event @(
        'version',
        'broker_sequence',
        'event_type',
        'recorded_at'
      )
      if (
        -not (Test-YefengInteger $event.version) -or
        [int64] $event.version -ne 1 -or
        -not (Test-YefengInteger $event.broker_sequence) -or
        [int64] $event.broker_sequence -lt 1
      ) {
        throw "Broker journal line $lineNumber has an invalid version or sequence."
      }
      Assert-YefengTimestamp "Broker journal line $lineNumber recorded_at" $event.recorded_at
      $sequence = [int64] $event.broker_sequence
      if ($sequence -le $maximumSequence) {
        throw "Broker journal sequence is not strictly increasing at line $lineNumber."
      }
      $maximumSequence = $sequence
      if ([string] $event.event_type -ceq 'MESSAGE_ACCEPTED') {
        Assert-YefengRequiredProperties "Accepted journal line $lineNumber" $event @(
          'source_sha256',
          'message',
          'inbox_path',
          'receipt_path'
        )
        $messageId = [string] $event.message.message_id
        if ($acceptedById.ContainsKey($messageId)) {
          throw "Broker journal contains duplicate accepted message_id: $messageId"
        }
        $acceptedById.Add($messageId, $event)
        $senderKey = '{0}|{1}|{2}|{3}' -f
          [string] $event.message.role_id,
          [string] $event.message.assignment_id,
          [string] $event.message.run_id,
          [int64] $event.message.sender_sequence
        if ($senderSequences.ContainsKey($senderKey)) {
          throw "Broker journal contains duplicate sender sequence: $senderKey"
        }
        $senderSequences.Add($senderKey, $messageId)
      }
      $events.Add($event)
    }
  }
  return [pscustomobject]@{
    events = $events.ToArray()
    accepted_by_id = $acceptedById
    sender_sequences = $senderSequences
    maximum_sequence = $maximumSequence
  }
}

function Assert-NullableMessageId([string] $Label, [object] $Value) {
  if ($null -eq $Value) {
    return
  }
  if (
    $Value -isnot [string] -or
    [string]::IsNullOrWhiteSpace([string] $Value) -or
    [string] $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
  ) {
    throw "$Label is not null or one stable message identifier."
  }
}

function Assert-NullableString([string] $Label, [object] $Value) {
  if ($null -ne $Value -and $Value -isnot [string]) {
    throw "$Label must be null or a native String."
  }
}

function Assert-BrokerMessage(
  [object] $Message,
  [string] $SourcePath,
  [object] $Snapshot,
  [object] $Paths
) {
  $messageProperties = @(
    'version',
    'message_id',
    'control_repo_id',
    'scope_id',
    'run_epoch',
    'role_id',
    'assignment_id',
    'run_id',
    'transport_mode',
    'sender_sequence',
    'sent_at',
    'type',
    'recipient',
    'correlation_id',
    'causation_id',
    'priority',
    'blocking',
    'blocked_role',
    'blocked_checkpoint',
    'blocked_by',
    'resume_when',
    'required_evidence',
    'wake_target',
    'payload'
  )
  Assert-YefengExactProperties 'Role message' $Message $messageProperties
  Assert-YefengExactProperties 'Role message payload' $Message.payload @(
    'summary',
    'details',
    'related_files'
  )
  if (
    -not (Test-YefengInteger $Message.version) -or
    [int64] $Message.version -ne 1
  ) {
    throw 'Message version must be integer 1.'
  }
  foreach ($name in @('message_id', 'control_repo_id', 'scope_id', 'role_id', 'assignment_id', 'run_id', 'recipient')) {
    Assert-YefengStableId "Message $name" $Message.$name
  }
  if (
    -not (Test-YefengInteger $Message.run_epoch) -or
    [int64] $Message.run_epoch -lt 1 -or
    -not (Test-YefengInteger $Message.sender_sequence) -or
    [int64] $Message.sender_sequence -lt 1
  ) {
    throw 'Message epoch and sender_sequence must be positive integers.'
  }
  Assert-YefengTimestamp 'Message sent_at' $Message.sent_at
  if ($script:YefengMessageTypes -cnotcontains [string] $Message.type) {
    throw "Unsupported message type: $($Message.type)"
  }
  if ([string] $Message.transport_mode -cne 'control-spool') {
    throw 'Message transport_mode must be control-spool.'
  }
  if ([string] $Message.priority -cnotin @('low', 'normal', 'high', 'urgent')) {
    throw "Unsupported message priority: $($Message.priority)"
  }
  if ($Message.blocking -isnot [bool]) {
    throw 'Message blocking must be a native Boolean.'
  }
  Assert-NullableMessageId 'Message correlation_id' $Message.correlation_id
  Assert-NullableMessageId 'Message causation_id' $Message.causation_id
  foreach ($name in @('blocked_role', 'blocked_checkpoint', 'blocked_by', 'resume_when', 'required_evidence', 'wake_target')) {
    Assert-NullableString "Message $name" $Message.$name
  }
  if ([bool] $Message.blocking) {
    foreach ($name in @('blocked_role', 'blocked_checkpoint', 'blocked_by', 'resume_when', 'required_evidence', 'wake_target')) {
      if ([string]::IsNullOrWhiteSpace([string] $Message.$name)) {
        throw "Blocking message is missing $name."
      }
    }
    Assert-YefengStableId 'Message blocked_role' $Message.blocked_role
    Assert-YefengStableId 'Message wake_target' $Message.wake_target
    if ([string] $Message.blocked_role -cne [string] $Message.role_id) {
      throw 'Blocking message blocked_role must be the sender.'
    }
  } else {
    foreach ($name in @('blocked_role', 'blocked_checkpoint', 'blocked_by', 'resume_when', 'required_evidence', 'wake_target')) {
      if ($null -ne $Message.$name) {
        throw "Non-blocking message cannot populate $name."
      }
    }
  }
  if ([string] $Message.type -ceq 'BLOCKER' -and -not [bool] $Message.blocking) {
    throw 'A BLOCKER message must be blocking.'
  }
  if (
    [string] $Message.type -ceq 'HEARTBEAT' -and
    ([string] $Message.recipient -cne 'TOTAL_CONTROL' -or [bool] $Message.blocking)
  ) {
    throw 'HEARTBEAT must be non-blocking and addressed to TOTAL_CONTROL.'
  }
  if (
    $Message.payload.summary -isnot [string] -or
    [string]::IsNullOrWhiteSpace([string] $Message.payload.summary) -or
    ([string] $Message.payload.summary).Length -gt 4096
  ) {
    throw 'Message payload summary is invalid.'
  }
  if (
    $Message.payload.details -isnot [string] -or
    ([string] $Message.payload.details).Length -gt 32768
  ) {
    throw 'Message payload details is invalid.'
  }
  $relatedFiles = @($Message.payload.related_files)
  if ($relatedFiles.Count -gt 32) {
    throw 'Message payload related_files exceeds 32 entries.'
  }
  foreach ($relatedFile in $relatedFiles) {
    if (
      $relatedFile -isnot [string] -or
      [string]::IsNullOrWhiteSpace([string] $relatedFile) -or
      ([string] $relatedFile).Length -gt 512 -or
      ([string] $relatedFile).Contains([char] 0)
    ) {
      throw 'Message payload contains an invalid related_files entry.'
    }
  }
  if (
    [string] $Message.control_repo_id -cne [string] $Snapshot.topology.control_repo_id -or
    [string] $Message.scope_id -cne [string] $Snapshot.control.scope_id
  ) {
    throw 'Message control repository or scope identity mismatch.'
  }
  if ([int64] $Message.run_epoch -ne [int64] $Snapshot.control.run_epoch) {
    throw 'Message run epoch is stale or from the future.'
  }
  $expectedSourceRoot = Normalize-YefengPath (
    Join-Path $Paths.outbox_root (
      Join-Path ([string] $Message.role_id) ([string] $Message.run_id)
    )
  )
  $sourceParent = Normalize-YefengPath (Split-Path -Parent $SourcePath)
  if (-not $sourceParent.Equals($expectedSourceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Message file is not in the sender assignment/run outbox.'
  }
  $expectedLeaf = ([string] $Message.message_id) + '.json'
  if (-not (Split-Path -Leaf $SourcePath).Equals($expectedLeaf, [System.StringComparison]::Ordinal)) {
    throw 'Message filename does not match message_id.'
  }
  $matchingRoles = @($Snapshot.roles.roles | Where-Object {
    [string] $_.role_id -ceq [string] $Message.role_id
  })
  if ($matchingRoles.Count -ne 1) {
    throw 'Message sender role is absent or ambiguous.'
  }
  $role = $matchingRoles[0]
  if (
    [string] $role.assignment_id -cne [string] $Message.assignment_id -or
    [string] $role.run_id -cne [string] $Message.run_id -or
    [int64] $role.run_epoch -ne [int64] $Message.run_epoch -or
    [string] $role.control_repo_id -cne [string] $Message.control_repo_id -or
    $script:YefengActiveRoleStates -cnotcontains [string] $role.state
  ) {
    throw 'Message sender does not match one active governed role assignment.'
  }
  $matchingRuns = @($Snapshot.runs.runs | Where-Object {
    [string] $_.run_id -ceq [string] $Message.run_id
  })
  if ($matchingRuns.Count -ne 1) {
    throw 'Message sender run is absent or ambiguous.'
  }
  $run = $matchingRuns[0]
  if (
    [string] $run.role_id -cne [string] $Message.role_id -or
    [string] $run.assignment_id -cne [string] $Message.assignment_id -or
    [int64] $run.run_epoch -ne [int64] $Message.run_epoch -or
    [string] $run.control_repo_id -cne [string] $Message.control_repo_id -or
    [string] $run.transport_mode -cne 'control-spool' -or
    [string] $run.status -cne 'RUNNING'
  ) {
    throw 'Message sender does not match one active governed run.'
  }
  if ([string] $Message.recipient -cne 'TOTAL_CONTROL') {
    $recipientRoles = @($Snapshot.roles.roles | Where-Object {
      [string] $_.role_id -ceq [string] $Message.recipient
    })
    if ($recipientRoles.Count -ne 1) {
      throw 'Message recipient is not one governed role in this scope.'
    }
  }
}

function Ensure-BrokerProjections(
  [object] $AcceptedEvent,
  [object] $Paths
) {
  $inboxPath = Assert-YefengPathInside $Paths.inbox_root ([string] $AcceptedEvent.inbox_path) 'Accepted inbox projection'
  $receiptPath = Assert-YefengPathInside $Paths.receipt_root ([string] $AcceptedEvent.receipt_path) 'Accepted receipt projection'
  $repaired = 0
  $eventJson = (ConvertTo-BrokerJson $AcceptedEvent) + "`n"
  if (Test-Path -LiteralPath $inboxPath -PathType Leaf) {
    $existingInbox = Read-YefengJsonFile $inboxPath $script:YefengMaximumMessageBytes
    if (
      [int64] $existingInbox.broker_sequence -ne [int64] $AcceptedEvent.broker_sequence -or
      [string] $existingInbox.source_sha256 -cne [string] $AcceptedEvent.source_sha256 -or
      [string] $existingInbox.message.message_id -cne [string] $AcceptedEvent.message.message_id
    ) {
      throw 'Existing inbox projection conflicts with the accepted journal event.'
    }
  } else {
    Write-YefengUtf8FileAtomically $inboxPath $eventJson -NoOverwrite
    $repaired += 1
  }
  $receipt = [ordered]@{
    version = 1
    status = 'accepted'
    message_id = [string] $AcceptedEvent.message.message_id
    broker_sequence = [int64] $AcceptedEvent.broker_sequence
    source_sha256 = [string] $AcceptedEvent.source_sha256
    accepted_at = [string] $AcceptedEvent.recorded_at
    recipient = [string] $AcceptedEvent.message.recipient
  }
  if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
    $existingReceipt = Read-YefengJsonFile $receiptPath $script:YefengMaximumMessageBytes
    if (
      [int64] $existingReceipt.broker_sequence -ne [int64] $AcceptedEvent.broker_sequence -or
      [string] $existingReceipt.source_sha256 -cne [string] $AcceptedEvent.source_sha256 -or
      [string] $existingReceipt.message_id -cne [string] $AcceptedEvent.message.message_id
    ) {
      throw 'Existing sender receipt conflicts with the accepted journal event.'
    }
  } else {
    Write-YefengUtf8FileAtomically $receiptPath (($receipt | ConvertTo-Json -Depth 10) + "`n") -NoOverwrite
    $repaired += 1
  }
  return $repaired
}

function Move-BrokerMessageToQuarantine(
  [string] $SourcePath,
  [string] $Reason,
  [string] $SourceSha256,
  [object] $Message,
  [object] $Paths,
  [int64] $BrokerSequence
) {
  if (-not (Test-Path -LiteralPath $Paths.quarantine_root -PathType Container)) {
    New-Item -ItemType Directory -Path $Paths.quarantine_root -Force | Out-Null
  }
  $stamp = [DateTimeOffset]::UtcNow
  $token = '{0}-{1}' -f $stamp.ToString('yyyyMMddHHmmssfff'), ([guid]::NewGuid().ToString('N').Substring(0, 12))
  $quarantinePath = Join-Path $Paths.quarantine_root "$token.message.json"
  [System.IO.File]::Move($SourcePath, $quarantinePath)
  $messageId = if ($null -ne $Message -and $Message.PSObject.Properties.Name -contains 'message_id') {
    [string] $Message.message_id
  } else {
    [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
  }
  $reasonRecord = [ordered]@{
    version = 1
    message_id = $messageId
    source_sha256 = $SourceSha256
    reason = $Reason
    quarantined_at = $stamp.ToString('o')
    quarantine_path = $quarantinePath
  }
  Write-YefengUtf8FileAtomically (Join-Path $Paths.quarantine_root "$token.reason.json") (($reasonRecord | ConvertTo-Json -Depth 10) + "`n") -NoOverwrite
  $event = [ordered]@{
    version = 1
    broker_sequence = $BrokerSequence
    event_type = 'MESSAGE_QUARANTINED'
    recorded_at = $stamp.ToString('o')
    message_id = $messageId
    source_sha256 = $SourceSha256
    reason = $Reason
    quarantine_path = $quarantinePath
  }
  Append-BrokerJournal $Paths.journal_path $event
  return $event
}

function Invoke-BrokerBatch(
  [object] $Snapshot,
  [object] $Paths,
  [int] $BatchLimit
) {
  foreach ($directory in @(
    $Paths.runtime_root,
    (Split-Path -Parent $Paths.journal_path),
    $Paths.inbox_root,
    $Paths.receipt_root,
    $Paths.outbox_root,
    $Paths.quarantine_root
  )) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
      New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
  }
  $journal = Read-BrokerJournal $Paths.journal_path
  $nextSequence = [int64] $journal.maximum_sequence
  $files = @(
    Get-ChildItem -LiteralPath $Paths.outbox_root -Filter 'msg-*.json' -File -Recurse -Force -ErrorAction Stop |
      Sort-Object FullName |
      Select-Object -First $BatchLimit
  )
  $counts = [ordered]@{
    scanned = $files.Count
    accepted = 0
    duplicates = 0
    quarantined = 0
    repaired = 0
    deferred_errors = 0
  }
  foreach ($file in $files) {
    $message = $null
    $sourceSha256 = $null
    $acceptedEvent = $null
    try {
      $sourcePath = Assert-YefengPathInside $Paths.outbox_root $file.FullName 'Broker source message'
      $sourceSha256 = Get-YefengFileSha256Hex $sourcePath
      $bytes = Get-YefengFileBytes $sourcePath $script:YefengMaximumMessageBytes
      $text = $script:YefengUtf8Strict.GetString($bytes)
      $message = ConvertFrom-YefengJson $text
      Assert-BrokerMessage $message $sourcePath $Snapshot $Paths
      $messageId = [string] $message.message_id
      if ($journal.accepted_by_id.ContainsKey($messageId)) {
        $existing = $journal.accepted_by_id[$messageId]
        if ([string] $existing.source_sha256 -cne $sourceSha256) {
          throw 'Duplicate message_id has a conflicting source digest.'
        }
        $counts.repaired += Ensure-BrokerProjections $existing $Paths
        [System.IO.File]::Delete($sourcePath)
        $counts.duplicates += 1
        continue
      }
      $senderKey = '{0}|{1}|{2}|{3}' -f
        [string] $message.role_id,
        [string] $message.assignment_id,
        [string] $message.run_id,
        [int64] $message.sender_sequence
      if ($journal.sender_sequences.ContainsKey($senderKey)) {
        throw 'Sender sequence is already bound to a different message_id.'
      }
      $nextSequence += 1
      $inboxDirectory = Join-Path $Paths.inbox_root ([string] $message.recipient)
      $inboxName = '{0:D12}--{1}.json' -f $nextSequence, [string] $message.message_id
      $inboxPath = Join-Path $inboxDirectory $inboxName
      $receiptPath = Join-Path (
        Join-Path $Paths.receipt_root ([string] $message.role_id)
      ) (([string] $message.message_id) + '.json')
      $acceptedEvent = [ordered]@{
        version = 1
        broker_sequence = $nextSequence
        event_type = 'MESSAGE_ACCEPTED'
        recorded_at = [DateTimeOffset]::UtcNow.ToString('o')
        source_sha256 = $sourceSha256
        inbox_path = $inboxPath
        receipt_path = $receiptPath
        message = $message
      }
      Append-BrokerJournal $Paths.journal_path $acceptedEvent
      $journal.accepted_by_id.Add($messageId, $acceptedEvent)
      $journal.sender_sequences.Add($senderKey, $messageId)
      try {
        $counts.repaired += Ensure-BrokerProjections $acceptedEvent $Paths
        [System.IO.File]::Delete($sourcePath)
        $counts.accepted += 1
      } catch {
        $counts.deferred_errors += 1
      }
    } catch {
      if ($null -ne $acceptedEvent) {
        $counts.deferred_errors += 1
        continue
      }
      $nextSequence += 1
      if ([string]::IsNullOrWhiteSpace($sourceSha256) -and (Test-Path -LiteralPath $file.FullName -PathType Leaf)) {
        try {
          $sourceSha256 = Get-YefengFileSha256Hex $file.FullName
        } catch {
          $sourceSha256 = ('0' * 64)
        }
      }
      if (Test-Path -LiteralPath $file.FullName -PathType Leaf) {
        $null = Move-BrokerMessageToQuarantine (
          $file.FullName
        ) (
          [string] $_.Exception.Message
        ) (
          [string] $sourceSha256
        ) $message $Paths $nextSequence
      }
      $counts.quarantined += 1
    }
  }
  return [pscustomobject]@{
    counts = $counts
    last_broker_sequence = $nextSequence
  }
}

function Enter-BrokerGuard([object] $Paths) {
  if (-not (Test-Path -LiteralPath $Paths.runtime_root -PathType Container)) {
    New-Item -ItemType Directory -Path $Paths.runtime_root -Force | Out-Null
  }
  try {
    return [System.IO.File]::Open(
      $Paths.guard_path,
      [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None
    )
  } catch [System.IO.IOException] {
    throw "Another message broker already owns scope $ScopeId."
  }
}

function Get-BrokerProcessStatus([object] $Paths) {
  if (-not (Test-Path -LiteralPath $Paths.process_state_path -PathType Leaf)) {
    return [pscustomobject]@{
      running = $false
      stale = $false
      state = $null
      process = $null
    }
  }
  $state = Read-YefengJsonFile $Paths.process_state_path 16384
  Assert-YefengRequiredProperties 'Broker process state' $state @(
    'version',
    'control_root',
    'scope_id',
    'instance_id',
    'process_id',
    'process_start_time',
    'machine_name',
    'script_path',
    'script_sha256',
    'started_at',
    'last_poll_at'
  )
  if (
    -not (Test-YefengInteger $state.version) -or
    [int64] $state.version -ne 1 -or
    -not (Test-YefengInteger $state.process_id) -or
    [int64] $state.process_id -lt 1 -or
    [string] $state.scope_id -cne $ScopeId -or
    -not (Normalize-YefengPath ([string] $state.control_root)).Equals(
      (Normalize-YefengPath $ControlRoot),
      [System.StringComparison]::OrdinalIgnoreCase
    )
  ) {
    throw 'Broker process state identity is invalid.'
  }
  Assert-YefengStableId 'Broker instance_id' $state.instance_id
  Assert-YefengTimestamp 'Broker process_start_time' $state.process_start_time
  Assert-YefengTimestamp 'Broker started_at' $state.started_at
  Assert-YefengTimestamp 'Broker last_poll_at' $state.last_poll_at
  if (
    [string] $state.machine_name -cne [Environment]::MachineName -or
    [string] $state.script_sha256 -notmatch '^[A-Fa-f0-9]{64}$'
  ) {
    return [pscustomobject]@{
      running = $false
      stale = $true
      state = $state
      process = $null
    }
  }
  $process = Get-Process -Id ([int] $state.process_id) -ErrorAction SilentlyContinue
  if ($null -eq $process) {
    return [pscustomobject]@{
      running = $false
      stale = $true
      state = $state
      process = $null
    }
  }
  $recordedStart = [DateTimeOffset]::Parse([string] $state.process_start_time).UtcDateTime
  $actualStart = $process.StartTime.ToUniversalTime()
  $sameStart = [Math]::Abs(($actualStart - $recordedStart).TotalMilliseconds) -lt 2
  $scriptPath = Normalize-YefengPath ([string] $state.script_path)
  $sameScript = $scriptPath.Equals(
    (Normalize-YefengPath $PSCommandPath),
    [System.StringComparison]::OrdinalIgnoreCase
  )
  $sameHash = (Get-YefengFileSha256Hex $scriptPath) -ceq [string] $state.script_sha256
  $cimProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $([int] $state.process_id)" -ErrorAction SilentlyContinue
  $commandLine = if ($null -ne $cimProcess) { [string] $cimProcess.CommandLine } else { '' }
  $sameCommand = (
    -not [string]::IsNullOrWhiteSpace($commandLine) -and
    $commandLine.IndexOf($scriptPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
    $commandLine.IndexOf('-Mode Run', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
    $commandLine.IndexOf([string] $state.instance_id, [System.StringComparison]::Ordinal) -ge 0
  )
  if (-not $sameStart -or -not $sameScript -or -not $sameHash -or -not $sameCommand) {
    return [pscustomobject]@{
      running = $false
      stale = $true
      state = $state
      process = $process
    }
  }
  return [pscustomobject]@{
    running = $true
    stale = $false
    state = $state
    process = $process
  }
}

function Quote-BrokerProcessArgument([string] $Value) {
  if ($Value.Contains('"')) {
    throw 'Broker process arguments cannot contain a double quote.'
  }
  return '"' + $Value + '"'
}

function Start-DetachedBrokerProcess(
  [string] $EnginePath,
  [string[]] $Arguments,
  [string] $WorkingDirectory
) {
  if ($env:OS -cne 'Windows_NT') {
    throw 'Detached broker startup currently requires Windows; use -Mode Run under an external supervisor on other platforms.'
  }
  $commandLineParts = New-Object System.Collections.Generic.List[string]
  $commandLineParts.Add((Quote-BrokerProcessArgument $EnginePath))
  foreach ($argument in $Arguments) {
    $commandLineParts.Add([string] $argument)
  }
  $startup = New-CimInstance `
    -ClassName Win32_ProcessStartup `
    -Property @{ ShowWindow = [uint16] 0 } `
    -ClientOnly
  $created = Invoke-CimMethod `
    -ClassName Win32_Process `
    -MethodName Create `
    -Arguments @{
      CommandLine = ($commandLineParts -join ' ')
      CurrentDirectory = $WorkingDirectory
      ProcessStartupInformation = $startup
    }
  if ([int] $created.ReturnValue -ne 0 -or [int] $created.ProcessId -lt 1) {
    throw "Win32_Process.Create failed for the broker with return value $($created.ReturnValue)."
  }
  return [int] $created.ProcessId
}

Assert-YefengStableId 'ScopeId' $ScopeId
$snapshot = Get-YefengControlSnapshot $ControlRoot $ScopeId -RequireActiveExecution:($Mode -in @('Once', 'Run', 'Start'))
$ControlRoot = $snapshot.control_root
$paths = Get-YefengBrokerPaths $ControlRoot $ScopeId

if ($Mode -ceq 'Status') {
  $status = Get-BrokerProcessStatus $paths
  [ordered]@{
    mode = 'Status'
    scope_id = $ScopeId
    running = [bool] $status.running
    stale = [bool] $status.stale
    process_id = if ($null -ne $status.state) { [int] $status.state.process_id } else { $null }
    instance_id = if ($null -ne $status.state) { [string] $status.state.instance_id } else { $null }
    last_poll_at = if ($null -ne $status.state) { [string] $status.state.last_poll_at } else { $null }
  } | ConvertTo-Json -Depth 10
  exit 0
}

if ($Mode -ceq 'Stop') {
  $status = Get-BrokerProcessStatus $paths
  if (-not $status.running) {
    [ordered]@{
      mode = 'Stop'
      scope_id = $ScopeId
      stopped = $true
      already_stopped = $true
      stale = [bool] $status.stale
    } | ConvertTo-Json -Depth 10
    exit 0
  }
  $request = [ordered]@{
    version = 1
    instance_id = [string] $status.state.instance_id
    requested_at = [DateTimeOffset]::UtcNow.ToString('o')
    requested_by_process_id = $PID
  }
  Write-YefengUtf8FileAtomically $paths.stop_request_path (($request | ConvertTo-Json -Depth 10) + "`n")
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($StopTimeoutSeconds)
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
    $current = Get-BrokerProcessStatus $paths
    if (-not $current.running) {
      [ordered]@{
        mode = 'Stop'
        scope_id = $ScopeId
        stopped = $true
        already_stopped = $false
        process_id = [int] $status.state.process_id
        instance_id = [string] $status.state.instance_id
      } | ConvertTo-Json -Depth 10
      exit 0
    }
  }
  throw 'Broker did not stop cooperatively before StopTimeoutSeconds elapsed.'
}

if ($Mode -ceq 'Start') {
  $status = Get-BrokerProcessStatus $paths
  if ($status.running) {
    [ordered]@{
      mode = 'Start'
      scope_id = $ScopeId
      running = $true
      already_running = $true
      process_id = [int] $status.state.process_id
      instance_id = [string] $status.state.instance_id
    } | ConvertTo-Json -Depth 10
    exit 0
  }
  foreach ($directory in @($paths.runtime_root, $paths.logs_root)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
      New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
  }
  $newInstanceId = 'broker-' + [guid]::NewGuid().ToString('N')
  $failurePath = Join-Path $paths.logs_root "$newInstanceId.failure.json"
  $enginePath = (Get-Process -Id $PID -ErrorAction Stop).Path
  if ([string]::IsNullOrWhiteSpace($enginePath)) {
    throw 'Cannot resolve the current PowerShell executable for broker startup.'
  }
  $arguments = @(
    '-NoLogo',
    '-NoProfile',
    '-File',
    (Quote-BrokerProcessArgument $PSCommandPath),
    '-Mode',
    'Run',
    '-ControlRoot',
    (Quote-BrokerProcessArgument $ControlRoot),
    '-ScopeId',
    (Quote-BrokerProcessArgument $ScopeId),
    '-PollIntervalMilliseconds',
    [string] $PollIntervalMilliseconds,
    '-MaximumBatchSize',
    [string] $MaximumBatchSize,
    '-InstanceId',
    (Quote-BrokerProcessArgument $newInstanceId)
  )
  $childProcessId = Start-DetachedBrokerProcess $enginePath $arguments $ControlRoot
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
    $ready = Get-BrokerProcessStatus $paths
    if ($ready.running -and [string] $ready.state.instance_id -ceq $newInstanceId) {
      [ordered]@{
        mode = 'Start'
        scope_id = $ScopeId
        running = $true
        already_running = $false
        process_id = [int] $ready.state.process_id
        instance_id = $newInstanceId
        failure_path = $failurePath
      } | ConvertTo-Json -Depth 10
      exit 0
    }
    if ($null -eq (Get-Process -Id $childProcessId -ErrorAction SilentlyContinue)) {
      $failureText = if (Test-Path -LiteralPath $failurePath) {
        (Get-Content -LiteralPath $failurePath -Raw -Encoding UTF8)
      } else {
        ''
      }
      throw "Broker child exited before readiness: $failureText"
    }
  }
  throw 'Broker child did not publish a valid ready state within 10 seconds.'
}

$brokerGuard = Enter-BrokerGuard $paths
try {
  if ($Mode -ceq 'Once') {
    $batch = Invoke-BrokerBatch $snapshot $paths $MaximumBatchSize
    [ordered]@{
      mode = 'Once'
      scope_id = $ScopeId
      scanned = [int] $batch.counts.scanned
      accepted = [int] $batch.counts.accepted
      duplicates = [int] $batch.counts.duplicates
      quarantined = [int] $batch.counts.quarantined
      repaired = [int] $batch.counts.repaired
      deferred_errors = [int] $batch.counts.deferred_errors
      last_broker_sequence = [int64] $batch.last_broker_sequence
      journal_path = $paths.journal_path
    } | ConvertTo-Json -Depth 10
    exit 0
  }

  if ([string]::IsNullOrWhiteSpace($InstanceId)) {
    throw 'Run mode requires an internally supplied InstanceId.'
  }
  Assert-YefengStableId 'InstanceId' $InstanceId
  $process = Get-Process -Id $PID -ErrorAction Stop
  $processState = [ordered]@{
    version = 1
    control_root = $ControlRoot
    scope_id = $ScopeId
    instance_id = $InstanceId
    process_id = $PID
    process_start_time = $process.StartTime.ToUniversalTime().ToString('o')
    machine_name = [Environment]::MachineName
    script_path = Normalize-YefengPath $PSCommandPath
    script_sha256 = Get-YefengFileSha256Hex $PSCommandPath
    started_at = [DateTimeOffset]::UtcNow.ToString('o')
    last_poll_at = [DateTimeOffset]::UtcNow.ToString('o')
    totals = [ordered]@{
      scanned = 0
      accepted = 0
      duplicates = 0
      quarantined = 0
      repaired = 0
      deferred_errors = 0
    }
  }
  Write-YefengUtf8FileAtomically $paths.process_state_path (($processState | ConvertTo-Json -Depth 20) + "`n")
  while ($true) {
    if (Test-Path -LiteralPath $paths.stop_request_path -PathType Leaf) {
      $stopRequest = Read-YefengJsonFile $paths.stop_request_path 4096
      if ([string] $stopRequest.instance_id -ceq $InstanceId) {
        break
      }
    }
    $snapshot = Get-YefengControlSnapshot $ControlRoot $ScopeId -RequireActiveExecution
    $batch = Invoke-BrokerBatch $snapshot $paths $MaximumBatchSize
    foreach ($name in @('scanned', 'accepted', 'duplicates', 'quarantined', 'repaired', 'deferred_errors')) {
      $processState.totals.$name = [int64] $processState.totals.$name + [int64] $batch.counts.$name
    }
    $processState.last_poll_at = [DateTimeOffset]::UtcNow.ToString('o')
    Write-YefengUtf8FileAtomically $paths.process_state_path (($processState | ConvertTo-Json -Depth 20) + "`n")
    Start-Sleep -Milliseconds $PollIntervalMilliseconds
  }
} catch {
  if ($Mode -ceq 'Run' -and -not [string]::IsNullOrWhiteSpace($InstanceId)) {
    try {
      if (-not (Test-Path -LiteralPath $paths.logs_root -PathType Container)) {
        New-Item -ItemType Directory -Path $paths.logs_root -Force | Out-Null
      }
      $failure = [ordered]@{
        version = 1
        instance_id = $InstanceId
        failed_at = [DateTimeOffset]::UtcNow.ToString('o')
        error = [string] $_.Exception.Message
      }
      Write-YefengUtf8FileAtomically (
        Join-Path $paths.logs_root "$InstanceId.failure.json"
      ) (($failure | ConvertTo-Json -Depth 10) + "`n")
    } catch {
      # Preserve the original broker failure.
    }
  }
  throw
} finally {
  if ($Mode -ceq 'Run') {
    if (Test-Path -LiteralPath $paths.process_state_path -PathType Leaf) {
      try {
        $finalState = Read-YefengJsonFile $paths.process_state_path 16384
        if ([string] $finalState.instance_id -ceq $InstanceId) {
          [System.IO.File]::Delete($paths.process_state_path)
        }
      } catch {
        # Leave ambiguous state for status/recovery rather than deleting blindly.
      }
    }
    if (Test-Path -LiteralPath $paths.stop_request_path -PathType Leaf) {
      try {
        $finalRequest = Read-YefengJsonFile $paths.stop_request_path 4096
        if ([string] $finalRequest.instance_id -ceq $InstanceId) {
          [System.IO.File]::Delete($paths.stop_request_path)
        }
      } catch {
        # Keep malformed stop evidence for diagnosis.
      }
    }
  }
  $brokerGuard.Dispose()
}
