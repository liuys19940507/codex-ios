BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../CodexRemote.Launcher.psm1') -Force
}

Describe 'PowerShell launcher' {
    It 'preserves Unicode, spaces and shell metacharacters as arguments' {
        $actual = @(Get-CodexRemoteArguments -RemoteUrl 'ws://127.0.0.1:8390' -ProjectPath 'D:\项目 空格\a;&$b' -Prompt '检查 ; & $x 中文' -CliArguments @('--model', 'gpt-6.1-sol'))
        $expected = @('--remote', 'ws://127.0.0.1:8390', '--remote-auth-token-env', 'CODEX_REMOTE_LOCAL_TOKEN', '-C', 'D:\项目 空格\a;&$b', '--model', 'gpt-6.1-sol', '--', '检查 ; & $x 中文')
        $actual.Count | Should -Be $expected.Count
        for ($i=0; $i -lt $expected.Count; $i++) { $actual[$i] | Should -BeExactly $expected[$i] }
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
