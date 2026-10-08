#!/usr/bin/env bash
set -euo pipefail
echo "[lb] $(hostname) — serveurs applicatifs lus dans /vagrant/config/noeuds.yml :"
python3 - <<'EOF'
import yaml
inv = yaml.safe_load(open("/vagrant/config/noeuds.yml"))
for n in inv["noeuds"]:
    if n["role"] == "app":
        print(f"   -> {n['nom']}  {n['ip']}")
EOF
echo "[lb] HAProxy : à venir (Étape 5)"