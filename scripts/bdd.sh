#!/usr/bin/env bash
# bdd1 — PostgreSQL primaire : installation, configuration, rôles, données
# Idempotent : peut être rejoué sans rien modifier.
set -euo pipefail
source /vagrant/scripts/lib.sh

PG_VER=16
SERVICE="postgresql@${PG_VER}-main"
echo "[bdd] $(hostname) — PostgreSQL ${PG_VER} (primaire)"

# --- 1. Installation et configuration -------------------------------------
installer_paquets "postgresql-${PG_VER}"
systemctl enable --now "$SERVICE" > /dev/null 2>&1

if ecrire_config_postgresql; then
  echo "   redémarrage de PostgreSQL (configuration modifiée)"
  systemctl restart "$SERVICE"
fi
attendre_postgresql

# --- 2. Rôles et base -------------------------------------------------------
cd /tmp   # évite l'avertissement « could not change directory » de sudo -u postgres

sudo -u postgres psql -q -v ON_ERROR_STOP=1 \
     -v su_pw="${PG_SUPERUSER_PASSWORD}" \
     -v app_user="${PG_APP_USER}"  -v app_pw="${PG_APP_PASSWORD}" \
     -v repl_user="${PG_REPL_USER}" -v repl_pw="${PG_REPL_PASSWORD}" <<'SQL'
SET client_min_messages TO warning;
ALTER ROLE postgres WITH PASSWORD :'su_pw';

-- Compte applicatif (lecture seule, droits accordés plus bas)
SELECT format('CREATE ROLE %I LOGIN', :'app_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec
ALTER ROLE :"app_user" WITH LOGIN PASSWORD :'app_pw';

-- Compte de réplication (droit REPLICATION uniquement)
SELECT format('CREATE ROLE %I WITH REPLICATION LOGIN', :'repl_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'repl_user') \gexec
ALTER ROLE :"repl_user" WITH REPLICATION LOGIN PASSWORD :'repl_pw';

SELECT 'CREATE DATABASE resultats'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'resultats') \gexec
SQL

# --- 3. Table et données ----------------------------------------------------
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

-- 50 000 candidats, jeu DÉTERMINISTE ; n'insère que si la table est vide
INSERT INTO resultats (matricule, nom, serie, moyenne, admis)
SELECT 'BF2026' || lpad(g::text, 6, '0'),
       'Candidat ' || g,
       (ARRAY['A4','C','D','E','F3','G2'])[1 + g % 6],
       m,
       m >= 10
FROM (SELECT g, round(((g::bigint * 7919) % 2001) / 100.0, 2) AS m
      FROM generate_series(1, 50000) AS g) AS t
WHERE NOT EXISTS (SELECT 1 FROM resultats);

-- Moindre privilège : le compte applicatif ne peut que LIRE
REVOKE ALL ON DATABASE resultats FROM PUBLIC;
GRANT CONNECT ON DATABASE resultats TO :"app_user";
GRANT USAGE ON SCHEMA public TO :"app_user";
REVOKE ALL ON resultats FROM :"app_user";
GRANT SELECT ON resultats TO :"app_user";
SQL

NB=$(sudo -u postgres psql -tA -d resultats -c "SELECT count(*) FROM resultats")
echo "[bdd] $(hostname) — table resultats : ${NB} lignes — OK"
