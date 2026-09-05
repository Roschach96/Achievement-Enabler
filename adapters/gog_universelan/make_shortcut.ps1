# adapters\gog_universelan\make_shortcut.ps1
# Creates a desktop shortcut that launches UniverseLANServer(64).exe and the
# game together, with linked lifetimes: whichever of the two exits first,
# the other is closed too. A plain .lnk can only point at one target, so
# this generates a small launcher script (_ae_gog_launch.ps1) next to the
# game exe and points the shortcut at that instead of the exe directly.
#
# Reads env vars set by AchievementEnabler.bat:
#   AE_EXE_PATH    - full absolute path to the selected game executable
#   AE_GAME_NAME   - folder name, used as the shortcut label
#   AE_DESTINATION - folder containing Galaxy(64).dll and the matching
#                    UniverseLANServer(64).exe (deploy_universelan.ps1
#                    deletes whichever bitness doesn't match the game)

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace AchievementEnablerGog {

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
        public static bool Create(string lnkPath, string target, string args, string workDir,
                                  string iconPath, int iconIndex) {
            var link = (IShellLinkW) new ShellLink();
            link.SetPath(target);
            link.SetArguments(args);
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

$exePath     = $env:AE_EXE_PATH
$work        = Split-Path -Parent $exePath
$desktop     = [Environment]::GetFolderPath('Desktop')
$destination = $env:AE_DESTINATION

$name = $env:AE_GAME_NAME
if ([string]::IsNullOrWhiteSpace($name)) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($exePath)
}

# Find whichever UniverseLANServer(64).exe survived deploy_universelan.ps1's
# bitness cleanup (it deletes the one that doesn't match the game's Galaxy
# dll, so exactly one of these two should exist here).
$serverExe = $null
if ($destination -and (Test-Path -LiteralPath $destination)) {
    foreach ($candidate in @('UniverseLANServer64.exe', 'UniverseLANServer.exe')) {
        $p = Join-Path $destination $candidate
        if (Test-Path -LiteralPath $p) {
            $serverExe = $p
            break
        }
    }
}

$launchTarget = $exePath
$launchArgs   = ''

if ($serverExe) {
    # Generate a small launcher script that starts the server, then the
    # game, and ties their lifetimes together: whichever process exits
    # first, the other is closed too. The shortcut points at this launcher
    # instead of the game exe directly, since a .lnk can only target one
    # executable.
    $launcherPath = Join-Path $work '_ae_gog_launch.ps1'
    $launcherContent = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$serverProc = Start-Process -FilePath '$serverExe' -WorkingDirectory '$destination' -PassThru
Start-Sleep -Milliseconds 100
`$gameProc = Start-Process -FilePath '$exePath' -WorkingDirectory '$work' -PassThru

while ((-not `$serverProc.HasExited) -and (-not `$gameProc.HasExited)) {
    Start-Sleep -Milliseconds 500
}

if (-not `$gameProc.HasExited) { Stop-Process -Id `$gameProc.Id -Force }
if (-not `$serverProc.HasExited) { Stop-Process -Id `$serverProc.Id -Force }
"@
    try {
        [System.IO.File]::WriteAllText($launcherPath, $launcherContent, [System.Text.UTF8Encoding]::new($false))
        Write-Host "[INFO] Launcher script written: $launcherPath"
        $launchTarget = (Get-Command 'powershell.exe').Source
        $launchArgs   = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`""
        Write-Host "[INFO] Shortcut will start $([System.IO.Path]::GetFileName($serverExe)) and the game together, with linked lifetimes."
    } catch {
        Write-Host "[WARN] Could not write launcher script ($_) - shortcut will point at the game exe directly."
        $launchTarget = $exePath
        $launchArgs   = ''
    }
} else {
    Write-Host "[WARN] No UniverseLANServer(64).exe found in $destination - shortcut will point at the game exe directly."
}

function Try-Shortcut($lnkPath, $shortcutName) {
    try {
        $ok = [AchievementEnablerGog.ShortcutHelper]::Create($lnkPath, $launchTarget, $launchArgs, $work, $exePath, 0)
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
