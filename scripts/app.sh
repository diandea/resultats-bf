#!/usr/bin/env bash
# appN — service applicatif Flask sans état (gunicorn + systemd)
# Idempotent : le service n'est redémarré que si le code ou la configuration change.
set -euo pipefail
source /vagrant/scripts/lib.sh
echo "[app] $(hostname) — service applicatif"

# --- 1. Paquets (un seul appel apt) ------------------------------------------
installer_paquets python3-flask python3-psycopg gunicorn

# --- 2. Compte système dédié, sans shell (moindre privilège) -----------------
id resultats >/dev/null 2>&1 || \
  useradd --system --no-create-home --shell /usr/sbin/nologin resultats
install -d -o root -g resultats -m 750 /etc/resultats
install -d -o root -g root      -m 755 /opt/resultats

# --- 3. Configuration : adresses des bases lues dans la source de vérité -----
DB_HOSTS="$(ip_noeud bdd1),$(ip_noeud bdd2)"
REDEMARRER=0

ecrire_si_change /etc/resultats/app.env root:resultats 640 <<EOF && REDEMARRER=1
DB_HOSTS=${DB_HOSTS}
DB_USER=${PG_APP_USER}
DB_PASSWORD=${PG_APP_PASSWORD}
EOF

# --- 4. Code : copié hors du dossier partagé ---------------------------------
ecrire_si_change /opt/resultats/app.py root:root 644 < /vagrant/app/app.py && REDEMARRER=1

# --- 5. Service systemd ------------------------------------------------------
if ecrire_si_change /etc/systemd/system/resultats.service root:root 644 <<'EOF'
[Unit]
Description=RESULTATS-BF - service applicatif (gunicorn)
After=network-online.target
Wants=network-online.target

[Service]
User=resultats
Group=resultats
EnvironmentFile=/etc/resultats/app.env
WorkingDirectory=/opt/resultats
ExecStart=/usr/bin/gunicorn --bind 0.0.0.0:3000 --workers 3 --timeout 15 app:app
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
then
  systemctl daemon-reload
  REDEMARRER=1
fi

systemctl enable resultats > /dev/null 2>&1
if [ "$REDEMARRER" = 1 ]; then
  echo "   (re)démarrage du service (code ou configuration modifiés)"
  systemctl restart resultats
else
  systemctl start resultats      # sans effet s'il tourne déjà
fi

# --- 6. Contrôle : le service répond ------------------------------------------
for i in $(seq 1 15); do
  curl -sf -o /dev/null http://127.0.0.1:3000/info && break
  sleep 1
done
CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/sante || true)
echo "[app] $(hostname) — service actif sur :3000 — /sante = ${CODE}"
