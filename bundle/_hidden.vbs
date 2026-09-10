' _hidden.vbs <script.ps1> [args...]
'
' Runs a PowerShell script with no window at all. wscript.exe is a GUI-subsystem
' host, so nothing flashes and no console lingers after the emulator launches.
' _run.cmd routes every PowerShell helper through here.
Option Explicit
Dim sh, cmd, i, a
Set sh = CreateObject("WScript.Shell")
cmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & WScript.Arguments(0) & """"
For i = 1 To WScript.Arguments.Count - 1
    a = WScript.Arguments(i)
    If Left(a, 1) = "-" Then
        cmd = cmd & " " & a
    Else
        cmd = cmd & " """ & a & """"
    End If
Next
sh.Run cmd, 0, True
