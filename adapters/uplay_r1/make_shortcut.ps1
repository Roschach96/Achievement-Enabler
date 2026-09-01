# adapters\uplay_r1\make_shortcut.ps1
# Creates a desktop shortcut pointing directly at the selected game exe.
# Uses the native IShellLink COM interface via C# to fully support Unicode paths.
#
# Reads env vars set by AchievementEnabler.bat:
#   AE_EXE_PATH    - full absolute path to the selected game executable
#   AE_GAME_NAME   - folder name, used as the shortcut label

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace AchievementEnablerUplayR1 {

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class ShellLink {}

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile,
                     int cchMaxPath, IntPtr pfd, uint fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName,
                            int cchMaxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir,
                                 int cchMaxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs,
                          int cchMaxPath);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath,
                             int cchIconPath, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel,
                             uint dwReserved);
        void Resolve(IntPtr hwnd, uint fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    [ComImport, Guid("0000010C-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPersist {
        void GetClassID(out Guid pClassID);
    }

    [ComImport, Guid("0000010B-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPersistFile : IPersist {
        new void GetClassID(out Guid pClassID);
        void IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName,
                  [MarshalAs(UnmanagedType.Bool)] bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }

    public static class ShortcutHelper {
        public static bool Create(string lnkPath, string target, string workDir,
                                  string iconPath, int iconIndex) {
            var link = (IShellLinkW) new ShellLink();
            link.SetPath(target);
            link.SetWorkingDirectory(workDir);
            link.SetIconLocation(iconPath, iconIndex);
            var pf = (IPersistFile) link;
            pf.Save(lnkPath, true);

            var check = (IShellLinkW) new ShellLink();
            var cpf   = (IPersistFile) check;
            cpf.Load(lnkPath, 0);
            var sb = new StringBuilder(260);
            check.GetPath(sb, sb.Capacity, IntPtr.Zero, 0);
            return sb.Length > 0;
        }
    }
}
"@

$exePath = $env:AE_EXE_PATH
$work    = Split-Path -Parent $exePath
$desktop = [Environment]::GetFolderPath('Desktop')

$name = $env:AE_GAME_NAME
if ([string]::IsNullOrWhiteSpace($name)) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($exePath)
}

function Try-Shortcut($lnkPath, $shortcutName) {
    try {
        $ok = [AchievementEnablerUplayR1.ShortcutHelper]::Create($lnkPath, $exePath, $work, $exePath, 0)
        if ($ok) {
            Write-Host "Shortcut created: $shortcutName -> $(Split-Path -Leaf $exePath)"
            return $true
        }
    } catch {
        Write-Host "  [warn] $_"
    }
    Remove-Item $lnkPath -ErrorAction SilentlyContinue
    return $false
}

$lnkPath = "$desktop\$name.lnk"
if (-not (Try-Shortcut $lnkPath $name)) {
    $fallbackName = [System.IO.Path]::GetFileNameWithoutExtension($exePath)
    $lnkPath2     = "$desktop\$fallbackName.lnk"
    if (-not (Try-Shortcut $lnkPath2 $fallbackName)) {
        Write-Host 'Failed to create desktop shortcut.'
    }
}
