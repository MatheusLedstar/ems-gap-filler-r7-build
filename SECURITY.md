# Security

## ⚠️ Secrets já versionados (acao requerida)

Os scripts em `scripts/*.ps1` foram criados com credenciais hardcoded
durante a fase de levantamento. **As seguintes credenciais devem ser
ROTACIONADAS o quanto antes:**

| Tipo | Credencial | Como rotacionar |
|------|-----------|-----------------|
| GitLab Personal Access Token | `glpat-1KBJACUAPmj8f3V1ivdBLmM6MQpvOjEKdTptbDV2aQ8.01.1706sk2g4` | gitlab.com/-/user_settings/personal_access_tokens → revogar + criar novo |
| SSH password | `cesar.silva` no servidor 150.150.251.112 | `passwd cesar.silva` via admin do servidor |
| Postgres ems_user PRD | `Glimmer7-Enroll-Bloomers` | `ALTER ROLE ems_user WITH PASSWORD '...'` + atualizar config do `ems-api` |
| Postgres ems_user HOM | `Sureness-Stencil9-Flap` | idem em homolog |
| FTP Schneider EGX300 | `Administrator/Gateway` (default Schneider) | via web UI do gateway, trocar pra senha forte |

## Por que NÃO reescrever histórico

Reescrever o git history (`git filter-repo`/BFG) é arriscado em repo
compartilhado e não invalida cópias já clonadas. **Rotacionar as
credenciais é o único fix definitivo.**

## Onde guardar secrets daqui pra frente

- **Senhas e tokens** → variáveis de ambiente do container (`docker-compose.yml`
  via `env_file: .env` que está no `.gitignore`)
- **Senha do banco de medidores** → coluna `ems.ftp_source.fts_password_enc`
  cifrada com `pgp_sym_encrypt(value, KEY)`. A `KEY` vem de env var
  `GAPFILLER_CRYPTO_PGP_KEY`
- **Token GitLab** → não usar em produção. Em CI/CD, usar `CI_JOB_TOKEN`
  built-in do GitLab Runner

## Reportar vulnerabilidade

Email: matheus.venancio@ledstar.com.br (ou abrir issue privada no repo)
