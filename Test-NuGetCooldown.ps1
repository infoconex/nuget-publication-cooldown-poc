#Requires -Version 7
[CmdletBinding()]
param(
    [string]$DotnetPath = (Join-Path $HOME 'dotnet-sdks/11.0.100-rc.2.26504.105/dotnet.exe'),
    [ValidateRange(1, 8760)][int]$CooldownHours = 72,
    [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$PackageId = 'Cooldown.Sample'
$Root = Join-Path $PSScriptRoot 'artifacts'
$Run = Join-Path $Root ('run-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0, 8))
$Feed = Join-Path $Run 'feed'
$Results = [System.Collections.Generic.List[object]]::new()
$SdkVersion = $null
$Logs = Join-Path $Run 'logs'
$script:CommandNumber = 0
$StartedAtUtc = [DateTime]::UtcNow
$PreparationError = $null

<#
.SYNOPSIS
Runs a dotnet command and writes complete diagnostics to a numbered log file.
.DESCRIPTION
Normal output is intentionally quiet. -Detailed echoes the captured command
output. Unexpected exit codes raise an error including the log path and tail.
#>
function Run-Dotnet {
    param([string[]]$Arguments, [string]$Directory, [int[]]$Allowed = @(0))
    $script:CommandNumber++
    $LogPath = Join-Path $Logs ('{0:00}-{1}.log' -f $script:CommandNumber, $Arguments[0])
    Push-Location -LiteralPath $Directory
    try {
        $OutputLines = @(& $DotnetPath @Arguments 2>&1)
        $ExitCode = $LASTEXITCODE
    }
    finally { Pop-Location }
    $Text = ($OutputLines | Out-String).Trim()
    @(
        ('Directory: {0}' -f $Directory),
        ('Command: dotnet {0}' -f ($Arguments -join ' ')),
        ('Exit code: {0}' -f $ExitCode),
        '',
        $Text
    ) | Set-Content -LiteralPath $LogPath -Encoding utf8
    if ($Detailed) {
        Write-Host ('  > dotnet {0} (exit {1})' -f ($Arguments -join ' '), $ExitCode) -ForegroundColor DarkGray
        if ($Text) { Write-Host $Text }
    }
    if ($Allowed -notcontains $ExitCode) {
        $Tail = ($Text -split '\r?\n' | Select-Object -Last 8) -join [Environment]::NewLine
        throw ('Command returned exit {0}; expected {1}. {2} Log: {3}' -f $ExitCode, ($Allowed -join ', '), $Tail, $LogPath)
    }
    return [pscustomobject]@{ ExitCode = $ExitCode; Output = $Text; LogPath = $LogPath }
}

function New-Consumer {
    param([string]$Name, [bool]$Cooldown, [string]$Reference)
    $Directory = Join-Path $Run $Name
    New-Item -ItemType Directory -Path $Directory | Out-Null
    $FeedXml = [System.Security.SecurityElement]::Escape($Feed)
    $CacheXml = [System.Security.SecurityElement]::Escape((Join-Path $Directory 'packages'))
    $Age = if ($Cooldown) { 'minPublishAgeHours="{0}"' -f $CooldownHours } else { '' }
    $Config = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources><clear /><add key="local" value="{0}" {1} /></packageSources>
  <minPublishAgeExceptions />
  <config><add key="globalPackagesFolder" value="{2}" /></config>
</configuration>
'@ -f $FeedXml, $Age, $CacheXml
    Set-Content -LiteralPath (Join-Path $Directory 'nuget.config') -Value $Config -Encoding utf8
    $Dependency = if ($Reference) {
        '<ItemGroup><PackageReference Include="{0}" Version="{1}" /></ItemGroup>' -f $PackageId, $Reference
    } else { '' }
    $ProjectXml = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net11.0</TargetFramework><NuGetAudit>false</NuGetAudit></PropertyGroup>
  {0}
</Project>
'@ -f $Dependency
    Set-Content -LiteralPath (Join-Path $Directory 'Consumer.csproj') -Value $ProjectXml -Encoding utf8
    return $Directory
}

function Assert-Version {
    param([string]$Directory, [string]$Expected)
    [xml]$Project = Get-Content -LiteralPath (Join-Path $Directory 'Consumer.csproj') -Raw
    $Reference = $Project.SelectSingleNode('//PackageReference[@Include="Cooldown.Sample"]')
    if ($null -eq $Reference -or $Reference.GetAttribute('Version') -ne $Expected) {
        throw ('Unexpected PackageReference in {0}. Expected {1}.' -f $Directory, $Expected)
    }
    $AssetsFile = Join-Path $Directory 'obj/project.assets.json'
    if (-not (Test-Path -LiteralPath $AssetsFile)) { throw ('Missing assets file: {0}' -f $Directory) }
    $Assets = Get-Content -LiteralPath $AssetsFile -Raw | ConvertFrom-Json
    if (('{0}/{1}' -f $PackageId, $Expected) -notin @($Assets.libraries.PSObject.Properties.Name)) {
        throw ('Resolved version differs from {0} in {1}.' -f $Expected, $Directory)
    }
}

<#
.SYNOPSIS
Displays a banner, runs one test function, and records its observed result.
.DESCRIPTION
A test is PASS only after its assertions succeed. An exception is shown as FAIL;
all independent scenarios continue so the final report is still useful.
#>
function Invoke-Scenario {
    param(
        [int]$Number,
        [string]$Title,
        [string]$Purpose,
        [string]$Cooldown,
        [string]$Expected,
        [scriptblock]$Action
    )
    Write-Host ''
    Write-Host ('=' * 76) -ForegroundColor Cyan
    Write-Host ('SCENARIO {0}/5: {1}' -f $Number, $Title) -ForegroundColor Cyan
    Write-Host ('-' * 76) -ForegroundColor DarkGray
    Write-Host ('Evaluates : {0}' -f $Purpose)
    Write-Host ('Package   : {0}' -f $PackageId)
    Write-Host ('Cooldown  : {0}' -f $Cooldown)
    Write-Host ('Expected  : {0}' -f $Expected)
    try {
        $Actual = & $Action
        $Entry = [pscustomobject]@{
            Number = $Number; Scenario = $Title; Expected = $Expected
            Observed = $Actual.Observed; ExitCode = $Actual.ExitCode
            Status = 'PASS'; Finding = $Actual.Finding
        }
        Write-Host ('Observed  : {0}' -f $Actual.Observed)
        Write-Host ('Exit code : {0}' -f $Actual.ExitCode)
        Write-Host 'Result    : PASS' -ForegroundColor Green
        Write-Host ('Finding   : {0}' -f $Actual.Finding)
    }
    catch {
        $Message = $_.Exception.Message
        $Entry = [pscustomobject]@{
            Number = $Number; Scenario = $Title; Expected = $Expected
            Observed = $Message; ExitCode = $null
            Status = 'FAIL'; Finding = 'Expected behavior not confirmed'
        }
        Write-Host ('Observed  : {0}' -f $Message) -ForegroundColor Red
        Write-Host 'Result    : FAIL' -ForegroundColor Red
    }
    $Results.Add($Entry)
}

<#
.SYNOPSIS
Displays the summary and interpretation of the scenario results.
#>
function Show-Summary {
    $Passed = @($Results | Where-Object Status -eq 'PASS').Count
    $Failed = @($Results | Where-Object Status -eq 'FAIL').Count
    Write-Host ''
    Write-Host ('=' * 76) -ForegroundColor Cyan
    Write-Host 'SUMMARY OF FINDINGS' -ForegroundColor Cyan
    Write-Host ('-' * 76) -ForegroundColor DarkGray
    Write-Host ('{0,-4} {1,-29} {2,-8} {3}' -f '#', 'Scenario', 'Status', 'Finding')
    foreach ($Item in $Results) {
        $Color = if ($Item.Status -eq 'PASS') { 'Green' } else { 'Red' }
        $Short = switch ($Item.Number) {
            1 { 'Newest 2.0.0 selected' }
            2 { 'Older 1.0.0 selected' }
            3 { '1.0.0 retained (exit 2)' }
            4 { 'Pinned 2.0.0 restored' }
            5 { 'NU1020 on floating restore' }
        }
        if ($Item.Status -ne 'PASS') { $Short = 'See failed scenario above' }
        Write-Host ('{0,-4} {1,-29} {2,-8} {3}' -f $Item.Number, $Item.Scenario, $Item.Status, $Short) -ForegroundColor $Color
    }
    Write-Host ''
    if ($Passed -eq 5 -and $Failed -eq 0) {
        Write-Host 'RESULT: 5 PASSED, 0 FAILED' -ForegroundColor Green
        Write-Host 'Cooldown affects automatic version selection, not exact-version restores.'
        Write-Host 'Floating references fail with NU1020 when cooldown applies.'
        Write-Host 'Package publication age does not establish safety.'
    }
    else {
        Write-Host ('RESULT: {0} PASSED, {1} FAILED (of 5)' -f $Passed, $Failed) -ForegroundColor Red
        Write-Host 'Review failed scenarios and logs before interpreting the findings.'
        if ($null -ne $PreparationError) {
            Write-Host ('Preparation failure: {0}' -f $PreparationError) -ForegroundColor Red
        }
    }
}

<#
.SYNOPSIS
Scenario 1: Baseline automatic package selection.
.DESCRIPTION
Add without publication age restrictions; assert reference and assets are 2.0.0.
#>
function Test-AddWithoutCooldown {
    $Baseline = New-Consumer -Name 'add-no-cooldown' -Cooldown $false
    $env:NUGET_PACKAGES = Join-Path $Baseline 'packages'
    $Add = Run-Dotnet -Directory $Baseline -Arguments @('package', 'add', $PackageId, '--project', (Join-Path $Baseline 'Consumer.csproj'))
    $null = Run-Dotnet -Directory $Baseline -Arguments @('restore', (Join-Path $Baseline 'Consumer.csproj'), '--configfile', (Join-Path $Baseline 'nuget.config'), '-p:NuGetAudit=false')
    Assert-Version -Directory $Baseline -Expected '2.0.0'

    return [pscustomobject]@{
        Observed = 'Version 2.0.0 selected and restored'
        ExitCode = $Add.ExitCode
        Finding = 'The latest version is selected without a cooldown.'
    }
}

<#
.SYNOPSIS
Scenario 2: Automatic package selection with cooldown.
.DESCRIPTION
Add with a source cooldown; assert the older 1.0.0 reference and resolved asset.
#>
function Test-AddWithCooldown {
    $Cooled = New-Consumer -Name 'add-cooldown' -Cooldown $true
    $env:NUGET_PACKAGES = Join-Path $Cooled 'packages'
    $Add = Run-Dotnet -Directory $Cooled -Arguments @('package', 'add', $PackageId, '--project', (Join-Path $Cooled 'Consumer.csproj'))
    $null = Run-Dotnet -Directory $Cooled -Arguments @('restore', (Join-Path $Cooled 'Consumer.csproj'), '--configfile', (Join-Path $Cooled 'nuget.config'), '-p:NuGetAudit=false')
    Assert-Version -Directory $Cooled -Expected '1.0.0'

    return [pscustomobject]@{
        Observed = 'Version 1.0.0 selected and restored'
        ExitCode = $Add.ExitCode
        Finding = 'Cooldown defers the recent version during package add.'
    }
}

<#
.SYNOPSIS
Scenario 3: Package update with cooldown.
.DESCRIPTION
Attempt update from 1.0.0. Verify it remains pinned and exit code 2 means no eligible update.
#>
function Test-UpdateWithCooldown {
    $Updating = New-Consumer -Name 'update-cooldown' -Cooldown $true -Reference '1.0.0'
    $env:NUGET_PACKAGES = Join-Path $Updating 'packages'
    $UpdateProject = Join-Path $Updating 'Consumer.csproj'
    $null = Run-Dotnet -Directory $Updating -Arguments @('restore', $UpdateProject, '-p:NuGetAudit=false')
    $Update = Run-Dotnet -Directory $Updating -Arguments @('package', 'update', $PackageId, '--project', $UpdateProject) -Allowed @(2)
    Assert-Version -Directory $Updating -Expected '1.0.0'
    if ($Update.Output -notmatch 'minimum publish age') { throw 'Update output did not explain the cooldown.' }

    return [pscustomobject]@{
        Observed = 'Version 1.0.0 retained'
        ExitCode = $Update.ExitCode
        Finding = 'Update keeps 1.0.0; exit 2 means no eligible update.'
    }
}

<#
.SYNOPSIS
Scenario 4: Explicit version restores during cooldown.
.DESCRIPTION
Restore exact [2.0.0] and assert recent version exists in the assets file.
#>
function Test-ExplicitRestore {
    $Pinned = New-Consumer -Name 'explicit-restore' -Cooldown $true -Reference '[2.0.0]'
    $env:NUGET_PACKAGES = Join-Path $Pinned 'packages'
    $PinnedRestore = Run-Dotnet -Directory $Pinned -Arguments @('restore', (Join-Path $Pinned 'Consumer.csproj'), '-p:NuGetAudit=false')
    $PinnedAssets = Get-Content -LiteralPath (Join-Path $Pinned 'obj/project.assets.json') -Raw | ConvertFrom-Json
    if ('Cooldown.Sample/2.0.0' -notin @($PinnedAssets.libraries.PSObject.Properties.Name)) { throw 'Pinned 2.0.0 not restored.' }

    return [pscustomobject]@{
        Observed = 'Recent version 2.0.0 restored'
        ExitCode = $PinnedRestore.ExitCode
        Finding = 'Explicit pinned restore is not age-gated.'
    }
}

<#
.SYNOPSIS
Scenario 5: Floating version restore with cooldown.
.DESCRIPTION
Restore a floating 2.* reference and verify NU1020 with exit code 1.
#>
function Test-FloatingRestore {
    $Floating = New-Consumer -Name 'floating-restore' -Cooldown $true -Reference '2.*'
    $env:NUGET_PACKAGES = Join-Path $Floating 'packages'
    $FloatRestore = Run-Dotnet -Directory $Floating -Arguments @('restore', (Join-Path $Floating 'Consumer.csproj'), '-p:NuGetAudit=false') -Allowed @(1)
    if ($FloatRestore.Output -notmatch 'NU1020') { throw 'Expected NU1020 was not present.' }
    return [pscustomobject]@{
        Observed = 'NU1020; restore intentionally rejected'
        ExitCode = $FloatRestore.ExitCode
        Finding = 'Floating versions are rejected with NU1020.'
    }
}

<#
.SYNOPSIS
Builds local test packages and assigns deterministic simulated publication ages.
#>
function Initialize-TestFeed {
    New-Item -ItemType Directory -Path $Feed -Force | Out-Null
    $Source = Join-Path $Run 'source'
    $null = Run-Dotnet -Directory $Run -Arguments @('new', 'classlib', '--name', $PackageId, '--framework', 'net11.0', '--output', $Source, '--no-restore')
    $Project = Join-Path $Source 'Cooldown.Sample.csproj'
    $null = Run-Dotnet -Directory $Run -Arguments @('restore', $Project, '--source', $Feed, '--packages', (Join-Path $Run 'packages-source'), '-p:NuGetAudit=false')
    foreach ($Version in @('1.0.0', '2.0.0')) {
        $null = Run-Dotnet -Directory $Run -Arguments @('pack', $Project, '--configuration', 'Release', '--no-restore', '--output', $Feed, ('-p:PackageVersion={0}' -f $Version))
    }
    $Old = Join-Path $Feed 'Cooldown.Sample.1.0.0.nupkg'
    $Recent = Join-Path $Feed 'Cooldown.Sample.2.0.0.nupkg'
    $Now = [DateTime]::UtcNow
    [IO.File]::SetLastWriteTimeUtc($Old, $Now.AddHours(-($CooldownHours + 24)))
    [IO.File]::SetLastWriteTimeUtc($Recent, $Now)

}

Write-Host 'NuGet Publication Cooldown | Controlled POC' -ForegroundColor Cyan
Write-Host ('=' * 76) -ForegroundColor Cyan
$PreviousAot = $env:DOTNET_CLI_ENABLEAOT
$PreviousPackages = $env:NUGET_PACKAGES
$PreviousTelemetry = $env:DOTNET_CLI_TELEMETRY_OPTOUT
try {
    $env:DOTNET_CLI_ENABLEAOT = 'false'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    New-Item -ItemType Directory -Path $Logs -Force | Out-Null
    if (-not (Test-Path -LiteralPath $DotnetPath -PathType Leaf)) { throw ('SDK not found: {0}' -f $DotnetPath) }
    $env:DOTNET_CLI_ENABLEAOT = 'false'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $SdkVersion = (Run-Dotnet -Arguments @('--version') -Directory $PSScriptRoot).Output
    if ($SdkVersion -notmatch '^11\.') { throw ('Expected a .NET 11 SDK, got {0}' -f $SdkVersion) }
    $Help = Run-Dotnet -Arguments @('nuget', 'add', 'source', '--help') -Directory $PSScriptRoot
    if ($Help.Output -notmatch 'min-publish-age-hours') { throw 'NuGet cooldown option not found.' }
    $UpdateHelp = Run-Dotnet -Arguments @('package', 'update', '--help') -Directory $PSScriptRoot
    if ($UpdateHelp.Output -notmatch 'Update referenced packages') { throw 'NuGet package update command not found.' }


    Write-Host ('SDK       : {0}' -f $SdkVersion)
    Write-Host ('Cooldown  : {0} hours' -f $CooldownHours)
    Write-Host 'Feed      : Disposable local NuGet feed'
    Write-Host ('Versions  : 1.0.0 ({0}h old); 2.0.0 (new)' -f ($CooldownHours + 24))
    Write-Host ''
    Write-Host 'Preparing local test packages...' -ForegroundColor Cyan
    Initialize-TestFeed
    Write-Host 'Packages ready.' -ForegroundColor Green

    Invoke-Scenario -Number 1 -Title 'Add without cooldown' -Purpose 'Does NuGet choose the newest version with no cooldown?' -Cooldown 'Off' -Expected '2.0.0 selected and restored' -Action { Test-AddWithoutCooldown }
    Invoke-Scenario -Number 2 -Title 'Add with cooldown' -Purpose 'Does package add defer a newly published version?' -Cooldown ('{0}h' -f $CooldownHours) -Expected '1.0.0 selected and restored' -Action { Test-AddWithCooldown }
    Invoke-Scenario -Number 3 -Title 'Update with cooldown' -Purpose 'Does package update defer version 2.0.0?' -Cooldown ('{0}h' -f $CooldownHours) -Expected 'Keep 1.0.0, exit code 2' -Action { Test-UpdateWithCooldown }
    Invoke-Scenario -Number 4 -Title 'Explicit-version restore' -Purpose 'Can an exact recent version be restored anyway?' -Cooldown ('{0}h' -f $CooldownHours) -Expected 'Pinned 2.0.0 restores' -Action { Test-ExplicitRestore }
    Invoke-Scenario -Number 5 -Title 'Floating-version restore' -Purpose 'What happens when a floating version meets a cooldown?' -Cooldown ('{0}h' -f $CooldownHours) -Expected 'NU1020; exit code 1' -Action { Test-FloatingRestore }
}
catch {
    $PreparationError = $_.Exception.Message
    Write-Host ('PREPARATION FAILED: {0}' -f $PreparationError) -ForegroundColor Red
}
finally {
    Show-Summary
    if (Test-Path -LiteralPath $Run) {
        $PassCount = @($Results | Where-Object Status -eq 'PASS').Count
        [pscustomobject]@{
            Sdk = $SdkVersion
            CooldownHours = $CooldownHours
            Status = if ($null -eq $PreparationError -and $PassCount -eq 5) { 'PASS' } else { 'FAIL' }
            StartedAtUtc = $StartedAtUtc.ToString('o')
            FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
            RunDirectory = $Run
            Tests = @($Results.ToArray())
            PreparationError = $PreparationError
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'results.json') -Encoding utf8
        Write-Host ''
        Write-Host ('Results  : {0}' -f (Join-Path $Run 'results.json'))
        Write-Host ('Logs     : {0}' -f $Logs)
        Write-Host ('Workspace: {0}' -f $Run)
        Write-Host 'Use -Detailed to show full dotnet command output.'
    }
    $env:DOTNET_CLI_ENABLEAOT = $PreviousAot
    $env:NUGET_PACKAGES = $PreviousPackages
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = $PreviousTelemetry
}
if ($null -ne $PreparationError -or @($Results | Where-Object Status -eq 'FAIL').Count -gt 0) {
    throw 'One or more experiments failed; review the report and command logs.'
}
