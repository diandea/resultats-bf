# RÉSULTATS-BF — Infrastructure résiliente décrite en code

Projet de groupe du module DevOps, Master 1, **groupe 4** (réseau `192.168.59.0/24`).

RÉSULTATS-BF publie les résultats d'un examen national : un candidat saisit son matricule et obtient sa moyenne et sa décision. Toute la plateforme est décrite en code avec **Vagrant** et **VirtualBox** : `vagrant up` la construit entièrement, sans aucune commande manuelle, et `vagrant destroy -f` la supprime.

| Membre | Rôle |
|---|---|
| Nassiro (`diandea`) | Coordination, architecture réseau et répartition |
| Basile | Ingénieur applicatif |
| Salif | Ingénieur données |
| Sanata | Ingénieure essais et observabilité |

> **État au 29 octobre 2026.** Les huit exigences (R1 à R8) et les deux extensions (E1 : répartiteur redondant, E2 : supervision) sont réalisées et fusionnées dans `main`, avec le cache de paquets partagé (PR #10). La preuve globale d'idempotence conclut « R2 VÉRIFIÉE » sur 7 VM et 56 fichiers de configuration (`mesures/r2_idempotence.txt`). Reste la campagne de mesures finale, notamment V3. Voir [État d'avancement](#état-davancement).

---

## Sommaire

1. [Architecture](#architecture)
2. [Prérequis sur le poste Windows](#prérequis-sur-le-poste-windows)
3. [Installation et premier démarrage](#installation-et-premier-démarrage)
4. [Paramètres](#paramètres)
5. [Utiliser la plateforme](#utiliser-la-plateforme)
6. [Scénarios de démonstration V1 à V6](#scénarios-de-démonstration-v1-à-v6)
7. [Organisation du dépôt](#organisation-du-dépôt)
8. [État d'avancement](#état-davancement)
9. [Dépannage](#dépannage)
10. [Méthode de travail](#méthode-de-travail)

---

## Architecture

```
                       Client (poste Windows : navigateur, curl, ab)
                                       │
                 IP virtuelle 192.168.59.5 (ou 127.0.0.1:PORT_HOTE → lb1)
                                       │
        ┌──────────── Répartition (E1 : keepalived, VRRP) ────────────┐
        │   lb1 · 192.168.59.11              lb2 · 192.168.59.12      │
        │   HAProxy + keepalived (maître)    HAProxy + keepalived     │
        └─────────────────────────────────────────────────────────────┘
                                       │  tourniquet + contrôle /sante
        ┌──────────── Application (NB_APP serveurs) ──────────────────┐
        │   app1 · .21        app2 · .22        app3 … appN           │
        │   Flask + gunicorn, port 3000                               │
        └─────────────────────────────────────────────────────────────┘
                                       │  SQL vers le primaire (read-write)
        ┌──────────── Données (PostgreSQL 16) ────────────────────────┐
        │   bdd1 · 192.168.59.31  ── flux WAL ──▶  bdd2 · 192.168.59.32│
        │   primaire                               réplique, promue   │
        │                                          en cas de panne    │
        └─────────────────────────────────────────────────────────────┘

        obs · 192.168.59.41 (E2) : Prometheus + Grafana, node_exporter sur toutes les VM
```

**Principes de conception**

- **Source unique de vérité.** Le `Vagrantfile` engendre `config/noeuds.yml` (nom, adresse IP et rôle de chaque machine) à partir des paramètres de `.env`. Les scripts lisent ce fichier : aucune adresse IP n'est écrite en dur ailleurs.
- **Idempotence (R2).** Les scripts de `scripts/` n'écrivent un fichier que s'il change (`ecrire_si_change`), n'installent un paquet que s'il manque (`installer_paquets`) et ne relancent un service qu'en cas de modification. Rejouer `vagrant provision` ne change donc rien sur une plateforme déjà à jour.
- **Cache de paquets partagé.** Les paquets `.deb` téléchargés par une VM sont copiés dans `.cache/apt/` (dossier du projet, sur l'hôte, hors Git) et réutilisés par les autres VM et lors des reconstructions. Un paquet n'est téléchargé qu'une fois pour toute la plateforme. Les paquets sont copiés plutôt que d'être lus directement dans le dossier partagé, car les verrous d'`apt` fonctionnent mal sur les dossiers partagés VirtualBox.
- **Répartition.** La configuration HAProxy est engendrée à partir de `config/haproxy.cfg.modele` et validée par `haproxy -c` avant d'être installée. Chaque serveur est interrogé sur `/sante` toutes les secondes, et il est écarté après 2 échecs. Quand aucun serveur ne répond, le client reçoit une erreur 503 en JSON.
- **Application.** Flask servi par gunicorn (3 processus) sous systemd. La connexion à la base est multi-hôtes (`target_session_attrs=read-write`) : l'application suit automatiquement le primaire après une bascule.
- **Données.** PostgreSQL 16, authentification `scram-sha-256`. L'application utilise un rôle en lecture seule. Le jeu de données est déterministe : 50 000 candidats. Réplication en flux asynchrone de bdd1 vers bdd2.
- **Protection contre deux primaires.** PostgreSQL ne démarre pas seul au démarrage des VM de base. Le provisionnement décide d'abord du rôle de bdd1, grâce au fichier d'état `.etat/primaire` écrit lors d'une bascule. Un ancien primaire est reconstruit en réplique, ou reste arrêté si le nouveau primaire est injoignable.
- **Haute disponibilité du répartiteur (E1).** keepalived en VRRP unicast, priorités 150 (lb1) et 100 (lb2). Le script de surveillance `pgrep -x haproxy` retire 60 points à lb1 si HAProxy s'arrête.
- **Supervision (E2).** Prometheus collecte node_exporter sur toutes les VM et l'exportateur intégré de HAProxy. Grafana 11.2.0 affiche un tableau de bord provisionné de 6 panneaux.

---

## Prérequis sur le poste Windows

| Élément | Version ou réglage |
|---|---|
| Windows | 11, au moins 12 Go de RAM (16 Go ou plus conseillés pour la configuration complète) |
| VirtualBox | 7.2.8 |
| Vagrant | 2.4.9 |
| Git pour Windows | avec **Git Bash**, qui sert de terminal pour toutes les commandes |
| Box | `bento/ubuntu-24.04`, version épinglée `202510.26.0` |
| Apache Bench (`ab`) | pour les essais de charge : copier **tout** le dossier `Apache24\bin` (ab.exe a besoin de ses DLL) et l'ajouter au `PATH` |

**Réglages Windows indispensables**

1. **Désactiver Hyper-V**, sinon VirtualBox tourne en mode lent (icône de tortue verte). Dans un terminal administrateur :
   ```
   bcdedit /set hypervisorlaunchtype off
   ```
   Désactiver aussi *Sécurité Windows → Sécurité de l'appareil → Isolation du noyau → Intégrité de la mémoire*. Puis redémarrer.
2. **Désactiver la mise en veille** pendant les essais : une VM peut rester figée après une veille.
3. **Vérifier que le port hôte est libre.** Windows réserve parfois des plages de ports :
   ```
   netsh interface ipv4 show excludedportrange protocol=tcp
   ```
   Si `8080` est dans une plage, choisir un autre port avec `PORT_HOTE` (par exemple `18080`).
4. **Garder au moins 15 Go de disque libre.** Un disque plein met les VM en pause.

---

## Installation et premier démarrage

```bash
cd /c/projets_virtualisation
git clone https://github.com/diandea/resultats-bf.git
cd resultats-bf

cp .env.exemple .env
notepad .env          # remplacer chaque « changez-moi » par un vrai mot de passe
                      # pour l'extension E2, ajouter aussi : OBS=1 et GRAFANA_ADMIN_PASSWORD=...

vagrant box add bento/ubuntu-24.04 --box-version 202510.26.0 --provider virtualbox
time vagrant up
```

Le `Vagrantfile` **refuse de démarrer** si un secret manque ou vaut encore `changez-moi`, si `VRRP_PASSWORD` dépasse 8 caractères, ou si un script de `scripts/` a des fins de ligne Windows (CRLF).

Vérification :

```bash
vagrant status                                   # toutes les VM « running »
curl -s http://127.0.0.1:8080/sante; echo        # remplacer 8080 par PORT_HOTE si besoin
```

Pour tout supprimer : `vagrant destroy -f`. Avant une reconstruction depuis zéro, fermer l'interface VirtualBox et lancer plutôt `bash scripts/nettoyer_vbox.sh`. Ce script détruit les VM et supprime aussi les dossiers résiduels que VirtualBox laisse parfois sur le disque. Il ne touche qu'aux VM `rbf-g<N>-*` et `temp_clone_*` ; les autres VM du poste sont préservées.

---

## Paramètres

Tous les paramètres sont dans `.env` (jamais versionné). `.env.exemple`, versionné, ne contient que des valeurs factices.

| Variable | Rôle | Valeur par défaut |
|---|---|---|
| `GROUPE` | Numéro de groupe, préfixe des noms de VM (`rbf-g4-…`) | `4` |
| `NB_APP` | Nombre de serveurs applicatifs (R3) | `2` |
| `NB_LB` | `1` = un répartiteur ; `2` = extension E1 (lb2 + IP virtuelle) | `1` (`2` dans `.env.exemple`) |
| `OBS` | `0` = sans supervision ; `1` = extension E2 (VM obs) ; absent de `.env.exemple`, à ajouter | `0` |
| `PORT_HOTE` | Port de l'hôte redirigé vers lb1 | `8080` |
| `PG_SUPERUSER_PASSWORD` | Mot de passe du superutilisateur PostgreSQL | à définir |
| `PG_APP_USER`, `PG_APP_PASSWORD` | Rôle en lecture seule de l'application | `resultats`, à définir |
| `PG_REPL_USER`, `PG_REPL_PASSWORD` | Rôle de réplication | `replicateur`, à définir |
| `VRRP_PASSWORD` | Secret VRRP partagé par lb1 et lb2 (8 caractères au plus) | à définir |
| `GRAFANA_ADMIN_PASSWORD` | Administrateur Grafana (requis avec `OBS=1`) ; lettres et chiffres | à définir |

Configuration complète utilisée pour la démonstration : `NB_APP=2`, `NB_LB=2`, `OBS=1`, soit 7 VM et environ 4,3 Go de RAM réservés aux VM : 768 Mo pour bdd1, bdd2 et obs, 512 Mo pour chaque serveur applicatif et chaque répartiteur, 1 processeur virtuel par VM.

**Changer le nombre de serveurs applicatifs**, par exemple de 2 à 4 : mettre `NB_APP=4` dans `.env`, puis :

```bash
vagrant up app3 app4
vagrant provision lb1 lb2        # HAProxy est régénéré avec 4 serveurs
```

Pour revenir à 2 serveurs : remettre `NB_APP=2` dans `.env`, puis `NB_APP=4 vagrant destroy -f app3 app4` et `vagrant provision lb1 lb2`.

---

## Utiliser la plateforme

| Service | Adresse depuis le poste Windows |
|---|---|
| Application, par la redirection de port | `http://127.0.0.1:8080` (ou `PORT_HOTE`) |
| Application, par l'IP virtuelle (E1) | `http://192.168.59.5` |
| Statistiques HAProxy | `http://192.168.59.11:8404/stats` |
| Prometheus (E2) | `http://192.168.59.41:9090/targets` |
| Grafana (E2) | `http://192.168.59.41:3000` (consultation anonyme ; administrateur `admin`) |

Points d'accès de l'application :

| Chemin | Réponse |
|---|---|
| `/resultat?matricule=BF2026000042` | Résultat du candidat en JSON (moyenne 4.32 pour ce matricule) |
| `/sante` | État du serveur et de sa connexion à la base ; utilisé par HAProxy |
| `/info` | Nom du serveur qui a répondu ; utile pour observer la répartition |

Les erreurs sont toujours renvoyées en JSON, y compris le 503 du répartiteur quand aucun serveur n'est disponible.

---

## Scénarios de démonstration V1 à V6

Toutes les commandes se lancent depuis Git Bash, à la racine du dépôt. Définir d'abord le port :

```bash
PORT=$(grep -E '^PORT_HOTE=' .env | cut -d= -f2 | tr -d '\r '); PORT=${PORT:-8080}
```

**V1 — Répartition de charge**

```bash
for i in $(seq 1 20); do curl -s http://127.0.0.1:$PORT/info; echo; done | sort | uniq -c
```

Attendu : environ 10 réponses par serveur avec `NB_APP=2` (10/10/10/10 sur 40 appels avec `NB_APP=4`).

**V2 — Panne d'un serveur applicatif pendant le trafic**

```bash
( for i in $(seq 1 75); do printf '%s %s\n' "$(date +%H:%M:%S.%3N)" "$(curl -s -m 3 -w ' %{http_code}' http://127.0.0.1:$PORT/info)"; sleep 0.2; done ) > mesures/v2_panne_app1.txt &
sleep 3; vagrant halt app1
wait
echo "Requêtes en erreur : $(grep -vc ' 200$' mesures/v2_panne_app1.txt) sur $(wc -l < mesures/v2_panne_app1.txt)"
vagrant up app1
```

Attendu : aucune requête perdue ; app1 passe au rouge sur la page de statistiques, puis revient.

**V3 — Montée en charge**

```bash
ab -n 2000 -c 50 "http://127.0.0.1:$PORT/resultat?matricule=BF2026000042"
```

À lancer avec `NB_APP=2`, puis avec `NB_APP=4`, et comparer *Requests per second* et *Failed requests*.

**V4 — Panne de la base primaire et bascule**

```bash
bash scripts/mesure_v4.sh
```

Le script vérifie l'état nominal, lance une sonde client, arrête bdd1, exécute la bascule (`scripts/bascule.sh` : contrôle de bdd1, promotion de bdd2, enregistrement dans `.etat/primaire`) et écrit la synthèse dans `mesures/v4_synthese.txt`.

Après la bascule, bdd2 est le primaire. `vagrant up bdd1`, avec bdd2 en marche, reconstruit bdd1 comme réplique de bdd2. Pour retrouver bdd1 primaire, il faut reconstruire la plateforme. La procédure complète, avec ses vérifications, est décrite dans [`docs/procedure-bascule.md`](docs/procedure-bascule.md).

**V5 — Reconstruction complète**

```bash
bash scripts/nettoyer_vbox.sh
time vagrant up
```

Le cache `.cache/apt/` survit à `vagrant destroy -f` : une reconstruction ne retélécharge pas les paquets. Pour mesurer une reconstruction sans cache, supprimer d'abord `.cache/apt`.

**V6 — Panne du répartiteur (E1, avec `NB_LB=2`)**

```bash
bash scripts/mesure_v6.sh            # arrêt propre de lb1
vagrant up lb1
bash scripts/mesure_v6.sh --brutal   # coupure brutale de lb1
vagrant up lb1
```

L'IP virtuelle passe sur lb2, puis revient sur lb1 à son retour.

**R2 — Preuve globale d'idempotence** (plateforme démarrée, environ 10 minutes)

```bash
bash scripts/verifier_idempotence.sh
```

Le script rejoue deux fois `vagrant provision` sur toutes les VM démarrées. Il compare les empreintes md5 de tous les fichiers de configuration gérés et vérifie dans les journaux qu'aucun rejeu n'a écrit de fichier, installé de paquet ni redémarré de service. Le rapport est écrit dans `mesures/r2_idempotence.txt` et doit conclure « R2 VÉRIFIÉE ». `.pgpass` n'y figure que par son empreinte : aucun mot de passe n'apparaît.

---

## Organisation du dépôt

```
Vagrantfile                  Définition des VM, lecture de .env, garde-fous, génération de config/noeuds.yml
.env.exemple                 Paramètres et secrets factices (copier en .env)
.editorconfig, .gitattributes  Fins de ligne LF imposées
app/app.py                   Application Flask
config/haproxy.cfg.modele    Modèle de configuration HAProxy
config/grafana-resultats.json  Tableau de bord Grafana (provisionné par obs.sh)
scripts/lib.sh               Fonctions communes (ecrire_si_change, installer_paquets…)
scripts/commun.sh            Socle de toutes les VM (paquets de base, node_exporter)
scripts/bdd.sh               Primaire PostgreSQL, données, décision de rôle au démarrage
scripts/replique.sh          Réplique PostgreSQL (bdd2)
scripts/app.sh               Serveur applicatif (gunicorn, systemd)
scripts/lb.sh                HAProxy et keepalived
scripts/obs.sh               Prometheus et Grafana
scripts/bascule.sh           Procédure de bascule vers bdd2 (R6), lancée depuis l'hôte
scripts/promouvoir.sh        Promotion de bdd2 en une seule connexion SSH
scripts/mesure_v4.sh         Campagne V4 automatisée
scripts/mesure_v6.sh         Campagne V6 automatisée
scripts/nettoyer_vbox.sh     Nettoyage des restes VirtualBox avant une reconstruction (hôte)
scripts/verifier_idempotence.sh  Preuve globale de R2 : double rejeu et comparaison d'empreintes (hôte)
docs/procedure-bascule.md    Procédure d'exploitation de la bascule de la base
docs/captures/               Captures d'écran Grafana (tableau de bord, charge, panne de app1)
mesures/                     Relevés bruts des essais (V1, V2, V4, V6, R2)
README.md, JOURNAL.md        Présent document et journal de bord
```

Fichiers non versionnés : `.env`, `.vagrant/`, `config/noeuds.yml` (engendré), `.etat/` (état de bascule), `.cache/` (cache de paquets apt).

Le contrôle des fins de ligne est fait par le `Vagrantfile` lui-même : il refuse de démarrer si un script de `scripts/` contient des fins de ligne CRLF.

---

## État d'avancement

**Exigences obligatoires**

| Exigence | État | Preuve ou mesure |
|---|---|---|
| R1 Reconstruction intégrale | Réalisée | Réussie sur les quatre postes ; de 6 min 42 s à 14 min 09 s selon le poste |
| R2 Idempotence | Réalisée et vérifiée | Double rejeu sur 7 VM : 56 fichiers aux empreintes identiques, 0 action de modification (`mesures/r2_idempotence.txt`) |
| R3 Nombre de serveurs paramétrable | Réalisée | `NB_APP=4 vagrant up` en 4 min 51 s ; répartition 10/10/10/10 |
| R4 Sonde de santé | Réalisée | Serveur écarté en environ 1,2 s ; 0 requête perdue sur 75 |
| R5 Réplication en flux | Réalisée | Délai de rejeu de 3,6 ms |
| R6 Procédure de bascule | Réalisée | Promotion en environ 2,8 s ; procédure complète en 32,7 s |
| R7 Aucun secret en clair | Réalisée | Secrets dans `.env`, exclu de Git ; refus de démarrer sans secret |
| R8 Cloisonnement réseau | Réalisée | Réseau privé ; seul lb1 redirige un port vers l'hôte |

**Extensions**

| Extension | État | Résultat |
|---|---|---|
| E1 Répartiteur redondant | Réalisée | Arrêt propre de lb1 : aucune interruption (212/212) ; coupure brutale : 4,2 s |
| E2 Supervision | Réalisée | Prometheus, node_exporter sur toutes les VM, tableau de bord Grafana |

**Scénarios**

| Scénario | État | Résultat |
|---|---|---|
| V1 Répartition | Mesuré | 10/10 (N=2) ; 10/10/10/10 (N=4) |
| V2 Panne d'un serveur | Mesuré | 0 erreur sur 75 requêtes ; 0 échec sur 40 000 sous charge |
| V3 Montée en charge | À mesurer | Relevé préliminaire à N=2 : 166 requêtes/s (`ab -n 20000 -c 20`) |
| V4 Panne de la base | Mesuré | 101 réponses 200, 184 réponses 503 JSON, 0 erreur brute ; bascule en 32,7 s |
| V5 Reconstruction | Mesuré ; mesure officielle à refaire | Voir R1 ; gain du cache apt mesuré dans la PR #10 |
| V6 Panne du répartiteur | Mesuré | Voir E1 |

Les chiffres viennent des postes de l'équipe ; ils seront remesurés sur le poste de démonstration lors de la campagne finale.

---

## Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| VM très lentes, tortue verte dans VirtualBox | Hyper-V actif | `bcdedit /set hypervisorlaunchtype off`, désactiver l'intégrité de la mémoire, redémarrer |
| `ab.exe` ne démarre pas | DLL manquantes | Copier tout le dossier `Apache24\bin` |
| Erreur de redirection de port au démarrage de lb1 | Port pris ou réservé par Windows | `netsh interface ipv4 show excludedportrange protocol=tcp`, puis changer `PORT_HOTE` |
| Le `Vagrantfile` signale des fins de ligne CRLF | Fichier enregistré au format Windows | Le réenregistrer en LF (VS Code : en bas à droite) |
| `VERR_ALREADY_EXISTS` à la création d'une VM | Dossier résiduel dans `VirtualBox VMs` après un `destroy` | Fermer l'interface VirtualBox, puis `bash scripts/nettoyer_vbox.sh` |
| `VERR_INTNET_FLT_IF_NOT_FOUND` | Carte réseau hôte VirtualBox non attachée | Redémarrer le poste, relancer `vagrant up` |
| « Machine already provisioned » après un `up` interrompu | Le provisionnement n'a pas été rejoué | `vagrant provision <vm>` |
| bdd2 en échec au premier démarrage | bdd1 n'était pas démarrée | Démarrer bdd1, puis `vagrant provision bdd2` |
| bdd1 reste arrêtée après une bascule | Protection contre deux primaires : bdd2 promue mais injoignable | Démarrer bdd2, puis `vagrant up bdd1` (reconstruite en réplique) |
| VM figée après une mise en veille, ou en pause | Veille Windows ou disque plein | Désactiver la veille, libérer de l'espace, `vagrant reload <vm>` |
---

## Méthode de travail

- Une branche par étape, puis une demande de fusion (PR) relue **et testée** par un autre membre sur son propre poste avant la fusion dans `main`.
- Rotation des rôles : chaque membre a contribué hors de son domaine principal.
- Historique des étapes : *Pull requests → Closed*. Contributions par membre : *Insights → Contributors* et `git shortlog -sn --no-merges`.
- Relevés bruts des essais : dossier `mesures/`.
