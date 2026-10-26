#!/bin/zsh
# Reports the TCC grants of the app that runs this shell (Claude.app or Terminal.app).
# Read-only: never changes a setting. Use it before mix-prep runs and after revoking.
python3 -I -c '
import ctypes
ax = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
cg = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
for lib, fn in ((ax, "AXIsProcessTrusted"), (cg, "CGPreflightPostEventAccess"), (cg, "CGPreflightScreenCaptureAccess")):
    f = getattr(lib, fn); f.restype = ctypes.c_bool
    print(f"{fn:32} {f()}")
'
if osascript -e 'tell application "Logic Pro" to get name of documents' >/dev/null 2>&1; then
  echo "Automation -> Logic Pro          True"
else
  echo "Automation -> Logic Pro          False"
fi
