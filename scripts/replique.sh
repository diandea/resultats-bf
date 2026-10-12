#!/usr/bin/env bash
# bdd2 — réplique en flux de bdd1 (hot standby, promouvable)
# Idempotent : la copie initiale n'est faite qu'UNE fois (fichier marqueur).
set -euo pipefail
source /vagrant/scripts/lib.sh

PG_VER=16
SERVICE="postgresql@${PG_VER}-main"
PGDATA="/var/lib/postgresql/${PG_VER}/main"
MARQUEUR="/var/lib/postgresql/.replique-initialisee"
PGPASS="/var/lib/postgresql/.pgpass"
IP_PRIMAIRE="$(ip_noeud bdd1)"
echo "[replique] $(hostname) — réplique de bdd1 (${IP_PRIMAIRE})"

# --- 1. Installation et configuration (identique au primaire) ---------------
installer_paquets "postgresql-${PG_VER}"

CONFIG_CHANGEE=0
ecrire_config_postgresql && CONFIG_CHANGEE=1

# Identifiants de réplication : lisibles par l'utilisateur postgres seul
ecrire_si_change "$PGPASS" postgres:postgres 600 <<EOF || true
${IP_PRIMAIRE}:5432:replication:${PG_REPL_USER}:${PG_REPL_PASSWORD}
EOF

# --- 2. Copie initiale, une seule fois --------------------------------------
cd /tmp
if [ -f "$MARQUEUR" ]; then
  echo "   réplique déjà initialisée : pas de nouvelle copie"
  if [ "$CONFIG_CHANGEE" = 1 ]; then
    echo "   redémarrage de PostgreSQL (configuration modifiée)"
    systemctl restart "$SERVICE"
  fi
  systemctl start "$SERVICE"
else
  echo "   attente du primaire ${IP_PRIMAIRE}..."
  attendre_postgresql "$IP_PRIMAIRE"

  echo "   copie initiale depuis bdd1 (pg_basebackup)"
  systemctl stop "$SERVICE"
  rm -rf "$PGDATA"
  sudo -u postgres pg_basebackup \
       -d "host=${IP_PRIMAIRE} port=5432 user=${PG_REPL_USER} passfile=${PGPASS} application_name=$(hostname)" \
       -D "$PGDATA" -X stream -R -c fast
  # -R : crée standby.signal et écrit primary_conninfo => démarrage en réplique
  touch "$MARQUEUR"
  systemctl start "$SERVICE"
fi

attendre_postgresql

# --- 3. Contrôle ------------------------------------------------------------
EN_REPLIQUE=$(sudo -u postgres psql -tAc "SELECT pg_is_in_recovery()")
NB=$(sudo -u postgres psql -tA -d resultats -c "SELECT count(*) FROM resultats")
echo "[replique] $(hostname) — en mode réplique : ${EN_REPLIQUE} — ${NB} lignes — OK"
