BeforeAll {
    $script:checker = Join-Path $PSScriptRoot '../Check-AppRefresh.ps1'
    function Invoke-RefreshCheck {
        $output = & $script:checker -ConfigPath $script:configFile
        ($output | Out-String) | ConvertFrom-Json
    }
}

Describe 'Signing maintenance evidence boundaries' {
    BeforeEach {
        $script:daemonExe = Join-Path $TestDrive 'sideloadlydaemon.exe'
        [IO.File]::WriteAllText($script:daemonExe, 'fixture')
        $script:logDir = Join-Path $TestDrive 'logs'
        $script:configFile = Join-Path $TestDrive 'maintenance.json'
        $script:approvedHash = 'A' * 64
        $script:settings = @{daemonExe=$script:daemonExe;daemonSha256=$script:approvedHash;logDir=$script:logDir;evidence=$null}
        [IO.File]::WriteAllText($script:configFile, ($script:settings | ConvertTo-Json))
        $script:ownerSID = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Mock Get-FileHash { [pscustomobject]@{Hash=('A' * 64)} }
        Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='NotSigned'} }
        $processReply = New-CimInstance -ClassName Win32_Process -ClientOnly -Property @{ProcessId=[uint32]11;ExecutablePath=$script:daemonExe;Name='sideloadlydaemon.exe'}
        $ownerReply = [pscustomobject]@{Sid=$script:ownerSID}
        Mock Get-CimInstance -MockWith ({ $processReply }.GetNewClosure())
        Mock Invoke-CimMethod -MockWith ({ $ownerReply }.GetNewClosure())
        Mock Get-PnpDevice { [pscustomobject]@{FriendlyName='Apple Mobile Device USB';Status='OK'} }
        Mock Start-Process { [pscustomobject]@{Id=12} }
    }

    It 'RunningDaemonDoesNotProveRenewal' {
        $result = Invoke-RefreshCheck
        $result.daemon | Should -Be 'running' -Because $result.message
        $result.renewal | Should -Be 'unknown'
        $result.evidenceAt | Should -BeNullOrEmpty
        Should -Invoke Start-Process -Times 0
    }

    It 'MissingConfiguredExeFailsClearly' {
        $script:settings.daemonExe = Join-Path $TestDrive 'missing.exe'
        [IO.File]::WriteAllText($script:configFile, ($script:settings | ConvertTo-Json))
        $result = Invoke-RefreshCheck
        $result.daemon | Should -Be 'missing'
        $result.renewal | Should -Be 'needs_user'
        $LASTEXITCODE | Should -Not -Be 0
        Should -Invoke Start-Process -Times 0
    }

    It 'StartsHiddenOnlyOnce' {
        Mock Get-CimInstance { $null }
        $result = Invoke-RefreshCheck
        $result.daemon | Should -Be 'started' -Because $result.message
        $result.renewal | Should -Be 'unknown'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq $script:daemonExe -and $WindowStyle -eq 'Hidden' }
    }

    It 'NoDeviceWaitsWithoutRetryLoop' {
        Mock Get-PnpDevice { @() }
        $result = Invoke-RefreshCheck
        $result.renewal | Should -Be 'waiting'
        Should -Invoke Start-Process -Times 0
        Should -Invoke Get-PnpDevice -Times 1 -Exactly
    }

    It 'OldEvidenceDoesNotConfirmNewRenewal' {
        [IO.Directory]::CreateDirectory($script:logDir) | Out-Null
        $old = @{renewal='confirmed';evidenceAt=[DateTime]::UtcNow.AddDays(-3).ToString('o')}
        [IO.File]::WriteAllText((Join-Path $script:logDir 'last-check.json'), ($old | ConvertTo-Json))
        $result = Invoke-RefreshCheck
        $result.renewal | Should -Be 'unknown'
        $result.evidenceAt | Should -BeNullOrEmpty
    }

    It 'ReplacedExecutableIsNotStarted' {
        Mock Get-FileHash { [pscustomobject]@{Hash=('B' * 64)} }
        $result = Invoke-RefreshCheck
        $result.renewal | Should -Be 'needs_user'
        Should -Invoke Start-Process -Times 0
    }
}
