<#
.SYNOPSIS
Reads broker-delivered messages for one exact governed role assignment.

.DESCRIPTION
This command is read-only. It validates the assignment-bound inbox and returns
accepted journal projections after a caller-held broker sequence cursor.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $AssignmentPath,

  [ValidateRange(0, [long]::MaxValue)]
  [long] $AfterBrokerSequence = 0,

  [ValidateRange(1, 1000)]
  [int] $Limit = 100
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'message-common.ps1')
[Console]::InputEncoding = $script:YefengUtf8NoBom
[Console]::OutputEncoding = $script:YefengUtf8NoBom
$OutputEncoding = $script:YefengUtf8NoBom

$context = Get-YefengAssignmentContext $AssignmentPath
$messages = New-Object System.Collections.Generic.List[object]
$nextSequence = [int64] $AfterBrokerSequence
if (Test-Path -LiteralPath $context.inbox_dir -PathType Container) {
  $files = @(
    Get-ChildItem -LiteralPath $context.inbox_dir -Filter '*.json' -File -Force |
      Sort-Object Name
  )
  foreach ($file in $files) {
    $path = Assert-YefengPathInside $context.inbox_dir $file.FullName 'Role inbox message'
    $event = Read-YefengJsonFile $path $script:YefengMaximumMessageBytes
    Assert-YefengRequiredProperties 'Role inbox event' $event @(
      'version',
      'broker_sequence',
      'event_type',
      'recorded_at',
      'source_sha256',
      'message'
    )
    if (
      -not (Test-YefengInteger $event.version) -or
      [int64] $event.version -ne 1 -or
      -not (Test-YefengInteger $event.broker_sequence) -or
      [int64] $event.broker_sequence -lt 1 -or
      [string] $event.event_type -cne 'MESSAGE_ACCEPTED' -or
      [string] $event.source_sha256 -notmatch '^[A-Fa-f0-9]{64}$'
    ) {
      throw "Inbox projection has an invalid broker envelope: $path"
    }
    Assert-YefengTimestamp 'Inbox event recorded_at' $event.recorded_at
    Assert-YefengRequiredProperties 'Inbox role message' $event.message @(
      'message_id',
      'control_repo_id',
      'scope_id',
      'run_epoch',
      'recipient'
    )
    if (
      [string] $event.message.control_repo_id -cne [string] $context.assignment.control_repo_id -or
      [string] $event.message.scope_id -cne [string] $context.assignment.scope_id -or
      [string] $event.message.recipient -cne [string] $context.assignment.role_id
    ) {
      throw "Inbox projection is addressed to a different control scope or role: $path"
    }
    $sequence = [int64] $event.broker_sequence
    if ($sequence -le $AfterBrokerSequence) {
      continue
    }
    $messages.Add($event)
    if ($sequence -gt $nextSequence) {
      $nextSequence = $sequence
    }
    if ($messages.Count -ge $Limit) {
      break
    }
  }
}

[ordered]@{
  scope_id = [string] $context.assignment.scope_id
  role_id = [string] $context.assignment.role_id
  assignment_id = [string] $context.assignment.assignment_id
  run_id = [string] $context.assignment.run_id
  after_broker_sequence = [int64] $AfterBrokerSequence
  next_broker_sequence = [int64] $nextSequence
  count = $messages.Count
  messages = $messages.ToArray()
} | ConvertTo-Json -Depth 30
