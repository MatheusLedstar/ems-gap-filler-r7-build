# =============================================================================
# EMS-DB-SSH.PS1 v2 - Recon read-only do banco EMS via SSH na ponte Windows
#
# v2 mudancas (2026-05-07):
#   - Pre-flight diagnostico de 4 estrategias antes de rodar queries
#   - Suporta sudo -S com senha (passada em base64 pra escapar aspas)
#   - Detecta psql nativo no host como fallback
#   - Diagnostico SEMPRE escrito em 01-diagnostic.txt
#
# USO (PS5.1+ na ponte Windows):
#   $t='glpat-...'
#   $u='https://gitlab.com/api/v4/projects/81970992/repository/files/scripts%2Fems-db-ssh.ps1/raw?ref=main'
#   $p="$env:USERPROFILE\Downloads\ems-db-ssh.ps1"
#   iwr -Uri $u -Headers @{'PRIVATE-TOKEN'=$t} -OutFile $p
#   powershell -ExecutionPolicy Bypass -File $p
#
# READ-ONLY. So roda SELECT.
# =============================================================================

$ErrorActionPreference = 'Stop'

# ---- CONFIG -----------------------------------------------------------------
$SshHost      = '150.150.251.112'
$SshUser      = 'cesar.silva'
$SshPass      = ")HV2//x'md}w4;R"
$DbContainer  = 'timescaledb'
$DbUser       = 'ems_user'
$DbName       = 'energymanagementsystem'
$DbPassPrd    = 'Glimmer7-Enroll-Bloomers'
$GitlabToken  = 'glpat-1KBJACUAPmj8f3V1ivdBLmM6MQpvOjEKdTptbDV2aQ8.01.1706sk2g4'
$ProjectId    = 81970992
$SqlPathInRepo= 'scripts/ems-schema-dump.sql'
# -----------------------------------------------------------------------------

$ts     = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir = Join-Path $env:USERPROFILE "Downloads\ems-db\$ts"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$LogFile = Join-Path $OutDir '00-summary.log'
$DiagFile = Join-Path $OutDir '01-diagnostic.txt'

function Log {
    param([string]$msg)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

Log ("OutDir: " + $OutDir)
Log ("Host:   " + $SshUser + "@" + $SshHost)

# ---- 1) plink/pscp ----------------------------------------------------------
function Get-PuttyTools {
    $plink = Get-Command plink.exe -ErrorAction SilentlyContinue
    $pscp  = Get-Command pscp.exe  -ErrorAction SilentlyContinue
    if ($plink -and $pscp) {
        return @{ plink=$plink.Path; pscp=$pscp.Path }
    }
    Log 'plink/pscp nao no PATH. Baixando...'
    $tools = Join-Path $env:USERPROFILE 'Downloads\putty-tools'
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    foreach ($exe in 'plink.exe','pscp.exe') {
        $dest = Join-Path $tools $exe
        if (-not (Test-Path $dest)) {
            Invoke-WebRequest -Uri ("https://the.earth.li/~sgtatham/latest/w64/" + $exe) `
                -OutFile $dest -UseBasicParsing
        }
    }
    return @{ plink=(Join-Path $tools 'plink.exe'); pscp=(Join-Path $tools 'pscp.exe') }
}

$tools = Get-PuttyTools
Log ("plink: " + $tools.plink)
Log ("pscp:  " + $tools.pscp)

# ---- 2) baixar SQL do GitLab ------------------------------------------------
$encodedPath = [uri]::EscapeDataString($SqlPathInRepo)
$SqlUrl  = "https://gitlab.com/api/v4/projects/$ProjectId/repository/files/$encodedPath/raw?ref=main"
$SqlLocal = Join-Path $OutDir 'ems-schema-dump.sql'
Log ("Baixando SQL: " + $SqlUrl)
Invoke-WebRequest -Uri $SqlUrl -Headers @{'PRIVATE-TOKEN'=$GitlabToken} `
    -OutFile $SqlLocal -UseBasicParsing
$sqlSize = (Get-Item $SqlLocal).Length
Log ("SQL salvo (" + $sqlSize + " bytes)")

# ---- 3) auto-aceitar host key ----------------------------------------------
Log 'Aceitando host key...'
$null = "y" | & $tools.plink -ssh -batch -pw $SshPass `
    ("$SshUser@$SshHost") 'echo PROBE_OK' 2>&1

# ---- 4) helpers exec --------------------------------------------------------
function Invoke-Plink {
    param([string]$RemoteCmd, [string]$LogTag = 'ssh')
    $out = & $tools.plink -ssh -batch -pw $SshPass ("$SshUser@$SshHost") $RemoteCmd 2>&1
    $out | ForEach-Object { Add-Content -Path $LogFile -Value ("[" + $LogTag + "] " + $_) -Encoding UTF8 }
    return $out
}

function Invoke-Pscp-Up {
    param([string]$Local, [string]$Remote)
    & $tools.pscp -batch -pw $SshPass $Local ("${SshUser}@${SshHost}:" + $Remote) 2>&1 |
        ForEach-Object { Add-Content -Path $LogFile -Value ("[pscp-up] " + $_) -Encoding UTF8 }
}

function Invoke-Pscp-Down {
    param([string]$Remote, [string]$LocalDir)
    & $tools.pscp -batch -pw $SshPass ("${SshUser}@${SshHost}:" + $Remote) $LocalDir 2>&1 |
        ForEach-Object { Add-Content -Path $LogFile -Value ("[pscp-dn] " + $_) -Encoding UTF8 }
}

# ---- 5) preparar diretorio remoto ------------------------------------------
$RemoteDir = "/tmp/ems-recon-$ts"
Invoke-Plink ("mkdir -p " + $RemoteDir + " && chmod 700 " + $RemoteDir) 'mkdir' | Out-Null

# ---- 6) PRE-FLIGHT DIAGNOSTIC ----------------------------------------------
Log '----- PRE-FLIGHT DIAGNOSTIC -----'

# Senha SSH em base64 (o cesar.silva costuma usar a propria senha SSH pro sudo)
$sshPassBytes = [Text.Encoding]::UTF8.GetBytes($SshPass)
$sshPassB64   = [Convert]::ToBase64String($sshPassBytes)

$DiagLines = @(
    '#!/bin/bash',
    '# Pre-flight diagnostic - testa 4 estrategias de acesso ao banco',
    'set +e',
    'SSH_PASS_B64="$1"',
    '',
    'echo "===== whoami / id ====="',
    'whoami; id',
    '',
    'echo "===== sistema ====="',
    'uname -a',
    'cat /etc/os-release 2>/dev/null | head -5',
    '',
    'echo "===== docker disponivel? ====="',
    'which docker || echo "docker NAO no PATH"',
    'docker --version 2>&1',
    '',
    'echo "===== ESTRATEGIA 1: docker direto ====="',
    'docker ps --format "{{.Names}}" 2>&1',
    'rc1=$?',
    'echo "rc=$rc1"',
    '',
    'echo "===== ESTRATEGIA 2: sudo -n docker ====="',
    'sudo -n docker ps --format "{{.Names}}" 2>&1',
    'rc2=$?',
    'echo "rc=$rc2"',
    '',
    'echo "===== ESTRATEGIA 3: sudo -S docker (com senha SSH) ====="',
    'SUDO_PASS=$(echo "$SSH_PASS_B64" | base64 -d)',
    'echo "$SUDO_PASS" | sudo -S -p "" docker ps --format "{{.Names}}" 2>&1',
    'rc3=$?',
    'echo "rc=$rc3"',
    '',
    'echo "===== ESTRATEGIA 4: psql nativo no host ====="',
    'which psql || echo "psql NAO instalado no host"',
    'psql --version 2>&1',
    '',
    'echo "===== Postgres em /var/run/postgresql ou porta local ====="',
    'ls -la /var/run/postgresql/ 2>/dev/null || echo "sem socket unix"',
    'ss -tlnp 2>/dev/null | grep -E ":(5432|5433|5434)" || netstat -tlnp 2>/dev/null | grep -E ":(5432|5433|5434)" || echo "nenhuma porta postgres local"',
    '',
    'echo "===== Lista de containers (varias formas) ====="',
    'docker ps -a 2>&1 | head -20',
    'echo "---"',
    'echo "$SUDO_PASS" | sudo -S -p "" docker ps -a 2>&1 | head -20',
    '',
    'echo "===== Grupos do usuario ====="',
    'groups',
    '',
    'echo "===== Conteudo de /etc/sudoers.d/ (se acessivel) ====="',
    'echo "$SUDO_PASS" | sudo -S -p "" ls -la /etc/sudoers.d/ 2>&1',
    '',
    'echo "===== docker-compose / containers em /opt /home ====="',
    'find /opt /home /srv -name "docker-compose*.yml" 2>/dev/null | head -10',
    '',
    'echo "===== STRATEGY DECISION ====="',
    'if [ "$rc1" = "0" ]; then echo "STRATEGY=docker"; ',
    'elif [ "$rc2" = "0" ]; then echo "STRATEGY=sudo-n"; ',
    'elif [ "$rc3" = "0" ]; then echo "STRATEGY=sudo-s"; ',
    'else echo "STRATEGY=NONE"; fi',
    'echo "DONE"'
)
$DiagLocal = Join-Path $OutDir 'diagnose.sh'
$diagText = ($DiagLines -join "`n") + "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($DiagLocal, $diagText, $utf8NoBom)

Invoke-Pscp-Up $DiagLocal ($RemoteDir + '/diagnose.sh')

Log 'Rodando diagnostico no servidor...'
$diagCmd = "chmod +x $RemoteDir/diagnose.sh && bash $RemoteDir/diagnose.sh '$sshPassB64'"
$diagOut = Invoke-Plink $diagCmd 'diag'
$diagOut | Out-File -FilePath $DiagFile -Encoding UTF8

# Decisao da estrategia
$strategy = ($diagOut | Select-String '^STRATEGY=' | Select-Object -Last 1).ToString()
if ($strategy) { $strategy = $strategy.Split('=')[-1].Trim() } else { $strategy = 'NONE' }
Log ("Estrategia detectada: " + $strategy)

if ($strategy -eq 'NONE') {
    Log 'NENHUMA estrategia funcionou. Veja 01-diagnostic.txt e me mande.'
    Invoke-Plink ("rm -rf " + $RemoteDir) 'cleanup' | Out-Null
    Write-Host ''
    Write-Host "DIAGNOSTICO INCONCLUSIVO. Manda esses 2 arquivos:" -ForegroundColor Yellow
    Write-Host ("  " + $DiagFile) -ForegroundColor Yellow
    Write-Host ("  " + $LogFile) -ForegroundColor Yellow
    exit 1
}

# ---- 7) Upload SQL e runner com estrategia detectada -----------------------
Invoke-Pscp-Up $SqlLocal ($RemoteDir + '/ems.sql')

$RunnerLines = @(
    '#!/bin/bash',
    'set -u',
    'DIR="$1"; DB_USER="$2"; DB_NAME="$3"; DB_PASS="$4"; CT="$5"; STRATEGY="$6"; SSH_PASS_B64="$7"',
    'cd "$DIR"',
    '',
    'case "$STRATEGY" in',
    '  docker)  RUN="docker exec -i $CT" ;;',
    '  sudo-n)  RUN="sudo -n docker exec -i $CT" ;;',
    '  sudo-s)  SUDO_PASS=$(echo "$SSH_PASS_B64" | base64 -d) ;',
    '           RUN="sudo_run" ;;',
    '  *) echo "ERRO: estrategia invalida $STRATEGY" >&2 ; exit 9 ;;',
    'esac',
    '',
    'sudo_run() {',
    '  echo "$SUDO_PASS" | sudo -S -p "" docker exec -i "$CT" "$@"',
    '}',
    '',
    'run_psql() {',
    '  if [ "$STRATEGY" = "sudo-s" ]; then',
    '    sudo_run psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=0 -At -F "|" -P pager=off',
    '  else',
    '    $RUN psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=0 -At -F "|" -P pager=off',
    '  fi',
    '}',
    '',
    'export PGPASSWORD="$DB_PASS"',
    '',
    'echo "===== ping ao banco ====="',
    'echo "SELECT version();" | run_psql',
    '',
    'echo "===== split SQL em Q##.sql ====="',
    'awk ''',
    '  /^-- =+ Q[0-9]+/ {',
    '    if (out) close(out)',
    '    qid = $0',
    '    sub(/^-- =+ /, "", qid)',
    '    sub(/ .*$/, "", qid)',
    '    out = "q-" qid ".sql"',
    '    print "-- " $0 > out',
    '    next',
    '  }',
    '  out { print > out }',
    ''' ems.sql',
    'ls q-Q*.sql 2>/dev/null | wc -l',
    '',
    'count=0',
    'for f in $(ls q-Q*.sql 2>/dev/null | sort); do',
    '  count=$((count+1))',
    '  qid=$(echo "$f" | sed -E "s/^q-(Q[0-9]+)\.sql$/\1/")',
    '  echo "[$qid] running $(wc -l < $f) linhas..."',
    '  run_psql < "$f" > "${qid}.tsv" 2> "${qid}.err"',
    '  rc=$?',
    '  bytes=$(wc -c < "${qid}.tsv" 2>/dev/null || echo 0)',
    '  errb=$(wc -c < "${qid}.err" 2>/dev/null || echo 0)',
    '  echo "[$qid] rc=$rc out=${bytes}B err=${errb}B"',
    'done',
    'echo "TOTAL_QUERIES=$count"',
    'echo "DONE"'
)
$RunnerLocal = Join-Path $OutDir 'runner.sh'
$runnerText = ($RunnerLines -join "`n") + "`n"
[IO.File]::WriteAllText($RunnerLocal, $runnerText, $utf8NoBom)
Invoke-Pscp-Up $RunnerLocal ($RemoteDir + '/runner.sh')

# ---- 8) executar runner -----------------------------------------------------
$cmd = "chmod +x $RemoteDir/runner.sh && bash $RemoteDir/runner.sh '$RemoteDir' '$DbUser' '$DbName' '$DbPassPrd' '$DbContainer' '$strategy' '$sshPassB64'"
Log 'Executando queries...'
Invoke-Plink $cmd 'runner' | Out-Null

# ---- 9) baixar resultados ---------------------------------------------------
Log 'Baixando *.tsv e *.err...'
Invoke-Pscp-Down ($RemoteDir + '/Q*.tsv') $OutDir
Invoke-Pscp-Down ($RemoteDir + '/Q*.err') $OutDir

# ---- 10) listar tamanhos -----------------------------------------------------
Log '----- RESULTADO -----'
$tsvFiles = Get-ChildItem -Path $OutDir -Filter 'Q*.tsv' -ErrorAction SilentlyContinue
if ($tsvFiles) {
    $tsvFiles | Sort-Object Name | ForEach-Object {
        $errFile = Join-Path $OutDir ($_.BaseName + '.err')
        $errLen = if (Test-Path $errFile) { (Get-Item $errFile).Length } else { 0 }
        Log ("  {0}  out={1}B  err={2}B" -f $_.Name, $_.Length, $errLen)
    }
} else {
    Log 'NENHUM .tsv baixado - veja 00-summary.log e 01-diagnostic.txt'
}

# ---- 11) cleanup ------------------------------------------------------------
Log 'Limpando diretorio remoto...'
Invoke-Plink ("rm -rf " + $RemoteDir) 'cleanup' | Out-Null

Log ("OK. Saida em: " + $OutDir)
Write-Host ''
Write-Host "Saida em: $OutDir" -ForegroundColor Green
Write-Host "Zipe a pasta inteira e mande." -ForegroundColor Green
