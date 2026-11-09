[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$result = [ordered]@{checkedAt=[DateTime]::UtcNow.ToString('o');daemon='missing';renewal='needs_user';message='Maintenance configuration needs attention.';evidenceAt=$null}
$exitCode = 0
$logDirectory = $null
try {
    if (-not [IO.Path]::IsPathRooted($ConfigPath)) { throw 'Use an absolute maintenance configuration path.' }
    $settings = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
    $allowed = @('daemonExe','daemonSha256','logDir','evidence')
    if (@($settings.PSObject.Properties.Name | Where-Object { $_ -notin $allowed }).Count -ne 0) { throw 'Unsupported maintenance configuration field.' }
    if (-not [IO.Path]::IsPathRooted($settings.daemonExe) -or -not [IO.Path]::IsPathRooted($settings.logDir)) { throw 'Daemon and log paths must be absolute.' }
    if ([IO.Path]::GetFileName($settings.daemonExe) -ine 'sideloadlydaemon.exe') { throw 'Configure the installed Sideloadly daemon executable.' }
    if ($settings.daemonSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'A verified daemon SHA-256 is required.' }
    if ($null -ne $settings.evidence) { throw 'No automatic renewal evidence format has been verified for this installation.' }
    $logDirectory = [IO.Path]::GetFullPath($settings.logDir)
    [IO.Directory]::CreateDirectory($logDirectory) | Out-Null
    & (Join-Path $PSScriptRoot 'Protect-CodexRemotePath.ps1') -Path $logDirectory
    $daemonPath = [IO.Path]::GetFullPath($settings.daemonExe)
    if (-not (Test-Path -LiteralPath $daemonPath -PathType Leaf)) { throw 'The configured Sideloadly daemon executable does not exist.' }
    if ((Get-Item -LiteralPath $daemonPath).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The configured executable cannot be a reparse point.' }
    $actualHash = (Get-FileHash -LiteralPath $daemonPath -Algorithm SHA256).Hash
    $signature = (Get-AuthenticodeSignature -LiteralPath $daemonPath).Status.ToString()
    if ($actualHash -ine $settings.daemonSha256 -or $signature -notin @('Valid','NotSigned')) { throw 'The daemon executable identity does not match the verified installation.' }
    # The current official-installed daemon is unsigned. Only its previously
    # verified, pinned hash is allowed; never accept arbitrary unsigned files.
    $currentSID = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $running = $false
    foreach ($candidate in @(Get-CimInstance Win32_Process -Filter "Name='sideloadlydaemon.exe'")) {
        if ($null -eq $candidate) { continue }
        if (-not $candidate.ExecutablePath) { throw 'Cannot verify an existing daemon executable path.' }
        if (-not [String]::Equals($candidate.ExecutablePath, $daemonPath, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $owner = Invoke-CimMethod -InputObject $candidate -MethodName GetOwnerSid
        if (-not $owner.Sid) { throw 'Cannot verify the existing daemon owner.' }
        if ($owner.Sid -eq $currentSID) { $running = $true }
    }
    if ($running) { $result.daemon = 'running' }
    else {
        Start-Process -FilePath $daemonPath -WindowStyle Hidden -PassThru | Out-Null
        $result.daemon = 'started'
    }
    $usbDevices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' -and $_.FriendlyName -match 'Apple (Mobile Device|iPhone)' })
    if ($usbDevices.Count -eq 0) {
        $result.renewal = 'waiting'
        $result.message = 'No Apple USB device was observed. Wi-Fi pairing and renewal are not verified; no retry loop was started.'
    } else {
        $result.renewal = 'unknown'
        $result.message = 'Daemon is available and an Apple USB device was observed. This does not confirm pairing, installation or renewal.'
    }
    # Old receipts, process uptime and USB presence are not signing evidence.
    # There is intentionally no confirmed branch without an M1-verified reader.
} catch {
    $result.renewal = 'needs_user'
    $result.message = $_.Exception.Message
    $exitCode = 1
}
$json = $result | ConvertTo-Json -Compress
if ($logDirectory) {
    try { [IO.File]::WriteAllText((Join-Path $logDirectory 'last-check.json'), $json, [Text.UTF8Encoding]::new($false)) }
    catch { $result.renewal='needs_user';$result.message='Could not write the private maintenance report.';$json=$result|ConvertTo-Json -Compress;$exitCode=1 }
}
Write-Output $json
exit $exitCode
