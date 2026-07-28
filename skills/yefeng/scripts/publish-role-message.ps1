<#
.SYNOPSIS
Publishes one assignment-bound immutable role message to the yefeng control spool.

.DESCRIPTION
The caller supplies semantic content only. Sender, assignment, run, epoch,
control-repository identity, outbox, and inbox are derived from and verified
against the exact assignment manifest and authoritative scope state.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $AssignmentPath,

  [Parameter(Mandatory = $true)]
  [ValidateSet(
    'QUESTION',
    'ANSWER',
    'BLOCKER',
    'CONTRACT_CHANGE',
    'REVIEW_REQUEST',
    'REVIEW_RESULT',
    'HANDOFF',
    'BASELINE_UPDATED',
    'RESUME_NOTICE',
    'USER_DECISION_REQUIRED',
    'DIRECTIVE',
    'PROGRESS',
    'CHECKPOINT',
    'HEARTBEAT'
  )]
  [string] $Type,

  [Parameter(Mandatory = $true)]
  [string] $Recipient,

  [Parameter(Mandatory = $true)]
  [string] $Summary,

  [string] $Details = '',
  [string[]] $RelatedFiles = @(),
  [string] $CorrelationId = '',
  [string] $CausationId = '',

  [ValidateSet('low', 'normal', 'high', 'urgent')]
  [string] $Priority = 'normal',

  [switch] $Blocking,
  [string] $BlockedRole = '',
  [string] $BlockedCheckpoint = '',
  [string] $BlockedBy = '',
  [string] $ResumeWhen = '',
  [string] $RequiredEvidence = '',
  [string] $WakeTarget = '',

  [ValidateRange(1, 30)]
  [int] $PublisherLockTimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'message-common.ps1')
[Console]::InputEncoding = $script:YefengUtf8NoBom
[Console]::OutputEncoding = $script:YefengUtf8NoBom
$OutputEncoding = $script:YefengUtf8NoBom

function ConvertTo-NullableString([string] $Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }
  return $Value
}

function Assert-OptionalMessageId([string] $Label, [string] $Value) {
  if (
    -not [string]::IsNullOrWhiteSpace($Value) -and
    $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
  ) {
    throw "$Label must be empty or a stable message/correlation identifier."
  }
}

$context = Get-YefengAssignmentContext $AssignmentPath
Assert-YefengStableId 'Recipient' $Recipient
if ($Recipient -cne 'TOTAL_CONTROL') {
  $recipientRoles = @($context.snapshot.roles.roles | Where-Object {
    [string] $_.role_id -ceq $Recipient
  })
  if ($recipientRoles.Count -ne 1) {
    throw "Recipient is not one governed role in this scope: $Recipient"
  }
}
Assert-OptionalMessageId 'CorrelationId' $CorrelationId
Assert-OptionalMessageId 'CausationId' $CausationId

if ([string]::IsNullOrWhiteSpace($Summary)) {
  throw 'Summary must be non-empty.'
}
if ($Summary.Length -gt 4096) {
  throw 'Summary exceeds the 4096-character limit.'
}
if ($Details.Length -gt 32768) {
  throw 'Details exceeds the 32768-character limit.'
}
if ($RelatedFiles.Count -gt 32) {
  throw 'RelatedFiles contains more than 32 entries.'
}
foreach ($relatedFile in $RelatedFiles) {
  if (
    $null -eq $relatedFile -or
    [string]::IsNullOrWhiteSpace([string] $relatedFile) -or
    ([string] $relatedFile).Length -gt 512 -or
    ([string] $relatedFile).Contains([char] 0)
  ) {
    throw 'Every RelatedFiles entry must be a non-empty string of at most 512 characters.'
  }
}

$isBlocking = [bool] $Blocking
if ($Type -ceq 'BLOCKER' -and -not $isBlocking) {
  throw 'A BLOCKER message must set -Blocking and provide the complete blocking contract.'
}
$blockingValues = @(
  $BlockedRole,
  $BlockedCheckpoint,
  $BlockedBy,
  $ResumeWhen,
  $RequiredEvidence,
  $WakeTarget
)
if ($isBlocking) {
  if (@($blockingValues | Where-Object { [string]::IsNullOrWhiteSpace([string] $_) }).Count -gt 0) {
    throw 'A blocking message requires BlockedRole, BlockedCheckpoint, BlockedBy, ResumeWhen, RequiredEvidence, and WakeTarget.'
  }
  Assert-YefengStableId 'BlockedRole' $BlockedRole
  Assert-YefengStableId 'WakeTarget' $WakeTarget
  if ($BlockedRole -cne [string] $context.assignment.role_id) {
    throw 'BlockedRole must be the publishing role.'
  }
} elseif (@($blockingValues | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }).Count -gt 0) {
  throw 'Blocking fields cannot be populated unless -Blocking is set.'
}
if ($Type -ceq 'HEARTBEAT') {
  if ($Recipient -cne 'TOTAL_CONTROL' -or $isBlocking) {
    throw 'HEARTBEAT must be non-blocking and addressed to TOTAL_CONTROL.'
  }
}

New-Item -ItemType Directory -Path $context.outbox_dir -Force | Out-Null
$null = Assert-YefengPathInside $context.paths.outbox_root $context.outbox_dir 'Publisher outbox'
$guardPath = Join-Path $context.outbox_dir '.publisher.guard'
$sequencePath = Join-Path $context.outbox_dir '.sender-sequence.json'
$publisherGuard = $null
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($PublisherLockTimeoutSeconds)
while ($null -eq $publisherGuard) {
  try {
    $publisherGuard = [System.IO.File]::Open(
      $guardPath,
      [System.IO.FileMode]::OpenOrCreate,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None
    )
  } catch [System.IO.IOException] {
    if ([DateTimeOffset]::UtcNow -ge $deadline) {
      throw 'Timed out waiting for the role-local publisher sequence lock.'
    }
    Start-Sleep -Milliseconds 50
  }
}

try {
  $senderSequence = 1
  if (Test-Path -LiteralPath $sequencePath -PathType Leaf) {
    $sequenceState = Read-YefengJsonFile $sequencePath 4096
    Assert-YefengExactProperties 'Sender sequence state' $sequenceState @(
      'version',
      'control_repo_id',
      'scope_id',
      'run_epoch',
      'role_id',
      'assignment_id',
      'run_id',
      'last_sequence',
      'updated_at'
    )
    if (
      -not (Test-YefengInteger $sequenceState.version) -or
      [int64] $sequenceState.version -ne 1 -or
      [string] $sequenceState.control_repo_id -cne [string] $context.assignment.control_repo_id -or
      [string] $sequenceState.scope_id -cne [string] $context.assignment.scope_id -or
      [int64] $sequenceState.run_epoch -ne [int64] $context.assignment.run_epoch -or
      [string] $sequenceState.role_id -cne [string] $context.assignment.role_id -or
      [string] $sequenceState.assignment_id -cne [string] $context.assignment.assignment_id -or
      [string] $sequenceState.run_id -cne [string] $context.assignment.run_id -or
      -not (Test-YefengInteger $sequenceState.last_sequence) -or
      [int64] $sequenceState.last_sequence -lt 0 -or
      [int64] $sequenceState.last_sequence -ge [int]::MaxValue
    ) {
      throw 'Sender sequence state does not match the current assignment.'
    }
    $senderSequence = [int64] $sequenceState.last_sequence + 1
  }

  $now = [DateTimeOffset]::UtcNow
  $sequenceState = [ordered]@{
    version = 1
    control_repo_id = [string] $context.assignment.control_repo_id
    scope_id = [string] $context.assignment.scope_id
    run_epoch = [int] $context.assignment.run_epoch
    role_id = [string] $context.assignment.role_id
    assignment_id = [string] $context.assignment.assignment_id
    run_id = [string] $context.assignment.run_id
    last_sequence = [int64] $senderSequence
    updated_at = $now.ToString('o')
  }
  Write-YefengUtf8FileAtomically $sequencePath (($sequenceState | ConvertTo-Json -Depth 10) + "`n")

  $messageId = 'msg-{0}-{1}' -f $now.ToString('yyyyMMddHHmmssfff'), ([guid]::NewGuid().ToString('N').Substring(0, 16))
  $message = [ordered]@{
    version = 1
    message_id = $messageId
    control_repo_id = [string] $context.assignment.control_repo_id
    scope_id = [string] $context.assignment.scope_id
    run_epoch = [int] $context.assignment.run_epoch
    role_id = [string] $context.assignment.role_id
    assignment_id = [string] $context.assignment.assignment_id
    run_id = [string] $context.assignment.run_id
    transport_mode = 'control-spool'
    sender_sequence = [int64] $senderSequence
    sent_at = $now.ToString('o')
    type = $Type
    recipient = $Recipient
    correlation_id = ConvertTo-NullableString $CorrelationId
    causation_id = ConvertTo-NullableString $CausationId
    priority = $Priority
    blocking = $isBlocking
    blocked_role = ConvertTo-NullableString $BlockedRole
    blocked_checkpoint = ConvertTo-NullableString $BlockedCheckpoint
    blocked_by = ConvertTo-NullableString $BlockedBy
    resume_when = ConvertTo-NullableString $ResumeWhen
    required_evidence = ConvertTo-NullableString $RequiredEvidence
    wake_target = ConvertTo-NullableString $WakeTarget
    payload = [ordered]@{
      summary = $Summary
      details = $Details
      related_files = @($RelatedFiles)
    }
  }
  $messageJson = ($message | ConvertTo-Json -Depth 20) + "`n"
  $messageBytes = $script:YefengUtf8NoBom.GetBytes($messageJson)
  if ($messageBytes.Length -gt $script:YefengMaximumMessageBytes) {
    throw "Serialized message exceeds the $($script:YefengMaximumMessageBytes)-byte limit."
  }
  $messagePath = Join-Path $context.outbox_dir "$messageId.json"
  Write-YefengUtf8FileAtomically $messagePath $messageJson -NoOverwrite

  [ordered]@{
    published = $true
    message_id = $messageId
    sender_sequence = [int64] $senderSequence
    message_path = $messagePath
    outbox_dir = $context.outbox_dir
    recipient = $Recipient
    type = $Type
  } | ConvertTo-Json -Depth 10
} finally {
  $publisherGuard.Dispose()
}
