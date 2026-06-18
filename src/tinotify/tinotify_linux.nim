## Linux desktop notification backend.
##
## Fires a notification via the Desktop Notifications Specification: a
## D-Bus method call to `org.freedesktop.Notifications.Notify` at path
## `/org/freedesktop/Notifications`. This is the native API that
## `notify-send` wraps — we call it directly over the session bus.
##
## libdbus is reached via dynamic linking (`libdbus-1.so`); the
## connection/message/iterator structs are opaque buffers to us, we
## only pass their addresses to C. No dbus dev headers are needed at
## compile time, and the binary is not enlarged (dynamic link only).

import std/[strutils]

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

proc dbus_bus_get(bus: cint; err: ptr DbusError): DbusConnection
  {.importc: "dbus_bus_get", dynlib: dbusLib.}
proc dbus_connection_unref(conn: DbusConnection)
  {.importc: "dbus_connection_unref", dynlib: dbusLib.}
proc dbus_connection_send_with_reply_and_block(conn: DbusConnection;
    msg: DbusMessage; timeout: cint; err: ptr DbusError): DbusMessage
  {.importc: "dbus_connection_send_with_reply_and_block", dynlib: dbusLib.}
proc dbus_message_new_method_call(dest, path, iface, aMethod: cstring):
    DbusMessage {.importc: "dbus_message_new_method_call", dynlib: dbusLib.}
proc dbus_message_unref(msg: DbusMessage)
  {.importc: "dbus_message_unref", dynlib: dbusLib.}

proc dbus_message_iter_init_append(msg: DbusMessage; iter: ptr DbusIter): bool
  {.importc: "dbus_message_iter_init_append", dynlib: dbusLib.}
proc dbus_message_iter_open_container(iter: ptr DbusIter;
    typ: cint; containedSig: cstring; sub: ptr DbusIter): bool
  {.importc: "dbus_message_iter_open_container", dynlib: dbusLib.}
proc dbus_message_iter_close_container(iter: ptr DbusIter;
    sub: ptr DbusIter): bool
  {.importc: "dbus_message_iter_close_container", dynlib: dbusLib.}
proc dbus_message_iter_append_basic(iter: ptr DbusIter;
    typ: cint; value: pointer): bool
  {.importc: "dbus_message_iter_append_basic", dynlib: dbusLib.}

proc dbus_error_init(err: ptr DbusError)
  {.importc: "dbus_error_init", dynlib: dbusLib.}
proc dbus_error_free(err: ptr DbusError)
  {.importc: "dbus_error_free", dynlib: dbusLib.}

proc dbus_connection_send(conn: DbusConnection; msg: DbusMessage;
    serial: ptr uint32): bool
  {.importc: "dbus_connection_send", dynlib: dbusLib.}
proc dbus_connection_flush(conn: DbusConnection)
  {.importc: "dbus_connection_flush", dynlib: dbusLib.}

const
  busSession = cint(0)  # DBUS_BUS_SESSION

template toPtr[T](x: var T): pointer = cast[pointer](x.addr)

proc appendStr(iter: ptr DbusIter; s: string) =
  var cs: cstring = s
  discard dbus_message_iter_append_basic(iter, typeString, cs.addr.pointer)

proc appendUint32(iter: ptr DbusIter; v: uint32) =
  var n = v
  discard dbus_message_iter_append_basic(iter, typeUint32, n.addr.pointer)

proc appendVariantStr(iter: ptr DbusIter; s: string) =
  var sub: DbusIter
  discard dbus_message_iter_open_container(iter, typeVariant, "s", sub.addr)
  var cs: cstring = s
  discard dbus_message_iter_append_basic(sub.addr, typeString, cs.addr.pointer)
  discard dbus_message_iter_close_container(iter, sub.addr)

proc notify*(appName, title, body: string) =
  var err: DbusError
  dbus_error_init(err.addr)
  let conn = dbus_bus_get(busSession, err.addr)
  if cast[pointer](conn) == nil: return

  let msg = dbus_message_new_method_call(
    "org.freedesktop.Notifications",
    "/org/freedesktop/Notifications",
    "org.freedesktop.Notifications",
    "Notify")
  if cast[pointer](msg) == nil:
    dbus_connection_unref(conn)
    return

  var root: DbusIter
  discard dbus_message_iter_init_append(msg, root.addr)

  # Notify(app_name:s, replaces_id:u, app_icon:s, summary:s, body:s,
  #        actions:as, hints:a{sv}, timeout:i)
  appendStr(root.addr, appName)
  appendUint32(root.addr, 0'u32)              # replaces_id = 0 (no replace)
  appendStr(root.addr, "")                    # app_icon (empty: let daemon pick)
  appendStr(root.addr, title)
  appendStr(root.addr, body)

  # actions: as -> empty array
  var actArr: DbusIter
  discard dbus_message_iter_open_container(root.addr, typeArray, "s", actArr.addr)
  discard dbus_message_iter_close_container(root.addr, actArr.addr)

  # hints: a{sv} -> empty dict
  var hintsArr: DbusIter
  discard dbus_message_iter_open_container(root.addr, typeArray, "{sv}", hintsArr.addr)
  discard dbus_message_iter_close_container(root.addr, hintsArr.addr)

  # timeout: i (int32) -> -1 means "use the daemon's default expiry"
  var timeout: int32 = -1
  discard dbus_message_iter_append_basic(root.addr, cint('i'.ord), timeout.addr.pointer)

  discard dbus_connection_send_with_reply_and_block(conn, msg, -1, err.addr)
  dbus_message_unref(msg)
  dbus_connection_unref(conn)
