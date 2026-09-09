# Windows QA

## Short load test

Connect Yurich Connect, then run:

```powershell
.\windows\qa\load_test_windows.ps1 -DurationSeconds 300 -Concurrency 16
```

## Long-running soak test

The soak test monitors network requests, local proxy availability, Yurich Core
process liveness, memory, handles, and CPU usage.

Ten-minute validation:

```powershell
.\windows\qa\soak_test_windows.ps1 -DurationMinutes 10 -Concurrency 16
```

Overnight validation:

```powershell
.\windows\qa\soak_test_windows.ps1 -DurationMinutes 480 -Concurrency 8
```

Reports are written to:

```text
%APPDATA%\Yurich Connect\diagnostics\soak-report.zip
```

## Release metadata

Validate that every Windows component uses the same version:

```powershell
.\windows\qa\prepare_release_metadata.ps1 -ValidateOnly
```

After `smoke_windows.ps1` builds the artifacts, prepare individual SHA-256 files, `SHA256SUMS.txt`, and release notes with:

```powershell
.\windows\qa\prepare_release_metadata.ps1 -Version 1.0.105
```

GitHub Actions creates a hidden draft, verifies the uploaded asset digests, and only then publishes it. Existing releases are never overwritten; bump the version instead of replacing public binaries.
