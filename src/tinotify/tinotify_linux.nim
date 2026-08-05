## Linux desktop notification backend.
##
## Fires a notification via the Desktop Notifications Specification: a
## D-Bus method call to `org.freedesktop.Notifications.Notify` at path
## `/org/freedesktop/Notifications`. This is the native API that
## `notify-send` wraps — we call it directly over the session bus.
##
## libdbus is loaded lazily with `loadLibPattern` on the first `notify`
## call, not via the `dynlib` pragma: the pragma resolves symbols at
## module init (before `main`), which hard-exits the process when
## libdbus is absent (Termux, minimal containers, headless servers).
## Lazy loading keeps the promise that `notify` silently no-ops when
## no notification service exists.

import std/[dynlib, strutils]

const dbusLib* = "libdbus-1.so(.3|.2|)"

# libdbus type codes (dbus-protocol.h); integer constants, not symbols.
const
  typeString = cint('s'.ord)   # DBUS_TYPE_STRING
  typeUint32 = cint('u'.ord)   # DBUS_TYPE_UINT32
  typeArray = cint('a'.ord)    # DBUS_TYPE_ARRAY
  typeVariant = cint('v'.ord)  # DBUS_TYPE_VARIANT

type
  # Opaque handles. libdbus returns these as pointers; we never
  # dereference them in Nim.
  DbusConnection = distinct pointer
  DbusMessage = distinct pointer

  # DBusError is a public struct written by libdbus. Its layout (on
  # every supported platform) is: const char *name; const char *message;
  # unsigned int dummy1..dummy4; dbus_bool_t padding1. 6 pointers' worth
  # of storage is more than enough.
  DbusError = object
    storage: array[6, uint]

  # DBusMessageIter is written into by init_append/open_container. Its
  # real layout is ~16 words; we over-allocate to be safe.
  DbusIter = object
    storage: array[16, uint]

  DbusApi = object
    busGet: proc(bus: cint; err: ptr DbusError): DbusConnection {.cdecl.}
    connectionUnref: proc(conn: DbusConnection) {.cdecl.}
    sendWithReplyAndBlock: proc(conn: DbusConnection; msg: DbusMessage;
        timeout: cint; err: ptr DbusError): DbusMessage {.cdecl.}
    messageNewMethodCall: proc(dest, path, iface, aMethod: cstring):
        DbusMessage {.cdecl.}
    messageUnref: proc(msg: DbusMessage) {.cdecl.}
    iterInitAppend: proc(msg: DbusMessage; iter: ptr DbusIter): bool {.cdecl.}
    iterOpenContainer: proc(iter: ptr DbusIter; typ: cint;
        containedSig: cstring; sub: ptr DbusIter): bool {.cdecl.}
    iterCloseContainer: proc(iter: ptr DbusIter; sub: ptr DbusIter): bool {.cdecl.}
    iterAppendBasic: proc(iter: ptr DbusIter; typ: cint;
        value: pointer): bool {.cdecl.}
    errorInit: proc(err: ptr DbusError) {.cdecl.}

var
  dbus: DbusApi
  dbusLoaded = false

proc loadDbus(): bool =
  ## Resolve libdbus once. Returns false (and `notify` no-ops) when the
  ## library is not installed; the result is cached so repeat calls are
  ## free in both directions.
  if dbusLoaded:
    return dbus.busGet != nil
  dbusLoaded = true
  let lib = loadLibPattern(dbusLib)
  if lib == nil:
    return false
  template sym(field, name: untyped) =
    dbus.field = cast[typeof(dbus.field)](lib.symAddr(name))
    if dbus.field == nil:
      dbus.busGet = nil
      return false
  sym busGet, "dbus_bus_get"
  sym connectionUnref, "dbus_connection_unref"
  sym sendWithReplyAndBlock, "dbus_connection_send_with_reply_and_block"
  sym messageNewMethodCall, "dbus_message_new_method_call"
  sym messageUnref, "dbus_message_unref"
  sym iterInitAppend, "dbus_message_iter_init_append"
  sym iterOpenContainer, "dbus_message_iter_open_container"
  sym iterCloseContainer, "dbus_message_iter_close_container"
  sym iterAppendBasic, "dbus_message_iter_append_basic"
  sym errorInit, "dbus_error_init"
  true

const
  busSession = cint(0)  # DBUS_BUS_SESSION

template toPtr[T](x: var T): pointer = cast[pointer](x.addr)

proc appendStr(iter: ptr DbusIter; s: string) =
  var cs: cstring = s
  discard dbus.iterAppendBasic(iter, typeString, cs.addr.pointer)

proc appendUint32(iter: ptr DbusIter; n: uint32) =
  var v = n
  discard dbus.iterAppendBasic(iter, typeUint32, v.addr.pointer)

proc appendVariantStr(iter: ptr DbusIter; s: string) =
  var sub: DbusIter
  discard dbus.iterOpenContainer(iter, typeVariant, "s", sub.addr)
  var cs: cstring = s
  discard dbus.iterAppendBasic(sub.addr, typeString, cs.addr.pointer)
  discard dbus.iterCloseContainer(iter, sub.addr)

proc notify*(appName, title, body: string) =
  if not loadDbus(): return

  var err: DbusError
  dbus.errorInit(err.addr)
  let conn = dbus.busGet(busSession, err.addr)
  if cast[pointer](conn) == nil: return

  let msg = dbus.messageNewMethodCall(
    "org.freedesktop.Notifications",
    "/org/freedesktop/Notifications",
    "org.freedesktop.Notifications",
    "Notify")
  if cast[pointer](msg) == nil:
    dbus.connectionUnref(conn)
    return

  var root: DbusIter
  discard dbus.iterInitAppend(msg, root.addr)

  # Notify(app_name:s, replaces_id:u, app_icon:s, summary:s, body:s,
  #        actions:as, hints:a{sv}, timeout:i)
  appendStr(root.addr, appName)
  appendUint32(root.addr, 0'u32)              # replaces_id = 0 (no replace)
  appendStr(root.addr, "")                    # app_icon (empty: let daemon pick)
  appendStr(root.addr, title)
  appendStr(root.addr, body)

  # actions: as -> empty array
  var actArr: DbusIter
  discard dbus.iterOpenContainer(root.addr, typeArray, "s", actArr.addr)
  discard dbus.iterCloseContainer(root.addr, actArr.addr)

  # hints: a{sv} -> empty dict
  var hintsArr: DbusIter
  discard dbus.iterOpenContainer(root.addr, typeArray, "{sv}", hintsArr.addr)
  discard dbus.iterCloseContainer(root.addr, hintsArr.addr)

  # timeout: i (int32) -> -1 means "use the daemon's default expiry"
  var timeout: int32 = -1
  discard dbus.iterAppendBasic(root.addr, cint('i'.ord), timeout.addr.pointer)

  discard dbus.sendWithReplyAndBlock(conn, msg, -1, err.addr)
  dbus.messageUnref(msg)
  dbus.connectionUnref(conn)
