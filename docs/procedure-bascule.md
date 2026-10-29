# Procédure de bascule de la base — RÉSULTATS-BF

## Quand l'appliquer
bdd1 (primaire) est hors service : `/sante` renvoie 503 en JSON sur tous les serveurs.

## Bascule (environ 32,7 s, voir mesures/v4_bascule.txt)
    bash scripts/bascule.sh
La procédure refuse de s'exécuter si bdd1 répond encore (protection contre deux primaires).
Aucune intervention sur les serveurs applicatifs ni sur le répartiteur : les applications
se connectent automatiquement au serveur qui accepte les écritures.

## Après la bascule : réintégrer bdd1
    vagrant up bdd1
bdd1 détecte que bdd2 est primaire et se reconstruit automatiquement en réplique de bdd2.
Si bdd2 est injoignable à ce moment-là, bdd1 reste arrêtée ; relancer `vagrant provision bdd1`
une fois bdd2 démarrée.

## Revenir à la situation nominale (bdd1 primaire)
    vagrant destroy -f && vagrant up

## Vérifications
    vagrant ssh bdd2 -c "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'"   # f = primaire
    curl -s http://127.0.0.1:8080/sante                                             # "base":"192.168.59.32"
