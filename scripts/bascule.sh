#!/usr/bin/env bash
# Procédure de bascule de la base (R6) : promotion de bdd2 en primaire.
# À exécuter SUR L'HÔTE (Git Bash), depuis la racine du dépôt :
#     bash scripts/bascule.sh
# Préalable : bdd1 est hors service. Affiche la durée de chaque étape et la durée totale.
set -euo pipefail
cd "$(dirname "$0")/.."

T0=$(date +%s.%N)
chrono() { awk -v t="$(date +%s.%N)" -v t0="$T0" -v m="$*" 'BEGIN { printf "[%6.2f s] %s\n", t - t0, m }'; }
PORT=$(grep -E '^PORT_HOTE=' .env 2>/dev/null | cut -d= -f2 | tr -d '\r ' || true); PORT=${PORT:-8080}
sql_bdd2() { vagrant ssh bdd2 -c "sudo -u postgres psql -tAc \"$1\"" 2>/dev/null | tr -d '\r[:space:]' || true; }

chrono "Début de la procédure de bascule"

# 1. Sécurité : ne JAMAIS promouvoir bdd2 si bdd1 répond encore (deux primaires)
chrono "1/5 Vérification que bdd1 est bien hors service"
if vagrant ssh bdd2 -c 'source /vagrant/scripts/lib.sh; pg_isready -q -h "$(ip_noeud bdd1)" -t 2' 2>/dev/null; then
  chrono "ARRÊT : bdd1 répond encore. Promouvoir bdd2 créerait deux primaires."
  exit 1
fi

# 2. bdd2 doit être une réplique en état de marche
chrono "2/5 Vérification que bdd2 est une réplique"
case "$(sql_bdd2 'SELECT pg_is_in_recovery()')" in
  t) ;;
  f) chrono "bdd2 est déjà primaire : rien à faire."; exit 0 ;;
  *) chrono "ARRÊT : bdd2 ne répond pas."; exit 1 ;;
esac

# 3. Promotion
chrono "3/5 Promotion de bdd2 (pg_promote)"
[ "$(sql_bdd2 'SELECT pg_promote(true, 30)')" = "t" ] || { chrono "ÉCHEC de la promotion"; exit 1; }
chrono "    bdd2 est désormais PRIMAIRE (lecture et écriture)"

# 4. Mémoriser le nouveau primaire : bdd1 ne redémarrera pas en primaire
chrono "4/5 Enregistrement de l'état : primaire = bdd2"
mkdir -p .etat && echo "bdd2" > .etat/primaire

# 5. Attendre le retour du service de bout en bout (répartiteur -> app -> bdd2)
chrono "5/5 Attente du rétablissement du service via le répartiteur"
REP=""
for i in $(seq 1 120); do
  REP=$(curl -s -m 3 "http://127.0.0.1:${PORT}/sante" || true)
  case "$REP" in *'"statut":"ok"'*) break ;; esac
  sleep 0.5
done
case "$REP" in
  *'"statut":"ok"'*) chrono "SERVICE RÉTABLI : $REP" ;;
  *) chrono "ÉCHEC : service non rétabli après 60 s : $REP"; exit 1 ;;
esac

echo
echo "Réintégrer bdd1 (en réplique de bdd2)     : vagrant up bdd1"
echo "Revenir à la situation nominale (bdd1 primaire) : vagrant destroy -f && vagrant up"