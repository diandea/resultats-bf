#!/usr/bin/env bash
# Provisionnement commun à toutes les VM — idempotent
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_SUSPEND=1

echo "[commun] $(hostname) — groupe ${GROUPE}, réseau ${RESEAU}.0/24"

# Fuseau horaire : ne change que si nécessaire
if [ "$(timedatectl show -p Timezone --value)" != "Africa/Ouagadougou" ]; then
  timedatectl set-timezone Africa/Ouagadougou
fi

# apt-get update au plus une fois par heure (provisionnement rejouable et économe)
if [ -z "$(find /var/lib/apt/lists -maxdepth 1 -name '*_InRelease' -mmin -60 2>/dev/null)" ]; then
  apt-get update -qq
fi

# Paquets communs, installés en un seul appel
apt-get install -y -qq --no-install-recommends curl python3-yaml prometheus-node-exporter > /dev/null
echo "[commun] $(hostname) — OK"