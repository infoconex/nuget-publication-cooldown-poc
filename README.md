# NuGet Publication Cooldown — Reproducible Proof of Concept

A small, reproducible Windows/PowerShell experiment for the `minPublishAgeHours` feature introduced in .NET 11 RC2. It demonstrates where package publication cooldowns affect automatic version selection and where they **do not** prevent a package from being restored.

This project supports the investigation for [coding.infoconex.com](https://coding.infoconex.com) and the proposed article **“Too Hot to Handle? Testing NuGet's New Package Cooldown.”**

## Prerequisites

- Windows and **PowerShell 7**.
- Internet access to install the tool and SDK and clone the repository; the cooldown experiments themselves use only a local feed.
- Git for the clone instructions below.
- No administrator access or existing system-wide .NET SDK required.

## Getting started

The supported setup uses [Isolated .NET SDK](https://github.com/infoconex/isolated-dotnet-sdk), which installs SDKs under your own `$HOME/dotnet-sdks` directory without modifying the machine-wide SDK installation or PATH.

### 1. Install Isolated .NET SDK

In **PowerShell 7**, run the project's official stable bootstrap:

~~~powershell
irm https://infoconex.github.io/isolated-dotnet-sdk/install.ps1 | iex
~~~

This bootstrap downloads and checks the published tool release; as with any piped bootstrap, you must trust the HTTPS-delivered entry point. For installation alternatives and security details, see the [Windows getting-started instructions](https://github.com/infoconex/isolated-dotnet-sdk/blob/main/docs/getting-started/windows-powershell.md).

Verify that the tool was installed:

~~~powershell
& "$HOME/dotnet-sdks/isolated-dotnet-sdk.ps1" -Version
~~~

### 2. Install and verify .NET 11 RC2

The experiments were validated manually using the exact SDK version `11.0.100-rc.2.26504.105`.

~~~powershell
$SdkVersion = '11.0.100-rc.2.26504.105'

& "$HOME/dotnet-sdks/isolated-dotnet-sdk.ps1" `
    -Action Install `
    -SdkVersion $SdkVersion

& "$HOME/dotnet-sdks/isolated-dotnet-sdk.ps1" `
    -Action Verify `
    -SdkVersion $SdkVersion

& "$HOME/dotnet-sdks/$SdkVersion/dotnet.exe" --version
~~~

The last command should print `11.0.100-rc.2.26504.105`. No system-wide installation or PATH modification is needed.

### 3. Clone this repository

Choose a disposable working directory, then run:

~~~powershell
git clone https://github.com/infoconex/nuget-publication-cooldown-poc.git
cd nuget-publication-cooldown-poc
~~~

While this project is still in review, use the draft pull-request branch:

~~~powershell
git fetch origin feature/reproducible-powershell-poc
git switch feature/reproducible-powershell-poc
~~~

Once the tested change is merged, the default branch will contain the runner.

### 4. Run the five test scenarios

~~~powershell
./Test-NuGetCooldown.ps1
~~~

The runner automatically uses the isolated SDK version from step 2. To choose a different supported SDK path or cooldown duration:

~~~powershell
./Test-NuGetCooldown.ps1 `
    -DotnetPath "$HOME/dotnet-sdks/11.0.100-rc.2.26504.105/dotnet.exe" `
    -CooldownHours 48
~~~

The normal console report displays a title and purpose for each scenario, relevant settings, expected and observed outcomes, and PASS/FAIL. A blank line separates the scenario reports.

### Example console report

Illustrative excerpt; results depend on an actual run:

~~~text
NuGet Publication Cooldown | Controlled POC
============================================================================
SDK       : 11.0.100-rc.2.26504.105
Cooldown  : 72 hours
Feed      : Disposable local NuGet feed
Versions  : 1.0.0 (96h old); 2.0.0 (new)

Preparing local test packages...
Packages ready.

============================================================================
SCENARIO 2/5: Add with cooldown
----------------------------------------------------------------------------
Evaluates : Does package add defer a newly published version?
Package   : Cooldown.Sample
Cooldown  : 72h
Expected  : 1.0.0 selected and restored
Observed  : Version 1.0.0 selected and restored
Exit code : 0
Result    : PASS
Finding   : Cooldown defers the recent version during package add.

============================================================================
SUMMARY OF FINDINGS
----------------------------------------------------------------------------
#    Scenario                      Status   Finding
1    Add without cooldown          PASS     Newest 2.0.0 selected
2    Add with cooldown             PASS     Older 1.0.0 selected
3    Update with cooldown          PASS     1.0.0 retained (exit 2)
4    Explicit-version restore      PASS     Pinned 2.0.0 restored
5    Floating-version restore      PASS     NU1020 on floating restore

RESULT: 5 PASSED, 0 FAILED
~~~

### Detailed diagnostic output

To also display the full `dotnet` command output as each test runs:

~~~powershell
./Test-NuGetCooldown.ps1 -Detailed
~~~

Full output for **every** command is always saved in numbered files under `artifacts/run-.../logs/`, even when `-Detailed` is not specified. A `results.json` file records the test outcomes.

The expected `NU1020` error in scenario 5 is considered **PASS** only when the script confirms the expected diagnostic and exit code `1`. Likewise, exit code `2` from a cooldown-deferred package update means no eligible update, not necessarily a failed test.

The script builds two `Cooldown.Sample` package versions into a local feed. Their file modification timestamps simulate publication ages: `1.0.0` is older than the selected cooldown and `2.0.0` is newly published.

| Experiment | Expected result |
| --- | --- |
| Automatic add without cooldown | `2.0.0` selected |
| Automatic add with cooldown | `1.0.0` selected |
| Update from `1.0.0` with cooldown | Stays on `1.0.0`, exit code `2` (nothing eligible to update) |
| Restore explicit `[2.0.0]` with cooldown | `2.0.0` restored |
| Restore floating `2.*` with cooldown | Restore fails with `NU1020` |

Each test checks both the command result and the actual project or restore state. Unexpected behavior causes a failed script run.

The script sets `DOTNET_CLI_ENABLEAOT=false` only within its PowerShell process to expose the .NET 11 RC2 managed `dotnet package update` command. Process environment settings are restored afterward.

## Output and cleanup

Each run creates a new directory under `artifacts/run-<timestamp>-<id>/` with disposable projects, package files, individual NuGet caches, numbered command logs in `logs/`, and `results.json`. The `artifacts` directory is gitignored. Existing runs are never overwritten.

To delete the generated files, from the repository root:

```powershell
Remove-Item -LiteralPath (Join-Path (Get-Location).Path 'artifacts') -Recurse -Force
```

Inspect the directory before deleting if you want to keep any results. The script does not alter machine-level NuGet configuration, PATH, or SDK installations. The .NET CLI can still create per-user first-run state; an isolated SDK is not a security sandbox.

## Scope and limitations

This proves behavior using **simulated local-feed package timestamps**. It does not test the NuGet.org registration API, package maliciousness, missing publication metadata on remote feeds, or the security effectiveness of any particular cooldown duration.

Our broader manual investigation also covered transitive dependencies, configuration inheritance, exceptions, floating versions, locked restores, and differences between .NET 10 and .NET 11. Those cases are deliberately excluded from the five-test runner to keep it small.

A cooldown delays certain **version-selection operations**; it is **not** an enforcement gate for all package restores. Package age does not establish package safety.

## References

- [NuGet Package Update Cooldown V1 specification](https://github.com/NuGet/Home/blob/dev/accepted/2026/package-update-cooldown.md)
- [.NET 11 RC2 NuGet release notes](https://github.com/dotnet/core/blob/main/release-notes/11.0/preview/rc2/nuget.md)
- [Microsoft dotnet package update documentation](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-package-update)
