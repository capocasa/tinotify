## macOS notification backend.
##
## Modern macOS (11 Big Sur and later) removed `NSUserNotificationCenter`,
## which is what `osascript`'s `display notification` drives under the hood.
## `NSUserNotificationCenter.default` is `nil` there, so the scripting-bridge
## path is a silent no-op: the call returns 0 but no toast ever appears.
## (`UNUserNotificationCenter` is the replacement, but it cannot be reached
## from a bare Foundation tool or via `osascript` — it crashes with
## `UNErrorDomain` outside an app bundle. terminal-notifier ships as an `.app`
## bundle for exactly this reason: radar://11956694.)
##
## So on macOS 11+ we compile a tiny Swift helper once, cache it as an `.app`
## bundle (which gives `UNUserNotificationCenter` the bundle identity it needs
## to not crash), and shell out to it. The helper requests authorization on
## first use (the standard one-time prompt) and then posts via
## `UNUserNotificationCenter`. `swiftc` ships with Xcode Command Line Tools,
## present on any Mac that builds code.
##
## On older macOS (where `NSUserNotificationCenter` still exists) or when
## `swiftc` is unavailable, we fall back to the zero-cost `osascript` path.
## `notify` is always safe to call.

import std/[osproc, strutils, os]

const
  HelperBundleId = "dev.capocasa.tinotify.helper"
  HelperName = "tinotify-notify"

# Swift source for the cached helper app. Posts a banner via
# UNUserNotificationCenter. Must run inside an .app bundle (see above), so we
# synthesize one on first compile. Args: <title> <body> <subtitle>.
const SwiftHelperSrc = """
import Foundation
import AppKit
import UserNotifications

class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        let title = args.count > 1 ? args[1] : "Notification"
        let body = args.count > 2 ? args[2] : ""
        let subtitle = args.count > 3 ? args[3] : ""
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            if !subtitle.isEmpty { c.subtitle = subtitle }
            let req = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: c, trigger: nil)
            center.add(req) { err in
                if let e = err {
                    FileHandle.standardError.write(
                        "tinotify helper: \(e.localizedDescription)\n"
                            .data(using: .utf8)!)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
let app = NSApplication.shared
let d = Delegate()
app.delegate = d
app.run()
"""

proc applescriptEscaped(s: string): string =
  result = newStringOfCap(s.len + 4)
  for c in s:
    if c == '"': result.add "\\\""
    elif c == '\\': result.add "\\\\"
    else: result.add c

proc notifyViaOsascript(appName, title, body: string) =
  let script = "display notification \"" & applescriptEscaped(body) &
    "\" with title \"" & applescriptEscaped(title) &
    "\" subtitle \"" & applescriptEscaped(appName) & "\""
  try:
    discard execCmdEx("osascript -e " & "'" & script.replace("'", "'\\''") & "'")
  except CatchableError:
    discard

proc helperDir*(): string =
  ## Cache dir for the compiled Swift helper. Stable across runs so the
  ## one-time compile is not repeated.
  result = getCacheDir() / "tinotify"
  try: createDir(result)
  except CatchableError: discard

proc helperBinary*(): string =
  helperDir() / HelperName & ".app/Contents/MacOS/" & HelperName

proc ensureSwiftHelper*(): bool =
  ## Compile the Swift helper into a cached `.app` bundle if needed.
  ## Returns true if the helper is ready to run.
  let bin = helperBinary()
  if fileExists(bin):
    return true
  let dir = helperDir()
  let appDir = dir / HelperName & ".app"
  let macosDir = appDir / "Contents/MacOS"
  let srcPath = dir / HelperName & ".swift"
  let plistPath = appDir / "Contents/Info.plist"
  try:
    createDir(macosDir)
    writeFile(srcPath, SwiftHelperSrc)
    writeFile(plistPath,
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
      "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " &
      "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" &
      "<plist version=\"1.0\"><dict>\n" &
      "<key>CFBundleName</key><string>" & HelperName & "</string>\n" &
      "<key>CFBundleIdentifier</key><string>" & HelperBundleId & "</string>\n" &
      "<key>CFBundleVersion</key><string>1</string>\n" &
      "<key>CFBundleExecutable</key><string>" & HelperName & "</string>\n" &
      "<key>LSMinimumSystemVersion</key><string>11.0</string>\n" &
      "</dict></plist>\n")
    # swiftc exits non-zero on failure; capture so a broken toolchain
    # degrades to the osascript fallback instead of raising.
    let rc = execCmdEx("swiftc -O " & quoteShell(srcPath) &
      " -o " & quoteShell(macosDir / HelperName))
    if rc[1] != 0:
      return false
    result = true
  except CatchableError:
    result = false

proc notifyViaSwiftHelper*(title, body, subtitle: string): bool =
  ## Post via the cached Swift helper. Returns false if it could not be built
  ## (no `swiftc`, compile error), so the caller can fall back to osascript.
  if not ensureSwiftHelper():
    return false
  try:
    # Args carry the text; the helper reads them positionally. Shell-quote
    # each so embedded spaces/quotes can't break the command.
    let cmd = helperBinary() & " " & quoteShell(title) & " " &
      quoteShell(body) & " " & quoteShell(subtitle)
    discard execCmdEx(cmd)
    result = true
  except CatchableError:
    result = false

proc notify*(appName, title, body: string) =
  ## On macOS 11+ `NSUserNotificationCenter` (the `osascript` path) is gone,
  ## so we post via the compiled `UNUserNotificationCenter` helper. If the
  ## helper can't be built (no `swiftc`, or an older macOS where the legacy
  ## center still works), we fall back to `osascript`. `notify` is always
  ## safe to call.
  if not notifyViaSwiftHelper(title, body, appName):
    notifyViaOsascript(appName, title, body)
