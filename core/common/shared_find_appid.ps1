# shared_find_appid.ps1
# Emulator-agnostic Steam AppID lookup by folder/game name.
# Used by every adapter - do not fork this per-emulator, fix it here once.
#
# Writes _ae_appid.cmd with:  set "gameAppID=<id>"

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$GameName
)

$outFile = Join-Path (Get-Location).Path "_ae_appid.cmd"

function Write-Result([string]$id) {
    [System.IO.File]::WriteAllLines($outFile, @("set `"gameAppID=$id`""), [System.Text.Encoding]::ASCII)
}

try {
    $folderName = $GameName
    $queries = [System.Collections.Generic.List[string]]::new()
    $queries.Add($folderName)

    $cleanName = $folderName -replace '\[[^\]]*\]', ' ' -replace '\([^\)]*\)', ' '
    $cleanName = $cleanName -replace '(?i)\b(resynced|reloaded|fitgirl|dodi|elamigos|codex|rune|tenoke|goldberg|portable|repack)\b', ' '
    $cleanName = ($cleanName -replace '\s+', ' ').Trim(' ', '.', '-', '_')
    if ($cleanName -and $cleanName -ne $folderName) { $queries.Add($cleanName) }

    $steamMatches = @()
    foreach ($query in $queries) {
        $encodedQuery = [uri]::EscapeDataString($query)
        try {
            $uri = "https://store.steampowered.com/search?term=$encodedQuery&category1=998&l=english&cc=us"
            $headers = @{
                'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36'
                'Accept-Language' = 'en-US,en;q=0.9'
            }
            $response = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec 20 -UseBasicParsing -Headers $headers
            $steamMatches = @(
                [regex]::Matches(
                    $response.Content,
                    '(?is)<a\b(?=[^>]*\bdata-ds-appid="(?<id>\d+)")[^>]*\bhref="[^>]*store\.steampowered\.com/app/[^>]*"[^>]*>(?<body>.*?)</a>'
                ) | ForEach-Object {
                    $title = [regex]::Match($_.Groups['body'].Value, '(?is)<span\s+class="title">\s*(?<name>.*?)\s*</span>')
                    [pscustomobject]@{
                        id   = $_.Groups['id'].Value
                        name = [System.Net.WebUtility]::HtmlDecode(($title.Groups['name'].Value -replace '(?is)<[^>]+>', '').Trim())
                    }
                } | Where-Object { $_.id -match '^\d+$' -and $_.name } | Select-Object -Unique id, name
            )
            if ($steamMatches.Count -gt 0) { break }
        }
        catch {
            Write-Warning "Steam search failed for '$query': $($_.Exception.Message)"
        }
    }

    $selectedId = $null

    if ($steamMatches.Count -eq 1) {
        Write-Host ''
        Write-Host "Steam matches for: $folderName"
        Write-Host ('[1] {0}  (AppID {1})' -f $steamMatches[0].name, $steamMatches[0].id)
        $selectedId = [string]($steamMatches[0].id)
        Write-Host "[INFO] Only one result found - auto-selected AppID $selectedId."
    }
    elseif ($steamMatches.Count -gt 1) {
        Write-Host ''
        Write-Host "Steam matches for: $folderName"
        for ($index = 0; $index -lt $steamMatches.Count; $index++) {
            Write-Host ('[{0}] {1}  (AppID {2})' -f ($index + 1), $steamMatches[$index].name, $steamMatches[$index].id)
        }
        $choice = (Read-Host 'Choose a number, or enter an AppID manually').Trim()
        $choiceNumber = 0
        if ($choice -match '^\d+$' -and [int]::TryParse($choice, [ref]$choiceNumber)) {
            if ($choiceNumber -ge 1 -and $choiceNumber -le $steamMatches.Count) {
                $selectedId = [string]($steamMatches[($choiceNumber - 1)].id)
            }
            elseif ($choice.Length -le 10) {
                $selectedId = $choice
            }
        }
    }
    else {
        Write-Warning 'No Steam Store results were returned.'
        $choice = Read-Host 'Enter the AppID manually'
        if ($choice -match '^\d{1,10}$') {
            $selectedId = $choice
        }
    }

    if (-not $selectedId) {
        Write-Host 'No AppID selected.'
        Write-Host ''
        exit 1
    }

    Write-Result $selectedId
    Write-Host "AppID selected: $selectedId"
    Write-Host ''
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    Write-Host ''
    exit 1
}
