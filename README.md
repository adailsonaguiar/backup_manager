# backup-manager

Backups automatizados de bancos de dados PostgreSQL.

Os dumps são gerados no formato custom do `pg_dump` (`.dump`), salvos localmente em
`backups/<nome>/` e removidos automaticamente após 30 dias.

## Estrutura

```
backup-manager/
├── config/
│   └── databases.yml      # lista de bancos a serem backupeados
├── scripts/
│   ├── backup.sh          # executa os dumps e chama a limpeza
│   └── cleanup.sh         # remove backups com mais de 30 dias
├── backups/               # dumps gerados (por banco)
├── logs/                  # logs de execução
├── .env.example           # exemplo das variáveis de senha
├── .gitignore
└── README.md
```

## Pré-requisitos (Ubuntu)

Instale o cliente do PostgreSQL e o `yq`:

```bash
sudo apt update
sudo apt install -y postgresql-client

# yq (parser de YAML em bash)
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
  -O /usr/local/bin/yq
sudo chmod +x /usr/local/bin/yq
```

## 1. Configurar os bancos

Edite `config/databases.yml`:

```yaml
databases:
  - name: financeiro
    host: postgres-financeiro
    port: 5432
    database: financeiro
    user: backup

  - name: cursos
    host: postgres-cursos
    port: 5432
    database: ita
    user: backup
```

- `name`: identificador usado no nome da pasta e do arquivo.
- `host`, `port`, `database`, `user`: dados da conexão.
- A senha **não** fica no YAML (ver abaixo).

## 2. Configurar as senhas

Copie o exemplo e preencha:

```bash
cp .env.example .env
nano .env
```

```bash
PGPASSWORD=senha_geral                # fallback para todos os bancos

PGPASSWORD_FINANCEIRO=senha_financeiro # opcional, sobrescreve a global
PGPASSWORD_CURSOS=senha_cursos
PGPASSWORD_USUARIOS=senha_usuarios
```

A variável específica segue o padrão `PGPASSWORD_<NOME_EM_MAIÚSCULAS>`
(hífens viram `_`). Ex.: banco `financeiro` → `PGPASSWORD_FINANCEIRO`.

## 3. Executar manualmente

```bash
cd /caminho/para/backup-manager
./scripts/backup.sh
```

Saída esperada:

```
✓ financeiro  245 MB
✓ cursos      830 MB
✓ usuarios    120 MB
Backup concluído: 3/3
```

Para testar com um único banco, deixe apenas ele em `databases.yml`.

## 4. Agendar no cron (Ubuntu)

Abra o crontab:

```bash
crontab -e
```

Adicione a linha para rodar diariamente às **03:00**. O script carrega o `.env`
com `set -a; . .env; set +a`:

```cron
0 3 * * * cd /caminho/para/backup-manager && set -a && . ./.env && set +a && ./scripts/backup.sh >> ./logs/cron.log 2>&1
```

> Substitua `/caminho/para/backup-manager` pelo caminho real no servidor.

Outros exemplos de agendamento:

```cron
# Todos os dias às 03:00
0 3 * * * ...

# A cada 6 horas
0 */6 * * * ...

# Segunda a sexta às 02:00
0 2 * * 1-5 ...
```

Verificar se o cron está ativo e listar tarefas:

```bash
systemctl status cron    # ou systemctl status crond
crontab -l
```

## 5. Restaurar um backup

```bash
pg_restore --host=HOST --port=5432 --username=backup \
  --dbname=financeiro backups/financeiro/financeiro_20260913_030000.dump
```

## 6. Logs

- Cada execução gera `logs/backup_<data>_<hora>.log` (backup) e
  `logs/cleanup_<data>_<hora>.log` (limpeza).
- A saída do cron é acumulada em `logs/cron.log`.

## Retenção

O `cleanup.sh` remove arquivos `*.dump` com mais de 30 dias. Para alterar,
edite `RETENTION_DAYS=30` no topo de `scripts/cleanup.sh` e
`scripts/backup.sh`.
