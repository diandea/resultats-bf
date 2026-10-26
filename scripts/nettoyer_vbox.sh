#!/usr/bin/env bash
# Nettoyage des restes VirtualBox du projet, AVANT une reconstruction depuis zéro.
# À EXÉCUTER SUR L'HÔTE (Git Bash), interface VirtualBox FERMÉE :
#     bash scripts/nettoyer_vbox.sh
# Ne touche QU'aux VM et dossiers nommés rbf-g<N>-* et temp_clone_* ;
# la VM maître des clones liés et les autres VM du poste sont préservées.
set -euo pipefail
cd "$(dirname "$0")/.."

VBOX="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
[ -x "$VBOX" ] || VBOX="VBoxManage"
DOSSIER_VMS="/c/Users/${USERNAME:-$USER}/VirtualBox VMs"
GROUPE=$(grep -E '^GROUPE=' .env 2>/dev/null | cut -d= -f2 | tr -d '\r ' || true); GROUPE=${GROUPE:-4}
MOTIF="rbf-g${GROUPE}-"

echo "== 1/4 vagrant destroy -f"
vagrant destroy -f

echo "== 2/4 VM résiduelles enregistrées dans VirtualBox"
"$VBOX" list vms | grep -oE "\"(temp_clone_|${MOTIF})[^\"]*\"" | tr -d '"' | while read -r vm; do
  echo "   suppression de $vm"; "$VBOX" unregistervm "$vm" --delete || true
done

echo "== 3/4 Dossiers résiduels dans ${DOSSIER_VMS}"
rm -rf "${DOSSIER_VMS}"/${MOTIF}* "${DOSSIER_VMS}"/temp_clone_*

echo "== 4/4 Vérifications"
if ls "${DOSSIER_VMS}" 2>/dev/null | grep -qE "${MOTIF}|temp_clone_"; then
  echo "ÉCHEC : des dossiers résiduels subsistent (interface VirtualBox ouverte ?)"; exit 1
fi
vagrant global-status --prune > /dev/null
echo "PROPRE — vous pouvez lancer : time vagrant up"
