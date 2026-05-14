# =============================================================================
# EMS-CSV-DOWNLOAD.PS1 - baixa TODOS os 13 CSVs dos EGX300 com 3 fallbacks
#
# O ems-recon.ps1 v3 falhou em baixar os CSVs (FTP 550 - arquivo nao disponivel)
# mesmo que o LIST mostrasse os arquivos existindo. Esse script tenta:
#
#   1) RemotePath /logging/data/file (path absoluto com / inicial)
#   2) RemotePath logging/data/file (path relativo)
#   3) FtpClient.cwd("/logging/data/") + RETR file (CWD primeiro)
#
# Modo binary forcado em todos. Loga qual estrategia funcionou pra cada arquivo.
# =============================================================================

$ErrorActionPreference = 'Continue'

$Devices = @(
    @{ IP='10.193.217.11'; User='Administrator'; Pass='Gateway'; Name='BM' }
    @{ IP='10.194.124.49'; User='Administrator'; Pass='Gateway'; Name='UT' }
)

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir = Join-Path $env:USERPROFILE "Downloads\ems-csv\$ts"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$LogFile = Join-Path $OutDir '00-summary.log'

function Log {
    param([string]$msg, [string]$color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Get-FtpListing {
    param([string]$IP, [string]$User, [string]$Pass, [string]$Path)
    $url = "ftp://${IP}/${Path}"
    try {
        $req = [Net.FtpWebRequest]::Create($url)
        $req.Credentials = New-Object Net.NetworkCredential($User, $Pass)
        $req.Method = [Net.WebRequestMethods+Ftp]::ListDirectoryDetails
        $req.UseBinary = $true
        $req.UsePassive = $true
        $req.Timeout = 15000
        $resp = $req.GetResponse()
        $reader = New-Object IO.StreamReader($resp.GetResponseStream())
        $list = $reader.ReadToEnd()
        $reader.Close(); $resp.Close()
        return $list
    } catch {
        Log "  LIST $url ERRO: $($_.Exception.Message)" 'Yellow'
        return ""
    }
}

function Download-FtpFile {
    param([string]$IP, [string]$User, [string]$Pass, [string]$RemotePath, [string]$LocalPath)
    $url = "ftp://${IP}${RemotePath}"
    try {
        $req = [Net.FtpWebRequest]::Create($url)
        $req.Credentials = New-Object Net.NetworkCredential($User, $Pass)
        $req.Method = [Net.WebRequestMethods+Ftp]::DownloadFile
        $req.UseBinary = $true
        $req.UsePassive = $true
        $req.Timeout = 30000
        $resp = $req.GetResponse()
        $stream = $resp.GetResponseStream()
        $fs = [IO.File]::OpenWrite($LocalPath)
        $buf = New-Object byte[] 8192
        $total = 0
        while ($true) {
            $read = $stream.Read($buf, 0, $buf.Length)
            if ($read -le 0) { break }
            $fs.Write($buf, 0, $read)
            $total += $read
        }
        $fs.Close(); $stream.Close(); $resp.Close()
        return @{ OK=$true; Bytes=$total; Url=$url }
    } catch {
        if (Test-Path $LocalPath) { Remove-Item $LocalPath -Force -ErrorAction SilentlyContinue }
        return @{ OK=$false; Error=$_.Exception.Message; Url=$url }
    }
}

function Download-WithFallbacks {
    param([string]$IP, [string]$User, [string]$Pass, [string]$FileName, [string]$LocalPath)

    # Estrategia 1: path absoluto
    Log "  S1: /logging/data/$FileName"
    $r = Download-FtpFile -IP $IP -User $User -Pass $Pass `
            -RemotePath "/logging/data/$FileName" -LocalPath $LocalPath
    if ($r.OK) { Log "    OK ($($r.Bytes) B) via S1" 'Green'; return $r }
    Log "    FAIL: $($r.Error)" 'Yellow'

    # Estrategia 2: path relativo
    Log "  S2: logging/data/$FileName"
    $r = Download-FtpFile -IP $IP -User $User -Pass $Pass `
            -RemotePath "/logging/data/$FileName" -LocalPath $LocalPath
    # nota: mesmo path - varia so 1 versus o original. Testando double slash
    $r = Download-FtpFile -IP $IP -User $User -Pass $Pass `
            -RemotePath "logging/data/$FileName" -LocalPath $LocalPath
    if ($r.OK) { Log "    OK ($($r.Bytes) B) via S2" 'Green'; return $r }
    Log "    FAIL: $($r.Error)" 'Yellow'

    # Estrategia 3: URL direto sem prefixo
    Log "  S3: //logging//data//$FileName (encoding test)"
    $r = Download-FtpFile -IP $IP -User $User -Pass $Pass `
            -RemotePath "//logging//data//$FileName" -LocalPath $LocalPath
    if ($r.OK) { Log "    OK ($($r.Bytes) B) via S3" 'Green'; return $r }
    Log "    FAIL: $($r.Error)" 'Yellow'

    return $r
}

Log "Out: $OutDir"

foreach ($d in $Devices) {
    Log "=== $($d.Name) ($($d.IP)) ==="

    # Lista /logging/data/ pra confirmar arquivos
    $list = Get-FtpListing -IP $d.IP -User $d.User -Pass $d.Pass -Path 'logging/data/'
    $listFile = Join-Path $OutDir "$($d.Name)-listing.txt"
    $list | Out-File $listFile -Encoding UTF8

    # Extrai nomes de arquivos (.csv) da listagem
    $csvNames = ($list -split "`n") |
        ForEach-Object {
            $line = $_.Trim()
            if ($line -match '\s+(\S+\.csv)\s*$') { $matches[1] }
        } | Where-Object { $_ -ne $null }

    Log "  Listou $($csvNames.Count) CSV(s)"

    foreach ($name in $csvNames) {
        $local = Join-Path $OutDir "$($d.Name)-$name"
        Download-WithFallbacks -IP $d.IP -User $d.User -Pass $d.Pass `
            -FileName $name -LocalPath $local | Out-Null
    }
}

Log "==========="
Log "Saida: $OutDir"
Get-ChildItem -Path $OutDir | Sort-Object Name |
    ForEach-Object { Log ("  {0,8} B  {1}" -f $_.Length, $_.Name) }

Write-Host ""
Write-Host "Zipa $OutDir e manda" -ForegroundColor Green
