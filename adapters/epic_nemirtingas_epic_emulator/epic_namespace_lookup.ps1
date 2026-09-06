# adapters\epic_nemirtingas_epic_emulator\epic_namespace_lookup.ps1
# Looks up an Epic Games namespace/sandboxId by game name via egdata.app.
# Epic games carry no local ID file comparable to GOG's goggame-*.info, so
# this is the only way to recover the sandboxId needed by
# NemirtingasEpicEmu.json, Launch *.bat, and the Jokerverse achievements API.
#
# Dot-sourced by write_config.ps1 - defines Invoke-EpicNamespaceLookup only.

function Search-EGData {
    param([string]$Name)

    $url = "https://api.egdata.app/search/v2/search?country=US"
    $body = @{
        title     = $Name
        offerType = "BASE_GAME"
        price     = @{ min = 100; max = 100000 }
        page      = 1
        limit     = 28
    } | ConvertTo-Json

    try {
        $resp = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -Body $body -UseBasicParsing
        $offers = $resp.offers
        return @($offers | Where-Object {
            -not $_.prePurchase -and
            -not $_.isCodeRedemptionOnly -and
            $_.price.price.discountPrice -gt 0
        })
    } catch {
        Write-Host "[WARN] egdata.app lookup failed: $_"
        return @()
    }
}

function Invoke-EpicNamespaceLookup {
    param([Parameter(Mandatory)][string]$GameName)

    $searchName = $GameName
    $items = @(Search-EGData $searchName)

    while ($items.Count -eq 0) {
        Write-Host "[INFO] No Epic Games results found for '$searchName'"
        $searchName = Read-Host "Enter the game's name"
        if ([string]::IsNullOrWhiteSpace($searchName)) { continue }
        $items = @(Search-EGData $searchName)
    }

    if ($items.Count -eq 1) {
        $selected = $items[0]
        Write-Host "[INFO] Auto-selected: $($selected.title)  [namespace: $($selected.namespace)]"
    } else {
        Write-Host "[INFO] Epic Games (egdata.app) results for '$searchName':"
        for ($i = 0; $i -lt $items.Count; $i++) {
            Write-Host (" [{0}] {1}  [namespace: {2}]" -f ($i + 1), $items[$i].title, $items[$i].namespace)
        }
        do {
            $choice = Read-Host "Select a result (1-$($items.Count))"
        } while (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt $items.Count)
        $selected = $items[[int]$choice - 1]
    }

    return [PSCustomObject]@{
        Title     = $selected.title
        Namespace = $selected.namespace
    }
}
