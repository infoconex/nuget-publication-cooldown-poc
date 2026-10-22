# NuGet Publication Cooldown — Reproducible Proof of Concept

A small, reproducible Windows/PowerShell experiment for the \`minPublishAgeHours\` feature introduced in .NET 11 RC2. It demonstrates where package publication cooldowns affect automatic version selection and where they **do not** prevent a package from being restored.

This project supports the investigation for [coding.infoconex.com](https://coding.infoconex.com) and the proposed article **“Too Hot to Handle? Testing NuGet's New Package Cooldown.”**

## Prerequisites

- Windows and **PowerShell 7**.
- .NET 11 RC2 SDK version \`11.0.100-rc.2.26504.105\`. Newer .NET 11 SDKs with this NuGet feature may also work, but the observed baseline was RC2.
- No NuGet.org packages, public package publishing, or administrator privileges required.

You can use [infoconex/isolated-dotnet-sdk](https://github.com/infoconex/isolated-dotnet-sdk) to install the SDK without changing your system-wide installation or PATH.

## Run

From the repository root in PowerShell 7:

\`\`\`powershell
./Test-NuGetCooldown.ps1 -DotnetPath "$HOME/dotnet-sdks/11.0.100-rc.2.26504.105/dotnet.exe"
\`\`\`

The script defaults to that isolated SDK location. You can supply a different path using \`-DotnetPath\`, or a different delay using \`-CooldownHours 48\`.

The script builds two \`Cooldown.Sample\` package versions into a local feed. Their file modification timestamps simulate publication ages: \`1.0.0\` is older than the selected cooldown and \`2.0.0\` is newly published.

| Experiment | Expected result |
| --- | --- |
| Automatic add without cooldown | \`2.0.0\` selected |
| Automatic add with cooldown | \`1.0.0\` selected |
| Update from \`1.0.0\` with cooldown | Stays on \`1.0.0\`, exit code \`2\` (nothing eligible to update) |
| Restore explicit \`[2.0.0]\` with cooldown | \`2.0.0\` restored |
| Restore floating \`2.*\` with cooldown | Restore fails with \`NU1020\` |

Each test checks both the command result and the actual project or restore state. Unexpected behavior causes a failed script run.

The script sets \`DOTNET_CLI_ENABLEAOT=false\` only within its PowerShell process to expose the .NET 11 RC2 managed \`dotnet package update\` command. Process environment settings are restored afterward.

## Output and cleanup

Each run creates a new directory under \`artifacts/run-<timestamp>-<id>/\` with disposable projects, package files, individual NuGet caches, and \`results.json\`. The \`artifacts\` directory is gitignored. Existing runs are never overwritten.

To delete the generated files, from the repository root:

\`\`\`powershell
Remove-Item -LiteralPath (Join-Path (Get-Location).Path 'artifacts') -Recurse -Force
\`\`\`

Inspect the directory before deleting if you want to keep any results. The script does not alter machine-level NuGet configuration, PATH, or SDK installations. The .NET CLI can still create per-user first-run state; an isolated SDK is not a security sandbox.

## Scope and limitations

This proves behavior using **simulated local-feed package timestamps**. It does not test the NuGet.org registration API, package maliciousness, missing publication metadata on remote feeds, or the security effectiveness of any particular cooldown duration.

Our broader manual investigation also covered transitive dependencies, configuration inheritance, exceptions, floating versions, locked restores, and differences between .NET 10 and .NET 11. Those cases are deliberately excluded from the five-test runner to keep it small.

A cooldown delays certain **version-selection operations**; it is **not** an enforcement gate for all package restores. Package age does not establish package safety.

## References

- [NuGet Package Update Cooldown V1 specification](https://github.com/NuGet/Home/blob/dev/accepted/2026/package-update-cooldown.md)
- [.NET 11 RC2 NuGet release notes](https://github.com/dotnet/core/blob/main/release-notes/11.0/preview/rc2/nuget.md)
- [Microsoft dotnet package update documentation](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-package-update)
