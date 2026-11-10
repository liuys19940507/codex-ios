Set-StrictMode -Version Latest

function Get-CodexRemoteLaunchMode {
    param([string[]]$CliArguments = @())
    $nativeCommands = @('agents','exec','e','review','login','logout','mcp','plugin','app-server','remote-control','app','completion','update','doctor','sandbox','debug','apply','a','queue','archive','delete','migrate-rollouts','migrate-nfs-db','unarchive','cloud','exec-server','features','help')
    $valueFlags = @('-m','--model','-p','--profile','-c','--config','-s','--sandbox','-a','--ask-for-approval','-C','--cd','--add-dir','-i','--image')
    foreach ($argument in $CliArguments) {
        if ($argument -eq '--') { break }
        if (@('--version','-V','--help','-h','--no-daemon','--remote','--remote-auth-token-env') -ccontains $argument -or $argument -like '--remote=*' -or $argument -like '--remote-auth-token-env=*') { return 'native' }
    }
    for ($index = 0; $index -lt $CliArguments.Count; $index++) {
        $argument = $CliArguments[$index]
        if ($argument -eq '--') { return 'shared' }
        if (@('--version','-V','--help','-h','--no-daemon','--remote','--remote-auth-token-env') -ccontains $argument -or $argument -like '--remote=*' -or $argument -like '--remote-auth-token-env=*') { return 'native' }
        if ($valueFlags -ccontains $argument) { $index++; continue }
        if ($argument.StartsWith('-')) { continue }
        if ($nativeCommands -ccontains $argument) { return 'native' }
        return 'shared'
    }
    return 'shared'
}

function Get-CodexRemoteProfileContent {
    param([AllowEmptyString()][string]$Source, [string]$LauncherPath, [string]$ConfigPath)
    $tokens = $null; $parseErrors = $null
    $syntax = [System.Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count) { throw 'Existing PowerShell profile has syntax errors; no changes made' }
    $functions = @($syntax.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'codex' },$true))
    if ($functions.Count -gt 1) { throw 'Ambiguous codex function definitions; no changes made' }
    $newline = if ($Source.Contains("`r`n")) { "`r`n" } else { "`n" }
    $launcherLiteral = $LauncherPath.Replace("'", "''")
    $configLiteral = $ConfigPath.Replace("'", "''")
    $definition = "function codex {$newline    & '$launcherLiteral' -ConfigPath '$configLiteral' -CodexArguments " + '$args' + "$newline}"
    if ($functions.Count -eq 1) {
        $extent = $functions[0].Extent
        return $Source.Substring(0,$extent.StartOffset) + $definition + $Source.Substring($extent.EndOffset)
    }
    return $Source.TrimEnd("`r","`n") + $newline + $newline + $definition + $newline
}

function Resolve-CodexRemoteProjectDirectory {
    param([Parameter(Mandatory=$true)]$Config, [string]$ProjectId, [string]$ProjectPath)
    if ($ProjectId -and $ProjectPath) { throw 'Choose either ProjectId or ProjectPath' }
    if ($ProjectId) {
        $project = @($Config.projects | Where-Object id -EQ $ProjectId)
        if ($project.Count -ne 1) { throw 'Unknown or duplicate configured project ID' }
        $ProjectPath = $project[0].path
    }
    if (-not $ProjectPath) { $ProjectPath = (Get-Location).ProviderPath }
    $directory = (Get-Item -LiteralPath $ProjectPath -ErrorAction Stop)
    if (-not $directory.PSIsContainer -or $directory.PSProvider.Name -ne 'FileSystem') { throw 'Select an existing local project directory' }
    $resolved = $directory.FullName
    $discovery = $Config.PSObject.Properties['discoverProjects'] -and $Config.discoverProjects -eq $true
    if (-not $discovery) {
        $inside = @($Config.projects | Where-Object {
            $root = [IO.Path]::GetFullPath($_.path).TrimEnd('\','/')
            $resolved.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $resolved.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
        })
        if ($inside.Count -eq 0) { throw 'Project directory is outside configured project roots' }
    }
    return $resolved
}

function Get-CodexRemoteArguments {
    param([string]$RemoteUrl, [string]$ProjectPath, [string]$Prompt, [string[]]$CliArguments = @())
    $hasDirectory = $false
    $valueFlags = @('-m','--model','-p','--profile','-c','--config','-s','--sandbox','-a','--ask-for-approval','--add-dir','-i','--image')
    for ($index = 0; $index -lt $CliArguments.Count; $index++) {
        $argument = $CliArguments[$index]
        if ($argument -ceq '--') { break }
        if ($argument -ceq '-C' -or $argument -ceq '--cd' -or $argument.StartsWith('--cd=',[StringComparison]::Ordinal) -or $argument.StartsWith('-C',[StringComparison]::Ordinal)) {
            $hasDirectory = $true; break
        }
        if ($valueFlags -ccontains $argument) { $index++ }
    }
    $result = @('--remote', $RemoteUrl, '--remote-auth-token-env', 'CODEX_REMOTE_LOCAL_TOKEN')
    if (!$hasDirectory) { $result += @('-C', $ProjectPath) }
    $result += $CliArguments
    if ($Prompt) { $result += @('--', $Prompt) }
    return $result
}

function Invoke-CodexRemoteClient {
    param([string]$CodexExe, [string]$RemoteUrl, [string]$TokenFile, [string]$ProjectPath, [string]$Prompt, [string[]]$CliArguments = @(), [string]$NodeExe = (@(Get-Command node.exe -CommandType Application -ErrorAction Stop)[0].Source))
    $remoteArguments = @(Get-CodexRemoteArguments -RemoteUrl $RemoteUrl -ProjectPath $ProjectPath -Prompt $Prompt -CliArguments $CliArguments)
    Invoke-CodexProcess -CodexExe $CodexExe -TokenFile $TokenFile -CliArguments $remoteArguments -NodeExe $NodeExe
}

function Invoke-CodexNativeClient {
    param([string]$CodexExe, [string[]]$CliArguments = @(), [string]$NodeExe = (@(Get-Command node.exe -CommandType Application -ErrorAction Stop)[0].Source))
    Invoke-CodexProcess -CodexExe $CodexExe -CliArguments $CliArguments -NodeExe $NodeExe
}

function Invoke-CodexProcess {
    param([string]$CodexExe, [string]$TokenFile, [string[]]$CliArguments = @(), [string]$NodeExe)
    $privateDir = Join-Path ([IO.Path]::GetTempPath()) ('codex-launch-' + [guid]::NewGuid().ToString('N'))
    $requestFile = Join-Path $privateDir 'request.json'
    [IO.Directory]::CreateDirectory($privateDir) | Out-Null
    try {
        & (Join-Path $PSScriptRoot 'Protect-CodexRemotePath.ps1') -Path $privateDir
        $requestData = @{codexExe=$CodexExe;args=$CliArguments}
        if ($TokenFile) { $requestData.tokenFile = $TokenFile }
        $request = $requestData | ConvertTo-Json -Depth 4 -Compress
        [IO.File]::WriteAllText($requestFile, $request, (New-Object Text.UTF8Encoding($false)))
        # Only a trusted file path crosses PowerShell's legacy native binder.
        # Node spawns Codex using the original array and a child-only environment.
        $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        & $NodeExe (Join-Path $repo 'bridge/node_modules/tsx/dist/cli.mjs') (Join-Path $repo 'bridge/scripts/run-cli.ts') --request $requestFile
        if ($LASTEXITCODE -ne 0) { throw "Codex exited with code $LASTEXITCODE" }
    } finally {
        if ([IO.File]::Exists($requestFile)) { [IO.File]::Delete($requestFile) }
        [IO.Directory]::Delete($privateDir)
    }
}
Export-ModuleMember -Function Get-CodexRemoteArguments,Invoke-CodexRemoteClient,Invoke-CodexNativeClient,Resolve-CodexRemoteProjectDirectory,Get-CodexRemoteLaunchMode,Get-CodexRemoteProfileContent
