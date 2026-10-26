#!/usr/bin/env bash
# Exécuté DANS bdd2 par scripts/bascule.sh, en une seule connexion SSH.
# Codes retour : 0 = promue ; 10 = bdd1 répond encore ; 11 = déjà primaire ; 1 = échec
set -euo pipefail
source /vagrant/scripts/lib.sh
cd /tmp
T0=$(date +%s.%N)
chrono() { awk -v t="$(date +%s.%N)" -v t0="$T0" -v m="$*" 'BEGIN { printf "      [bdd2 +%5.2f s] %s\n", t - t0, m }'; }

IP1="$(ip_noeud bdd1)"
chrono "1/3 bdd1 (${IP1}) est-elle hors service ?"
if pg_isready -q -h "$IP1" -t 2; then chrono "    bdd1 répond encore"; exit 10; fi
chrono "    bdd1 ne répond pas"

chrono "2/3 bdd2 est-elle une réplique ?"
case "$(sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()')" in
  t) chrono "    oui" ;;
  f) chrono "    bdd2 est déjà primaire"; exit 11 ;;
  *) chrono "    bdd2 ne répond pas"; exit 1 ;;
esac

chrono "3/3 Promotion (pg_promote)"
[ "$(sudo -u postgres psql -tAc 'SELECT pg_promote(true, 30)')" = "t" ] || { chrono "    échec"; exit 1; }
chrono "    bdd2 est PRIMAIRE"
