#!/usr/bin/env bash
# Run on the server by GitHub Actions after rsync has copied the code to /opt/chatapp/app:
#   bash /opt/chatapp/app/scripts/deploy.sh <git-sha>
#
# It only touches this app's own files and service:
#   /opt/chatapp, /etc/nginx/snippets/chatapp.conf and chatapp.service.
# Other sites, services and databases are not changed.
set -euo pipefail

REVISION="${1:-unknown}"
APP_DIR=/opt/chatapp/app
VENV=/opt/chatapp/venv
ENV_FILE=/etc/chatapp/chatapp.env
SOCKET=/run/chatapp/gunicorn.sock
SNIPPET=/etc/nginx/snippets/chatapp.conf
INCLUDE_RE='^[[:space:]]*include[[:space:]]+(/etc/nginx/)?snippets/chatapp[.]conf[[:space:]]*;'

cd "$APP_DIR"

echo '==> Virtual environment and dependencies'
[ -d "$VENV" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r requirements.txt

# The running version comes from the deployment (github.sha), not from a hand-written value
echo "$REVISION" > REVISION

echo '==> Database schema'
DB_NAME="$(sudo grep -E '^DB_NAME=' "$ENV_FILE" | cut -d= -f2)"
sudo mysql "$DB_NAME" < deploy/sql/schema.sql

echo '==> Nginx snippet (/viikko5/)'
if ! sudo grep -REq "$INCLUDE_RE" /etc/nginx/sites-enabled/; then
    echo 'ERROR: the snippet is not included in an Nginx site. Add this line once inside the' >&2
    echo 'server { } block of your existing site, then run the deployment again:' >&2
    echo '    include snippets/chatapp.conf;' >&2
    exit 1
fi

# Nginx (www-data) needs access to Gunicorn's socket, which belongs to group chatapp
NGINX_ACTION=reload
if ! id -nG www-data | grep -qw chatapp; then
    sudo usermod -aG chatapp www-data
    NGINX_ACTION=restart   # a new group membership only applies after a restart
fi

# Install the new snippet but keep the old one: if nginx -t fails, restore it so Nginx
# and the pages of earlier weeks keep working.
sudo cp -p "$SNIPPET" "$SNIPPET.bak" 2>/dev/null || true
sudo install -m 644 deploy/nginx/chatapp.conf "$SNIPPET"
if ! sudo nginx -t; then
    echo 'ERROR: invalid Nginx configuration, restoring the previous snippet.' >&2
    if [ -f "$SNIPPET.bak" ]; then sudo mv "$SNIPPET.bak" "$SNIPPET"; fi
    exit 1
fi
sudo rm -f "$SNIPPET.bak"
sudo systemctl "$NGINX_ACTION" nginx

echo '==> systemd service (only chatapp)'
sudo install -m 644 deploy/systemd/chatapp.service /etc/systemd/system/chatapp.service
sudo systemctl daemon-reload
sudo systemctl enable chatapp >/dev/null
sudo systemctl restart chatapp

echo "==> Health check through the socket (waiting for version $REVISION)"
for _ in $(seq 1 20); do
    if sudo curl -fsS --unix-socket "$SOCKET" http://localhost/health 2>/dev/null | grep -qx "$REVISION"; then
        echo "OK: version $REVISION is running."
        exit 0
    fi
    sleep 2
done

echo 'ERROR: the app did not answer with the expected version.' >&2
sudo journalctl -u chatapp -n 50 --no-pager >&2
exit 1