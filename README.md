# backup-manager

Container independente da aplicação que faz backup de **um banco PostgreSQL** para
Amazon S3 a cada 6 horas (00:00, 06:00, 12:00 e 18:00 **UTC**). Usa `pg_dump` em
formato customizado, confere o catálogo com `pg_restore --list`, envia com
criptografia SSE-S3 e, opcionalmente, sinaliza sucesso ao Uptime Kuma.
Logs vão para `docker compose logs`; o container não guarda backups após o envio.
Baseado no procedimento em [`doc_s3_backup.md`](doc_s3_backup.md).

## Requisitos

- Docker com Compose e acesso do container ao PostgreSQL, S3 e, se utilizado,
  Uptime Kuma. `localhost` **dentro do container não é o host Docker**: use um
  nome de serviço numa rede compartilhada, IP acessível ou hostname de banco
  gerenciado. Suba este Compose separadamente do deploy da aplicação.
- `pg_dump` da imagem é **PostgreSQL 16**. Use servidor PostgreSQL 16 ou versão
  anterior compatível; se o servidor for mais recente, ajuste a versão da
  imagem no `Dockerfile` para a mesma versão principal do servidor antes do
  build.
- Espaço livre no volume `backup_tmp` para **pelo menos um dump inteiro**,
  inclusive durante o upload. Dimensione e monitore o armazenamento Docker.
- Usuário do banco com acesso de leitura a todos os objetos desejados. O dump
  de um banco não inclui roles nem outros objetos globais do cluster.

## Configuração

1. Copie `.env.example` para `.env` e preencha os dados de **um** banco e do
   bucket. O `.env` antigo deste repositório, se existir, contém variáveis de
   senha da implementação anterior: remova-as do arquivo local ao migrar. Não
    coloque senhas no `.env`. A pasta no S3 usa `PGDATABASE` (letras, números,
    `_`, `.` e `-`); a antiga variável `BACKUP_NAME` não é mais usada.
2. Crie `secrets/pgpass` com uma linha no formato
   `HOST:PORTA:BANCO:USUARIO:SENHA`, com os quatro primeiros campos iguais aos
   configurados no `.env`. Escape `:` e `\` na senha com `\`. Sem curingas,
   o arquivo não autentica conexões inesperadas. Exemplo:

   ```text
   postgres.example.com:5432:app:backup:SENHA_DO_BANCO
   ```

3. Crie `secrets/aws_credentials` (perfil **default**):

   ```ini
   [default]
   aws_access_key_id = SUA_ACCESS_KEY
   aws_secret_access_key = SUA_SECRET_KEY
   ```

   Restrinja os arquivos no host: `chmod 600 secrets/pgpass
secrets/aws_credentials` e mantenha o diretório acessível apenas ao
   operador (`chmod 700 secrets`). São secrets de arquivo do Compose, montados
   em tempo de execução; **Compose local não criptografa secrets nem substitui
   um cofre**. O entrypoint copia as credenciais para arquivos privados `0600`
   (exigência do libpq para `pgpass`). Não inclua `secrets/` na imagem ou no Git.
   Use uma credencial IAM exclusiva com permissão mínima, por exemplo:

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

   O bucket deve ser privado. O exemplo usa SSE-S3; SSE-KMS exige permissões
   adicionais na chave KMS.

4. Para PostgreSQL com CA própria, grave a CA em
   `secrets/ca-certificate.crt`, configure no `.env`
   `PGSSLMODE=verify-full` e
   `PGSSLROOTCERT=/run/backup-ca/ca-certificate.crt`, e use também o arquivo
   `compose.ca.yaml`. O certificado deve ser legível no container. O valor
   padrão `PGSSLMODE=require` exige TLS, mas **não valida o hostname**;
   prefira `verify-full` sempre que possível.

## Executar

```bash
docker compose build
docker compose up -d
docker compose logs -f backup
```

O cron permanece em primeiro plano; horários e timestamps dos arquivos usam
UTC. Para testar imediatamente, sem aguardar o cron:

```bash
docker compose exec backup /usr/local/bin/backup-postgres.sh
```

Os testes locais do fluxo (com PostgreSQL, S3 e Push simulados) rodam com
`bash tests/backup.sh`. Eles não substituem o teste real acima.

Uma execução já em andamento bloqueia outra com `flock` e retorna erro. O
arquivo temporário é removido ao término, inclusive em falhas normais do
script; uma interrupção abrupta (por exemplo, `SIGKILL`) pode deixar resíduos
no volume, que deverão ser verificados pelo operador. O arquivo é enviado para
`s3://BUCKET/postgresql/PGDATABASE/backup-DATA-UTC.dump` somente após validação
básica. Verifique também o objeto no console S3.

## Monitor Uptime Kuma (opcional)

Crie um monitor do tipo **Push** no Uptime Kuma. Salve a URL completa de Push
fornecida pelo Kuma em `secrets/kuma_push_url`, sem quebra de linha, e restrinja
o acesso ao arquivo (`chmod 600 secrets/kuma_push_url`). A URL contém um token:
trate-a como segredo e não a coloque no `.env` nem no Git. O endereço precisa
ser acessível **de dentro do container**; `localhost` ali não aponta para o host
Docker. Para habilitar o secret, inicie com o override:

```bash
docker compose -f compose.yaml -f compose.monitor.yaml up -d --build
```

Em cada execução, o próprio container `backup` gera o dump, verifica se seu
catálogo pode ser lido com `pg_restore --list` e envia o arquivo ao S3. **Só
depois do upload bem-sucedido** o script faz uma requisição HTTP à URL de Push.
Essa verificação do arquivo não é um teste de restauração em um banco.

Se a geração, a verificação ou o upload falhar, não há Push: o Kuma detectará
que o sinal esperado não chegou. Configure o intervalo do monitor em **6 horas**
e uma margem de atraso adequada à duração do backup. A requisição de Push tem
limite de 15 segundos e até 2 tentativas adicionais; se falhar, o job registra
erro e termina com falha, **mesmo que o objeto já esteja no S3**. Sem o override
e o arquivo de URL, o monitoramento fica desativado. Mantenha o override nos
próximos deploys deste serviço e combine `compose.ca.yaml` se necessário.

## Retenção no S3

Configure no bucket, em **Management → Lifecycle rules**, uma regra apenas para
`postgresql/`: expirar objetos após **30 dias** e abortar uploads multipart
incompletos após **7 dias**. Se houver versionamento, configure também a
expiração das versões anteriores. O container **não exclui** backups do S3.
Monitore capacidade do volume temporário e resultados no S3 separadamente.

## Restauração manual

Não há restauração periódica automatizada. Para conferir um backup, baixe um
objeto do S3 com **credencial de leitura separada**, em um ambiente isolado;
crie um banco vazio de teste e restaure nele:

```bash
pg_restore --host=HOST_DE_TESTE --port=5432 --username=USUARIO_DE_TESTE \
  --dbname=BANCO_VAZIO_DE_TESTE --no-owner --no-privileges \
  --exit-on-error backup.dump
```

Confira tabelas, registros e a aplicação. `pg_restore --list` no job só verifica
se o catálogo do arquivo pode ser lido; **não comprova restauração efetiva**.

## Migração da versão anterior

`config/databases.yml`, `backups/` e `logs/` pertencem ao fluxo antigo e não
são usados pelo container. Os dumps locais existentes não são removidos. O
script de limpeza local foi substituído pelo Lifecycle do S3. Nunca monte o
`.env` antigo na imagem: ele pode conter senhas da configuração anterior.
