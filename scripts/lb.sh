#!/usr/bin/env bash
# lbN — répartiteur HAProxy. Configuration ENGENDRÉE depuis config/noeuds.yml.
# Exécuté à chaque « vagrant up » (run: always) : un changement de NB_APP est
# pris en compte sans intervention (R3). Idempotent : HAProxy n'est rechargé
# que si la configuration a réellement changé.
set -euo pipefail
source /vagrant/scripts/lib.sh
echo "[lb] $(hostname) — répartiteur HAProxy"

installer_paquets haproxy
RECHARGER=0

# --- 1. Engendrer la configuration depuis la source de vérité ----------------
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
NOM="$(hostname)" python3 - > "$TMP" <<'PY'
import os, yaml
inv = yaml.safe_load(open("/vagrant/config/noeuds.yml"))
moi = next(n for n in inv["noeuds"] if n["nom"] == os.environ["NOM"])
apps = [n for n in inv["noeuds"] if n["role"] == "app"]
serveurs = "\n".join(f"    server {n['nom']} {n['ip']}:3000 check" for n in apps)
modele = open("/vagrant/config/haproxy.cfg.modele", encoding="utf-8").read()
print("# FICHIER ENGENDRE par scripts/lb.sh depuis config/noeuds.yml - ne pas modifier\n")
config = modele.replace("@@SERVEURS@@", serveurs).replace("@@IP_LB@@", moi["ip"])
print(config if config.endswith("\n") else config + "\n", end="")
PY

# --- 2. Vérifier AVANT d'installer : jamais de configuration invalide en service
if ! haproxy -c -q -f "$TMP"; then
  echo "ERREUR : configuration HAProxy engendrée invalide :"
  haproxy -c -f "$TMP" || true
  exit 1
fi

# --- 3. Installer, puis recharger seulement si quelque chose a changé ---------
ecrire_si_change /etc/haproxy/haproxy.cfg root:root 644 < "$TMP" && RECHARGER=1

systemctl enable haproxy > /dev/null 2>&1
if [ "$RECHARGER" = 1 ]; then
  echo "   rechargement de HAProxy (sans coupure des connexions en cours)"
  systemctl reload-or-restart haproxy
else
  systemctl start haproxy          # sans effet s'il tourne déjà
fi

# --- 4. Contrôle ---------------------------------------------------------------
NB=$(grep -c '^\s*server ' /etc/haproxy/haproxy.cfg)
echo "[lb] $(hostname) — ${NB} serveur(s) applicatif(s) engendré(s) :"
grep '^\s*server ' /etc/haproxy/haproxy.cfg | awk '{print "   -> " $2 "  " $3}'