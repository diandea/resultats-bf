#!/usr/bin/env bash
# bdd1 — PostgreSQL primaire : installation, configuration, rôles, données
# Idempotent : peut être rejoué sans rien modifier.
set -euo pipefail
source /vagrant/scripts/lib.sh

PG_VER=16
PG_CONF_DIR="/etc/postgresql/${PG_VER}/main"
echo "[bdd] $(hostname) — PostgreSQL ${PG_VER} (primaire)"

# --- 1. Installation -----------------------------------------------------
installer_paquets "postgresql-${PG_VER}"
systemctl enable --now "postgresql@${PG_VER}-main" > /dev/null 2>&1

REDEMARRER=0
RECHARGER=0

# --- 2. Configuration (fichier dédié dans conf.d, inclus par défaut) ----
if ecrire_si_change "${PG_CONF_DIR}/conf.d/resultats.conf" postgres:postgres 644 <<EOF
# Géré par le provisionnement Vagrant — ne pas modifier à la main
listen_addresses = '*'          # filtrage assuré par pg_hba.conf
port = 5432
max_connections = 100
EOF
then REDEMARRER=1; fi

# --- 3. Contrôle d'accès : réseau privé uniquement, mot de passe obligatoire
if ecrire_si_change "${PG_CONF_DIR}/pg_hba.conf" postgres:postgres 640 <<EOF
# Géré par le provisionnement Vagrant — ne pas modifier à la main
# TYPE  BASE       UTILISATEUR      ADRESSE              MÉTHODE
local   all        postgres                              peer
local   all        all                                   peer
host    all        all              127.0.0.1/32         scram-sha-256
host    resultats  ${PG_APP_USER}   ${RESEAU}.0/24       scram-sha-256
EOF
then RECHARGER=1; fi

if [ "$REDEMARRER" = 1 ]; then
  echo "   redémarrage de PostgreSQL (listen_addresses modifié)"
  systemctl restart "postgresql@${PG_VER}-main"
elif [ "$RECHARGER" = 1 ]; then
  echo "   rechargement de PostgreSQL (pg_hba.conf modifié)"
  systemctl reload "postgresql@${PG_VER}-main"
fi

# Attendre que le serveur accepte les connexions
for i in $(seq 1 30); do
  pg_isready -q && break
  sleep 1
done
pg_isready -q || { echo "ERREUR : PostgreSQL ne répond pas"; exit 1; }

# --- 4. Rôles, base, table et données -------------------------------------
cd /tmp   # évite l'avertissement « could not change directory » de sudo -u postgres

sudo -u postgres psql -q -v ON_ERROR_STOP=1 \
     -v app_user="${PG_APP_USER}" -v app_pw="${PG_APP_PASSWORD}" \
     -v su_pw="${PG_SUPERUSER_PASSWORD}" <<'SQL'
ALTER ROLE postgres WITH PASSWORD :'su_pw';
SELECT format('CREATE ROLE %I LOGIN', :'app_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec
ALTER ROLE :"app_user" WITH LOGIN PASSWORD :'app_pw';
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

-- 50 000 candidats, jeu DÉTERMINISTE : identique à chaque reconstruction.
-- N'insère que si la table est vide (idempotence).
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
