Option Explicit

Dim shell, fso, root, script, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(root, "app\skin-manager-gui.ps1")
If Not fso.FileExists(script) Then
  MsgBox "Codex Dream Skin 图形界面文件缺失。" & vbCrLf & vbCrLf & _
    "请完整解压整个文件夹后再启动。" & vbCrLf & script, _
    vbCritical, "Codex Dream Skin"
  WScript.Quit 1
End If

command = "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & script & Chr(34)

On Error Resume Next
shell.Run command, 0, False
If Err.Number <> 0 Then
  MsgBox "Codex Dream Skin 图形界面启动失败。" & vbCrLf & vbCrLf & _
    "请尝试双击 Start-CodexDreamSkin.cmd 使用备用菜单。" & vbCrLf & _
    Err.Description, vbCritical, "Codex Dream Skin"
  WScript.Quit 1
End If
On Error GoTo 0

WScript.Quit 0
