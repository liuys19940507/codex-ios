Set-StrictMode -Version Latest

function Get-CodexRemoteArguments {
    param([string]$RemoteUrl, [string]$ProjectPath, [string]$Prompt, [string[]]$CliArguments = @())
    $result = @('--remote', $RemoteUrl, '--remote-auth-token-env', 'CODEX_REMOTE_LOCAL_TOKEN', '-C', $ProjectPath) + $CliArguments
    if ($Prompt) { $result += @('--', $Prompt) }
    return $result
}

function Invoke-CodexRemoteClient {
    param([string]$CodexExe, [string]$RemoteUrl, [string]$TokenFile, [string]$ProjectPath, [string]$Prompt, [string[]]$CliArguments = @(), [string]$NodeExe = (Get-Command node.exe -CommandType Application -ErrorAction Stop).Source)
    $privateDir = Join-Path ([IO.Path]::GetTempPath()) ('codex-launch-' + [guid]::NewGuid().ToString('N'))
    $requestFile = Join-Path $privateDir 'request.json'
    [IO.Directory]::CreateDirectory($privateDir) | Out-Null
    try {
        & (Join-Path $PSScriptRoot 'Protect-CodexRemotePath.ps1') -Path $privateDir
        $CodexArgs = @(Get-CodexRemoteArguments -RemoteUrl $RemoteUrl -ProjectPath $ProjectPath -Prompt $Prompt -CliArguments $CliArguments)
        $request = @{codexExe=$CodexExe;tokenFile=$TokenFile;args=$CodexArgs} | ConvertTo-Json -Depth 4 -Compress
        [IO.File]::WriteAllText($requestFile, $request, (New-Object Text.UTF8Encoding($false)))
        # Only a trusted file path crosses PowerShell's legacy native binder.
        # Node spawns Codex using the original array and a child-only environment.
        $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        & $NodeExe (Join-Path $repo 'bridge/node_modules/tsx/dist/cli.mjs') (Join-Path $repo 'bridge/scripts/run-cli.ts') --request $requestFile
        if ($LASTEXITCODE -ne 0) { throw "Remote Codex exited with code $LASTEXITCODE" }
    } finally {
        if ([IO.File]::Exists($requestFile)) { [IO.File]::Delete($requestFile) }
        [IO.Directory]::Delete($privateDir)
    }
}
Export-ModuleMember -Function Get-CodexRemoteArguments,Invoke-CodexRemoteClient
