Option Explicit
Dim shell, fso, root, trayScript, setupScript, localConfig, command, setupResult
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
trayScript = fso.BuildPath(root, "scripts\tray-launcher.ps1")
setupScript = fso.BuildPath(root, "scripts\configure-llama.ps1")
localConfig = fso.BuildPath(root, "config\local.psd1")

If Not fso.FileExists(localConfig) Then
    command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File """ & setupScript & """ -FirstRun"
    setupResult = shell.Run(command, 1, True)
    If setupResult <> 0 Then WScript.Quit setupResult
End If

command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & trayScript & """"
shell.Run command, 0, False
