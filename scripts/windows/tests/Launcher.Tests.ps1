BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../CodexRemote.Launcher.psm1') -Force
}

Describe 'PowerShell launcher' {
    It 'routes interactive work to shared transport and keeps native utilities and explicit transports' {
        Get-CodexRemoteLaunchMode -CliArguments @() | Should -BeExactly 'shared'
        Get-CodexRemoteLaunchMode -CliArguments @('resume','a-thread') | Should -BeExactly 'shared'
        Get-CodexRemoteLaunchMode -CliArguments @('-m','model','resume','a-thread') | Should -BeExactly 'shared'
        foreach($arguments in @(@('--version'),@('login'),@('-m','model','exec','literal prompt'),@('--remote','ws://other.example'),@('literal prompt','--remote=ws://other.example'),@('--no-daemon'))) {
            Get-CodexRemoteLaunchMode -CliArguments $arguments | Should -BeExactly 'native'
        }
        Get-CodexRemoteLaunchMode -CliArguments @('--','login') | Should -BeExactly 'shared'
    }
    It 'replaces only the codex function and quotes paths without changing another account entry' {
        $source = "# preserve 中文`r`nfunction codex2 { `$env:CODEX_HOME='C:\alternate'; codex }`r`nfunction codex { codex.cmd --no-daemon @args }`r`n"
        $updated = Get-CodexRemoteProfileContent -Source $source -LauncherPath "D:\O'Brien\Start-CodexDefault.ps1" -ConfigPath 'C:\private\runtime.json'
        $updated | Should -Match "O''Brien"
        $updated | Should -Match 'function codex2'
        $updated | Should -Match ([regex]::Escape("`$env:CODEX_HOME='C:\alternate'"))
        $updated | Should -Not -Match 'codex.cmd --no-daemon'
        $tokens = $null; $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($updated,[ref]$tokens,[ref]$parseErrors)|Out-Null
        @($parseErrors).Count | Should -Be 0
    }
    It 'uses the actual current directory when history project discovery is enabled' {
        $directory = Join-Path $TestDrive 'another project'
        New-Item -ItemType Directory -Path $directory | Out-Null
        Push-Location -LiteralPath $directory
        try {
            $config = [pscustomobject]@{discoverProjects=$true;projects=@([pscustomobject]@{id='known';path=$TestDrive})}
            Resolve-CodexRemoteProjectDirectory -Config $config | Should -BeExactly $directory
        } finally { Pop-Location }
    }
    It 'preserves an explicitly selected project and rejects unknown IDs' {
        $config = [pscustomobject]@{projects=@([pscustomobject]@{id='known';path=$TestDrive})}
        Resolve-CodexRemoteProjectDirectory -Config $config -ProjectId 'known' | Should -BeExactly $TestDrive
        { Resolve-CodexRemoteProjectDirectory -Config $config -ProjectId 'unknown' } | Should -Throw
    }
    It 'keeps static project scope and rejects conflicting selection arguments' {
        $config = [pscustomobject]@{projects=@([pscustomobject]@{id='known';path=(Join-Path $TestDrive 'known')})}
        { Resolve-CodexRemoteProjectDirectory -Config $config -ProjectPath $TestDrive } | Should -Throw
        { Resolve-CodexRemoteProjectDirectory -Config $config -ProjectId 'known' -ProjectPath $TestDrive } | Should -Throw
    }
    It 'preserves Unicode, spaces and shell metacharacters as arguments' {
        $actual = @(Get-CodexRemoteArguments -RemoteUrl 'ws://127.0.0.1:8390' -ProjectPath 'D:\项目 空格\a;&$b' -Prompt '检查 ; & $x 中文' -CliArguments @('--model', 'gpt-6.1-sol'))
        $expected = @('--remote', 'ws://127.0.0.1:8390', '--remote-auth-token-env', 'CODEX_REMOTE_LOCAL_TOKEN', '-C', 'D:\项目 空格\a;&$b', '--model', 'gpt-6.1-sol', '--', '检查 ; & $x 中文')
        $actual.Count | Should -Be $expected.Count
        for ($i=0; $i -lt $expected.Count; $i++) { $actual[$i] | Should -BeExactly $expected[$i] }
    }

    It 'honors an explicit native directory without adding a duplicate option' {
        foreach ($arguments in @(@('-C','D:\项目 空格','resume','thread'),@('--cd','D:\other'),@('--cd=D:\other'),@('-CD:\other'),@('resume','thread','--cd','D:\other'))) {
            $actual = @(Get-CodexRemoteArguments -RemoteUrl 'ws://127.0.0.1:8390' -ProjectPath 'C:\default' -CliArguments $arguments)
            $actual.Count | Should -Be (4 + $arguments.Count)
            for ($i=0; $i -lt $arguments.Count; $i++) { $actual[4+$i] | Should -BeExactly $arguments[$i] }
        }
    }
    It 'keeps default directory for configuration values and literal prompt text' {
        foreach ($arguments in @(@('-c','name=value'),@('--config','-Cdata'),@('--model','--cd=literal'),@('--','explain','--cd','literal'))) {
            $actual = @(Get-CodexRemoteArguments -RemoteUrl 'ws://127.0.0.1:8390' -ProjectPath 'C:\default' -CliArguments $arguments)
            $actual.Count | Should -Be (6 + $arguments.Count)
            $actual[4] | Should -BeExactly '-C'
            $actual[5] | Should -BeExactly 'C:\default'
        }
    }

    It 'captures literal arguments in an actual native process and restores the environment' {
        $preferredNode = @(Get-Command node.exe -CommandType Application)[0].Source
        Mock Get-Command -ModuleName CodexRemote.Launcher -ParameterFilter { $Name -eq 'node.exe' } -MockWith {
            [pscustomobject]@{Source=$preferredNode}
            [pscustomobject]@{Source='C:\unused-second-node\node.exe'}
        }
        $captureExe = Join-Path $TestDrive 'codex.exe'
        Add-Type -TypeDefinition @'
using System;
public class CaptureArguments {
    public static void Main(string[] args) {
        foreach (string arg in args) Console.WriteLine(Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(arg)));
        Console.WriteLine("TOKEN:" + Environment.GetEnvironmentVariable("CODEX_REMOTE_LOCAL_TOKEN"));
    }
}
'@ -OutputAssembly $captureExe -OutputType ConsoleApplication
        $tokenFile = Join-Path $TestDrive 'token'
        [IO.File]::WriteAllText($tokenFile, 'test-token')
        $env:CODEX_REMOTE_LOCAL_TOKEN = 'parent-value'
        try {
            $output = @(Invoke-CodexRemoteClient -CodexExe $captureExe -RemoteUrl 'ws://127.0.0.1:8390' -TokenFile $tokenFile -ProjectPath 'D:\项目 空格\a;&$b' -CliArguments @('--config','x="a\b"','','D:\目录 有空格\') -Prompt '检查 "引号" ; & $x 中文')
            $decoded = @($output | Where-Object { $_ -notlike 'TOKEN:*' } | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
            $decoded[-1] | Should -BeExactly '检查 "引号" ; & $x 中文'
            $decoded[5] | Should -BeExactly 'D:\项目 空格\a;&$b'
            $decoded[7] | Should -BeExactly 'x="a\b"'
            $decoded[8] | Should -BeExactly ''
            $decoded[9] | Should -BeExactly 'D:\目录 有空格\'
            $decoded.Count | Should -Be 12
            $output[-1] | Should -BeExactly 'TOKEN:test-token'
            $env:CODEX_REMOTE_LOCAL_TOKEN | Should -BeExactly 'parent-value'
        } finally { Remove-Item Env:CODEX_REMOTE_LOCAL_TOKEN -ErrorAction SilentlyContinue }
    }
}
