# =============================================================================
# EMS-DEPLOY-HOMOLOG.PS1 v2 - deploy RAPIDO na ponte Windows
#
# >>> DEPRECADO: usar `ems-deploy.ps1` (parametrizado HOM/PRD; baixa o JAR do
# >>> ultimo build de `main` no CI). Este aqui ainda baixa o JAR v0.1.1 fixo do
# >>> Package Registry = codigo ANTIGO (sem o parser v2 / CompressionGuard).
# >>>   powershell -ExecutionPolicy Bypass -File ems-deploy.ps1            # HOM
# >>>   powershell -ExecutionPolicy Bypass -File ems-deploy.ps1 -Env prd   # PRD
#
# v2 mudancas:
#   - Baixa JAR pre-buildado do GitLab Package Registry (32MB) em vez de
#     compilar do source (que precisava JDK 200MB + Maven 80MB + 3min build)
#   - Procura Java >= 17 no sistema antes de baixar JRE portable
#   - Default JRE 21 (75MB) em vez de JDK (200MB) - so precisa rodar, nao compilar
#
# Tempo total: ~30s a 2min na 1a vez (depende se tem Java instalado)
#              ~10s nas proximas (tudo cacheado)
#
# OBJETIVO: rodar em HOMOLOG (172.25.0.3, banco vazio) pra validar fluxo
#           SEM TOCAR EM PRODUCAO.
#
# SEGURANCAS:
#   - Tunnel SSH HARDCODED 172.25.0.3 (HOM)
#   - SPRING_PROFILES_ACTIVE=hom + senha HOM
#   - GAPFILLER_RECENT_ENABLED=false (cron OFF)
#   - Bind 127.0.0.1 only
# =============================================================================

$ErrorActionPreference = 'Stop'

# ---- CONFIG -----------------------------------------------------------------
$SshHost      = '150.150.251.112'
$SshUser      = 'cesar.silva'
$SshPass      = ")HV2//x'md}w4;R"
$LocalDbPort  = 15432
$PgIpHom      = '172.25.0.3'
$DbName       = 'energymanagementsystem'
$DbUser       = 'ems_user'
$DbPassHom    = 'Sureness-Stencil9-Flap'
$AppPort      = 8080
$GitlabToken  = 'glpat-1KBJACUAPmj8f3V1ivdBLmM6MQpvOjEKdTptbDV2aQ8.01.1706sk2g4'
$ProjectId    = 81970992
$JarVersion   = 'v0.1.1'
$JarUrl       = "https://gitlab.com/api/v4/projects/$ProjectId/packages/generic/ems-gap-filler/$JarVersion/ems-gap-filler-$JarVersion.jar"
$JreUrl       = 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.5%2B11/OpenJDK21U-jre_x64_windows_hotspot_21.0.5_11.zip'
# -----------------------------------------------------------------------------

$ts        = Get-Date -Format 'yyyyMMdd-HHmmss'
$BaseDir   = Join-Path $env:USERPROFILE 'Downloads\ems-gap-filler'
$ToolsDir  = Join-Path $BaseDir 'tools'
$LogsDir   = Join-Path $BaseDir 'logs'
New-Item -ItemType Directory -Force -Path $BaseDir, $ToolsDir, $LogsDir | Out-Null

$RunLog = Join-Path $LogsDir "deploy-$ts.log"
$AppLog = Join-Path $LogsDir "app-$ts.log"

function Log {
    param([string]$msg, [string]$color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $RunLog -Value $line -Encoding UTF8
}
function Fail { param([string]$m) Log "ERRO: $m" 'Red'; exit 1 }

# ---- 1) Java 17+ ------------------------------------------------------------
function Test-JavaVersion {
    param([string]$Path)
    # java -version imprime no STDERR. Em PS com $ErrorActionPreference=Stop,
    # qualquer stderr de native command vira NativeCommandError. Forcamos Continue
    # localmente pra capturar a saida sem abortar o script.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = ""
    try {
        $out = (& $Path -version 2>&1 | ForEach-Object { "$_" }) -join "`n"
    } catch { $out = "" }
    finally { $ErrorActionPreference = $prev }

    # Java 8: "1.8.0_x" -> major=1; Java 21: "21.0.5" -> major=21
    # Versoes >= 9 nao tem prefixo "1.", entao major direto eh o real major.
    if ($out -match 'version "(\d+)\.?(\d*)') {
        $m1 = [int]$matches[1]
        $m2 = if ($matches[2]) { [int]$matches[2] } else { 0 }
        $major = if ($m1 -eq 1) { $m2 } else { $m1 }
        return @{ Major = $major; Raw = $out.Trim() }
    }
    return @{ Major = 0; Raw = $out }
}

function Find-Java {
    $j = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($j) {
        $info = Test-JavaVersion -Path $j.Path
        if ($info.Major -ge 17) {
            Log "Java no PATH: $($j.Path) (major=$($info.Major))"
            return $j.Path
        }
        Log "Java no PATH eh major=$($info.Major), precisamos >=17 - procurando outra instalacao..."
    }
    $candidates = @(
        "$env:ProgramFiles\Eclipse Adoptium\jdk-2*\bin\java.exe",
        "$env:ProgramFiles\Eclipse Adoptium\jre-2*\bin\java.exe",
        "$env:ProgramFiles\Java\jdk-2*\bin\java.exe",
        "$env:ProgramFiles\Java\jre-2*\bin\java.exe",
        "$env:ProgramFiles\Microsoft\jdk-2*\bin\java.exe",
        "$env:LOCALAPPDATA\Programs\Eclipse Adoptium\*\bin\java.exe"
    )
    foreach ($c in $candidates) {
        $found = Get-ChildItem $c -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $info = Test-JavaVersion -Path $found.FullName
            if ($info.Major -ge 17) {
                Log "Java em: $($found.FullName) (major=$($info.Major))"
                return $found.FullName
            }
        }
    }
    Log "Java >=17 nao encontrado. Baixando JRE 21 portable (75MB ~30s)..."
    $jreZip = Join-Path $ToolsDir 'jre21.zip'
    $jreDir = Join-Path $ToolsDir 'jre21'
    if (-not (Test-Path "$jreDir\*\bin\java.exe")) {
        if (-not (Test-Path $jreZip)) {
            Invoke-WebRequest -Uri $JreUrl -OutFile $jreZip -UseBasicParsing
        }
        Expand-Archive -Path $jreZip -DestinationPath $jreDir -Force
        Remove-Item $jreZip -Force
    }
    $java = Get-ChildItem -Path $jreDir -Filter "java.exe" -Recurse | Select-Object -First 1
    if (-not $java) { Fail "JRE extraida mas java.exe nao achado" }
    return $java.FullName
}

$Java = Find-Java
$javaInfo = Test-JavaVersion -Path $Java
Log "  $($javaInfo.Raw -replace "`n", ' | ')"

# ---- 2) JAR pre-buildado do GitLab -----------------------------------------
$JarLocal = Join-Path $ToolsDir 'ems-gap-filler.jar'
if (-not (Test-Path $JarLocal)) {
    Log "Baixando JAR $JarVersion (32MB ~10s)..."
    Invoke-WebRequest -Uri $JarUrl -Headers @{'PRIVATE-TOKEN'=$GitlabToken} `
        -OutFile $JarLocal -UseBasicParsing
}
Log "JAR = $JarLocal ($([Math]::Round((Get-Item $JarLocal).Length / 1MB, 1)) MB)"

# ---- 3) plink + tunnel SSH -> HOM -------------------------------------------
$plink = (Get-Command plink.exe -ErrorAction SilentlyContinue).Path
if (-not $plink) { $plink = 'C:\Program Files\PuTTY\plink.exe' }
if (-not (Test-Path $plink)) { Fail "plink.exe nao achado" }

$null = "y" | & $plink -ssh -batch -pw $SshPass "$SshUser@$SshHost" 'echo OK' 2>&1

Get-NetTCPConnection -LocalPort $LocalDbPort -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }

Log "Tunnel HOM 127.0.0.1:$LocalDbPort -> $PgIpHom`:5432..."
$tunnelArgs = @('-ssh','-batch','-N','-pw',$SshPass,
                '-L', "${LocalDbPort}:${PgIpHom}:5432",
                "$SshUser@$SshHost")
$tunnelProc = Start-Process -FilePath $plink -ArgumentList $tunnelArgs `
    -WindowStyle Hidden -PassThru
Log "tunnel PID=$($tunnelProc.Id)"

$ok = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-NetConnection -ComputerName 127.0.0.1 -Port $LocalDbPort `
        -InformationLevel Quiet -WarningAction SilentlyContinue) { $ok = $true; break }
}
if (-not $ok) {
    try { Stop-Process -Id $tunnelProc.Id -Force } catch {}
    Fail "tunnel nao subiu em 10s"
}
Log "tunnel OK"

# ---- 4) Spring Boot ---------------------------------------------------------
$env:SPRING_PROFILES_ACTIVE   = 'hom'
$env:DB_URL                   = "jdbc:postgresql://127.0.0.1:$LocalDbPort/$DbName"
$env:DB_USER                  = $DbUser
$env:DB_PASSWORD              = $DbPassHom
$env:SERVER_PORT              = "$AppPort"
$env:SERVER_ADDRESS           = '127.0.0.1'
$env:GAPFILLER_RECENT_ENABLED = 'false'
$env:TZ                       = 'America/Manaus'

Get-NetTCPConnection -LocalPort $AppPort -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }

Log "Iniciando ems-gap-filler (porta $AppPort, profile=hom, cron=OFF)..."
$jvmArgs = @('-Duser.timezone=America/Manaus','-Xms256m','-Xmx512m','-jar',$JarLocal)
$appProc = Start-Process -FilePath $Java -ArgumentList $jvmArgs `
    -RedirectStandardOutput $AppLog -RedirectStandardError "$AppLog.err" `
    -WindowStyle Hidden -PassThru

Log "app PID=$($appProc.Id), aguardando /actuator/health UP (timeout 90s)..."
$healthy = $false
$lastErr = ""
for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep -Seconds 2
    try {
        $h = Invoke-RestMethod -Uri "http://127.0.0.1:$AppPort/actuator/health" `
            -TimeoutSec 3 -ErrorAction Stop
        if ($h.status -eq 'UP') { $healthy = $true; break }
        $lastErr = "status=$($h.status)"
    } catch { $lastErr = $_.Exception.Message }
}

if (-not $healthy) {
    Log "app NAO ficou UP. ultimo erro: $lastErr" 'Yellow'
    Log "log app:" 'Yellow'
    Get-Content $AppLog -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Log "  $_" }
} else {
    Log "app UP" 'Green'

    Log "Smoke test: POST /api/v1/backfill (sensor 30, janela 1h)..."
    $now = Get-Date
    $body = @{
        sensorIds = @(30)
        windowStart = $now.AddHours(-2).ToString("yyyy-MM-ddTHH:mm:ss")
        windowEnd   = $now.AddHours(-1).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$AppPort/api/v1/backfill" `
            -Method Post -Body $body -ContentType "application/json" `
            -Headers @{'X-Requested-By' = 'deploy-script'} -TimeoutSec 10
        Log "submit OK -> id=$($resp.id) status=$($resp.status)"
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 10
            $get = Invoke-RestMethod -Uri "http://127.0.0.1:$AppPort/api/v1/backfill/$($resp.id)" `
                -TimeoutSec 5
            Log "  poll: status=$($get.status) inserted=$($get.inserted) skipped=$($get.skipped)"
            if ($get.status -in 'COMPLETED','FAILED','CANCELLED') { break }
        }
    } catch { Log "smoke test: $($_.Exception.Message)" 'Yellow' }
}

# ---- 5) Empacotar logs -----------------------------------------------------
$zipPath = Join-Path $env:USERPROFILE "Downloads\ems-gap-filler-deploy-$ts.zip"
$tmpStage = Join-Path $env:TEMP "stage-$ts"
New-Item -ItemType Directory -Force -Path $tmpStage | Out-Null
Copy-Item $RunLog $tmpStage -Force
Copy-Item $AppLog $tmpStage -Force -ErrorAction SilentlyContinue
Copy-Item "$AppLog.err" $tmpStage -Force -ErrorAction SilentlyContinue
Compress-Archive -Path "$tmpStage\*" -DestinationPath $zipPath -Force
Remove-Item $tmpStage -Recurse -Force

Log "===================================================="
Log "DEPLOY HOMOLOG"
Log "  app PID:    $($appProc.Id)"
Log "  tunnel PID: $($tunnelProc.Id)"
Log "  health:     http://127.0.0.1:$AppPort/actuator/health"
Log "  log app:    $AppLog"
Log "  zip:        $zipPath"
Log "===================================================="
Log "Pra parar:" 'Yellow'
Log "  Stop-Process -Id $($appProc.Id) -Force ; Stop-Process -Id $($tunnelProc.Id) -Force"
Log ""
Log "MANDA $zipPath PRO CHAT" 'Green'
