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
