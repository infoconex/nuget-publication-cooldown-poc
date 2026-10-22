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

The commands above assume the proof of concept has been merged into the default branch. If you are **reviewing pull request #1 before merge**, switch to its branch first:

~~~powershell
git fetch origin feature/reproducible-powershell-poc
git switch feature/reproducible-powershell-poc
~~~

Once merged, no branch switch is needed.

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

## Understanding the experiment

The runner creates a disposable NuGet feed and builds two versions of the same test package, `Cooldown.Sample`. They both target `net11.0` and have no external NuGet package dependencies. To simulate publication age, the runner changes each package file's last-modified timestamp. NuGet uses these timestamps as publication dates when working with a local file feed.

| Version | Simulated publication age with the default 72-hour cooldown | Eligibility during cooldown-aware selection |
| --- | --- | --- |
| `1.0.0` | 96 hours old | Eligible |
| `2.0.0` | Just published | Not yet eligible |

The runner creates fresh consumer projects, separate NuGet package caches and source configurations under a new ignored `artifacts/run-.../` directory. These details matter: we want to observe package selection, not accidentally reuse versions already installed by earlier tests.

When a scenario enables the policy, the disposable `nuget.config` contains a source entry equivalent to:

~~~xml
<packageSources>
  <clear />
  <add key="local"
       value="C:\path\to\generated\feed"
       minPublishAgeHours="72" />
</packageSources>
~~~

The path is illustrative; the runner writes the actual local feed path and selected cooldown automatically. The setting belongs to a **package source**, not to an individual project or a universal restore policy.

The five scenarios intentionally isolate four operations: automatic package addition, automatic package update, exact-version restore, and floating-version restore. Their different outcomes are the point of this POC.

## The five test scenarios

### Scenario 1: Add without cooldown — establish the control

**Question:** When no age restriction applies, which version does NuGet choose if the developer does not specify one?

**Why it matters:** Before attributing any behavior to a cooldown, we need a control case showing that NuGet would normally choose the newly published version. Otherwise a later selection of `1.0.0` might have another explanation, such as package compatibility, an unavailable feed or a stale package cache.

**What the runner does:** Creates a clean consumer project and `nuget.config` pointing only to the test feed, with no `minPublishAgeHours` attribute. It runs an automatic add:

~~~powershell
dotnet package add Cooldown.Sample
~~~

It then independently restores the project and checks both the `PackageReference` and the actual version recorded in `project.assets.json`.

**Verified finding:** `2.0.0` was selected and restored; command exit code `0`. **PASS.**

**Takeaway:** The baseline proves the new version is available and selectable. It gives us a meaningful comparison for Scenario 2. By itself, it says nothing about the safety of the package.

### Scenario 2: Add with cooldown — does selection change?

**Question:** Does a 72-hour source cooldown prevent an automatic add from selecting a version published moments ago?

**Why it matters:** This is the primary protection the feature is intended to offer: slowing the adoption of newly published releases when a developer lets NuGet choose the version.

**What the runner does:** Creates another clean consumer with the **same package feed**, this time configuring `minPublishAgeHours="72"`. It runs the same `dotnet package add Cooldown.Sample` operation, then restores and independently verifies the project reference and dependency assets.

**Verified finding:** NuGet selected `1.0.0`, not `2.0.0`; command exit code `0`. **PASS.**

**Takeaway:** The cooldown affects **automatic package version selection**. It provides a waiting period in which a newly released malicious version might be discovered and removed before a cooldown-aware tool selects it. It does not inspect the package's contents or guarantee that an older package is safe.

### Scenario 3: Update with cooldown — does an existing dependency stay put?

**Question:** Will `dotnet package update` move a project from `1.0.0` to the newly published `2.0.0` while the cooldown applies?

**Why it matters:** Teams frequently upgrade packages after they have already been added. If cooldown only affected initial installation, it would be of little use to an established codebase using assisted package updates.

**What the runner does:** Starts with a project referencing `Cooldown.Sample 1.0.0`, restores it, and invokes:

~~~powershell
dotnet package update Cooldown.Sample
~~~

The test checks that the reference and resolved dependency remain on `1.0.0`, that the command reports the minimum publish age, and that its exit code is `2`.

**Verified finding:** `1.0.0` was retained. NuGet reported that a newer version had not reached the configured minimum publish age and returned exit code `2`. **PASS.**

**Takeaway:** The cooldown also affects this update workflow. NuGet's exit code `2` means **no packages need updating under the current selection criteria**, not an unexpected failure. CI scripts should distinguish that outcome from an actual error. This scenario does **not** test a separate no-cooldown update control; that comparison was performed during the broader manual investigation.

### Scenario 4: Explicit-version restore — can the cooldown be bypassed?

**Question:** If the project explicitly requests the new version, will ordinary restore reject it because it is still inside the cooldown window?

**Why it matters:** A team might assume that putting `minPublishAgeHours` in its repository's `nuget.config` prevents *any* recently published package from entering CI builds. This scenario challenges that assumption.

**What the runner does:** Creates a consumer with a 72-hour cooldown and an exact package reference:

~~~xml
<PackageReference Include="Cooldown.Sample" Version="[2.0.0]" />
~~~

It runs `dotnet restore` and checks the restored dependency recorded in `project.assets.json`.

**Verified finding:** `2.0.0` restored successfully; exit code `0`. **PASS.**

**Takeaway:** A publication cooldown is **not a general restore-time enforcement boundary**. A manually approved or edited exact version can still restore, even if newly published. That can be useful for urgently needed fixes, but it also means dependency review and CI controls remain important. The test verifies an exact version; it does not establish every form of version-range behavior.

### Scenario 5: Floating-version restore — what happens with 2.*?

**Question:** Will restore automatically choose an eligible older version when the project uses a floating version and cooldown is enabled?

**Why it matters:** Some projects use floating references to follow newly available versions automatically. Turning on a cooldown could break an existing build rather than quietly making selection safer.

**What the runner does:** Configures the same 72-hour cooldown with:

~~~xml
<PackageReference Include="Cooldown.Sample" Version="2.*" />
~~~

It invokes `dotnet restore` and asserts both that the command exits with code `1` and that its diagnostic output contains `NU1020`.

**Verified finding:** NuGet rejected the floating reference with `NU1020` and exit code `1`. **PASS** — the restore failure is exactly what this scenario was designed to verify.

**Takeaway:** NuGet does **not** simply pick an older eligible version for a floating reference in this situation. Teams using floating versions should evaluate this compatibility impact before enabling a publication cooldown. The script treats the error as a passing test only because it validates both the error code and message.

## Findings and engineering implications

The October 22, 2026 Windows/PowerShell run with .NET SDK `11.0.100-rc.2.26504.105` reported **5 scenarios passed, 0 failed**.

| Scenario | Observed result | What it demonstrates |
| --- | --- | --- |
| Add without cooldown | `2.0.0` selected | Normal selection can use the recent version |
| Add with cooldown | `1.0.0` selected | Automatic add respects the cooldown |
| Update with cooldown | `1.0.0` retained; exit `2` | Automatic update respects the cooldown |
| Explicit-version restore | `2.0.0` restored | Ordinary exact-version restore is not age-gated |
| Floating-version restore | `NU1020`; exit `1` | Floating references are rejected with cooldown enabled |

**The central result:** A publication cooldown helps delay *certain automated version selections*. It is not a guarantee that every restored package has passed an age check.

For a development team, that suggests three practical considerations:

1. **Match the policy to the update workflow.** The benefit is greatest when routine package additions and updates actually use tools that honor the cooldown. A CI pipeline that only restores committed exact versions will not obtain an age-based restore gate from this setting.
2. **Plan how to handle urgent security fixes.** Delaying a newly released patch can increase exposure to a known vulnerability. A deliberate, reviewed exact-version update can still be restored during the cooldown period.
3. **Use other supply-chain controls too.** Vulnerability auditing, source mapping, package signing/trust policies, code review and reproducible dependency resolution address risks that waiting alone cannot solve.

Our broader manual investigation additionally tested package exceptions, configuration precedence, transitive dependency behavior, locked restores and differences between .NET 10 and .NET 11. **Those are not automated in this five-scenario script.** In particular, the transitive test used an artificially backdated parent package; it should not be presented as evidence that a realistic, recently published malicious parent package would escape the cooldown during automatic selection.

Publication age creates time for detection; it **does not establish trust**. The tests also do not determine whether 24, 48 or 72 hours is the optimal duration for a particular organization.

The runner uses `DOTNET_CLI_ENABLEAOT=false` only inside its PowerShell process to access the managed `dotnet package update` command in this RC2 SDK. It restores previous environment values when finished.


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
