## Windows desktop notification backend.
##
## Uses the Win32 `Shell_NotifyIcon` API to show a system-tray
## balloon tip. On Windows 10/11 this surfaces in Action Center.
## No external process is spawned and no PowerShell is required —
## only `shell32.dll` and `kernel32.dll`, both always loaded.

import std/[strutils, winlean]

const
  NIM_ADD = 0x00000000'i32
  NIM_DELETE = 0x00000002'i32
  NIF_INFO = 0x00000010'i32
  NIIF_INFO = 0x00000001'i32

type
  HWND = HANDLE
  UINT = uint32

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
    hIcon: HANDLE          # HICON
    szTip: array[64, Utf16Char]
    dwState: DWORD
    dwStateMask: DWORD
    szInfo: array[256, Utf16Char]
    uTimeout: UINT         # union with uVersion; both UINT
    szInfoTitle: array[64, Utf16Char]
    dwInfoFlags: DWORD

proc Shell_NotifyIconW(dwMessage: DWORD, lpData: ptr NOTIFYICONDATAW): WINBOOL
  {.importc: "Shell_NotifyIconW", dynlib: "shell32.dll", stdcall.}

proc lstrcpyW(dst: WideCString, src: WideCString): WideCString
  {.importc: "lstrcpyW", dynlib: "kernel32.dll", stdcall.}

proc notify*(appName, title, body: string) =
  var nid: NOTIFYICONDATAW
  zeroMem(nid.addr, sizeof(nid))
  nid.cbSize = DWORD(sizeof(NOTIFYICONDATAW))
  nid.uID = 1
  nid.uFlags = UINT(NIF_INFO)
  nid.dwInfoFlags = DWORD(NIIF_INFO)
  let t = newWideCString(title)
  let b = newWideCString(body)
  discard lstrcpyW(cast[WideCString](nid.szInfo[0].addr), b)
  discard lstrcpyW(cast[WideCString](nid.szInfoTitle[0].addr), t)
  discard Shell_NotifyIconW(DWORD(NIM_ADD), nid.addr)
  discard Shell_NotifyIconW(DWORD(NIM_DELETE), nid.addr)
