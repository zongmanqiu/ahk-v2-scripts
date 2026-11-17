#Requires AutoHotkey v2.0
; 测试辅助：以不含 FILE_SHARE_DELETE 的方式持有文件，制造真实占用。
; 由 test/run.py 启动，测试结束即 terminate。不构成官方脚本出货件。
p := A_Args.Length ? A_Args[1] : A_Temp "\ahkdeck_unlock_test_target.txt"
h := DllCall("kernel32\CreateFileW", "Str", p, "UInt", 0x40000000
    , "UInt", 0x1 | 0x2, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
out := A_ScriptDir "\holder-out.txt"
try FileDelete(out)
FileAppend("holder pid=" DllCall("kernel32\GetCurrentProcessId", "UInt") " handle=" h "`n", out)
Sleep 20000
DllCall("kernel32\CloseHandle", "Ptr", h)
