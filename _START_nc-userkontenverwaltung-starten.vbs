Option Explicit

Dim shell, fso, scriptDir, ps1Path, command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = fso.BuildPath(scriptDir, "nc-userkontenverwaltung.ps1")

If Not fso.FileExists(ps1Path) Then
    MsgBox "Die PowerShell-Datei wurde nicht gefunden:" & vbCrLf & vbCrLf & ps1Path, _
           vbCritical, "Nextcloud Benutzerverwaltung"
    WScript.Quit 1
End If

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
          Chr(34) & ps1Path & Chr(34)

shell.Run command, 0, False
