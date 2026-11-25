Para **PostgreSQL + Amazon S3**, eu usaria `pg_dump` + AWS CLI + cron, com backup a cada 6 horas e retenção de 30 dias.

Abaixo está uma configuração para **Ubuntu**, executada como `root`. Ela funciona com PostgreSQL acessível pela rede, seja na VPS, em Docker com porta publicada localmente ou em um serviço gerenciado.

**1. Crie uma credencial de backup na AWS**

No console AWS, acesse **IAM → Users → Create user** e crie um usuário exclusivo, por exemplo `backup-vps`, sem acesso ao console.

Adicione esta política, substituindo `SEU-BUCKET` pelo nome real:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::SEU-BUCKET/postgresql/*"
    }
  ]
}
```

Essa política permite enviar backups ao prefixo `postgresql/` e cancelar uploads incompletos. A credencial não recebe acesso para baixar ou excluir backups. [Amazon Simple Storage Service](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-with-s3-policy-actions.html?utm_source=chatgpt.com)

Em **Security credentials → Create access key**, selecione a opção para aplicação executada fora da AWS. Guarde a Access Key e a Secret Key.

Mantenha o bucket privado. O exemplo abaixo considera criptografia **SSE-S3**; se você configurou uma chave KMS, será necessário ajustar também as permissões dessa chave.

**2. Instale as ferramentas na VPS**

Entre como `root`:

```bash
sudo -i
```

Instale os utilitários:

```bash
apt update
apt install -y curl unzip postgresql-client util-linux
```

Confira a versão:

```bash
pg_dump --version
```

**Prefira o cliente da mesma versão principal do servidor.** Por exemplo, servidor PostgreSQL 16 com `pg_dump` 16. Um cliente mais antigo que o servidor não consegue gerar o dump. O pacote padrão do Ubuntu pode precisar ser substituído pelo cliente correspondente. [postgresql.org](https://www.postgresql.org/docs/current/app-pgdump.html?utm_source=chatgpt.com)

Se a AWS CLI ainda não estiver instalada:

```bash
curl -fSL \
  "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" \
  -o /tmp/awscliv2.zip

unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

aws --version
```

Configure a credencial:

```bash
aws configure --profile backup
```

Informe as chaves e **a região do bucket**, como `us-east-1` ou `sa-east-1`. O formato de saída pode ser `json`. [Instalação oficial da AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).

**3. Configure a conexão PostgreSQL**

Crie o diretório:

```bash
install -d -m 700 /etc/pg-backup
```

Edite:

```bash
nano /etc/pg-backup/config
```

Preencha:

```bash
PGHOST='127.0.0.1'
PGPORT='5432'
PGDATABASE='nome_do_banco'
PGUSER='usuario_do_banco'

PGSSLMODE='prefer'
PGCONNECT_TIMEOUT='15'

S3_BUCKET='SEU-BUCKET'
AWS_REGION='us-east-1'
```

Use um usuário PostgreSQL com acesso a todos os objetos que precisam entrar no backup.

Para um **PostgreSQL gerenciado da DigitalOcean**, utilize o host e a porta fornecidos no painel. Configure preferencialmente:

```bash
PGSSLMODE='verify-full'
PGSSLROOTCERT='/etc/pg-backup/ca-certificate.crt'
```

Nesse caso, salve nesse caminho o certificado CA disponibilizado pela DigitalOcean e autorize a VPS a conectar ao banco.

Agora crie o arquivo da senha:

```bash
nano /etc/pg-backup/pgpass
```

Formato:

```text
HOST:PORTA:BANCO:USUARIO:SENHA
```

Exemplo:

```text
127.0.0.1:5432:minha_app:usuario_backup:SUA_SENHA
```

Os dados precisam corresponder ao arquivo de configuração. Se a senha contiver `:` ou `\`, escape esses caracteres com `\`.

Proteja os arquivos:

```bash
chmod 600 /etc/pg-backup/config /etc/pg-backup/pgpass
```

O PostgreSQL exige permissões restritas no arquivo de senha; assim ela também fica fora dos argumentos dos comandos. [postgresql.org](https://www.postgresql.org/docs/current/libpq-pgpass.html?utm_source=chatgpt.com)

**4. Crie o script**

Abra:

```bash
nano /usr/local/bin/backup-postgres.sh
```

Cole:

```bash
#!/bin/bash
set -Eeuo pipefail
umask 077

export PATH=/usr/local/bin:/usr/bin:/bin

# Carrega e exporta as configurações para os clientes PostgreSQL.
set -a
source /etc/pg-backup/config
set +a

export PGPASSFILE=/etc/pg-backup/pgpass
export AWS_RETRY_MODE=standard
export AWS_MAX_ATTEMPTS=5
export AWS_PAGER=""

log() {
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"
}

trap 'log "ERRO: backup falhou na linha $LINENO" >&2' ERR

# Impede duas execuções simultâneas.
exec 9>/run/lock/backup-postgres.lock
if ! flock -n 9; then
  log "Outra execução está em andamento."
  exit 1
fi

install -d -m 700 /var/backups/postgresql

WORK_DIR=$(mktemp -d /var/backups/postgresql/job.XXXXXX)
trap 'rm -rf -- "$WORK_DIR"' EXIT

STAMP=$(date -u +%Y-%m-%dT%H-%M-%S-%NZ)
FILE="$WORK_DIR/backup-$STAMP.dump"
DEST="s3://$S3_BUCKET/postgresql/$PGDATABASE/backup-$STAMP.dump"

log "Iniciando backup de $PGDATABASE"

# Formato customizado, já comprimido.
pg_dump \
  --no-password \
  --format=custom \
  --file="$FILE"

test -s "$FILE"

# Confere se o catálogo do arquivo pode ser lido.
pg_restore --list "$FILE" >/dev/null

log "Enviando para $DEST"

aws --profile backup --region "$AWS_REGION" s3 cp \
  "$FILE" "$DEST" \
  --sse AES256 \
  --only-show-errors

log "Backup enviado com sucesso."
```

Dê permissão e execute manualmente:

```bash
chmod 700 /usr/local/bin/backup-postgres.sh
/usr/local/bin/backup-postgres.sh
```

Confirme no console S3 que o arquivo apareceu.

O `pg_dump` produz uma cópia consistente de um banco enquanto a aplicação continua utilizando-o. Ele não inclui os usuários e demais objetos globais do cluster. [postgresql.org](https://www.postgresql.org/docs/current/app-pgdump.html?utm_source=chatgpt.com)

**5. Agende a execução**

Ainda como `root`:

```bash
crontab -e
```

Adicione:

```cron
0 */6 * * * /usr/local/bin/backup-postgres.sh >> /var/log/backup-postgres.log 2>&1
```

Executará às **00h, 06h, 12h e 18h, no fuso da VPS**. Os nomes dos arquivos usam UTC.

Para consultar o resultado:

```bash
tail -n 50 /var/log/backup-postgres.log
```

**6. Configure retenção e teste a restauração**

No console S3, em **bucket → Management → Lifecycle rules**, crie uma regra limitada ao prefixo `postgresql/` para:

- Expirar backups após **30 dias**.
- Cancelar uploads multipart incompletos após **7 dias**.
- Se houver versionamento, expirar também versões anteriores conforme a retenção desejada.

A limpeza fica a cargo do S3. [docs.aws.amazon.com](https://docs.aws.amazon.com/AmazonS3/latest/userguide/how-to-set-lifecycle-configuration-intro.html?utm_source=chatgpt.com)

Depois, baixe um backup pelo console e restaure em **um banco vazio de teste**, usando credenciais desse ambiente:

```bash
pg_restore \
  --host=HOST_DE_TESTE \
  --port=5432 \
  --username=USUARIO_DE_TESTE \
  --dbname=BANCO_VAZIO_DE_TESTE \
  --no-owner \
  --no-privileges \
  --exit-on-error \
  backup.dump
```

Confira tabelas, registros e funcionamento da aplicação. A leitura do catálogo feita pelo script é uma verificação básica; **a restauração é o teste efetivo do backup**. [postgresql.org](https://www.postgresql.org/docs/current/app-pgrestore.html?utm_source=chatgpt.com)

Como você já usa Uptime Kuma, um monitor do tipo **Push**, atualizado somente após o envio bem-sucedido, pode avisar se o backup parar de executar. O agendamento acima registra falhas no log, mas ainda não envia alertas.
