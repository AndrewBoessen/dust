# Windows Install

Install the Dust daemon and `dustctl` CLI on Windows from prebuilt
release binaries. Releases bundle the Erlang runtime and are fully
self-contained — no additional runtime dependencies are required.

Available artifacts on the
[GitHub Releases](https://github.com/AndrewBoessen/dust/releases) page:

| Component | Artifact                         |
| --------- | -------------------------------- |
| Daemon    | `dust-server-windows-x86_64.zip` |
| CLI       | `dustctl_windows_x86_64.exe`     |

Verify each download against the `SHA256SUMS.txt` included with the
release.

## Daemon

1. Download `dust-server-windows-x86_64.zip` from the releases page
2. Extract the archive to `C:\Program Files\Dust\`
3. Add `C:\Program Files\Dust\bin` to your system `PATH`
4. Open a terminal and run:

```powershell
dust start
```

To install as a Windows service, you need the [WinSW](https://github.com/winsw/winsw)
wrapper. Drop it into `%LOCALAPPDATA%\Dust\` renamed as `dust-service.exe`,
then let `dustctl` handle the rest:

```powershell
# One-time: place the WinSW wrapper where dustctl expects it
New-Item -ItemType Directory -Force -Path "$env:LOCALAPPDATA\Dust" | Out-Null
Copy-Item winsw.exe "$env:LOCALAPPDATA\Dust\dust-service.exe"

# Register and start the service
dustctl daemon install
dustctl daemon start
```

`dustctl daemon install` copies the bundled `dust-service.xml` next to
`dust-service.exe` and calls `dust-service.exe install`. To remove it,
run `dustctl daemon uninstall`.

## CLI (`dustctl`)

1. Download `dustctl_windows_x86_64.exe` from the releases page
2. Rename it to `dustctl.exe` and move it to `C:\Program Files\Dust\bin\`
3. Ensure `C:\Program Files\Dust\bin` is on your system `PATH`

Verify the install:

```powershell
dustctl version
```

---

**Next:** [Getting Started](../getting-started.md) — first-node setup
walkthrough.
