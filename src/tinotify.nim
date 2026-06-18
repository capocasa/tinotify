## Cross-platform desktop notification library.
##
## Provides a single `notify` procedure that fires a native system
## notification on Linux, macOS, and Windows. Each backend is a
## separate module; the correct one is selected at compile time.
##
## The public surface is intentionally tiny:
##
## .. code-block:: nim
##   import tinotify
##   notify("MyApp", "Title", "Body text")
##
## Backends:
##   - Linux: D-Bus `org.freedesktop.Notifications` (the native API
##     `notify-send` wraps), reached via libdbus dynamic linking.
##   - macOS: `osascript` `display notification` (calls
##     `NSUserNotificationCenter` under the hood).
##   - Windows: Win32 `Shell_NotifyIcon` balloon (Action Center),
##     reached via `shell32.dll` dynamic linking.
##
## Each backend talks directly to the platform's native notification
## API — no external helper binaries are spawned (except osascript on
## macOS, which is the native scripting path) — and silently no-ops if
## the service is unavailable, so `notify` is always safe to call.

when defined(windows):
  include tinotify/tinotify_windows
elif defined(macosx) or defined(macos):
  include tinotify/tinotify_macos
elif defined(linux):
  when defined(android) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    {.error: "tinotify: only Linux desktop is supported on this OS family.".}
  else:
    include tinotify/tinotify_linux
else:
  {.error: "tinotify: unsupported platform.".}
