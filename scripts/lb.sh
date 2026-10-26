#!/usr/bin/env bash
# lbN — répartiteur HAProxy. Configuration ENGENDRÉE depuis config/noeuds.yml.
# Exécuté à chaque « vagrant up » (run: always) : un changement de NB_APP est
# pris en compte sans intervention (R3). Idempotent : HAProxy n'est rechargé
# que si la configuration a réellement changé.
set -euo pipefail
source /vagrant/scripts/lib.sh
echo "[lb] $(hostname) — répartiteur HAProxy"

installer_paquets haproxy keepalived
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

# --- 1 bis. Réponse du répartiteur quand AUCUN serveur n'est disponible -------
# Du JSON, comme le reste de l'API : jamais une page HTML brute (scénario V4).
# Fichier HTTP complet ; HAProxy attend des fins de ligne CRLF.
install -d -m 755 /etc/haproxy/errors
ecrire_si_change /etc/haproxy/errors/503-resultats.http root:root 644 < <(printf '%s\r\n' \
  'HTTP/1.1 503 Service Unavailable' \
  'Content-Type: application/json; charset=utf-8' \
  'Cache-Control: no-cache' \
  'Connection: close' \
  '' \
  '{"erreur":"service temporairement indisponible","source":"repartiteur"}') && RECHARGER=1
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


# --- 5. keepalived : IP virtuelle VRRP (extension E1) ----------------------------
# Configuration ENGENDRÉE depuis noeuds.yml : priorité selon l'ordre des répartiteurs
# (lb1 = 150, lb2 = 100), pairs VRRP en unicast, IP virtuelle lue dans l'inventaire.
KTMP="$(mktemp)"
trap 'rm -f "$TMP" "$KTMP"' EXIT
NOM="$(hostname)" python3 - > "$KTMP" <<'PY'
import os, yaml
inv  = yaml.safe_load(open("/vagrant/config/noeuds.yml"))
lbs  = [n for n in inv["noeuds"] if n["role"] == "lb"]
moi  = next(n for n in lbs if n["nom"] == os.environ["NOM"])
prio = 150 - 50 * lbs.index(moi)
pairs = [n["ip"] for n in lbs if n is not moi]
unicast = ""
if pairs:
    unicast = (f"    unicast_src_ip {moi['ip']}\n    unicast_peer {{\n"
               + "".join(f"        {ip}\n" for ip in pairs) + "    }\n")
print(f"""# FICHIER ENGENDRE par scripts/lb.sh depuis config/noeuds.yml - ne pas modifier
global_defs {{
    router_id {moi['nom']}
    script_user root
    enable_script_security
}}

# HAProxy arrêté sur ce nœud => priorité abaissée de 60 : le pair prend l'IP virtuelle
vrrp_script haproxy_vivant {{
    script "/usr/bin/pidof haproxy"
    interval 1
    fall 2
    rise 2
    weight -60
}}

vrrp_instance RESULTATS {{
    state BACKUP
    interface eth1
    virtual_router_id {50 + int(inv['groupe'])}
    priority {prio}
    advert_int 1
{unicast}    authentication {{
        auth_type PASS
        auth_pass {os.environ['VRRP_PASSWORD']}
    }}
    virtual_ipaddress {{
        {inv['vip']}/24 dev eth1
    }}
    track_script {{
        haproxy_vivant
    }}
}}""")
PY

if ! keepalived -t -f "$KTMP" > /dev/null 2>&1; then
  echo "ERREUR : configuration keepalived engendrée invalide :"
  keepalived -t -f "$KTMP" || true
  exit 1
fi

systemctl enable keepalived > /dev/null 2>&1
if ecrire_si_change /etc/keepalived/keepalived.conf root:root 640 < "$KTMP"; then
  echo "   (re)démarrage de keepalived (configuration modifiée)"
  systemctl restart keepalived
else
  systemctl start keepalived
fi
VIP=$(python3 -c 'import yaml; print(yaml.safe_load(open("/vagrant/config/noeuds.yml"))["vip"])')
for i in $(seq 1 8); do                      # élection VRRP : ~3,6 s sans annonce
  ip -4 addr show eth1 | grep -q "${VIP}/" && break
  sleep 1
done
if ip -4 addr show eth1 | grep -q "${VIP}/"; then
  echo "[lb] $(hostname) — keepalived actif — PORTE l'IP virtuelle (maître)"
else
  echo "[lb] $(hostname) — keepalived actif — en secours (ne porte pas l'IP virtuelle)"
fi
