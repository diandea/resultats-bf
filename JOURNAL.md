# RÉSULTATS-BF — Journal de bord

Groupe 4 · Nassiro (`diandea`, coordination, réseau et répartition), Basile (application), Salif (données), Sanata (essais et observabilité) · du 6 au 27 octobre 2026

Chaque étape a été livrée sur une branche dédiée, puis fusionnée par une Pull Request testée et approuvée par un autre membre sur son propre poste. Le détail de chaque étape se trouve dans l'historique des Pull Requests du dépôt.

---

### Semaine 1 (6 au 11 octobre) — Préparation et socle

- **Organisation.** Rôles répartis, extensions E1 (répartiteur redondant) et E2 (supervision) retenues. Git Bash choisi comme terminal commun. Une branche par étape, avec relecture croisée avant fusion.
- **Décision — box.** La version `202404.23.0` prévue n'était plus publiée sur le catalogue. Le groupe a épinglé `bento/ubuntu-24.04` `202510.26.0` pour tous les postes.
- **Décision — secrets (R7).** `.env.exemple` versionné avec des valeurs factices, `.env` exclu de Git. Le `Vagrantfile` refuse de démarrer si un secret manque.
- **Difficulté — Hyper-V.** VirtualBox tournait en mode dégradé (tortue verte), ce qui aurait faussé toutes les mesures. Hyper-V et l'intégrité de la mémoire ont été désactivés sur tous les postes.
- **Difficulté — `ab.exe`.** L'outil ne démarrait pas sans ses DLL : tout le dossier `Apache24\bin` est désormais copié.
- **Étape 1 (PR #1, Nassiro, relue par Basile).** Socle de 5 VM sur `192.168.59.0/24`, inventaire `config/noeuds.yml` engendré à partir de `NB_APP`. Premier test de reproductibilité sur le poste de Basile : 8 min 23 s.
- **Difficulté — port 8080.** lb1 a échoué parce que le port hôte était occupé. Le port est devenu un paramètre (`PORT_HOTE`), avec `auto_correct: false` pour que l'échec soit explicite. *Leçon : une infrastructure reproductible ne doit pas supposer l'état du poste qui l'héberge.*

### Semaine 2 (12 au 13 octobre) — Base de données et réplication

- **Difficulté — fins de ligne (Salif).** Le premier provisionnement de bdd1 a échoué : `lib.sh` était en CRLF, et la première ligne des scripts contenait le nom du fichier. Ajout de `.editorconfig` et d'un garde-fou CRLF dans le `Vagrantfile`.
- **Décision — protection de `main`.** GitHub ne protège pas les branches d'un dépôt privé gratuit. La protection est remplacée par une convention : aucun envoi direct sur `main`, tout passe par une Pull Request approuvée.
- **Difficulté — carte réseau hôte (Sanata).** `VERR_INTNET_FLT_IF_NOT_FOUND` au premier démarrage : une relance de `vagrant up` a suffi. Vagrant considérant bdd1 comme provisionnée, il a fallu relancer `vagrant provision`. *Règle : après un `up` interrompu, provisionner explicitement ou repartir de `destroy -f`.*
- **Étape 2 (PR #2, Salif, relue par Sanata).** PostgreSQL 16, rôle en lecture seule, 50 000 candidats. Deux constructions indépendantes ont produit des données identiques (25 013 admis ; BF2026000042 à 4,32).
- **Étape 3 (PR #3, Salif, relue par Nassiro).** Réplication en flux bdd1 → bdd2, délai de rejeu de 3,6 ms. Le script de la réplique attend le primaire et s'arrête proprement s'il ne répond pas. Le test R5 a été réécrit pour nommer explicitement la VM visée : la première version interrogeait le primaire.
- **Difficulté — dossiers résiduels.** Après `vagrant destroy -f`, un dossier de VM restait sur le disque (`VERR_ALREADY_EXISTS`). Il fallait le supprimer à la main.

### Semaine 3 (14 au 20 octobre) — Application et répartiteur

- **Nettoyage du `Vagrantfile` (PR #4, Nassiro, relue par Salif).** Source unique de vérité et garde-fous regroupés.
- **Étape 4 (PR #5, Basile et Nassiro, relue par Sanata).** Application Flask servie par gunicorn sous systemd, connexion multi-hôtes à la base, erreurs en JSON, réessai sur connexion périmée.
- **Étape 5 (PR #6, Nassiro et Basile, relue par Salif).** HAProxy engendré à partir d'un modèle. Le premier fichier a été refusé par `haproxy -c` (retour à la ligne final manquant) : le garde-fou a empêché l'installation d'une configuration invalide. Passage de 2 à 4 serveurs par la seule variable `NB_APP`, répartition 10/10/10/10.
- **Difficulté de mesure.** Un premier dépouillement annonçait 75 erreurs sur 150 : chaque réponse occupait deux lignes. Après correction, 0 requête perdue sur 75 pendant la panne d'un serveur. *Leçon : vérifier un chiffre surprenant sur les données brutes.*
- **Récidive des dossiers résiduels** sur le poste de Salif : consigne de fermer l'interface VirtualBox avant toute destruction.

### Semaine 4 (21 au 27 octobre) — Bascule, extensions, consolidation

- **Étape 6 (PR #7, Salif, relue par Basile).** Procédure de bascule et protection contre deux primaires : un ancien primaire est reconstruit en réplique, ou reste arrêté si le nouveau primaire est injoignable.
- **Quatre tentatives de mesure V4 échouées, toutes extérieures au code :**
  1. Windows réservait la plage 8036–8135 sur le poste de Salif ; corrigé par `PORT_HOTE=18080`, sans modifier le dépôt.
  2. Une sonde trop courte, avec un délai client égal au délai de l'application.
  3. Un enchaînement manuel mal minuté, puis des VM figées après une mise en veille de Windows.
  4. L'ouverture de `vagrant ssh` coûtait 8 à 10 s et gonflait le chronométrage ; la promotion se fait désormais en une seule connexion (`promouvoir.sh`).
- **Décision — automatisation.** La campagne a été codée dans `mesure_v4.sh` (contrôles préalables, sonde arrêtée par signal, dépouillement calculé). Résultat du premier coup : 285 requêtes, 0 erreur brute, 184 réponses 503 en JSON, promotion en environ 2,8 s et procédure complète en 32,7 s. *Leçon : une mesure qui dépend de la rapidité de l'opérateur n'est pas reproductible.*
- **E1 (Nassiro, relue par Sanata).** keepalived, IP virtuelle 192.168.59.5. *Défaut trouvé :* sur Ubuntu 24.04, `pidof` est un lien vers `killall5`, et la sonde échouait en permanence sans que rien ne le montre. Elle a été remplacée par `pgrep -x haproxy`, avec un garde-fou. Le délai de sonde client a été ramené de 5 s à 1 s : une correction annoncée dans un commit n'avait pas été enregistrée, ce qu'un commit suivant a rectifié. Résultat : arrêt propre transparent (212/212), coupure brutale de 4,2 s. *Leçon : tester une sonde dans les deux sens, et se méfier des résultats trop ronds.*
- **E2 (Nassiro, relue par Basile).** Prometheus, node_exporter sur toutes les VM, Grafana avec un tableau de bord de 6 panneaux. En l'absence de Sanata, c'est Nassiro qui a réalisé cette extension. Sous 40 000 requêtes, l'arrêt d'un serveur applicatif n'a produit aucun échec.
- **Troisième occurrence des dossiers résiduels**, sur le poste de Basile. Le nettoyage est automatisé dans `nettoyer_vbox.sh`, limité aux VM du projet. Sa première version s'arrêtait sans message sur un poste propre (`grep` sous `pipefail`), d'où la correction `|| true`. *Leçon : tester aussi le cas où il n'y a rien à faire.*
- **Cache de paquets partagé (PR #10, Basile, relue par Salif).** Les paquets téléchargés sont réutilisés par toutes les VM et lors des reconstructions, conformément à la consigne « ne téléchargez pas la même chose quatre fois ».

---

### Bilan au 27 octobre

R1 à R8, E1 et E2 sont réalisées et fusionnées. Restent la preuve globale d'idempotence (`verifier_idempotence.sh`), la mesure V3 (`ab -n 2000 -c 50`, N=2 puis N=4) et une campagne finale sur le poste de démonstration.

Presque toutes les difficultés venaient des postes Windows et de VirtualBox, pas du code. Chacune a abouti à un garde-fou, un paramètre ou un script versionné, qui profite à toute l'équipe dès la reconstruction suivante.
