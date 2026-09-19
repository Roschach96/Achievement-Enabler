# core\common\watch_and_patch_joker_config.ps1
#
# Shared detached watcher (generalized from ea_origin_emulator's own copy),
# launched hidden by an adapter's modify_joker_json.ps1 so it keeps running
# after that script - and the whole setup run - has already exited.
# Necessary because Jokerverse creates a game's config on its OWN independent
# detection cycle (whenever it next notices no config exists yet for that
# appid), not in response to anything this setup script does. The .json can
# appear well after modify_joker_json.ps1 has finished, so a short
# synchronous wait during setup can never reliably catch it.
#
# Every ~2s, for up to ~3 minutes: scan every top-level .json in ConfigsDir,
# and for any whose "appid" matches AppId, check whether its
# executable/process_name (and arguments, if -PatchArguments was passed)
# already match what we want - if not (whether because Jokerverse just
# created it with its own naive guess, or rewrote it again later on a
# subsequent launch), patch it. This single check-and-correct loop handles
# both "file doesn't exist yet" and "file gets rewritten again later"
# uniformly, without needing to track "new vs already seen" state.
#
# Exits after 3 minutes regardless, so this can't accumulate as an orphaned
# background process indefinitely if the game is never launched again.

param(
    [Parameter(Mandatory)] [string]$ConfigsDir,
    [Parameter(Mandatory)] [string]$AppId,
    [Parameter(Mandatory)] [string]$Executable,
    [Parameter(Mandatory)] [string]$ProcessName,
    [string]$Arguments,
    [switch]$PatchArguments
)

$pollMs       = 2000
$maxTotalMs   = 3 * 60 * 1000
$totalElapsed = 0

while ($totalElapsed -lt $maxTotalMs) {
    if (Test-Path -LiteralPath $ConfigsDir) {
        $candidates = Get-ChildItem -LiteralPath $ConfigsDir -Filter '*.json' -File -ErrorAction SilentlyContinue
        foreach ($file in $candidates) {
            try {
                $json = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch {
                continue
            }

            if ("$($json.appid)" -ne $AppId) { continue }

            $needsPatch = ($json.executable -ne $Executable) -or ($json.process_name -ne $ProcessName)
            if ($PatchArguments) { $needsPatch = $needsPatch -or ($json.arguments -ne $Arguments) }

            if ($needsPatch) {
                try {
                    $json.executable   = $Executable
                    $json.process_name = $ProcessName
                    if ($PatchArguments) { $json.arguments = $Arguments }
                    $output = $json | ConvertTo-Json -Depth 10
                    [System.IO.File]::WriteAllText($file.FullName, $output, [System.Text.UTF8Encoding]::new($false))
                } catch {
                    # Best effort - try again next poll.
                }
            }
        }
    }

    Start-Sleep -Milliseconds $pollMs
    $totalElapsed += $pollMs
}
