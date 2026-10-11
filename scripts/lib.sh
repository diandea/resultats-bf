#!/usr/bin/env bash
# Fonctions communes aux scripts de provisionnement

# ecrire_si_change DESTINATION PROPRIETAIRE MODE  (contenu lu sur l'entrée standard)
# Écrit le fichier uniquement si son contenu diffère.
# Code retour : 0 = fichier modifié, 1 = inchangé.
ecrire_si_change() {
  local dest="$1" proprio="$2" mode="$3" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    echo "   = inchangé : $dest"
    return 1
  fi
  install -o "${proprio%%:*}" -g "${proprio##*:}" -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
  echo "   + écrit    : $dest"
  return 0
}

# installer_paquets PAQUET...  (n'appelle apt que s'il manque quelque chose)
installer_paquets() {
  local manquants=()
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || manquants+=("$p")
  done
  if [ ${#manquants[@]} -gt 0 ]; then
    echo "   installation : ${manquants[*]}"
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
      apt-get install -y -qq --no-install-recommends "${manquants[@]}" > /dev/null
  fi
}
