[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\CodexWorktreeTrustBridge.Maintenance.ps1')

$tokens = $null
$errors = $null
$validatorPath = Join-Path $root 'Validate-Gray.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($validatorPath, [ref]$tokens, [ref]$errors)
if (@($errors).Count) { throw "Validate-Gray.ps1 has parse errors: $($errors -join '; ')" }
foreach ($name in @('Test-GrayProcessIdentityGone', 'Get-GrayProcessResource')) {
    $definition = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $false))
    if ($definition.Count -ne 1) { throw "Expected exactly one $name definition in Validate-Gray.ps1." }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}

$self = [Diagnostics.Process]::GetCurrentProcess()
$short = $null
try {
    $selfIdentity = [pscustomobject]@{
        pid = $self.Id
        creationFileTimeUtc = $self.StartTime.ToUniversalTime().ToFileTimeUtc()
        executablePath = ConvertTo-BridgeCanonicalPath $self.MainModule.FileName
    }
    $sample = Get-GrayProcessResource -Identity $selfIdentity
    if ($null -eq $sample -or $sample.pid -ne $self.Id -or $sample.privateBytes -le 0 -or $sample.handles -le 0) {
        throw 'Live required process identity did not produce a resource sample.'
    }

    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Milliseconds 150')) {
        [void]$info.ArgumentList.Add($argument)
    }
    $short = [Diagnostics.Process]::new()
    $short.StartInfo = $info
    if (-not $short.Start()) { throw 'Could not start the controlled transient descendant fixture.' }
    [void]$short.Handle
    $shortIdentity = [pscustomobject]@{
        pid = $short.Id
        creationFileTimeUtc = $short.StartTime.ToUniversalTime().ToFileTimeUtc()
        executablePath = ConvertTo-BridgeCanonicalPath $info.FileName
    }
    if (-not $short.WaitForExit(10000)) { throw 'Controlled transient descendant did not exit.' }
    if ($null -ne (Get-GrayProcessResource -Identity $shortIdentity -AllowMissing)) {
        throw 'An exited optional descendant produced a resource sample.'
    }
    $requiredRejected = $false
    try { [void](Get-GrayProcessResource -Identity $shortIdentity) }
    catch { $requiredRejected = $true }
    if (-not $requiredRejected) { throw 'An exited required process identity was silently ignored.' }

    $reusedIdentity = [pscustomobject]@{
        pid = $selfIdentity.pid
        creationFileTimeUtc = [long]$selfIdentity.creationFileTimeUtc + 1
        executablePath = $selfIdentity.executablePath
    }
    if ($null -ne (Get-GrayProcessResource -Identity $reusedIdentity -AllowMissing)) {
        throw 'A reused PID identity was sampled as the stale descendant.'
    }

    $wrongExecutable = [pscustomobject]@{
        pid = $selfIdentity.pid
        creationFileTimeUtc = $selfIdentity.creationFileTimeUtc
        executablePath = Join-Path $root 'not-the-live-executable.exe'
    }
    $pathMismatchRejected = $false
    try { [void](Get-GrayProcessResource -Identity $wrongExecutable -AllowMissing) }
    catch { $pathMismatchRejected = $_.Exception.Message -like '*executable identity changed*' }
    if (-not $pathMismatchRejected) { throw 'A live executable identity mismatch was hidden as transient churn.' }

    [pscustomobject]@{
        passed = $true
        liveRequiredIdentitySampled = $true
        exitedOptionalDescendantIgnored = $true
        exitedRequiredIdentityRejected = $true
        reusedPidIgnoredForStaleOptionalIdentity = $true
        liveExecutableMismatchRejected = $true
        validatorSha256 = (Get-FileHash -LiteralPath $validatorPath -Algorithm SHA256).Hash
    } | ConvertTo-Json -Depth 5
}
finally {
    if ($null -ne $short) {
        try { if (-not $short.HasExited) { $short.Kill($true); [void]$short.WaitForExit(10000) } }
        finally { $short.Dispose() }
    }
    $self.Dispose()
}
