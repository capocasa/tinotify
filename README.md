# tinotify

Tiny cross-platform desktop notification library for Nim. Calls each
platform's native notification API directly — no helper binaries, no
external processes, no binary bloat.

## Usage

```nim
import tinotify

notify("MyApp", "Title", "Body text")
```

`notify(appName, title, body)` is the entire public surface. It is
always safe to call: if the platform service is unavailable it
silently no-ops.

## Backends

| Platform | Native API | How it's reached |
|----------|-----------|------------------|
| Linux    | D-Bus `org.freedesktop.Notifications` | libdbus via lazy `dynlib` (dlopen) — the exact API `notify-send` wraps |
| macOS    | `NSUserNotificationCenter` | `osascript` `display notification` (the native scripting path) |
| Windows  | `Shell_NotifyIcon` balloon (Action Center) | `shell32.dll` via `dynlib` (already loaded) |

### Design notes

- **No link-time dependencies.** Every backend uses `dynlib` pragmas,
  so libraries (`libdbus-1.so`, `shell32.dll`) load lazily at first
  call. `ldd` shows no hard dep; the binary weight is unchanged.
- **No shell-outs.** Linux talks D-Bus directly; Windows calls Win32
  directly. macOS uses `osascript`, which is the native AppleScript
  path into `NSUserNotificationCenter` (not a shell-out to a
  third-party tool).
- **Silent failure.** Notifications are best-effort. A missing daemon,
  DND mode, or unavailable bus never raises.

### macOS limitations

`NSUserNotificationCenter` (the API `display notification` uses) does
not support custom icons, click handlers, or bypassing Focus/DND.
Lifting those requires the modern `UNUserNotificationCenter`, which
demands entitlements and a permission prompt — out of scope for a
zero-dependency library.

## License

MIT
