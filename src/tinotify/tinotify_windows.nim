## Windows desktop notification backend.
##
## Uses the Win32 `Shell_NotifyIcon` API to show a system-tray
## balloon tip. On Windows 10/11 this surfaces as a toast in Action
## Center. No external process is spawned and no PowerShell is
## required — only `shell32.dll`, `user32.dll`, and `kernel32.dll`,
## all always loaded.
##
## `Shell_NotifyIcon` rejects a balloon whose `hWnd` is NULL, so we
## own a hidden message-only window for the icon's lifetime. Modern
## Windows also needs an `AppUserModelID` set on the process before
## the first toast or the notification is dropped silently; we set a
## stable one once.

import std/[strutils, winlean]

const
  NIM_ADD = 0x00000000'i32
  NIM_MODIFY = 0x00000001'i32
  NIM_DELETE = 0x00000002'i32
  NIF_MESSAGE = 0x00000001'i32
  NIF_ICON = 0x00000002'i32
  NIF_INFO = 0x00000010'i32
  NIIF_INFO = 0x00000001'i32
  HWND_MESSAGE = HANDLE(-3)
  WS_EX_TOOLWINDOW = 0x00000080'i32
  IDI_APPLICATION = 32512
  AppUserModelId = "dev.capocasa.3code"
  WmAppCallback = 0x8000'u32

type
  HWND = HANDLE
  HINSTANCE = HANDLE
  UINT = uint32
  WPARAM = uint
  LPARAM = int
  WNDPROC = proc(hWnd: HWND, msg: UINT, wParam: WPARAM,
                  lParam: LPARAM): int64 {.stdcall.}

  # Subset of NOTIFYICONDATAW (Unicode) covering balloon fields.
  # Field order and sizes match the documented struct; fields after
  # dwInfoFlags (GUID, hBalloonIcon) are omitted since cbSize tells
  # Windows how much is valid, and we don't set them.
  NOTIFYICONDATAW {.pure, final.} = object
    cbSize: DWORD
    hWnd: HWND
    uID: UINT
    uFlags: UINT
    uCallbackMessage: UINT
    hIcon: HANDLE
    szTip: array[64, Utf16Char]
    dwState: DWORD
    dwStateMask: DWORD
    szInfo: array[256, Utf16Char]
    uTimeout: UINT
    szInfoTitle: array[64, Utf16Char]
    dwInfoFlags: DWORD

  WNDCLASSW {.pure, final.} = object
    style: UINT
    lpfnWndProc: WNDPROC
    cbClsExtra: int32
    cbWndExtra: int32
    hInstance: HINSTANCE
    hIcon: HANDLE
    hCursor: HANDLE
    hbrBackground: HANDLE
    lpszMenuName: ptr Utf16Char
    lpszClassName: ptr Utf16Char

proc Shell_NotifyIconW(dwMessage: DWORD, lpData: ptr NOTIFYICONDATAW): WINBOOL
  {.importc: "Shell_NotifyIconW", dynlib: "shell32.dll", stdcall.}
proc lstrcpyW(dst: WideCString, src: WideCString): WideCString
  {.importc: "lstrcpyW", dynlib: "kernel32.dll", stdcall.}
proc DefWindowProcW(hWnd: HWND, msg: UINT, wParam: WPARAM,
                    lParam: LPARAM): int64
  {.importc: "DefWindowProcW", dynlib: "user32.dll", stdcall.}
proc RegisterClassW(lpWndClass: ptr WNDCLASSW): uint16
  {.importc: "RegisterClassW", dynlib: "user32.dll", stdcall.}
proc CreateWindowExW(dwExStyle: DWORD, lpClassName, lpWindowName: WideCString,
                     dwStyle: DWORD, x, y, nWidth, nHeight: int32,
                     hWndParent: HWND, hMenu: HANDLE, hInstance: HINSTANCE,
                     lpParam: pointer): HWND
  {.importc: "CreateWindowExW", dynlib: "user32.dll", stdcall.}
proc LoadIconW(hInstance: HINSTANCE, lpIconName: ptr Utf16Char): HANDLE
  {.importc: "LoadIconW", dynlib: "user32.dll", stdcall.}
proc GetModuleHandleW(lpModuleName: pointer): HINSTANCE
  {.importc: "GetModuleHandleW", dynlib: "kernel32.dll", stdcall.}
proc SetCurrentProcessExplicitAppUserModelID(appID: WideCString): int32
  {.importc: "SetCurrentProcessExplicitAppUserModelID",
     dynlib: "shell32.dll", stdcall.}
proc sleepWin(ms: DWORD) {.importc: "Sleep", dynlib: "kernel32.dll", stdcall.}

# Set once on first use. Idempotent: Windows keeps the last value.
var aumidSet = false

proc createMessageWindow(): HWND =
  let cls = newWideCString("TinotifyMsgWnd")
  var wc: WNDCLASSW
  zeroMem(wc.addr, sizeof(wc))
  wc.lpfnWndProc = DefWindowProcW
  wc.lpszClassName = cast[ptr Utf16Char](cls[0].unsafeAddr)
  wc.hInstance = GetModuleHandleW(nil)
  discard RegisterClassW(wc.addr)
  result = CreateWindowExW(DWORD(WS_EX_TOOLWINDOW), cls, newWideCString(""),
                           0'i32, 0, 0, 0, 0, HWND_MESSAGE, HANDLE(0),
                           GetModuleHandleW(nil), nil)

proc notify*(appName, title, body: string) =
  if not aumidSet:
    discard SetCurrentProcessExplicitAppUserModelID(
      newWideCString(AppUserModelId))
    aumidSet = true

  let hWnd = createMessageWindow()
  if cast[int](hWnd) == 0:
    return

  var nid: NOTIFYICONDATAW
  zeroMem(nid.addr, sizeof(nid))
  nid.cbSize = DWORD(sizeof(NOTIFYICONDATAW))
  nid.hWnd = hWnd
  nid.uID = 1
  # Add a tray icon first: a balloon without a resident icon (and a
  # NULL hWnd) is rejected by Shell_NotifyIcon on Windows 10/11.
  nid.uFlags = UINT(NIF_MESSAGE or NIF_ICON)
  nid.uCallbackMessage = WmAppCallback
  nid.hIcon = LoadIconW(HINSTANCE(0),
                        cast[ptr Utf16Char](IDI_APPLICATION))
  discard lstrcpyW(cast[WideCString](nid.szTip[0].addr),
                   newWideCString(appName))
  if Shell_NotifyIconW(DWORD(NIM_ADD), nid.addr) == WINBOOL(0):
    return

  nid.uFlags = UINT(NIF_INFO)
  nid.dwInfoFlags = DWORD(NIIF_INFO)
  discard lstrcpyW(cast[WideCString](nid.szInfo[0].addr), newWideCString(body))
  discard lstrcpyW(cast[WideCString](nid.szInfoTitle[0].addr),
                   newWideCString(title))
  discard Shell_NotifyIconW(DWORD(NIM_MODIFY), nid.addr)

  # Give the toast time to surface before the icon is removed.
  sleepWin(2000)
  discard Shell_NotifyIconW(DWORD(NIM_DELETE), nid.addr)
