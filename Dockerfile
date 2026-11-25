FROM postgres:16-bookworm

ENV TZ=UTC

RUN apt-get update \
    && apt-get install -y --no-install-recommends awscli cron curl util-linux ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/backup.sh /usr/local/bin/backup-postgres.sh
COPY scripts/entrypoint.sh /usr/local/bin/backup-entrypoint.sh
COPY docker/backup.cron /etc/cron.d/backup-postgres

RUN chmod 700 /usr/local/bin/backup-postgres.sh /usr/local/bin/backup-entrypoint.sh \
    && chmod 644 /etc/cron.d/backup-postgres \
    && mkdir -p /var/backups/postgresql

ENTRYPOINT ["/usr/local/bin/backup-entrypoint.sh"]
