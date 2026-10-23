#!/usr/bin/env bash
# Run as root on the VPS. No passwords in the command line or repository.
set -euo pipefail
umask 077
backup_dir=/var/backups/protores
mkdir -p "$backup_dir"
backup_stamp=$(date -u +%Y%m%dT%H%M%SZ)
mysqldump --defaults-file=/etc/mysql/debian.cnf --single-transaction --no-tablespaces protores | gzip > "$backup_dir/database-$backup_stamp.sql.gz"
tar -czf "$backup_dir/config-$backup_stamp.tar.gz" /etc/protores.env /etc/systemd/system/protores.service /etc/apache2/protores-api.conf /opt/protores/protores-api 2>/dev/null
find "$backup_dir" -type f -mtime +14 -delete
