#!/usr/bin/env bash
# Campagne V6 (extension E1) : panne du répartiteur maître, reprise par lb2 via l'IP virtuelle.
# À EXÉCUTER SUR L'HÔTE (Git Bash), depuis la racine du dépôt, avec NB_LB=2 :
#     bash scripts/mesure_v6.sh            # arrêt propre de lb1 (vagrant halt)
#     bash scripts/mesure_v6.sh --brutal   # coupure brutale (vagrant halt -f)
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="propre"; ARRET="vagrant halt lb1"
[ "${1:-}" = "--brutal" ] && { MODE="brutal"; ARRET="vagrant halt -f lb1"; }
VIP=$(awk '/^vip:/ {print $2}' config/noeuds.yml)
URL="http://${VIP}/sante"
DISPO="mesures/v6_disponibilite_${MODE}.txt"
SYNTH="mesures/v6_synthese_${MODE}.txt"
STOP=.etat/fin_mesure_v6
mkdir -p mesures .etat; rm -f "$STOP"

# --- 0. Contrôles préalables
echo "== Contrôle 1 : le service répond-il sur l'IP virtuelle ${VIP} ?"
REP=$(curl --noproxy '*' -s -m 5 -w ' [%{http_code}]' "$URL" || true)
case "$REP" in *'"statut":"ok"'*) echo "   OK : $REP" ;; *) echo "ARRÊT : réponse : ${REP:-aucune}"; exit 1 ;; esac
echo "== Contrôle 2 : lb1 porte-t-il l'IP virtuelle, et lb2 est-il démarré ?"
vagrant ssh lb1 -c "ip -4 -br addr show eth1" 2>/dev/null | tr -d '\r' | grep -q "${VIP}/" \
  || { echo "ARRÊT : lb1 ne porte pas l'IP virtuelle"; exit 1; }
vagrant status lb2 | grep -q running || { echo "ARRÊT : lb2 n'est pas démarré (NB_LB=2 ?)"; exit 1; }

# --- 1. Sonde client sur l'IP virtuelle, en arrière-plan
: > "$DISPO"
( while [ ! -f "$STOP" ]; do
    printf '%s %s\n' "$(date +%H:%M:%S.%3N)" "$(curl --noproxy '*' -s -m 1 -w ' %{http_code}' "$URL" | tr -d '\n')"
    sleep 0.25
  done ) >> "$DISPO" &
SONDE=$!
trap 'touch "$STOP"' EXIT
sleep 5

# --- 2. Panne du répartiteur maître
echo "== $(date +%T) PANNE (${MODE}) : ${ARRET}"
T_PANNE=$(date +%H:%M:%S.%3N)
$ARRET

# --- 3. Observation 15 s, puis arrêt de la sonde
sleep 15
touch "$STOP"; wait "$SONDE" || true; rm -f "$STOP"

# --- 4. Qui porte l'IP virtuelle maintenant ?
PORTEUR=$(vagrant ssh lb2 -c "ip -4 -br addr show eth1" 2>/dev/null | tr -d '\r')

# --- 5. Dépouillement
{
  echo "Campagne V6 (${MODE}) du $(date '+%Y-%m-%d %H:%M') — IP virtuelle ${VIP}"
  echo "Commande de panne lancée à : ${T_PANNE}"
  echo "Requêtes envoyées : $(wc -l < "$DISPO")"
  awk '
    function sec(t,  a) { split(t, a, ":"); return a[1]*3600 + a[2]*60 + a[3] }
    { code[$NF]++ }
    $NF != "200" && !debut { debut = $1 }
    debut && $NF == "200" && !fin { fin = $1 }
    END {
      for (k in code) printf "  code %s : %d\n", k, code[k]
      if (debut) {
        printf "Début de l interruption : %s\n", debut
        if (fin) printf "Reprise du service      : %s\nDurée d interruption    : %.1f s\n", fin, sec(fin) - sec(debut)
        else     print  "Reprise du service      : NON OBSERVÉE"
      } else print "Aucune interruption observée : la reprise a été transparente pour le client"
    }' "$DISPO"
  echo "Interfaces de lb2 après la panne : ${PORTEUR}"
} | tee "$SYNTH"
echo
echo "Remettre lb1 en service : vagrant up lb1   (il reprendra l'IP virtuelle, priorité 150)"