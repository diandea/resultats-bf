#!/usr/bin/env bash
# bdd1 — PostgreSQL, primaire en fonctionnement nominal.
# Rejoué à CHAQUE « vagrant up ». Avant de démarrer PostgreSQL, le script décide
# du rôle de bdd1, afin de ne JAMAIS avoir deux primaires après une bascule :
#   1. bdd1 est déjà une réplique (standby.signal)   -> démarrage en réplique
#   2. bdd2 est primaire et répond                   -> bdd1 reconstruite en réplique de bdd2
#   3. bdd2 promue (fichier d'état) mais injoignable -> bdd1 reste ARRÊTÉE
#   4. sinon                                         -> bdd1 primaire (nominal)
set -euo pipefail
source /vagrant/scripts/lib.sh

PG_VER=16
SERVICE="postgresql@${PG_VER}-main"
PGDATA="/var/lib/postgresql/${PG_VER}/main"
INIT="/var/lib/postgresql/.bdd1-initialisee"
ETAT="/vagrant/.etat/primaire"        # écrit par scripts/bascule.sh (sur l'hôte)
PGPASS="/var/lib/postgresql/.pgpass"
IP2="$(ip_noeud bdd2)"
echo "[bdd] $(hostname) — PostgreSQL ${PG_VER}"

installer_paquets "postgresql-${PG_VER}"
postgresql_demarrage_manuel
CONFIG_CHANGEE=0
ecrire_config_postgresql && CONFIG_CHANGEE=1
cd /tmp

demarrer() {
  if [ "$CONFIG_CHANGEE" = 1 ]; then systemctl restart "$SERVICE"; else systemctl start "$SERVICE"; fi
  attendre_postgresql
}

# --- Cas 1 : bdd1 est déjà une réplique de bdd2 --------------------------------
if [ -f "${PGDATA}/standby.signal" ]; then
  demarrer
  echo "[bdd] $(hostname) — RÉPLIQUE de bdd2 (bascule antérieure) — OK"
  exit 0
fi

# --- Cas 2 : bdd2 est primaire -> bdd1 (ancien primaire) devient sa réplique ----
if est_primaire "$IP2"; then
  echo "   bdd2 est PRIMAIRE : bdd1 (ancien primaire) est reconstruite en réplique"
  systemctl stop "$SERVICE"
  ecrire_si_change "$PGPASS" postgres:postgres 600 <<EOF || true
${IP2}:5432:replication:${PG_REPL_USER}:${PG_REPL_PASSWORD}
EOF
  rm -rf "$PGDATA"
  sudo -u postgres pg_basebackup \
       -d "host=${IP2} port=5432 user=${PG_REPL_USER} passfile=${PGPASS} application_name=$(hostname)" \
       -D "$PGDATA" -X stream -R -c fast
  touch "$INIT"
  systemctl start "$SERVICE"
  attendre_postgresql
  echo "[bdd] $(hostname) — reconstruite en RÉPLIQUE de bdd2 — OK"
  exit 0
fi

# --- Cas 3 : bdd2 a été promue mais ne répond pas -> bdd1 reste arrêtée --------
if [ -f "$INIT" ] && [ "$(tr -d '\r\n ' < "$ETAT" 2>/dev/null)" = "bdd2" ]; then
  systemctl stop "$SERVICE"
  echo "[bdd] ATTENTION : une bascule a eu lieu (bdd2 primaire), mais bdd2 ne répond pas."
  echo "[bdd] bdd1 reste ARRÊTÉE pour éviter deux primaires (split-brain)."
  echo "[bdd] Quand bdd2 sera démarrée : vagrant provision bdd1  (réintégration en réplique)"
  exit 0
fi

# --- Cas 4 : fonctionnement nominal, bdd1 primaire ------------------------------
demarrer

sudo -u postgres psql -q -v ON_ERROR_STOP=1 \
     -v su_pw="${PG_SUPERUSER_PASSWORD}" \
     -v app_user="${PG_APP_USER}"  -v app_pw="${PG_APP_PASSWORD}" \
     -v repl_user="${PG_REPL_USER}" -v repl_pw="${PG_REPL_PASSWORD}" <<'SQL'
SET client_min_messages TO warning;
ALTER ROLE postgres WITH PASSWORD :'su_pw';
SELECT format('CREATE ROLE %I LOGIN', :'app_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec
ALTER ROLE :"app_user" WITH LOGIN PASSWORD :'app_pw';
SELECT format('CREATE ROLE %I WITH REPLICATION LOGIN', :'repl_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'repl_user') \gexec
ALTER ROLE :"repl_user" WITH REPLICATION LOGIN PASSWORD :'repl_pw';
SELECT 'CREATE DATABASE resultats'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'resultats') \gexec
SQL

sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d resultats \
     -v app_user="${PG_APP_USER}" <<'SQL'
SET client_min_messages TO warning;
CREATE TABLE IF NOT EXISTS resultats (
  matricule  varchar(12)  PRIMARY KEY,
  nom        text         NOT NULL,
  serie      varchar(4)   NOT NULL,
  moyenne    numeric(4,2) NOT NULL CHECK (moyenne BETWEEN 0 AND 20),
  admis      boolean      NOT NULL
);
INSERT INTO resultats (matricule, nom, serie, moyenne, admis)
SELECT 'BF2026' || lpad(g::text, 6, '0'),
       'Candidat ' || g,
       (ARRAY['A4','C','D','E','F3','G2'])[1 + g % 6],
       m,
       m >= 10
FROM (SELECT g, round(((g::bigint * 7919) % 2001) / 100.0, 2) AS m
      FROM generate_series(1, 50000) AS g) AS t
WHERE NOT EXISTS (SELECT 1 FROM resultats);
REVOKE ALL ON DATABASE resultats FROM PUBLIC;
GRANT CONNECT ON DATABASE resultats TO :"app_user";
GRANT USAGE ON SCHEMA public TO :"app_user";
REVOKE ALL ON resultats FROM :"app_user";
GRANT SELECT ON resultats TO :"app_user";
SQL

touch "$INIT"
mkdir -p "$(dirname "$ETAT")"
[ "$(cat  "$ETAT"  2>/dev/null | tr -d  '\r\n ')" = "bdd1" ] || echo "bdd1" > "$ETAT"

NB=$(sudo -u postgres psql -tA -d resultats -c "SELECT count(*) FROM resultats")
echo "[bdd] $(hostname) — PRIMAIRE — table resultats : ${NB} lignes — OK"