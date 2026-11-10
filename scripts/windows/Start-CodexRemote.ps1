[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [string]$ProjectId,
    [string]$ProjectPath,
    [string]$Prompt,
    [string[]]$CodexArguments = @(),
    [string]$NodeExe = (@(Get-Command node.exe -CommandType Application -ErrorAction Stop)[0].Source)
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexRemote.Launcher.psm1') -Force
$configFile = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = [IO.File]::ReadAllText($configFile) | ConvertFrom-Json
$workingDirectory = Resolve-CodexRemoteProjectDirectory -Config $config -ProjectId $ProjectId -ProjectPath $ProjectPath
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$tsx = Join-Path $repo 'bridge/node_modules/tsx/dist/cli.mjs'
$control = Join-Path $repo 'bridge/scripts/service-control.ts'
$serviceJSON = & $NodeExe $tsx $control --config $configFile
if ($LASTEXITCODE -ne 0) { throw 'Shared service failed to start; see diagnostic above' }
$service = $serviceJSON | ConvertFrom-Json
$bridgeControl = Join-Path $repo 'bridge/scripts/bridge-control.ts'
$bridgeJSON = & $NodeExe $tsx $bridgeControl --config $configFile
if ($LASTEXITCODE -ne 0) { throw 'Bridge service failed to start; see diagnostic above' }
$bridge = $bridgeJSON | ConvertFrom-Json
Write-Host "Phone bridge: $($bridge.bridgeUrl)"
Write-Host "Shared instance $($service.instanceId) (Codex PID $($service.pid)); CLI exit keeps its tasks running."
Invoke-CodexRemoteClient -CodexExe $config.codexExe -RemoteUrl $service.codexUrl -TokenFile (Join-Path $config.stateDir 'codex-token') -ProjectPath $workingDirectory -Prompt $Prompt -CliArguments $CodexArguments -NodeExe $NodeExe
