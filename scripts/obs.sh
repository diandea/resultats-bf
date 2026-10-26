#!/usr/bin/env bash
# obs — supervision : Prometheus + Grafana (extension E2).
# Rejoué à chaque « vagrant up » : les cibles de Prometheus suivent noeuds.yml.
# Idempotent : services relancés seulement si leur configuration change.
set -euo pipefail
source /vagrant/scripts/lib.sh
GRAFANA_VERSION="11.2.0"      # version épinglée (reproductibilité)
echo "[obs] $(hostname) — Prometheus + Grafana"

# --- 1. Prometheus (dépôt Ubuntu) -------------------------------------------------
installer_paquets prometheus

# --- 2. Grafana (dépôt officiel, version épinglée) --------------------------------
if ! dpkg -s grafana > /dev/null 2>&1; then
  echo "   installation de Grafana ${GRAFANA_VERSION} (dépôt apt.grafana.com)"
  installer_paquets gnupg
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
    apt-get install -y -qq "grafana=${GRAFANA_VERSION}" > /dev/null
fi

# --- 3. Configuration de Prometheus ENGENDRÉE depuis la source de vérité ----------
PROM_CHANGE=0
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
python3 - > "$TMP" <<'PY'
import yaml
inv = yaml.safe_load(open("/vagrant/config/noeuds.yml"))
noeuds = inv["noeuds"]
def cible(n, port):
    return {"targets": [f"{n['ip']}:{port}"], "labels": {"nom": n["nom"], "role": n["role"]}}
conf = {
    "global": {"scrape_interval": "2s", "evaluation_interval": "2s"},
    "scrape_configs": [
        {"job_name": "node",
         "static_configs": [cible(n, 9100) for n in noeuds]},
        {"job_name": "haproxy", "metrics_path": "/metrics",
         "static_configs": [cible(n, 8404) for n in noeuds if n["role"] == "lb"]},
    ],
}
print("# FICHIER ENGENDRE par scripts/obs.sh depuis config/noeuds.yml - ne pas modifier")
print(yaml.safe_dump(conf, sort_keys=False), end="")
PY
if ! promtool check config "$TMP" > /dev/null 2>&1; then
  echo "ERREUR : prometheus.yml engendré invalide :"; promtool check config "$TMP" || true; exit 1
fi
ecrire_si_change /etc/prometheus/prometheus.yml root:root 644 < "$TMP" && PROM_CHANGE=1
ecrire_si_change /etc/default/prometheus root:root 644 <<'EOF' && PROM_CHANGE=1
# Géré par le provisionnement Vagrant — rétention courte (VM de 768 Mo)
ARGS="--storage.tsdb.retention.time=2d"
EOF

systemctl enable prometheus > /dev/null 2>&1
if [ "$PROM_CHANGE" = 1 ]; then
  echo "   (re)démarrage de Prometheus (configuration modifiée)"
  systemctl restart prometheus
else
  systemctl start prometheus
fi

# --- 4. Grafana : source de données, tableau de bord et réglages, décrits en code --
GRAF_CHANGE=0
install -d -o root -g grafana -m 755 /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards
install -d -o grafana -g grafana -m 755 /var/lib/grafana/dashboards

ecrire_si_change /etc/grafana/provisioning/datasources/resultats.yaml root:grafana 640 <<'EOF' && GRAF_CHANGE=1
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus-resultats
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    jsonData:
      timeInterval: 2s
EOF

ecrire_si_change /etc/grafana/provisioning/dashboards/resultats.yaml root:grafana 640 <<'EOF' && GRAF_CHANGE=1
apiVersion: 1
providers:
  - name: resultats-bf
    folder: RESULTATS-BF
    type: file
    options:
      path: /var/lib/grafana/dashboards
EOF

ecrire_si_change /var/lib/grafana/dashboards/resultats-bf.json grafana:grafana 644 \
  < /vagrant/config/grafana-resultats.json && GRAF_CHANGE=1

# Réglages par variables d'environnement (sans modifier grafana.ini du paquet)
install -d -m 755 /etc/systemd/system/grafana-server.service.d
if ecrire_si_change /etc/systemd/system/grafana-server.service.d/resultats.conf root:root 640 <<EOF
[Service]
Environment=GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
Environment=GF_AUTH_ANONYMOUS_ENABLED=true
Environment=GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
Environment=GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/resultats-bf.json
Environment=GF_ANALYTICS_REPORTING_ENABLED=false
Environment=GF_ANALYTICS_CHECK_FOR_UPDATES=false
EOF
then systemctl daemon-reload; GRAF_CHANGE=1; fi

systemctl enable grafana-server > /dev/null 2>&1
if [ "$GRAF_CHANGE" = 1 ]; then
  echo "   (re)démarrage de Grafana (configuration modifiée)"
  systemctl restart grafana-server
else
  systemctl start grafana-server
fi

# --- 5. Contrôles -----------------------------------------------------------------
for i in $(seq 1 60); do
  curl -sf -o /dev/null http://127.0.0.1:3000/api/health && break
  sleep 2
done
curl -sf -o /dev/null http://127.0.0.1:3000/api/health || { echo "ERREUR : Grafana ne répond pas"; exit 1; }
sleep 4   # laisser Prometheus effectuer un premier passage
curl -s http://127.0.0.1:9090/api/v1/targets | python3 -c '
import json, sys
c = json.load(sys.stdin)["data"]["activeTargets"]
up = [t["labels"]["nom"] + "/" + t["labels"]["job"] for t in c if t["health"] == "up"]
ko = [t["labels"]["nom"] + "/" + t["labels"]["job"] for t in c if t["health"] != "up"]
print(f"   cibles Prometheus : {len(up)} joignable(s) sur {len(c)}")
if ko: print("   pas encore joignables : " + ", ".join(ko))'
echo "[obs] $(hostname) — Grafana : http://$(ip_noeud obs):3000  (lecture anonyme ; admin / mot de passe du .env)"