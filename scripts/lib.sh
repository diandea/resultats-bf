#!/usr/bin/env bash
# Fonctions communes aux scripts de provisionnement

# ecrire_si_change DESTINATION PROPRIETAIRE MODE  (contenu lu sur l'entrée standard)
# Écrit le fichier uniquement si son contenu diffère.
# Code retour : 0 = fichier modifié, 1 = inchangé.
ecrire_si_change() {
  local dest="$1" proprio="$2" mode="$3" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    echo "   = inchangé : $dest"
    return 1
  fi
  install -o "${proprio%%:*}" -g "${proprio##*:}" -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
  echo "   + écrit    : $dest"
  return 0
}

# installer_paquets PAQUET...  (n'appelle apt que s'il manque quelque chose)
installer_paquets() {
  local manquants=()
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || manquants+=("$p")
  done
  if [ ${#manquants[@]} -gt 0 ]; then
    echo "   installation : ${manquants[*]}"
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
      apt-get install -y -qq --no-install-recommends "${manquants[@]}" > /dev/null
  fi
}

# ip_noeud NOM : renvoie l'adresse IP d'un nœud, lue dans la source de vérité
ip_noeud() {
  python3 - "$1" <<'PY'
import sys, yaml
inv = yaml.safe_load(open("/vagrant/config/noeuds.yml"))
print(next(n["ip"] for n in inv["noeuds"] if n["nom"] == sys.argv[1]))
PY
}

# attendre_postgresql [HOTE] : attend jusqu'à 60 s que PostgreSQL accepte les connexions
attendre_postgresql() {
  local hote="${1:-}" i
  for i in $(seq 1 60); do
    if [ -n "$hote" ]; then
      pg_isready -q -h "$hote" -p 5432 && return 0
    else
      pg_isready -q && return 0
    fi
    sleep 1
  done
  echo "ERREUR : PostgreSQL ${hote:-local} ne répond pas"
  return 1
}

# ecrire_config_postgresql : configuration COMMUNE au primaire et à la réplique.
# Identique sur les deux nœuds : après une bascule, bdd2 se comporte comme bdd1.
# Code retour : 0 = au moins un fichier modifié, 1 = rien n'a changé.
ecrire_config_postgresql() {
  local conf_dir="/etc/postgresql/16/main" change=1 ip1 ip2
  ip1="$(ip_noeud bdd1)"
  ip2="$(ip_noeud bdd2)"

  ecrire_si_change "${conf_dir}/conf.d/resultats.conf" postgres:postgres 644 <<EOF && change=0
# Géré par le provisionnement Vagrant — ne pas modifier à la main
listen_addresses = '*'          # filtrage assuré par pg_hba.conf
port = 5432
max_connections = 100
# Réplication en flux
wal_level = replica
max_wal_senders = 10
wal_keep_size = '256MB'
hot_standby = on
EOF

  ecrire_si_change "${conf_dir}/pg_hba.conf" postgres:postgres 640 <<EOF && change=0
# Géré par le provisionnement Vagrant — ne pas modifier à la main
# TYPE  BASE         UTILISATEUR       ADRESSE              MÉTHODE
local   all          postgres                               peer
local   all          all                                    peer
host    all          all               127.0.0.1/32         scram-sha-256
host    resultats    ${PG_APP_USER}    ${RESEAU}.0/24       scram-sha-256
host    replication  ${PG_REPL_USER}   ${ip1}/32            scram-sha-256
host    replication  ${PG_REPL_USER}   ${ip2}/32            scram-sha-256
EOF

  return $change
}
