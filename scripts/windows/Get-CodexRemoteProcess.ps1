param([Parameter(Mandatory=$true)][int]$ProcessId)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$owned = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId"
if (-not $owned) { 'null'; exit 0 }
@{
    pid = [int]$owned.ProcessId
    exe = [string]$owned.ExecutablePath
    createdAt = $owned.CreationDate.ToUniversalTime().ToString('o')
    commandLine = [string]$owned.CommandLine
} | ConvertTo-Json -Compress
