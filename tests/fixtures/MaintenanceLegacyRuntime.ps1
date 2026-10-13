[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$childScript = [string]$config.fixtureChildScriptPath
$childReadyPath = [string]$config.fixtureChildReadyPath
$readyPath = [string]$config.fixtureReadyPath

$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = (Get-Command pwsh.exe -ErrorAction Stop).Source
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $childScript, '-ReadyPath', $childReadyPath)) {
    [void]$info.ArgumentList.Add($argument)
}
$child = [Diagnostics.Process]::new()
$child.StartInfo = $info
if (-not $child.Start()) { throw 'Legacy fixture child did not start.' }
$self = [Diagnostics.Process]::GetCurrentProcess()
try {
    $record = [ordered]@{
        pid = $PID
        creationFileTimeUtc = $self.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
        childPid = $child.Id
        childCreationFileTimeUtc = $child.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
    }
    [IO.File]::WriteAllText($readyPath, ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    while ($true) { Start-Sleep -Seconds 1 }
}
finally {
    $self.Dispose()
    $child.Dispose()
}
