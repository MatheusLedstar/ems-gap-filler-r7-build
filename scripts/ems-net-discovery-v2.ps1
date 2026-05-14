# =============================================================================
# EMS-NET-DISCOVERY-V2.PS1 - scan TCP 5432 em todas as subredes detectadas
#
# v1 mostrou: postgres roda nativo no host (UID 70, "TimescaleDB Background Worker"),
# nao em container. Mas TCP 5432 nao aparece em /proc/net/tcp listening, e o user
# cesar.silva nao tem permissao pra ler /var/run/postgresql/.
#
# v2 escaneia rapido todas as 5 redes docker reais detectadas (172.17, 172.19,
# 172.22, 172.23, 172.25) + verifica bind addresses do postgres via /proc/<pid>/net/tcp
# do processo postgres encontrado.
# =============================================================================

$ErrorActionPreference = 'Stop'

$SshHost = '150.150.251.112'
$SshUser = 'cesar.silva'
$SshPass = ")HV2//x'md}w4;R"

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir = Join-Path $env:USERPROFILE "Downloads\ems-netdisc\$ts-v2"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Report = Join-Path $OutDir 'report.txt'

$plink = (Get-Command plink.exe -ErrorAction SilentlyContinue).Path
if (-not $plink) { $plink = 'C:\Program Files\PuTTY\plink.exe' }
if (-not (Test-Path $plink)) {
    Write-Host "ERRO: plink.exe nao encontrado" -ForegroundColor Red
    exit 1
}

$cmds = @(
    'echo "===== POSTGRES PIDS e bindings via /proc/<pid>/net/tcp ====="'
    'PIDS=$(pgrep -x postgres | head -5)'
    'echo "PIDS=$PIDS"'
    'for p in $PIDS; do'
    '  echo "--- PID $p ---"'
    '  if [ -r /proc/$p/net/tcp ]; then'
    '    awk "NR>1 && \$4==\"0A\" {print \$2}" /proc/$p/net/tcp 2>/dev/null | sort -u'
    '  else'
    '    echo "(sem permissao /proc/$p/net/tcp)"'
    '  fi'
    'done'
    ''
    'echo "===== /proc/net/tcp completo (todos LISTEN incluindo loopback) ====="'
    'awk "NR>1 && \$4==\"0A\"" /proc/net/tcp 2>/dev/null | head -40'
    ''
    'echo "===== /proc/net/tcp6 (IPv6 listen) ====="'
    'awk "NR>1 && \$4==\"0A\"" /proc/net/tcp6 2>/dev/null | head -20'
    ''
    'echo "===== Sockets unix do postgres ====="'
    'awk "/PGSQL/ || /postgres/" /proc/net/unix 2>/dev/null | head -20'
    'ls -la /var/run/postgresql/ 2>&1'
    'ls -la /tmp/.s.PGSQL.* 2>&1'
    'ls -la /run/postgresql/ 2>&1'
    ''
    'echo "===== SCAN TCP 5432 nas redes docker DETECTADAS ====="'
    'for net in 172.17 172.19 172.22 172.23 172.25; do'
    '  echo "--- Rede $net.0.0/16 (gw .0.1, varrendo .0.2 a .0.30) ---"'
    '  for h in 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do'
    '    timeout 0.5 bash -c "echo > /dev/tcp/$net.0.$h/5432" 2>/dev/null && echo "PG_FOUND $net.0.$h:5432"'
    '  done'
    'done'
    ''
    'echo "===== SCAN portas comuns no host (talvez expoe via porta nao-padrao) ====="'
    'for p in 5432 5433 5434 5435 15432 25432 54320 6432 7432; do'
    '  timeout 0.5 bash -c "echo > /dev/tcp/127.0.0.1/$p" 2>/dev/null && echo "LOCAL_OPEN 127.0.0.1:$p"'
    '  timeout 0.5 bash -c "echo > /dev/tcp/150.150.251.112/$p" 2>/dev/null && echo "EXTERN_OPEN 150.150.251.112:$p"'
    'done'
    ''
    'echo "===== CHECA se psql esta como binario em algum lugar ====="'
    'for p in /usr/bin /usr/local/bin /opt /snap/bin /home/*/bin; do'
    '  find $p -maxdepth 3 -name psql -executable 2>/dev/null | head -5'
    'done'
    ''
    'echo "===== Versao postgres detectavel via /proc ====="'
    'POSTGRES_PID=$(pgrep -x postgres | head -1)'
    'if [ -n "$POSTGRES_PID" ]; then'
    '  ls -l /proc/$POSTGRES_PID/exe 2>&1'
    '  cat /proc/$POSTGRES_PID/cmdline 2>&1 | tr "\0" " "; echo'
    '  awk "/^Uid|^Gid/" /proc/$POSTGRES_PID/status 2>&1'
    'fi'
    ''
    'echo "===== Containers visiveis para o user via cgroups ====="'
    'find /sys/fs/cgroup -maxdepth 4 -name "docker-*.scope" 2>/dev/null | head -20'
    ''
    'echo "===== Checa se 150.150.251.112 tem outras portas DB conhecidas ====="'
    'for port in 1521 1433 3306 27017 6379 9042; do'
    '  timeout 0.5 bash -c "echo > /dev/tcp/150.150.251.112/$port" 2>/dev/null && echo "OTHER_DB_PORT $port"'
    'done'
    ''
    'echo "DONE"'
)
$tmp = Join-Path $OutDir 'discover-v2.sh'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($tmp, ($cmds -join "`n") + "`n", $utf8NoBom)

$null = "y" | & $plink -ssh -batch -pw $SshPass "$SshUser@$SshHost" 'echo OK' 2>&1
$out = & $plink -ssh -batch -pw $SshPass -m $tmp "$SshUser@$SshHost" 2>&1
$out | Out-File -FilePath $Report -Encoding UTF8

Write-Host ""
Write-Host "===== INICIO REPORT v2 =====" -ForegroundColor Cyan
$out | ForEach-Object { Write-Host $_ }
Write-Host "===== FIM REPORT v2 =====" -ForegroundColor Cyan
Write-Host ""
Write-Host "Salvo em: $Report" -ForegroundColor Green
