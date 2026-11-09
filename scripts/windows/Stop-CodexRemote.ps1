[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [Parameter(Mandatory=$true)][string]$InstanceId,
    [string]$NodeExe = (Get-Command node.exe -CommandType Application -ErrorAction Stop).Source
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$tsx = Join-Path $repo 'bridge/node_modules/tsx/dist/cli.mjs'
$control = Join-Path $repo 'bridge/scripts/service-control.ts'
$configFile = (Resolve-Path -LiteralPath $ConfigPath).Path
$statusJSON = & $NodeExe $tsx $control --config $configFile --status
if ($LASTEXITCODE -ne 0) { throw 'Cannot verify owned service' }
$status = $statusJSON | ConvertFrom-Json
if (-not $status.service -or $status.service.instanceId -ne $InstanceId) { throw 'Instance ID no longer matches; nothing stopped' }
Write-Host "Stopping this shared service affects its loaded tasks: $($status.threads | ConvertTo-Json -Compress -Depth 4)"
if ($PSCmdlet.ShouldProcess("shared instance $InstanceId", 'Stop Codex and its loaded tasks')) {
    & $NodeExe $tsx $control --config $configFile --stop $InstanceId
    if ($LASTEXITCODE -ne 0) { throw 'Owned service stop failed' }
}
