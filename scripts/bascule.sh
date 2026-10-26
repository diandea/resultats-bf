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

chrono "Début de la procédure de bascule"

# 1-3. Vérifications et promotion, exécutées DANS bdd2 en une seule connexion SSH
chrono "1-3/5 Vérifications et promotion de bdd2"
set +e
vagrant ssh bdd2 -c "sudo bash /vagrant/scripts/promouvoir.sh" 2>/dev/null | tr -d '\r'
CODE=${PIPESTATUS[0]}
set -e
case "$CODE" in
  0)  chrono "    bdd2 est désormais PRIMAIRE (lecture et écriture)" ;;
  10) chrono "ARRÊT : bdd1 répond encore. Promouvoir bdd2 créerait deux primaires."; exit 1 ;;
  11) chrono "bdd2 est déjà primaire : rien à faire."; exit 0 ;;
  *)  chrono "ÉCHEC de la promotion (code ${CODE})"; exit 1 ;;
esac

# 4. Mémoriser le nouveau primaire : bdd1 ne redémarrera pas en primaire
chrono "4/5 Enregistrement de l'état : primaire = bdd2"
mkdir -p .etat && echo "bdd2" > .etat/primaire

# 5. Attendre le retour du service de bout en bout (répartiteur -> app -> bdd2)
chrono "5/5 Attente du rétablissement du service via le répartiteur (port ${PORT})"
REP=""
for i in $(seq 1 60); do
  REP=$(curl --noproxy '*' -s -m 2 "http://127.0.0.1:${PORT}/sante" || true)
  case "$REP" in *'"statut":"ok"'*) break ;; esac
  sleep 0.5
done
case "$REP" in
  *'"statut":"ok"'*) chrono "SERVICE RÉTABLI : $REP" ;;
  *) chrono "ÉCHEC : service non rétabli : ${REP:-aucune réponse du répartiteur}"; exit 1 ;;
esac

echo
echo "Réintégrer bdd1 (en réplique de bdd2)          : vagrant up bdd1"
echo "Revenir à la situation nominale (bdd1 primaire) : vagrant destroy -f && vagrant up"
