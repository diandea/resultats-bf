#!/usr/bin/env bash
# Preuve globale d'idempotence (R2). À EXÉCUTER SUR L'HÔTE, plateforme démarrée :
#     bash scripts/verifier_idempotence.sh
# Rejoue DEUX FOIS « vagrant provision » sur toutes les VM démarrées et vérifie :
#   1. que chaque rejeu réussit ;
#   2. qu'aucun fichier de configuration géré n'a changé (empreintes md5) ;
#   3. qu'aucun rejeu n'a écrit de fichier, installé de paquet ni (re)démarré de service.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p mesures
RAPPORT=mesures/r2_idempotence.txt
FICHIERS="/etc/postgresql /etc/haproxy /etc/keepalived /etc/resultats /opt/resultats \
/etc/prometheus /etc/default/prometheus /etc/grafana/provisioning /var/lib/grafana/dashboards \
/etc/systemd/system/resultats.service /etc/systemd/system/grafana-server.service.d \
/var/lib/postgresql/.pgpass"

VMS=$(vagrant status --machine-readable | awk -F, '$3=="state" && $4=="running" {print $2}' | tr '\n' ' ')
[ -n "$VMS" ] || { echo "ARRÊT : aucune VM démarrée"; exit 1; }
T=$(mktemp -d)

empreintes() {   # $1 = fichier de sortie : « vm  md5  chemin »
  : > "$1"
  for vm in $VMS; do
    vagrant ssh "$vm" -c "sudo find $FICHIERS -type f 2>/dev/null | sort | sudo xargs -r md5sum" 2>/dev/null \
      | tr -d '\r' | sed "s|^|${vm}  |" >> "$1"
  done
}
rejeu() {        # $1 = numéro du rejeu
  echo "== Rejeu $1 : vagrant provision"
  if ! vagrant provision > "$T/p$1.log" 2>&1; then
    echo "ÉCHEC du rejeu $1 :"; tail -30 "$T/p$1.log"; exit 1
  fi
}

echo "== VM concernées : $VMS"
echo "== Empreintes initiales";   empreintes "$T/a"
rejeu 1;  echo "== Empreintes après rejeu 1"; empreintes "$T/b"
rejeu 2;  echo "== Empreintes après rejeu 2"; empreintes "$T/c"

OK=1
{
  echo "Vérification d'idempotence (R2) du $(date '+%Y-%m-%d %H:%M')"
  echo "VM : $VMS"
  echo "Fichiers de configuration surveillés : $(wc -l < "$T/a")"
  for n in 1 2; do
    A=$(grep -cE '\+ écrit|démarrage|rechargement|installation' "$T/p$n.log" || true)
    echo "Rejeu $n : réussi — ${A} action(s) de modification signalée(s)"
    [ "$A" = "0" ] || { OK=0; grep -E '\+ écrit|démarrage|rechargement|installation' "$T/p$n.log"; }
  done
  if diff -q "$T/a" "$T/b" > /dev/null; then echo "Empreintes initiales / après rejeu 1 : IDENTIQUES"
  else OK=0; echo "Empreintes initiales / après rejeu 1 : DIFFÉRENTES"; diff "$T/a" "$T/b" || true; fi
  if diff -q "$T/b" "$T/c" > /dev/null; then echo "Empreintes après rejeu 1 / après rejeu 2 : IDENTIQUES"
  else OK=0; echo "Empreintes après rejeu 1 / après rejeu 2 : DIFFÉRENTES"; diff "$T/b" "$T/c" || true; fi
  [ "$OK" = 1 ] && echo "VERDICT : R2 VÉRIFIÉE" || echo "VERDICT : R2 NON VÉRIFIÉE"
} | tee "$RAPPORT"
rm -rf "$T"
[ "$OK" = 1 ]