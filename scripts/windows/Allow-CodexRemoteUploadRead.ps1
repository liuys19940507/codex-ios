param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$StateDir
)
$ErrorActionPreference = 'Stop'
$state = Get-Item -LiteralPath $StateDir -Force
$item = Get-Item -LiteralPath $Path -Force
$expected = [IO.Path]::GetFullPath((Join-Path $state.FullName 'uploads'))
if (-not $state.PSIsContainer -or -not $item.PSIsContainer -or
    -not [string]::Equals($item.FullName.TrimEnd('\'), $expected.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Sandbox read permission is limited to the attachment uploads directory'
}
if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($state.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Attachment permission targets cannot be reparse points'
}
# Legacy elevated Codex runs tools under these dedicated sandbox accounts.
# Grant only read/execute to uploaded content; the private parent is unchanged.
$group = Get-LocalGroup -Name 'CodexSandboxUsers' -ErrorAction SilentlyContinue
if ($null -eq $group) { return }
$acl = Get-Acl -LiteralPath $item.FullName
$rule = New-Object Security.AccessControl.FileSystemAccessRule($group.SID, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $item.FullName -AclObject $acl
