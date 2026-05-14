<#
.SYNOPSIS
    EMS Recon (medidores) - executa NATIVO no PowerShell da maquina-ponte.
    Coleta dos 3 EGX300 / Carlo Gavazzi via FTP + HTTP/HTTPS.

.DESCRIPTION
    Banco de dados nao e tratado aqui (use ems-schema-dump.sql no DBeaver).
    Saida: %USERPROFILE%\Downloads\ems-recon\<timestamp>\
    100% read-only nos medidores.

    O que coleta:
      - ping, port-scan TCP em 12 portas
      - FTP listing em paths reais do EGX300 (logging/, www/, system/)
      - Download completo do egx300cfg.txt (mapeamento Modbus dos circuitos)
      - Sample de 64KB do primeiro arquivo do FTP (formato CSV/binario)
      - Listagem recursiva em logging/<subdir>
      - HTTP/HTTPS com Basic Auth + sondagem de 25+ endpoints conhecidos
        Schneider EGX300, Carlo Gavazzi VMU-C/EM24

.PARAMETER OutputDir
    Default: %USERPROFILE%\Downloads\ems-recon

.EXAMPLE
    .\ems-recon.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputDir = "$env:USERPROFILE\Downloads\ems-recon"
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12,Tls11,Tls'

$Devices = @(
    @{ IP='10.193.217.11'; User='Administrator'; Pass='Gateway'; Label='Medidor BM Schneider EGX300' }
    @{ IP='10.194.124.49'; User='Administrator'; Pass='Gateway'; Label='Medidor UT Schneider EGX300' }
    @{ IP='10.193.217.50'; User='admin';         Pass='admin';   Label='Medidor 69k Carlo Gavazzi' }
)

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir = Join-Path $OutputDir $ts
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$Log = Join-Path $OutDir 'recon.log'

function Write-Log {
    param([string]$Msg, [string]$Color='Gray')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Msg
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $Log -Value $line
}

# --- Helpers FTP/HTTP ---------------------------------------------------------
function Test-Tcp {
    param([string]$IP,[int]$Port,[int]$TimeoutMs=1500)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($IP, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok) { $c.EndConnect($iar) | Out-Null; $c.Close(); return $true }
        $c.Close(); return $false
    } catch { return $false }
}

function Get-FtpListing {
    param([string]$IP,[string]$User,[string]$Pass,[string]$Path='')
    try {
        $uri = "ftp://$IP/$Path"
        $req = [System.Net.FtpWebRequest]::Create($uri)
        $req.Method      = [System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails
        $req.Credentials = New-Object System.Net.NetworkCredential($User, $Pass)
        $req.UsePassive  = $true; $req.UseBinary = $true; $req.KeepAlive = $false
        $req.Timeout     = 15000
        $resp = $req.GetResponse()
        $rdr  = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $out  = $rdr.ReadToEnd()
        $rdr.Close(); $resp.Close()
        return $out
    } catch {
        return ("ERRO ({0}): {1}" -f $Path, $_.Exception.Message)
    }
}

function Get-FtpFile {
    param([string]$IP,[string]$User,[string]$Pass,[string]$RemotePath,[string]$LocalPath,[int]$MaxBytes=0)
    try {
        $uri = "ftp://$IP/$RemotePath"
        $req = [System.Net.FtpWebRequest]::Create($uri)
        $req.Method      = [System.Net.WebRequestMethods+Ftp]::DownloadFile
        $req.Credentials = New-Object System.Net.NetworkCredential($User, $Pass)
        $req.UsePassive  = $true; $req.UseBinary = $true; $req.KeepAlive = $false
        $req.Timeout     = 30000
        $resp = $req.GetResponse()
        $stream = $resp.GetResponseStream()
        $fs = [System.IO.File]::Create($LocalPath)
        $buf = New-Object byte[] 8192
        $total = 0
        while ($true) {
            $read = $stream.Read($buf, 0, $buf.Length)
            if ($read -le 0) { break }
            if ($MaxBytes -gt 0 -and ($total + $read) -ge $MaxBytes) {
                $fs.Write($buf, 0, ($MaxBytes - $total))
                $total = $MaxBytes; break
            }
            $fs.Write($buf, 0, $read); $total += $read
        }
        $fs.Close(); $stream.Close(); $resp.Close()
        return $total
    } catch {
        Set-Content -Path "$LocalPath.err.txt" -Value $_.Exception.Message
        return 0
    }
}

function Try-Http {
    param([string]$Url,[string]$User,[string]$Pass,[string]$OutFile,[int]$TimeoutSec=5)
    try {
        # Basic Auth via header manual (compativel com PS 5.1, sem AllowUnencryptedAuthentication)
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}"))
        $headers = @{ Authorization = "Basic $b64" }
        $r = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -UseBasicParsing `
                               -Headers $headers -ErrorAction Stop
        $body = if ($r.Content) {
            if ($r.Content -is [string]) { $r.Content.Substring(0,[Math]::Min(8192,$r.Content.Length)) }
            else { try { [Text.Encoding]::UTF8.GetString($r.Content[0..([Math]::Min(8191,$r.Content.Length-1))]) } catch { '<binary>' } }
        } else { '' }
        @"
StatusCode: $($r.StatusCode)
Server: $($r.Headers.Server)
ContentType: $($r.Headers['Content-Type'])
Length: $($r.RawContentLength)

$body
"@ | Out-File -FilePath $OutFile -Encoding UTF8
        return $r.StatusCode
    } catch {
        $code = 0
        if ($_.Exception.Response) {
            try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        }
        "HTTP $code | $($_.Exception.Message)" | Out-File -FilePath $OutFile -Encoding UTF8
        return $code
    }
}

# --- Main loop ----------------------------------------------------------------
Write-Log "=== EMS Recon (medidores) ===" 'Cyan'
Write-Log "Output: $OutDir" 'Gray'
Write-Log "Banco: usar DBeaver com scripts/ems-schema-dump.sql" 'Gray'

foreach ($d in $Devices) {
    Write-Log ("--- {0} ({1}) ---" -f $d.Label, $d.IP) 'Cyan'
    $base = Join-Path $OutDir ("dev-" + ($d.IP -replace '\.','_'))

    # Ping
    try {
        Test-Connection -ComputerName $d.IP -Count 3 -ErrorAction SilentlyContinue |
            Format-Table -AutoSize | Out-String | Out-File "$base.01-ping.txt" -Encoding UTF8
    } catch {
        "Erro ping: $($_.Exception.Message)" | Out-File "$base.01-ping.txt"
    }

    # Portas
    $ports = 21,22,23,80,443,502,161,1883,4911,8080,20000,44818
    $portResults = foreach ($p in $ports) {
        $open = Test-Tcp -IP $d.IP -Port $p -TimeoutMs 1500
        [pscustomobject]@{ Port = $p; Status = $(if ($open) {'OPEN'} else {'closed/filtered'}) }
    }
    $portResults | Format-Table -AutoSize | Out-String | Out-File "$base.02-ports.txt" -Encoding UTF8
    $portOpen = @{}
    foreach ($r in $portResults) { $portOpen[$r.Port] = ($r.Status -eq 'OPEN') }

    # FTP
    if ($portOpen[21]) {
        Write-Log ("  [{0}] FTP aberto" -f $d.IP) 'Yellow'

        # Listing raiz
        $rootList = Get-FtpListing -IP $d.IP -User $d.User -Pass $d.Pass -Path ''
        $rootList | Out-File "$base.10-ftp-root.txt" -Encoding UTF8

        # Listings de paths reais (EGX300) + fallbacks comuns
        foreach ($p in 'logging','www','system','logs','log','data','history','csv','export','HISTLOG','TREND','ALARM') {
            $listing = Get-FtpListing -IP $d.IP -User $d.User -Pass $d.Pass -Path "$p/"
            $listing | Out-File "$base.11-ftp-$p.txt" -Encoding UTF8
        }

        # Recursivo dentro de logging/<sub>
        $recursiveOut = "$base.14-logging-recursive.txt"
        foreach ($sub in '','history/','trend/','alarm/','events/','data/') {
            $listing = Get-FtpListing -IP $d.IP -User $d.User -Pass $d.Pass -Path "logging/$sub"
            if ($listing -and $listing -notmatch '^ERRO') {
                Add-Content -Path $recursiveOut -Value "===== /logging/$sub ====="
                Add-Content -Path $recursiveOut -Value $listing
            }
        }

        # Baixar egx300cfg.txt INTEIRO (config Modbus)
        if ($rootList -match 'egx300cfg\.txt') {
            Write-Log ("  [{0}] baixando egx300cfg.txt completo" -f $d.IP) 'Yellow'
            $bytes = Get-FtpFile -IP $d.IP -User $d.User -Pass $d.Pass `
                -RemotePath 'egx300cfg.txt' -LocalPath "$base.15-egx300cfg.txt"
            Write-Log ("    -> $bytes bytes") 'Gray'
        }

        # Baixar version.txt
        if ($rootList -match 'version\.txt') {
            Get-FtpFile -IP $d.IP -User $d.User -Pass $d.Pass `
                -RemotePath 'version.txt' -LocalPath "$base.16-version.txt" | Out-Null
        }

        # Baixar TODOS os .conf de /system/ (revelam config de logging/export do EGX300)
        Write-Log ("  [{0}] baixando configs de /system/" -f $d.IP) 'Yellow'
        foreach ($cfg in 'data_export.conf','all_devices.conf','custom_devices.conf',
                         'devtypvis.conf','devicelogmethod.bin','system.log','maintenance.log') {
            $local = "$base.20-system-$($cfg -replace '\.','_').txt"
            Get-FtpFile -IP $d.IP -User $d.User -Pass $d.Pass `
                -RemotePath "system/$cfg" -LocalPath $local | Out-Null
        }

        # CRITICO: baixar 1 CSV completo de /logging/data/ -- formato real dos dados historicos
        $dataList = Get-FtpListing -IP $d.IP -User $d.User -Pass $d.Pass -Path 'logging/data/'
        $dataList | Out-File "$base.21-logging-data-list.txt" -Encoding UTF8
        $firstCsv = ($dataList -split "`n" |
                     Where-Object { $_ -match '\.csv\s*$' } |
                     Select-Object -First 1)
        if ($firstCsv) {
            $tokens = $firstCsv.Trim() -split '\s+'
            $csvName = $tokens[-1]
            Write-Log ("  [{0}] baixando CSV completo: logging/data/$csvName" -f $d.IP) 'Yellow'
            $csvFile = "$base.22-csv-$csvName"
            $bytes = Get-FtpFile -IP $d.IP -User $d.User -Pass $d.Pass `
                -RemotePath "logging/data/$csvName" -LocalPath $csvFile
            Write-Log ("    -> $bytes bytes") 'Gray'
        }

        # Tambem baixar 1 .bin pra ver formato proprietario
        $firstBin = ($dataList -split "`n" |
                     Where-Object { $_ -match '\.bin\s*$' } |
                     Select-Object -First 1)
        if ($firstBin) {
            $tokens = $firstBin.Trim() -split '\s+'
            $binName = $tokens[-1]
            Write-Log ("  [{0}] amostrando 64KB de logging/data/$binName" -f $d.IP) 'Yellow'
            $binFile = "$base.23-bin-sample-$binName"
            Get-FtpFile -IP $d.IP -User $d.User -Pass $d.Pass `
                -RemotePath "logging/data/$binName" -LocalPath $binFile -MaxBytes 65536 | Out-Null
        }

        # Listar /logging/templates/ e /logging/configuration/
        Get-FtpListing -IP $d.IP -User $d.User -Pass $d.Pass -Path 'logging/templates/' |
            Out-File "$base.24-logging-templates.txt" -Encoding UTF8
        Get-FtpListing -IP $d.IP -User $d.User -Pass $d.Pass -Path 'logging/configuration/' |
            Out-File "$base.25-logging-configuration.txt" -Encoding UTF8
    }

    # HTTP com Basic Auth
    if ($portOpen[80]) {
        Write-Log ("  [{0}] HTTP probe" -f $d.IP) 'Yellow'
        Try-Http -Url "http://$($d.IP)/" -User $d.User -Pass $d.Pass -OutFile "$base.30-http-root.txt" | Out-Null

        $endpoints = '/index.html','/about.shtml','/dashboard.html','/cgi-bin/login',
                     '/Portal/Portal.mwsl','/web/diagnose.shtml','/data','/api/v1/data',
                     '/data.json','/values','/log/','/csv/','/measurements','/realtime',
                     '/historic','/PowerLogic/','/Schneider/'
        $epOut = "$base.32-http-endpoints.txt"
        foreach ($ep in $endpoints) {
            $code = Try-Http -Url "http://$($d.IP)$ep" -User $d.User -Pass $d.Pass `
                             -OutFile (Join-Path $env:TEMP 'tmp.txt') -TimeoutSec 4
            "$code  $ep" | Add-Content -Path $epOut
        }
    }

    # HTTPS com Basic Auth (critico para Carlo Gavazzi)
    if ($portOpen[443]) {
        Write-Log ("  [{0}] HTTPS probe" -f $d.IP) 'Yellow'
        Try-Http -Url "https://$($d.IP)/" -User $d.User -Pass $d.Pass -OutFile "$base.33-https-root.txt" | Out-Null

        $epsHttps = '/login.html','/data.json','/values.json','/api/v1/data',
                    '/em24','/log.csv','/realtime/data.json','/datapoint',
                    '/cgi-bin/data.cgi','/data/datapoints.json','/csvexport',
                    '/datalogger','/DataLog','/measurements','/historic'
        $epOut = "$base.35-https-endpoints.txt"
        foreach ($ep in $epsHttps) {
            $code = Try-Http -Url "https://$($d.IP)$ep" -User $d.User -Pass $d.Pass `
                             -OutFile (Join-Path $env:TEMP 'tmp.txt') -TimeoutSec 4
            "$code  $ep" | Add-Content -Path $epOut
        }
    }

    if ($portOpen[502]) {
        "Modbus TCP aparentemente disponivel em 502" | Out-File "$base.40-modbus.txt"
    }
}

# Resumo
$txtCount = (Get-ChildItem -Path $OutDir -Filter '*.txt' -ErrorAction SilentlyContinue).Count
$totalSize = [math]::Round((Get-ChildItem -Path $OutDir -Recurse -File |
    Measure-Object -Property Length -Sum).Sum / 1KB, 1)

Write-Host ""
Write-Host "===============================================" -ForegroundColor Green
Write-Host "  EMS Recon (medidores) concluido!" -ForegroundColor Green
Write-Host "===============================================" -ForegroundColor Green
Write-Host "Pasta       : $OutDir"
Write-Host "Arquivos txt: $txtCount"
Write-Host "Tamanho     : $totalSize KB"
Write-Host ""
Write-Host "Banco: rode scripts\ems-schema-dump.sql no DBeaver e exporte os" -ForegroundColor Cyan
Write-Host "       resultsets como CSV/TSV pra mesma pasta." -ForegroundColor Cyan
Write-Host ""

Start-Process explorer.exe $OutDir
