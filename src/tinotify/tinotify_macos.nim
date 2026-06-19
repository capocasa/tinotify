## macOS notification backend.
##
## `osascript`'s `display notification` is the native path: it calls
## `NSUserNotificationCenter` under the hood. Zero dependencies, no
## binary cost, works everywhere. The icon/click/DND limitations are
## inherent to `NSUserNotificationCenter`; direct ObjC interop would
## not lift them without entitlements (the modern `UNUserNotificationCenter`
## needs a permission prompt).
##
## No suitable clean binary or native API exists that lifts those
## limits without significant additional work, so we fall back to the
## native scripting bridge and keep going.

import std/[osproc, strutils]

proc applescriptEscaped(s: string): string =
  result = newStringOfCap(s.len + 4)
  for c in s:
    if c == '"': result.add "\\\""
    elif c == '\\': result.add "\\\\"
    else: result.add c

proc notify*(appName, title, body: string) =
  let script = "display notification \"" & applescriptEscaped(body) &
    "\" with title \"" & applescriptEscaped(title) &
    "\" subtitle \"" & applescriptEscaped(appName) & "\""
  try:
    discard execCmdEx("osascript -e " & "'" & script.replace("'", "'\\''") & "'")
  except CatchableError:
    discard
