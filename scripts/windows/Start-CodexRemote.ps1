[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [Parameter(Mandatory=$true)][string]$ProjectId,
    [string]$Prompt,
    [string[]]$CodexArguments = @(),
    [string]$NodeExe = (Get-Command node.exe -CommandType Application -ErrorAction Stop).Source
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexRemote.Launcher.psm1') -Force
$configFile = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = [IO.File]::ReadAllText($configFile) | ConvertFrom-Json
$project = @($config.projects | Where-Object id -EQ $ProjectId)
if ($project.Count -ne 1) { throw 'Unknown or duplicate configured project ID' }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$tsx = Join-Path $repo 'bridge/node_modules/tsx/dist/cli.mjs'
$control = Join-Path $repo 'bridge/scripts/service-control.ts'
$serviceJSON = & $NodeExe $tsx $control --config $configFile
if ($LASTEXITCODE -ne 0) { throw 'Shared service failed to start; see diagnostic above' }
$service = $serviceJSON | ConvertFrom-Json
Write-Host "Shared instance $($service.instanceId) (Codex PID $($service.pid)); CLI exit keeps its tasks running."
Invoke-CodexRemoteClient -CodexExe $config.codexExe -RemoteUrl $service.codexUrl -TokenFile (Join-Path $config.stateDir 'codex-token') -ProjectPath $project[0].path -Prompt $Prompt -CliArguments $CodexArguments -NodeExe $NodeExe
