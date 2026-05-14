# =============================================================================
# EMS-DB-TUNNEL.PS1 - SSH tunnel + Npgsql + run Q01..Q23 read-only
#
# CAMINHO DESCOBERTO (discovery v2):
#   - Postgres roda em containers Docker, alcancavel via 172.25.0.3:5432 (PRD)
#     e 172.25.0.7:5432 (HOM) atraves da rede docker_gwbridge do servidor
#   - cesar.silva tem SSH (sem privilegio), e SSH -L resolve sozinho o forward
#
# O QUE FAZ (READ-ONLY):
#   1) Baixa Npgsql 4.0.13 (driver .NET puro pra PS 5.1) - cached em Downloads\nupkg
#   2) Acha plink.exe (PuTTY ja instalado na ponte)
#   3) Inicia plink -N -L 15432:<ip_pg>:5432 cesar.silva@150.150.251.112 em background
#   4) Aguarda 127.0.0.1:15432 abrir
#   5) Tenta conectar com PRD pass; se falhar, tenta HOM pass; se falhar tenta IP secundario
#   6) Baixa ems-schema-dump.sql do GitLab, splita em Q##.sql
#   7) Executa cada Q via Npgsql (NpgsqlCommand + NpgsqlDataReader), exporta TSV
#   8) Mata plink, zipa output em Downloads\ems-db\<ts>\result.zip
# =============================================================================

$ErrorActionPreference = 'Stop'

# ---- CONFIG -----------------------------------------------------------------
$SshHost      = '150.150.251.112'
$SshUser      = 'cesar.silva'
$SshPass      = ")HV2//x'md}w4;R"
$LocalPort    = 15432
$PgCandidates = @(
    @{ IP='172.25.0.7'; Hint='PRD-likely' }
    @{ IP='172.25.0.3'; Hint='HOM-vazio (ja confirmado em run anterior)' }
)
$DbUser       = 'ems_user'
$DbName       = 'energymanagementsystem'
$DbPasswords  = @(
    @{ Pass='Glimmer7-Enroll-Bloomers';  Env='PRD' }
    @{ Pass='Sureness-Stencil9-Flap';    Env='HOM' }
)
$GitlabToken  = 'glpat-1KBJACUAPmj8f3V1ivdBLmM6MQpvOjEKdTptbDV2aQ8.01.1706sk2g4'
$ProjectId    = 81970992
$SqlPathInRepo= 'scripts/ems-preadr-checks.sql'
# -----------------------------------------------------------------------------

$ts     = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir = Join-Path $env:USERPROFILE "Downloads\ems-preadr\$ts"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$LogFile = Join-Path $OutDir '00-summary.log'

function Log {
    param([string]$msg, [string]$color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

Log "OutDir: $OutDir"

# ---- 1) plink ---------------------------------------------------------------
$plink = (Get-Command plink.exe -ErrorAction SilentlyContinue).Path
if (-not $plink) { $plink = 'C:\Program Files\PuTTY\plink.exe' }
if (-not (Test-Path $plink)) { Log "ERRO: plink nao achado" 'Red'; exit 1 }
Log "plink: $plink"

# ---- 2) Npgsql via NuGet ----------------------------------------------------
$nupkgDir = Join-Path $env:USERPROFILE 'Downloads\nupkg'
New-Item -ItemType Directory -Force -Path $nupkgDir | Out-Null

function Get-NuGet {
    param([string]$Pkg, [string]$Ver)
    $nupkgPath = Join-Path $nupkgDir "$Pkg.$Ver.nupkg"
    $extractDir = Join-Path $nupkgDir "$Pkg.$Ver"
    if (-not (Test-Path $extractDir)) {
        if (-not (Test-Path $nupkgPath)) {
            $url = "https://www.nuget.org/api/v2/package/$Pkg/$Ver"
            Log "Baixando $Pkg $Ver..."
            Invoke-WebRequest -Uri $url -OutFile $nupkgPath -UseBasicParsing
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($nupkgPath, $extractDir)
    }
    return $extractDir
}

# Carrega Npgsql 4.0.13 + todas as deps numa pasta unica (merged/) -
# Add-Type vai resolver as dependencias automaticamente do mesmo diretorio.

function Find-NetFxDll {
    param([string]$ExtractDir, [string]$DllName)
    $prefs = @('net47','net46','net45','netstandard2.0','netstandard1.6','netstandard1.3','netstandard1.1')
    foreach ($p in $prefs) {
        $candidate = Get-ChildItem -Path "$ExtractDir\lib\$p" -Filter $DllName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    $any = Get-ChildItem -Path $ExtractDir -Recurse -Filter $DllName -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\ref\\' } | Select-Object -First 1
    if ($any) { return $any.FullName }
    return $null
}

$deps = @(
    @{ Pkg='System.Runtime.CompilerServices.Unsafe'; Ver='4.7.1'; Dll='System.Runtime.CompilerServices.Unsafe.dll' }
    @{ Pkg='System.Numerics.Vectors';                Ver='4.5.0'; Dll='System.Numerics.Vectors.dll' }
    @{ Pkg='System.Buffers';                         Ver='4.5.1'; Dll='System.Buffers.dll' }
    @{ Pkg='System.Memory';                          Ver='4.5.4'; Dll='System.Memory.dll' }
    @{ Pkg='System.Threading.Tasks.Extensions';      Ver='4.5.4'; Dll='System.Threading.Tasks.Extensions.dll' }
    @{ Pkg='System.ValueTuple';                      Ver='4.5.0'; Dll='System.ValueTuple.dll' }
)

# Pasta merged: copia todas as deps + Npgsql.dll juntas (ano-novo a cada run)
$mergedDir = Join-Path $nupkgDir "merged-$ts"
New-Item -ItemType Directory -Force -Path $mergedDir | Out-Null

foreach ($d in $deps) {
    $dir = Get-NuGet $d.Pkg $d.Ver
    $dll = Find-NetFxDll -ExtractDir $dir -DllName $d.Dll
    if ($dll) {
        Copy-Item -Path $dll -Destination $mergedDir -Force
        Log "  copy $($d.Pkg) -> merged"
    } else {
        Log "warn: nao encontrei $($d.Dll) em $dir" 'Yellow'
    }
}

$npgsqlDir = Get-NuGet 'Npgsql' '4.0.13'
$npgsqlSrc = Find-NetFxDll -ExtractDir $npgsqlDir -DllName 'Npgsql.dll'
if (-not $npgsqlSrc) { Log "ERRO: Npgsql.dll nao achada" 'Red'; exit 1 }
Copy-Item -Path $npgsqlSrc -Destination $mergedDir -Force
$npgsqlMerged = Join-Path $mergedDir 'Npgsql.dll'
Log "Npgsql merged: $npgsqlMerged"

# AssemblyResolve fallback caso CLR nao ache deps automaticamente
$null = [AppDomain]::CurrentDomain.add_AssemblyResolve({
    param($sender, $e)
    $name = ($e.Name -split ',')[0].Trim()
    $dir  = [AppDomain]::CurrentDomain.GetData('MergedDir')
    if (-not $dir) { return $null }
    $candidate = Join-Path $dir "$name.dll"
    if (Test-Path $candidate) {
        try { return [Reflection.Assembly]::LoadFrom($candidate) } catch {}
    }
    return $null
})
[AppDomain]::CurrentDomain.SetData('MergedDir', $mergedDir)

try {
    Add-Type -Path $npgsqlMerged -ErrorAction Stop
    Log "Npgsql Add-Type OK"
} catch {
    Log "Add-Type falhou: $($_.Exception.Message). Fallback LoadFrom..." 'Yellow'
    [Reflection.Assembly]::LoadFrom($npgsqlMerged) | Out-Null
}

# Smoke test: criar NpgsqlConnection (sem abrir)
try {
    $smoke = New-Object Npgsql.NpgsqlConnection("Host=127.0.0.1;Port=1;Database=x;Username=x;Password=x")
    $smoke.Dispose()
    Log "Npgsql smoke OK"
} catch {
    Log "ERRO smoke test: $($_.Exception.Message)" 'Red'
    exit 1
}

# ---- 3) baixar SQL do GitLab -----------------------------------------------
$encPath = [uri]::EscapeDataString($SqlPathInRepo)
$SqlUrl  = "https://gitlab.com/api/v4/projects/$ProjectId/repository/files/$encPath/raw?ref=main"
$SqlLocal = Join-Path $OutDir 'ems-schema-dump.sql'
Log "Baixando SQL..."
Invoke-WebRequest -Uri $SqlUrl -Headers @{'PRIVATE-TOKEN'=$GitlabToken} `
    -OutFile $SqlLocal -UseBasicParsing
Log "SQL: $((Get-Item $SqlLocal).Length) bytes"

# ---- 4) splita SQL local por marcador "-- =========== Q##" -----------------
$sqlText = Get-Content $SqlLocal -Raw
$blocks = [System.Collections.ArrayList]::new()
$current = $null
$lines = $sqlText -split "`r?`n"
foreach ($l in $lines) {
    if ($l -match '^-- =+\s*(Q\d+)\b') {
        if ($current) { [void]$blocks.Add($current) }
        $current = @{ Id = $matches[1]; Sql = New-Object System.Text.StringBuilder }
    }
    if ($current) { [void]$current.Sql.AppendLine($l) }
}
if ($current) { [void]$blocks.Add($current) }
Log "SQL splitado em $($blocks.Count) queries"

# ---- 5) auto-aceita host key SSH -------------------------------------------
Log "Aceitando host key SSH..."
$null = "y" | & $plink -ssh -batch -pw $SshPass "$SshUser@$SshHost" 'echo OK' 2>&1

# ---- 6) abre tunnel + tenta conectar ---------------------------------------
function Start-Tunnel {
    param([string]$RemoteIp)
    $args = @('-ssh','-batch','-N','-pw',$SshPass,
              '-L', "${LocalPort}:${RemoteIp}:5432",
              "$SshUser@$SshHost")
    $proc = Start-Process -FilePath $plink -ArgumentList $args `
        -WindowStyle Hidden -PassThru
    return $proc
}

function Wait-Port {
    param([int]$Port, [int]$TimeoutSec = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $tcp = Test-NetConnection -ComputerName 127.0.0.1 -Port $Port `
            -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($tcp) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Test-Db {
    param([string]$Pass)
    $cs = "Host=127.0.0.1;Port=$LocalPort;Database=$DbName;Username=$DbUser;Password=$Pass;Timeout=5;CommandTimeout=30;SSL Mode=Prefer;Trust Server Certificate=true"
    $conn = New-Object Npgsql.NpgsqlConnection($cs)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT current_database(), version()"
        $rdr = $cmd.ExecuteReader()
        $null = $rdr.Read()
        $info = "$($rdr.GetString(0)) | $($rdr.GetString(1))"
        $rdr.Close()
        $conn.Close()
        return @{ OK=$true; Info=$info; ConnString=$cs }
    } catch {
        try { $conn.Close() } catch {}
        return @{ OK=$false; Error=$_.Exception.Message; ConnString=$cs }
    }
}

$activeConn = $null
$activeProc = $null

foreach ($cand in $PgCandidates) {
    Log "Tentando tunnel para $($cand.IP):5432 ($($cand.Hint))..."
    $proc = Start-Tunnel $cand.IP
    Start-Sleep -Seconds 2
    if (-not (Wait-Port -Port $LocalPort -TimeoutSec 8)) {
        Log "Tunnel para $($cand.IP) nao subiu" 'Yellow'
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        continue
    }
    Log "Tunnel UP em 127.0.0.1:$LocalPort -> $($cand.IP):5432"

    foreach ($cred in $DbPasswords) {
        Log "Tentando auth $($cred.Env)..."
        $r = Test-Db -Pass $cred.Pass
        if ($r.OK) {
            Log "AUTH OK [$($cred.Env)] -> $($r.Info)" 'Green'
            $activeConn = @{
                ConnString = $r.ConnString
                Env        = $cred.Env
                IP         = $cand.IP
                Info       = $r.Info
            }
            $activeProc = $proc
            break
        } else {
            Log "auth $($cred.Env) falhou: $($r.Error)" 'Yellow'
        }
    }

    if ($activeConn) { break }
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 1
}

if (-not $activeConn) {
    Log "ERRO: nao consegui autenticar em nenhum candidato" 'Red'
    exit 2
}

Log "USANDO: $($activeConn.IP) [$($activeConn.Env)]" 'Green'

# ---- 7) executa Q##.sql -----------------------------------------------------
$conn = New-Object Npgsql.NpgsqlConnection($activeConn.ConnString)
$conn.Open()

foreach ($b in $blocks) {
    $qid = $b.Id
    $sql = $b.Sql.ToString()
    $tsvPath = Join-Path $OutDir "$qid.tsv"
    $errPath = Join-Path $OutDir "$qid.err"
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $sql
        $cmd.CommandTimeout = 120
        $rdr = $cmd.ExecuteReader()

        $sw = New-Object System.IO.StreamWriter($tsvPath, $false, [System.Text.UTF8Encoding]::new($false))
        $resultsetIdx = 0
        do {
            if ($resultsetIdx -gt 0) { $sw.WriteLine("--- resultset $resultsetIdx ---") }
            $cols = @()
            for ($i = 0; $i -lt $rdr.FieldCount; $i++) { $cols += $rdr.GetName($i) }
            $sw.WriteLine(($cols -join "`t"))
            while ($rdr.Read()) {
                $row = @()
                for ($i = 0; $i -lt $rdr.FieldCount; $i++) {
                    if ($rdr.IsDBNull($i)) {
                        $row += ''
                    } else {
                        $v = $rdr.GetValue($i).ToString().Replace("`t",' ').Replace("`n",' ').Replace("`r",'')
                        $row += $v
                    }
                }
                $sw.WriteLine(($row -join "`t"))
            }
            $resultsetIdx++
        } while ($rdr.NextResult())
        $rdr.Close()
        $sw.Close()
        $bytes = (Get-Item $tsvPath).Length
        Log "[$qid] OK $bytes B"
    } catch {
        $msg = $_.Exception.Message
        Set-Content -Path $errPath -Value $msg -Encoding UTF8
        Log "[$qid] ERRO: $msg" 'Yellow'
    }
}

$conn.Close()

# ---- 8) mata tunnel ---------------------------------------------------------
try {
    Stop-Process -Id $activeProc.Id -Force -ErrorAction SilentlyContinue
    Log "Tunnel encerrado"
} catch {}

# ---- 9) zipa --------------------------------------------------------------
$zipPath = Join-Path $env:USERPROFILE "Downloads\ems-preadr-$ts.zip"
Compress-Archive -Path "$OutDir\*" -DestinationPath $zipPath -Force
Log "Zip: $zipPath" 'Green'

Write-Host ""
Write-Host "===== RESULTADO =====" -ForegroundColor Cyan
Write-Host "Ambiente: $($activeConn.Env)" -ForegroundColor Cyan
Write-Host "IP postgres: $($activeConn.IP)" -ForegroundColor Cyan
Write-Host "Banco info: $($activeConn.Info)" -ForegroundColor Cyan
Write-Host ""
Write-Host "Saida: $OutDir" -ForegroundColor Green
Write-Host "Zip:   $zipPath" -ForegroundColor Green
Write-Host ""
Write-Host "Manda o zip pro Claude." -ForegroundColor Green
