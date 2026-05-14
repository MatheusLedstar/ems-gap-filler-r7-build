# =============================================================================
# EMS-DEPLOY.PS1 - deploy do ems-gap-filler RODANDO NA PONTE Windows (150.150.251.133)
#
# Roda o JAR (baixado do ultimo build de `main` no GitLab CI) como processo Java na
# ponte, conectando no Postgres do servidor EMS via tunnel SSH (cesar.silva).
# Substitui/generaliza o ems-deploy-homolog.ps1: mesmo padrao, parametrizado HOM/PRD.
#
# USO (na ponte 150.150.251.133):
#   powershell -ExecutionPolicy Bypass -File ems-deploy.ps1                 # HOM, cron OFF, smoke test
#   powershell -ExecutionPolicy Bypass -File ems-deploy.ps1 -DryRun         # HOM, ZERO reconcile: so boot+Flyway+API+report
#   powershell -ExecutionPolicy Bypass -File ems-deploy.ps1 -Env prd        # PRD, cron OFF (pede confirmacao)
#   powershell -ExecutionPolicy Bypass -File ems-deploy.ps1 -Env prd -Yes   # PRD, cron OFF, sem prompt
#   powershell -ExecutionPolicy Bypass -File ems-deploy.ps1 -Env prd -Yes -EnableCron   # PRD, cron ON
#
# RECOMENDACAO PRA PRD (gates ainda abertos - parser nao validado vs .csv cru do FTP):
#   1) rodar SEM -EnableCron  -> worker sobe mas nao reconcilia nada automaticamente
#   2) fazer 1 POST /api/v1/backfill manual numa janela pequena (curl impresso no fim)
#   3) conferir o resultado (filtrou o lixo do buffer? achou anomalia real? mexeu no dado certo?)
#   4) so entao rodar de novo com -EnableCron
#
# SEGURANCAS (kill-switches REAIS - viram env vars que o GapFillerScheduler le):
#   - tunnel SSH so pro IP do banco do ambiente escolhido (HOM .0.3 / PRD .0.7)
#   - GAPFILLER_RECENT_ENABLED=false por padrao (sweep RECENT horario OFF; -EnableCron pra ligar)
#   - GAPFILLER_HISTORICAL_ENABLED=true por padrao (fila de backfill drena -> o smoke test roda);
#     com -DryRun vira false E o smoke test e pulado -> o worker NAO toca em telemetria nenhuma
#   - bind 127.0.0.1 only
#   - PRD pede confirmacao "PROD" (a menos que -Yes)
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('hom','prd')] [string] $Env = 'hom',
    [switch] $EnableCron,
    [switch] $DryRun,
    [switch] $Yes,
    # -JarUrl: baixa o .jar direto dessa URL (com PRIVATE-TOKEN) em vez do artefato do CI.
    # Util quando os shared runners do GitLab estao sem minutos -> sobe-se um JAR via "generic package".
    # Ex: https://gitlab.com/api/v4/projects/81970992/packages/generic/ems-gap-filler/<versao>/ems-gap-filler-0.2.0-SNAPSHOT.jar
    [string] $JarUrl = ''
)

$ErrorActionPreference = 'Stop'

# ---- CONFIG -----------------------------------------------------------------
$SshHost     = '150.150.251.112'
$SshUser     = 'cesar.silva'
$SshPass     = ")HV2//x'md}w4;R"
$LocalDbPort = 15432
$DbName      = 'energymanagementsystem'
$DbUser      = 'ems_user'
$AppPort     = 8080
$GitlabToken = 'glpat-1KBJACUAPmj8f3V1ivdBLmM6MQpvOjEKdTptbDV2aQ8.01.1706sk2g4'
$ProjectId   = 81970992
# JAR = artefato do ultimo job `test` em main (mvn verify empacota o jar)
$JarZipUrl   = "https://gitlab.com/api/v4/projects/$ProjectId/jobs/artifacts/main/download?job=test"
$JreUrl      = 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.5%2B11/OpenJDK21U-jre_x64_windows_hotspot_21.0.5_11.zip'

if ($Env -eq 'prd') {
    $PgIp    = '172.25.0.7'
    $DbPass  = 'Glimmer7-Enroll-Bloomers'
    $Profile = 'prd'
} else {
    $PgIp    = '172.25.0.3'
    $DbPass  = 'Sureness-Stencil9-Flap'
    $Profile = 'hom'
}
$CronEnabled       = if ($EnableCron) { 'true' } else { 'false' }   # GAPFILLER_RECENT_ENABLED
$HistoricalEnabled = if ($DryRun)     { 'false' } else { 'true' }   # GAPFILLER_HISTORICAL_ENABLED (DryRun => fila nao drena, smoke pulado)
# -----------------------------------------------------------------------------

$ts       = Get-Date -Format 'yyyyMMdd-HHmmss'
$BaseDir  = Join-Path $env:USERPROFILE 'Downloads\ems-gap-filler'
$ToolsDir = Join-Path $BaseDir 'tools'
$LogsDir  = Join-Path $BaseDir 'logs'
New-Item -ItemType Directory -Force -Path $BaseDir, $ToolsDir, $LogsDir | Out-Null
$RunLog = Join-Path $LogsDir "deploy-$Env-$ts.log"
$AppLog = Join-Path $LogsDir "app-$Env-$ts.log"

function Log {
    param([string]$msg, [string]$color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $RunLog -Value $line -Encoding UTF8
}
function Fail { param([string]$m) Log "ERRO: $m" 'Red'; exit 1 }
# Out-File -Encoding utf8 do Windows PowerShell 5.1 grava BOM -> quebra parsers JSON estritos. Este helper nao.
function WriteUtf8NoBom { param([string]$Path, [string]$Text) [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false))) }

# ---- 0) confirmacao PRD -----------------------------------------------------
if ($Env -eq 'prd') {
    Log "======================================================" 'Yellow'
    Log "  ATENCAO: DEPLOY EM PRODUCAO (PG 172.25.0.7, profile=prd)" 'Yellow'
    Log "  cron = $CronEnabled $(if ($CronEnabled -eq 'true') {'<-- worker VAI reconciliar telemetria de PROD a cada hora'})" 'Yellow'
    Log "======================================================" 'Yellow'
    if (-not $Yes) {
        $c = Read-Host "Confirme digitando PROD (Ctrl+C pra cancelar)"
        if ($c -ne 'PROD') { Fail "cancelado." }
    }
}

# ---- 1) Java 17+ ------------------------------------------------------------
function Test-JavaVersion {
    param([string]$Path)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = ""
    try { $out = (& $Path -version 2>&1 | ForEach-Object { "$_" }) -join "`n" } catch { $out = "" }
    finally { $ErrorActionPreference = $prev }
    if ($out -match 'version "(\d+)\.?(\d*)') {
        $m1 = [int]$matches[1]; $m2 = if ($matches[2]) { [int]$matches[2] } else { 0 }
        $major = if ($m1 -eq 1) { $m2 } else { $m1 }
        return @{ Major = $major; Raw = $out.Trim() }
    }
    return @{ Major = 0; Raw = $out }
}
function Find-Java {
    $j = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($j -and (Test-JavaVersion -Path $j.Path).Major -ge 17) { Log "Java no PATH: $($j.Path)"; return $j.Path }
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
        if ($found -and (Test-JavaVersion -Path $found.FullName).Major -ge 17) { Log "Java em: $($found.FullName)"; return $found.FullName }
    }
    Log "Java >=17 nao encontrado. Baixando JRE 21 portable (75MB)..."
    $jreZip = Join-Path $ToolsDir 'jre21.zip'; $jreDir = Join-Path $ToolsDir 'jre21'
    if (-not (Test-Path "$jreDir\*\bin\java.exe")) {
        if (-not (Test-Path $jreZip)) { Invoke-WebRequest -Uri $JreUrl -OutFile $jreZip -UseBasicParsing }
        Expand-Archive -Path $jreZip -DestinationPath $jreDir -Force; Remove-Item $jreZip -Force
    }
    $java = Get-ChildItem -Path $jreDir -Filter "java.exe" -Recurse | Select-Object -First 1
    if (-not $java) { Fail "JRE extraida mas java.exe nao achado" }
    return $java.FullName
}
$Java = Find-Java
Log "  $((Test-JavaVersion -Path $Java).Raw -replace "`n", ' | ')"

# ---- 1.5) parar instancia anterior (senao o java antigo segura o .jar e o download falha) ---
Log "Parando instancia anterior (java + portas $AppPort/$LocalDbPort)..."
Get-NetTCPConnection -LocalPort $AppPort, $LocalDbPort -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object { try { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue } catch {} }
$JarLocal = Join-Path $ToolsDir "ems-gap-filler-main.jar"
Start-Sleep -Milliseconds 500
# se o jar antigo ainda esta travado por um java -jar nosso, mata todos os java e remove
if (Test-Path $JarLocal) {
    $locked = $false
    try { Rename-Item $JarLocal "$JarLocal.old" -Force -ErrorAction Stop; Rename-Item "$JarLocal.old" $JarLocal -Force }
    catch { $locked = $true }
    if ($locked) {
        Log "  jar travado por outro processo -> matando processos java" 'Yellow'
        Get-Process java -ErrorAction SilentlyContinue | ForEach-Object { try { Stop-Process -Id $_.Id -Force } catch {} }
        Start-Sleep -Seconds 1
    }
    Remove-Item $JarLocal -Force -ErrorAction SilentlyContinue
}

# ---- 2) JAR: -JarUrl (download direto) OU artefato do ultimo build de main ---
if ($JarUrl) {
    Log "Baixando JAR direto de: $JarUrl  (override -JarUrl, ignora o CI)"
    Invoke-WebRequest -Uri $JarUrl -Headers @{'PRIVATE-TOKEN'=$GitlabToken} -OutFile $JarLocal -UseBasicParsing
    if (-not (Test-Path $JarLocal) -or (Get-Item $JarLocal).Length -lt 1MB) { Fail "JAR baixado de -JarUrl invalido (<1MB)" }
    Log "JAR = $JarLocal ($([Math]::Round((Get-Item $JarLocal).Length / 1MB, 1)) MB) [-JarUrl]"
} else {
    $ZipLocal = Join-Path $ToolsDir "artifacts-$ts.zip"
    $ExtractDir = Join-Path $ToolsDir "artifacts-$ts"
    Log "Baixando artefato do ultimo `test` em main (~32MB)..."
    Invoke-WebRequest -Uri $JarZipUrl -Headers @{'PRIVATE-TOKEN'=$GitlabToken} -OutFile $ZipLocal -UseBasicParsing
    Expand-Archive -Path $ZipLocal -DestinationPath $ExtractDir -Force
    $jarFile = Get-ChildItem -Path $ExtractDir -Filter "*.jar" -Recurse | Where-Object { $_.Name -notmatch 'sources|javadoc' } | Select-Object -First 1
    if (-not $jarFile) { Fail "nao achei o .jar no artefato" }
    Copy-Item $jarFile.FullName $JarLocal -Force
    Remove-Item $ZipLocal, $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    Log "JAR = $JarLocal ($([Math]::Round((Get-Item $JarLocal).Length / 1MB, 1)) MB) [$($jarFile.Name)]"
}

# ---- 3) plink + tunnel SSH -> Postgres do ambiente -------------------------
$plink = (Get-Command plink.exe -ErrorAction SilentlyContinue).Path
if (-not $plink) { $plink = 'C:\Program Files\PuTTY\plink.exe' }
if (-not (Test-Path $plink)) { Fail "plink.exe nao achado (instale PuTTY)" }
$null = "y" | & $plink -ssh -batch -pw $SshPass "$SshUser@$SshHost" 'echo OK' 2>&1

Get-NetTCPConnection -LocalPort $LocalDbPort -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
Log "Tunnel ($Profile) 127.0.0.1:$LocalDbPort -> ${PgIp}:5432 ..."
$tunnelProc = Start-Process -FilePath $plink -ArgumentList @('-ssh','-batch','-N','-pw',$SshPass,'-L',"${LocalDbPort}:${PgIp}:5432","$SshUser@$SshHost") -WindowStyle Hidden -PassThru
Log "tunnel PID=$($tunnelProc.Id)"
$ok = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-NetConnection -ComputerName 127.0.0.1 -Port $LocalDbPort -InformationLevel Quiet -WarningAction SilentlyContinue) { $ok = $true; break }
}
if (-not $ok) { try { Stop-Process -Id $tunnelProc.Id -Force } catch {}; Fail "tunnel nao subiu em 10s" }
Log "tunnel OK"

# ---- 4) Spring Boot ---------------------------------------------------------
$env:SPRING_PROFILES_ACTIVE       = $Profile
$env:DB_URL                       = "jdbc:postgresql://127.0.0.1:$LocalDbPort/$DbName"
$env:DB_USER                      = $DbUser
$env:DB_PASSWORD                  = $DbPass
$env:SERVER_PORT                  = "$AppPort"
$env:SERVER_ADDRESS               = '127.0.0.1'
$env:GAPFILLER_RECENT_ENABLED     = $CronEnabled
$env:GAPFILLER_HISTORICAL_ENABLED = $HistoricalEnabled
$env:TZ                           = 'America/Manaus'

Get-NetTCPConnection -LocalPort $AppPort -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
Log "Iniciando ems-gap-filler (porta $AppPort, profile=$Profile, recent_cron=$CronEnabled, historical_queue=$HistoricalEnabled, dryRun=$DryRun)..."
$appProc = Start-Process -FilePath $Java -ArgumentList @('-Duser.timezone=America/Manaus','-Xms256m','-Xmx512m','-jar',$JarLocal) `
    -RedirectStandardOutput $AppLog -RedirectStandardError "$AppLog.err" -WindowStyle Hidden -PassThru
Log "app PID=$($appProc.Id), aguardando /actuator/health UP (timeout 90s)..."
$healthy = $false; $lastErr = ""
for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep -Seconds 2
    try {
        $h = Invoke-RestMethod -Uri "http://127.0.0.1:$AppPort/actuator/health" -TimeoutSec 3 -ErrorAction Stop
        if ($h.status -eq 'UP') { $healthy = $true; break }
        $lastErr = "status=$($h.status)"
    } catch { $lastErr = $_.Exception.Message }
}
if (-not $healthy) {
    Log "app NAO ficou UP. ultimo erro: $lastErr" 'Yellow'
    Get-Content $AppLog -Tail 50 -ErrorAction SilentlyContinue | ForEach-Object { Log "  $_" }
} else {
    Log "app UP (Flyway migrou, conexao com $Profile OK)" 'Green'
    if ($DryRun) {
        $sweep = if ($CronEnabled -eq 'true') { 'ON' } else { 'OFF' }
        Log "DryRun: smoke test PULADO. GAPFILLER_HISTORICAL_ENABLED=false (fila nao drena), sweep RECENT=$sweep. O worker NAO tocou em telemetria - so validou boot+Flyway+API+report." 'Yellow'
    } elseif ($Env -eq 'hom') {
        Log "Smoke test (HOM): POST /api/v1/backfill (sensor 30, janela 1h)..."
        $now = Get-Date
        $body = @{ sensorIds = @(30); windowStart = $now.AddHours(-2).ToString("yyyy-MM-ddTHH:mm:ss"); windowEnd = $now.AddHours(-1).ToString("yyyy-MM-ddTHH:mm:ss") } | ConvertTo-Json
        try {
            $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$AppPort/api/v1/backfill" -Method Post -Body $body -ContentType "application/json" -Headers @{'X-Requested-By'='deploy-script'} -TimeoutSec 10
            Log "submit OK -> id=$($resp.id) status=$($resp.status)"
            for ($i = 0; $i -lt 30; $i++) {
                Start-Sleep -Seconds 10
                $get = Invoke-RestMethod -Uri "http://127.0.0.1:$AppPort/api/v1/backfill/$($resp.id)" -TimeoutSec 5
                Log "  poll: status=$($get.status) inserted=$($get.inserted) skipped=$($get.skipped)"
                if ($get.status -in 'COMPLETED','FAILED','CANCELLED') { break }
            }
        } catch { Log "smoke test: $($_.Exception.Message)" 'Yellow' }
    } else {
        Log "PRD: smoke test automatico DESLIGADO (nao mexer em telemetria de PROD sem revisar)." 'Yellow'
        Log "Pra rodar um backfill manual quando estiver confiante:" 'Yellow'
        Log "  curl -sX POST http://127.0.0.1:$AppPort/api/v1/backfill -H 'Content-Type: application/json' -H 'X-Requested-By: matheus' -d '{\"sensorIds\":[30],\"windowStart\":\"2026-05-08T00:00:00\",\"windowEnd\":\"2026-05-08T01:00:00\"}'" 'Yellow'
    }
}

# ---- 4.5) Relatorio pos-run (raio-x do que o worker fez no banco) -----------
# GET /api/v1/report -> snapshot read-only: migrations aplicadas, ftp_source,
# backfill_request (status/inserted/skipped/erro), gap_log (anomalias tratadas),
# sanity da telemetria. Salva report-*.json + RESUMO-*.txt (entram no zip).
$ReportJson = Join-Path $LogsDir "report-$Env-$ts.json"
$ResumoTxt  = Join-Path $LogsDir "RESUMO-$Env-$ts.txt"
if ($healthy) {
    Log "Relatorio pos-run: GET /api/v1/report ..."
    try {
        $rep = Invoke-RestMethod -Uri "http://127.0.0.1:$AppPort/api/v1/report?limit=2000" -TimeoutSec 20 -ErrorAction Stop
        WriteUtf8NoBom $ReportJson ($rep | ConvertTo-Json -Depth 8)
        $L = New-Object System.Collections.Generic.List[string]
        $L.Add("EMS GAP-FILLER - RESUMO DO RUN ($Profile)  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $L.Add("==================================================================")
        $L.Add("profiles ativos : " + ($rep.profiles -join ', '))
        $fw = @($rep.flyway)
        $L.Add("migrations Flyway: " + $fw.Count + "  -> " + (($fw | ForEach-Object { 'V' + $_.version }) -join ' '))
        $L.Add("ems.ftp_source  : " + $rep.ftpSource.count + " medidores")
        $L.Add("")
        $L.Add("-- backfill_request (pedidos HISTORICAL) --")
        $bfs = @($rep.backfillRequests)
        if ($bfs.Count -eq 0) { $L.Add("  (nenhum)") }
        foreach ($b in $bfs) {
            $L.Add(("  {0}  status={1}  janela=[{2} .. {3}]  inserted={4} skipped={5}  por={6}" -f `
                $b.bfr_id, $b.bfr_status, $b.bfr_window_start, $b.bfr_window_end, $b.bfr_inserted, $b.bfr_skipped, $b.bfr_requested_by))
            if ($b.bfr_error) { $L.Add("      erro: " + $b.bfr_error) }
        }
        $L.Add("")
        $L.Add("-- gap_log (gaps/anomalias tratados) --  total=" + $rep.gapLog.count)
        foreach ($s in @($rep.gapLog.byStatus))     { $L.Add(("  status={0}: n={1} inserted={2} skipped={3}" -f $s.gpl_status, $s.n, $s.inserted, $s.skipped)) }
        foreach ($s in @($rep.gapLog.byModeSensor)) { $L.Add(("  {0} sensor {1}: n={2} inserted={3} skipped={4}" -f $s.gpl_mode, $s.gpl_sensor, $s.n, $s.inserted, $s.skipped)) }
        $L.Add("")
        $L.Add("-- telemetria (sanity) --")
        $tm = $rep.telemetry.mqttSensorDataRecord
        if ($tm.exists) { $L.Add("  mqtt.sensordatarecord: EXISTE  rows=" + $tm.rowCount + "  active=" + $tm.activeRowCount + "  ultima=" + $tm.latestCreation) }
        else            { $L.Add("  mqtt.sensordatarecord: NAO EXISTE (HOM vazio) -> reconcile vira no-op aqui") }
        $te = $rep.telemetry.emsSensor
        if ($te.exists) { $L.Add("  ems.sensor: EXISTE  count=" + $te.count) } else { $L.Add("  ems.sensor: NAO EXISTE (V76 virou no-op)") }
        $L.Add("  FK fk_ftp_source_sensor presente: " + $rep.telemetry.ftpSourceFk.fk_ftp_source_sensor_present)
        $L.Add("")
        $L.Add("(detalhes completos em report-$Env-$ts.json)")
        WriteUtf8NoBom $ResumoTxt ($L -join "`r`n")
        Log "relatorio salvo: $ReportJson  +  $ResumoTxt" 'Green'
        Get-Content $ResumoTxt | ForEach-Object { Log "  $_" }
    } catch {
        Log "relatorio pos-run falhou: $($_.Exception.Message)" 'Yellow'
        WriteUtf8NoBom $ResumoTxt "report endpoint indisponivel: $($_.Exception.Message)"
    }
}

# ---- 5) Empacotar logs -----------------------------------------------------
$zipPath = Join-Path $env:USERPROFILE "Downloads\ems-gap-filler-deploy-$Env-$ts.zip"
$tmpStage = Join-Path $env:TEMP "stage-$ts"
New-Item -ItemType Directory -Force -Path $tmpStage | Out-Null
Copy-Item $RunLog $tmpStage -Force
Copy-Item $AppLog $tmpStage -Force -ErrorAction SilentlyContinue
Copy-Item "$AppLog.err" $tmpStage -Force -ErrorAction SilentlyContinue
Copy-Item $ReportJson $tmpStage -Force -ErrorAction SilentlyContinue
Copy-Item $ResumoTxt  $tmpStage -Force -ErrorAction SilentlyContinue
Compress-Archive -Path "$tmpStage\*" -DestinationPath $zipPath -Force
Remove-Item $tmpStage -Recurse -Force

Log "===================================================="
Log "  DEPLOY $Profile  (RODANDO NA PONTE - processo bare java, nao container)"
Log "  app PID:    $($appProc.Id)"
Log "  tunnel PID: $($tunnelProc.Id)"
Log "  cron:       $CronEnabled"
Log "  health:     http://127.0.0.1:$AppPort/actuator/health"
Log "  report:     http://127.0.0.1:$AppPort/api/v1/report"
Log "  log app:    $AppLog"
Log "  resumo:     $ResumoTxt"
Log "  zip:        $zipPath  (contem deploy log + app log + report.json + RESUMO.txt)"
Log "===================================================="
Log "Pra parar:" 'Yellow'
Log "  Stop-Process -Id $($appProc.Id) -Force ; Stop-Process -Id $($tunnelProc.Id) -Force" 'Yellow'
Log "Pra deploy PERMANENTE (container, auto-restart): rodar scripts/deploy-server.sh no servidor (precisa admin com docker)." 'Yellow'
Log ""
Log "MANDA $zipPath PRO CHAT" 'Green'
