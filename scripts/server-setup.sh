#!/usr/bin/env bash
# One-time setup of an EXISTING cPouta server (server A).
# Pages, services and databases from earlier weeks are left untouched.
#
# Run on the server as the default user (ubuntu):
#   bash server-setup.sh [ollama-model]
# Example: bash server-setup.sh qwen2.5:0.5b
# The script can be run again safely.
set -euo pipefail

MODEL="${1:-qwen2.5:0.5b}"
DEPLOY_USER="${DEPLOY_USER:-$(whoami)}"
APP_ROOT=/opt/chatapp
ENV_DIR=/etc/chatapp
ENV_FILE=$ENV_DIR/chatapp.env
SNIPPET=/etc/nginx/snippets/chatapp.conf
DB_NAME=chatapp
DB_USER=chatapp
INCLUDE_RE='^[[:space:]]*include[[:space:]]+(/etc/nginx/)?snippets/chatapp[.]conf[[:space:]]*;'

echo '==> Server resources'
free -h
df -h /
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [ "$MEM_MB" -lt 3500 ]; then
    echo "NOTE: only ${MEM_MB} MB of RAM. Use a small model and consider swap."
fi

echo '==> Ports already in use (do not reuse them)'
sudo ss -ltnp

echo '==> Missing packages (installed packages are not upgraded or restarted)'
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-upgrade nginx mariadb-server python3-venv python3-pip rsync curl openssl zstd

echo '==> MariaDB: this must not be a read-only replica'
sudo systemctl enable --now mariadb
if [ "$(sudo mysql -N -e 'SELECT @@global.read_only;')" = '1' ]; then
    echo 'ERROR: MariaDB is read-only (a replica such as server B). Run this on server A.' >&2
    exit 1
fi

echo "==> Service user 'chatapp' and directories"
if ! id chatapp >/dev/null 2>&1; then
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin chatapp
fi
sudo mkdir -p "$APP_ROOT/app" "$ENV_DIR"
# The deploy user (GitHub Actions over SSH) owns the code; the service only reads it.
sudo chown -R "$DEPLOY_USER:$DEPLOY_USER" "$APP_ROOT"
sudo chmod 755 "$APP_ROOT" "$APP_ROOT/app"

echo '==> MariaDB: own database and user'
if [ ! -f "$ENV_FILE" ]; then
    DB_PASSWORD="$(openssl rand -hex 24)"
    sudo mysql <<SQL
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT SELECT, INSERT ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
    echo "==> Writing $ENV_FILE"
    sudo tee "$ENV_FILE" >/dev/null <<ENV
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
OLLAMA_URL=http://127.0.0.1:11434
OLLAMA_MODEL=$MODEL
HISTORY_LIMIT=10
ENV
    sudo chown root:chatapp "$ENV_FILE"
    sudo chmod 640 "$ENV_FILE"
else
    echo "    $ENV_FILE already exists - the password is not changed."
    sudo sed -i "s|^OLLAMA_MODEL=.*|OLLAMA_MODEL=$MODEL|" "$ENV_FILE"
fi

echo '==> Ollama (listens only on 127.0.0.1:11434)'
if ! command -v ollama >/dev/null 2>&1; then
    curl -fsSL https://ollama.com/install.sh | sh
fi
sudo systemctl enable --now ollama
for _ in $(seq 1 30); do
    curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
    sleep 2
done
echo "==> Pulling the model $MODEL (can take several minutes)"
ollama pull "$MODEL"

echo '==> Nginx snippet placeholder'
sudo mkdir -p /etc/nginx/snippets
if [ ! -f "$SNIPPET" ]; then
    echo '# chat app snippet - written by deploy.sh' | sudo tee "$SNIPPET" >/dev/null
fi

if sudo grep -REq "$INCLUDE_RE" /etc/nginx/sites-enabled/; then
    echo 'The include line is already in the site configuration.'
else
    echo 'NEXT: add this line once inside the server { } block of your existing site:'
    echo '    include snippets/chatapp.conf;'
    echo 'Then run: sudo nginx -t && sudo systemctl reload nginx'
fi

echo 'Done. Next: add the four GitHub secrets and push to main.'