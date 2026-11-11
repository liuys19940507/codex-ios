BeforeAll {
    $script:UploadHelper = Join-Path $PSScriptRoot '../Allow-CodexRemoteUploadRead.ps1'
    $script:ProtectHelper = Join-Path $PSScriptRoot '../Protect-CodexRemotePath.ps1'
}
Describe 'Attachment directory sandbox read permission' {
    BeforeEach {
        $script:State = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $State | Out-Null
        & $ProtectHelper -Path $State
        $script:Uploads = Join-Path $State 'uploads'
        New-Item -ItemType Directory -Path $Uploads | Out-Null
        $script:TestFile = Join-Path $Uploads 'example.txt'
        Set-Content -LiteralPath $TestFile -Value 'owned fixture'
        Mock Get-LocalGroup { [pscustomobject]@{SID=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')} }
    }
    It 'grants read and execute to attachment contents without granting write or changing the private parent' {
        & $UploadHelper -Path $Uploads -StateDir $State
        $group = (Get-Acl -LiteralPath $TestFile).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) |
            Where-Object {$_.IdentityReference.Value -eq 'S-1-5-32-545'}
        @($group).Count | Should -BeGreaterThan 0
        ($group.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadData) | Should -Not -Be 0
        ($group.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) | Should -Be 0
        $parent = (Get-Acl -LiteralPath $State).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) |
            Where-Object {$_.IdentityReference.Value -eq 'S-1-5-32-545'}
        @($parent).Count | Should -Be 0
    }
    It 'rejects granting access to the private state root itself' {
        { & $UploadHelper -Path $State -StateDir $State } | Should -Throw
    }
    It 'rejects granting access to an unrelated directory' {
        $other = Join-Path $TestDrive 'other'; New-Item -ItemType Directory -Path $other -Force | Out-Null
        { & $UploadHelper -Path $other -StateDir $State } | Should -Throw
    }
}
