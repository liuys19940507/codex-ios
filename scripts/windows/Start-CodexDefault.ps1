[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [string[]]$CodexArguments = @()
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexRemote.Launcher.psm1') -Force
$config = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path) | ConvertFrom-Json
$mode = Get-CodexRemoteLaunchMode -CliArguments $CodexArguments
$defaultCodexHome = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
$alternateHome = $env:CODEX_HOME -and -not ([IO.Path]::GetFullPath($env:CODEX_HOME).TrimEnd('\','/').Equals($defaultCodexHome,[StringComparison]::OrdinalIgnoreCase))
if ($mode -eq 'native' -or $alternateHome) {
    $nativeArguments = $CodexArguments
    if ($alternateHome -and -not ($nativeArguments -ccontains '--no-daemon')) { $nativeArguments = @('--no-daemon') + $nativeArguments }
    Invoke-CodexNativeClient -CodexExe $config.codexExe -CliArguments $nativeArguments
} else {
    & (Join-Path $PSScriptRoot 'Start-CodexRemote.ps1') -ConfigPath $ConfigPath -CodexArguments $CodexArguments
}
