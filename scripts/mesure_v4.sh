#!/usr/bin/env bash
# Campagne de mesure V4 : panne de la base primaire, puis bascule.
# À EXÉCUTER SUR L'HÔTE (Git Bash), depuis la racine du dépôt :
#     bash scripts/mesure_v4.sh
# Produit : mesures/v4_disponibilite.txt  (une ligne par requête /sante)
#           mesures/v4_bascule.txt        (sortie chronométrée de la procédure)
#           mesures/v4_synthese.txt       (dépouillement)
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=$(grep -E '^PORT_HOTE=' .env 2>/dev/null | cut -d= -f2 | tr -d '\r ' || true); PORT=${PORT:-8080}
URL="http://127.0.0.1:${PORT}/sante"
DISPO=mesures/v4_disponibilite.txt
BASC=mesures/v4_bascule.txt
SYNTH=mesures/v4_synthese.txt
STOP=.etat/fin_mesure
mkdir -p mesures .etat
rm -f "$STOP"

# --- 0. Contrôles préalables : on ne mesure que depuis la situation nominale ---
echo "== Contrôle 1 : le service répond-il sur le port ${PORT} ?"
REP=$(curl --noproxy '*' -s -m 5 -w ' [%{http_code}]' "$URL" || true)
case "$REP" in
  *'"statut":"ok"'*) echo "   OK : $REP" ;;
  *) echo "ARRÊT : /sante ne répond pas 200. Réponse reçue : ${REP:-aucune}"; exit 1 ;;
esac
echo "== Contrôle 2 : bdd2 est-elle bien une réplique ?"
R=$(vagrant ssh bdd2 -c "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'" 2>/dev/null | tr -d '\r[:space:]' || true)
[ "$R" = "t" ] || { echo "ARRÊT : bdd2 n'est pas une réplique. Revenir au nominal : vagrant destroy -f && vagrant up"; exit 1; }

# --- 1. Sonde client en arrière-plan : une requête toutes les 0,25 s jusqu'au signal d'arrêt
: > "$DISPO"
( while [ ! -f "$STOP" ]; do
    printf '%s %s\n' "$(date +%H:%M:%S.%3N)" "$(curl --noproxy '*' -s -m 5 -w ' %{http_code}' "$URL" | tr -d '\n')"
    sleep 0.25
  done ) >> "$DISPO" &
SONDE=$!
trap 'touch "$STOP"' EXIT          # la sonde s'arrête quoi qu'il arrive
sleep 5

# --- 2. Panne du primaire -------------------------------------------------------
echo "== $(date +%T) PANNE : arrêt de bdd1"
vagrant halt bdd1

# --- 3. Procédure de bascule chronométrée ---------------------------------------
echo "== $(date +%T) BASCULE"
bash scripts/bascule.sh | tee "$BASC" || echo "!! la procédure de bascule a signalé un échec"

# --- 4. Observation du service rétabli pendant 20 s, puis arrêt de la sonde -----
sleep 20
touch "$STOP"; wait "$SONDE" || true; rm -f "$STOP"

# --- 5. Dépouillement --------------------------------------------------------------
{
  echo "Campagne V4 du $(date '+%Y-%m-%d %H:%M') — port ${PORT}"
  echo "Requêtes envoyées : $(wc -l < "$DISPO")"
  awk '
    function sec(t,  a) { split(t, a, ":"); return a[1]*3600 + a[2]*60 + a[3] }
    { code[$NF]++ }
    $NF != "200" && !debut { debut = $1 }
    debut && $NF == "200" && !fin { fin = $1 }
    END {
      for (k in code) printf "  code %s : %d\n", k, code[k]
      if (debut) {
        printf "Début de l indisponibilité : %s\n", debut
        if (fin) printf "Retour du service          : %s\nDurée d indisponibilité    : %.1f s\n", fin, sec(fin) - sec(debut)
        else     print  "Retour du service          : NON OBSERVÉ"
      } else print "Aucune indisponibilité observée (la panne n a pas été captée)"
    }' "$DISPO"
  echo "Dernière réponse : $(tail -1 "$DISPO")"
  echo
  echo "Procédure de bascule :"
  cat "$BASC"
} | tee "$SYNTH"
