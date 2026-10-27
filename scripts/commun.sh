#!/usr/bin/env bash
# Provisionnement commun à toutes les VM — idempotent
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_SUSPEND=1
source /vagrant/scripts/lib.sh
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
installer_paquets curl python3-yaml prometheus-node-exporter.;
echo "[commun] $(hostname) — OK"