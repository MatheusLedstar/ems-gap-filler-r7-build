# =============================================================================
# EMS-NET-DISCOVERY.PS1 - descobre como chegar no timescaledb a partir do
# servidor 150.150.251.112 SEM privilegio (user cesar.silva)
#
# Roda comandos de rede inocuos via SSH (read-only de /proc, /etc, ip route, nc)
# pra mapear:
#   - DNS interno (timescaledb resolve no host?)
#   - Subredes docker (172.101.x.x homolog / 172.102.x.x prod)
#   - Host candidato pra fazer SSH tunnel -L
#
# Saida em %USERPROFILE%\Downloads\ems-netdisc\<ts>\report.txt
# =============================================================================

$ErrorActionPreference = 'Stop'

$SshHost = '150.150.251.112'
$SshUser = 'cesar.silva'
$SshPass = ")HV2//x'md}w4;R"

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir = Join-Path $env:USERPROFILE "Downloads\ems-netdisc\$ts"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Report = Join-Path $OutDir 'report.txt'

# acha plink
$plink = (Get-Command plink.exe -ErrorAction SilentlyContinue).Path
if (-not $plink) { $plink = 'C:\Program Files\PuTTY\plink.exe' }
if (-not (Test-Path $plink)) {
    Write-Host "ERRO: plink.exe nao encontrado" -ForegroundColor Red
    exit 1
}
Write-Host "plink: $plink"

# Comandos de discovery (todos read-only, sem privilegio)
$cmds = @(
    'echo "===== DNS: resolver timescaledb ====="'
    'getent hosts timescaledb 2>&1 || echo "NORESOLVE"'
    'getent hosts ems-timescaledb 2>&1 || echo "NORESOLVE"'
    'cat /etc/hosts 2>&1'
    ''
    'echo "===== Interfaces de rede ====="'
    'ip -4 addr show 2>&1 | grep -E "inet |^[0-9]+:"'
    ''
    'echo "===== Rotas (subredes acessiveis) ====="'
    'ip route 2>&1'
    ''
    'echo "===== Resolvedor DNS ====="'
    'cat /etc/resolv.conf 2>&1'
    ''
    'echo "===== Procurando porta 5432 em IPs locais ====="'
    'for ip in $(ip -4 addr show | grep -oP "(?<=inet )[0-9.]+" | grep -v ^127); do'
    '  if command -v nc >/dev/null 2>&1; then'
    '    timeout 2 nc -zv "$ip" 5432 2>&1 | head -2'
    '  else'
    '    echo "(no nc) $ip:5432"'
    '  fi'
    'done'
    ''
    'echo "===== Scan rapido subrede 172.101.x.0/24 e 172.102.x.0/24 (.0-.20) ====="'
    'for sub in 172.101.0 172.101.1 172.102.0 172.102.1; do'
    '  for h in 1 2 3 4 5 6 7 8 9 10; do'
    '    if command -v nc >/dev/null 2>&1; then'
    '      out=$(timeout 1 nc -z "$sub.$h" 5432 2>&1 && echo OK || echo FAIL)'
    '      if echo "$out" | grep -q OK; then echo "PG_FOUND $sub.$h:5432"; fi'
    '    fi'
    '  done'
    'done'
    ''
    'echo "===== /proc/net/tcp listening ports (best-effort) ====="'
    'awk "NR>1 && \$4==\"0A\" {print \$2}" /proc/net/tcp 2>/dev/null | sort -u | head -40'
    ''
    'echo "===== Socket file postgres? ====="'
    'find /var/run /tmp -maxdepth 2 -name ".s.PGSQL.*" 2>/dev/null'
    'find /var/lib/postgresql /opt/timescale 2>/dev/null | head -10'
    ''
    'echo "===== Checa se o user pode listar containers via ps -ef ====="'
    'ps -ef 2>&1 | grep -i -E "(postgres|timescale)" | grep -v grep | head -10'
    ''
    'echo "===== Verifica se ssh -L funciona (test localhost forward para self) ====="'
    'echo "(esse teste so vale na execucao do tunnel real, ignorar aqui)"'
    ''
    'echo "===== Resumo ====="'
    'echo "Hostname: $(hostname)"'
    'echo "Default route: $(ip route | grep default | head -1)"'
    'echo "DONE"'
)
$script = ($cmds -join "`n") + "`n"

Write-Host "Conectando em $SshUser@$SshHost..."

# 1x echo y pra aceitar host key (caso ainda nao tenha cache)
$null = "y" | & $plink -ssh -batch -pw $SshPass "$SshUser@$SshHost" 'echo OK' 2>&1

# Salva script local com LF e roda via plink lendo stdin
$tmp = Join-Path $OutDir 'discover.sh'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($tmp, $script, $utf8NoBom)

$out = & $plink -ssh -batch -pw $SshPass -m $tmp "$SshUser@$SshHost" 2>&1

$out | Out-File -FilePath $Report -Encoding UTF8

Write-Host ""
Write-Host "===== INICIO REPORT =====" -ForegroundColor Cyan
$out | ForEach-Object { Write-Host $_ }
Write-Host "===== FIM REPORT =====" -ForegroundColor Cyan
Write-Host ""
Write-Host "Salvo em: $Report" -ForegroundColor Green
Write-Host "Manda esse report pro Claude pra ele decidir como fazer o tunnel." -ForegroundColor Green
