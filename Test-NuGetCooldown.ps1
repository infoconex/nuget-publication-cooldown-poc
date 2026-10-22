#Requires -Version 7
[CmdletBinding()]
param(
    [string]$DotnetPath = (Join-Path $HOME 'dotnet-sdks/11.0.100-rc.2.26504.105/dotnet.exe'),
    [ValidateRange(1, 8760)][int]$CooldownHours = 72
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

function Run-Dotnet {
    param([string[]]$Arguments, [string]$Directory, [int[]]$Allowed = @(0))
    Push-Location -LiteralPath $Directory
    try {
        $OutputLines = @(& $DotnetPath @Arguments 2>&1)
        $ExitCode = $LASTEXITCODE
    }
    finally { Pop-Location }
    $Text = ($OutputLines | Out-String).Trim()
    if ($Text) { Write-Host $Text }
    if ($Allowed -notcontains $ExitCode) {
        throw ('dotnet {0} returned {1}; expected {2}' -f ($Arguments -join ' '), $ExitCode, ($Allowed -join ', '))
    }
    return [pscustomobject]@{ ExitCode = $ExitCode; Output = $Text }
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

function Pass {
    param([string]$Name, [string]$Observation, [int]$ExitCode)
    $Results.Add([pscustomobject]@{ Test = $Name; Status = 'PASS'; Observation = $Observation; ExitCode = $ExitCode })
    Write-Host ('PASS: {0} - {1}' -f $Name, $Observation) -ForegroundColor Green
}

$PreviousAot = $env:DOTNET_CLI_ENABLEAOT
$PreviousPackages = $env:NUGET_PACKAGES
$PreviousTelemetry = $env:DOTNET_CLI_TELEMETRY_OPTOUT
try {
    if (-not (Test-Path -LiteralPath $DotnetPath -PathType Leaf)) { throw ('SDK not found: {0}' -f $DotnetPath) }
    $env:DOTNET_CLI_ENABLEAOT = 'false'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $SdkVersion = (Run-Dotnet -Arguments @('--version') -Directory $PSScriptRoot).Output
    if ($SdkVersion -notmatch '^11\.') { throw ('Expected a .NET 11 SDK, got {0}' -f $SdkVersion) }
    $Help = Run-Dotnet -Arguments @('nuget', 'add', 'source', '--help') -Directory $PSScriptRoot
    if ($Help.Output -notmatch 'min-publish-age-hours') { throw 'NuGet cooldown option not found.' }
    $UpdateHelp = Run-Dotnet -Arguments @('package', 'update', '--help') -Directory $PSScriptRoot
    if ($UpdateHelp.Output -notmatch 'Update referenced packages') { throw 'NuGet package update command not found.' }

    New-Item -ItemType Directory -Path $Feed -Force | Out-Null
    Write-Host ('Workspace: {0}' -f $Run)
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

    $Baseline = New-Consumer -Name 'add-no-cooldown' -Cooldown $false
    $env:NUGET_PACKAGES = Join-Path $Baseline 'packages'
    $Add = Run-Dotnet -Directory $Baseline -Arguments @('package', 'add', $PackageId, '--project', (Join-Path $Baseline 'Consumer.csproj'))
    Assert-Version -Directory $Baseline -Expected '2.0.0'
    Pass -Name 'Add without cooldown' -Observation '2.0.0 selected' -ExitCode $Add.ExitCode

    $Cooled = New-Consumer -Name 'add-cooldown' -Cooldown $true
    $env:NUGET_PACKAGES = Join-Path $Cooled 'packages'
    $Add = Run-Dotnet -Directory $Cooled -Arguments @('package', 'add', $PackageId, '--project', (Join-Path $Cooled 'Consumer.csproj'))
    Assert-Version -Directory $Cooled -Expected '1.0.0'
    Pass -Name 'Add with cooldown' -Observation '1.0.0 selected' -ExitCode $Add.ExitCode

    $Updating = New-Consumer -Name 'update-cooldown' -Cooldown $true -Reference '1.0.0'
    $env:NUGET_PACKAGES = Join-Path $Updating 'packages'
    $UpdateProject = Join-Path $Updating 'Consumer.csproj'
    $null = Run-Dotnet -Directory $Updating -Arguments @('restore', $UpdateProject, '-p:NuGetAudit=false')
    $Update = Run-Dotnet -Directory $Updating -Arguments @('package', 'update', $PackageId, '--project', $UpdateProject) -Allowed @(2)
    Assert-Version -Directory $Updating -Expected '1.0.0'
    if ($Update.Output -notmatch 'minimum publish age') { throw 'Update output did not explain the cooldown.' }
    Pass -Name 'Update with cooldown' -Observation '1.0.0 retained; exit 2' -ExitCode $Update.ExitCode

    $Pinned = New-Consumer -Name 'explicit-restore' -Cooldown $true -Reference '[2.0.0]'
    $env:NUGET_PACKAGES = Join-Path $Pinned 'packages'
    $PinnedRestore = Run-Dotnet -Directory $Pinned -Arguments @('restore', (Join-Path $Pinned 'Consumer.csproj'), '-p:NuGetAudit=false')
    $PinnedAssets = Get-Content -LiteralPath (Join-Path $Pinned 'obj/project.assets.json') -Raw | ConvertFrom-Json
    if ('Cooldown.Sample/2.0.0' -notin @($PinnedAssets.libraries.PSObject.Properties.Name)) { throw 'Pinned 2.0.0 not restored.' }
    Pass -Name 'Explicit restore' -Observation '2.0.0 restored during cooldown' -ExitCode $PinnedRestore.ExitCode

    $Floating = New-Consumer -Name 'floating-restore' -Cooldown $true -Reference '2.*'
    $env:NUGET_PACKAGES = Join-Path $Floating 'packages'
    $FloatRestore = Run-Dotnet -Directory $Floating -Arguments @('restore', (Join-Path $Floating 'Consumer.csproj'), '-p:NuGetAudit=false') -Allowed @(1)
    if ($FloatRestore.Output -notmatch 'NU1020') { throw 'Expected NU1020 was not present.' }
    Pass -Name 'Floating restore' -Observation 'NU1020 as expected' -ExitCode $FloatRestore.ExitCode
    Write-Host ('All {0} checks passed.' -f $Results.Count) -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $Run) {
        [pscustomobject]@{ Sdk = $SdkVersion; CooldownHours = $CooldownHours; RunDirectory = $Run; Tests = @($Results.ToArray()) } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'results.json') -Encoding utf8
        Write-Host ('Saved results to {0}' -f (Join-Path $Run 'results.json'))
    }
    $env:DOTNET_CLI_ENABLEAOT = $PreviousAot
    $env:NUGET_PACKAGES = $PreviousPackages
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = $PreviousTelemetry
}