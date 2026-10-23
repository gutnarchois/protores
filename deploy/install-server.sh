#!/usr/bin/env bash
# First installation only. Run as root after uploading the validated binary,
# service, Apache include and private env to /root/protores-install/.
set -euo pipefail
umask 077
install_dir=/root/protores-install
if test -e /etc/protores.env || test -e /opt/protores; then
  echo 'Existing Protores installation: use the update procedure.' >&2
  exit 1
fi
source "$install_dir/bootstrap.env"
# Generated secrets are hex: safe for this SQL and the Go DSN.
[[ "$DB_PASSWORD" =~ ^[a-f0-9]{48}$ ]] || exit 1
[[ "$ADMIN_PASSWORD" =~ ^[a-f0-9]{32}$ ]] || exit 1
backup_stamp=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p /var/backups/protores
cp -a /etc/apache2/sites-available/restaurante-le-ssl.conf "/var/backups/protores/apache-before-$backup_stamp.conf"
cp -a /var/www/restaurante "/var/backups/protores/web-before-$backup_stamp"
mysql --defaults-file=/etc/mysql/debian.cnf <<SQL
CREATE DATABASE protores CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'protores'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, INDEX, REFERENCES ON protores.* TO 'protores'@'127.0.0.1';
SQL
id protores >/dev/null 2>&1 || useradd --system --home-dir /opt/protores --shell /usr/sbin/nologin protores
install -d -o root -g protores -m 750 /opt/protores
install -o root -g protores -m 750 "$install_dir/protores-api" /opt/protores/protores-api
printf 'MYSQL_DSN=protores:%s@tcp(127.0.0.1:3306)/protores\nLISTEN_ADDR=127.0.0.1:8091\n' "$DB_PASSWORD" > /etc/protores.env
chmod 600 /etc/protores.env
export MYSQL_DSN="protores:$DB_PASSWORD@tcp(127.0.0.1:3306)/protores" ADMIN_USER=admin ADMIN_PASSWORD
/opt/protores/protores-api bootstrap
install -m 644 "$install_dir/protores.service" /etc/systemd/system/protores.service
install -m 644 "$install_dir/apache-protores.conf" /etc/apache2/protores-api.conf
python3 - <<'PY'
from pathlib import Path
p=Path('/etc/apache2/sites-available/restaurante-le-ssl.conf')
s=p.read_text()
assert 'Include /etc/apache2/protores-api.conf' not in s
s=s.replace('</VirtualHost>', 'Include /etc/apache2/protores-api.conf\n</VirtualHost>')
p.write_text(s)
PY
apache2ctl configtest
systemctl daemon-reload
systemctl enable --now protores
systemctl reload apache2
# Bootstrap secret is retained only in the operator's private local file.
rm "$install_dir/bootstrap.env"
echo 'Protores installed. Verify HTTPS and create school users before the pilot.'
