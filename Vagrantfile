# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# RÉSULTATS-BF — Groupe 4
# Source unique de vérité : la table NOEUDS décrit les VM ET engendre
# config/noeuds.yml, lu par les scripts (configuration du répartiteur, etc.).

require 'yaml'
require 'fileutils'

RACINE = File.dirname(__FILE__)

# ---------------------------------------------------------------------
# 1. Lecture du fichier .env (secrets et paramètres) — exigence R7
# ---------------------------------------------------------------------
FICHIER_ENV = File.join(RACINE, ".env")
unless File.exist?(FICHIER_ENV)
  abort "ERREUR : fichier .env absent. Faites : cp .env.exemple .env " \
        "puis renseignez les mots de passe (voir README)."
end

ENV_FICHIER = {}
File.readlines(FICHIER_ENV).each do |ligne|
  ligne = ligne.strip
  next if ligne.empty? || ligne.start_with?("#")
  cle, valeur = ligne.split("=", 2)
  ENV_FICHIER[cle.strip] = valeur.to_s.strip
end

# Priorité : variable de la ligne de commande > .env > valeur par défaut
def param(nom, defaut = nil)
  ENV[nom] || ENV_FICHIER[nom] || defaut
end

SECRETS = %w[PG_SUPERUSER_PASSWORD PG_APP_USER PG_APP_PASSWORD
             PG_REPL_USER PG_REPL_PASSWORD VRRP_PASSWORD]
SECRETS.each do |s|
  v = param(s)
  abort "ERREUR : #{s} manquant dans .env" if v.nil? || v.empty?
  abort "ERREUR : #{s} vaut encore 'changez-moi' dans .env" if v == "changez-moi"
end
abort "ERREUR : VRRP_PASSWORD doit faire 8 caractères au plus (limite keepalived)" \
  if param("VRRP_PASSWORD").length > 8
    
# Piège n°5 : un script en fins de ligne Windows échoue dans la VM.
Dir.glob(File.join(RACINE, "scripts", "*.sh")).each do |f|
  if File.binread(f).include?("\r")
    abort "ERREUR : #{File.basename(f)} contient des fins de ligne Windows (CRLF). " \
          "Corrigez avec : sed -i 's/\\r$//' scripts/*.sh"
  end
end 

# ---------------------------------------------------------------------
# 2. Paramètres du déploiement
# ---------------------------------------------------------------------
GROUPE  = param("GROUPE", "4").to_i
NB_APP  = param("NB_APP", "2").to_i
PORT_HOTE = param("PORT_HOTE", "8080").to_i
NB_LB     = param("NB_LB", "1").to_i
abort "ERREUR : NB_LB doit valoir 1 (socle) ou 2 (extension E1)" unless [1, 2].include?(NB_LB)
abort "ERREUR : GROUPE doit être compris entre 1 et 8" unless (1..8).include?(GROUPE)
abort "ERREUR : NB_APP doit être >= 2 (résilience)"    if NB_APP < 2
abort "ERREUR : NB_APP doit être <= 9 (plage .21 à .29)" if NB_APP > 9

RESEAU  = "192.168.#{55 + GROUPE}"
BOITE   = "bento/ubuntu-24.04"
VERSION = "202510.26.0"   # 202404.23.0 du squelette retirée du catalogue

# ---------------------------------------------------------------------
# 3. SOURCE UNIQUE DE VÉRITÉ
#    Ordre important : lb1 est déclaré EN DERNIER, pour être (re)provisionné
#    après la création de tous les serveurs applicatifs.
# ---------------------------------------------------------------------
NOEUDS = []
NOEUDS << { "nom" => "bdd1", "ip" => "#{RESEAU}.31", "mem" => 768, "role" => "bdd" }
NOEUDS << { "nom" => "bdd2", "ip" => "#{RESEAU}.32", "mem" => 768, "role" => "replique" }
(1..NB_APP).each do |i|
  NOEUDS << { "nom" => "app#{i}", "ip" => "#{RESEAU}.#{20 + i}", "mem" => 512, "role" => "app" }
end
# Répartiteurs : lb1 (+ lb2 avec l'extension E1). Toujours déclarés EN DERNIER.
(1..NB_LB).each do |i|
  NOEUDS << { "nom" => "lb#{i}", "ip" => "#{RESEAU}.#{10 + i}", "mem" => 512, "role" => "lb" }
end
VIP = "#{RESEAU}.5"   # adresse virtuelle du service (portée par le répartiteur maître)

# Écriture de config/noeuds.yml — mode binaire ("wb") pour forcer des fins
# de ligne LF, même quand Vagrant tourne sous Windows.
FileUtils.mkdir_p(File.join(RACINE, "config"))
inventaire = { "groupe" => GROUPE, "reseau" => RESEAU, "vip" => VIP,
               "nb_app" => NB_APP, "nb_lb" => NB_LB, "noeuds" => NOEUDS }
File.write(File.join(RACINE, "config", "noeuds.yml"), inventaire.to_yaml, mode: "wb")

# Variables transmises aux scripts de provisionnement (jamais écrites dans le dépôt)
ENV_PROVISION = { "GROUPE" => GROUPE.to_s, "RESEAU" => RESEAU, "NB_APP" => NB_APP.to_s }
SECRETS.each { |s| ENV_PROVISION[s] = param(s) }

# ---------------------------------------------------------------------
# 4. Définition des machines virtuelles
# ---------------------------------------------------------------------
Vagrant.configure("2") do |config|
  config.vm.box              = BOITE
  config.vm.box_version      = VERSION
  config.vm.box_check_update = false
  config.vm.synced_folder ".", "/vagrant", SharedFoldersEnableSymlinksCreate: false

  NOEUDS.each do |n|
    config.vm.define n["nom"] do |m|
      m.vm.hostname = n["nom"]
      m.vm.network "private_network", ip: n["ip"]

      # R8 : seul le répartiteur expose un port vers l'hôte
            if n["nom"] == "lb1"
               m.vm.network "forwarded_port", guest: 80, host: PORT_HOTE,
                     host_ip: "127.0.0.1", auto_correct: false
      end

      m.vm.provider "virtualbox" do |vb|
        vb.name         = "rbf-g#{GROUPE}-#{n['nom']}"
        vb.memory       = n["mem"]
        vb.cpus         = 1
        vb.linked_clone = true   # clones liés : création bien plus rapide
      end

      m.vm.provision "commun",  type: "shell", path: "scripts/commun.sh",          env: ENV_PROVISION
      # Le répartiteur est reprovisionné à CHAQUE « vagrant up » : sa configuration
      # suit ainsi NB_APP sans intervention (R3). Sans risque : lb.sh est idempotent.
      m.vm.provision n["role"], type: "shell", path: "scripts/#{n['role']}.sh",
	  
	  # Rejoués à CHAQUE « vagrant up » (scripts idempotents) :
      #  - lb       : sa configuration suit NB_APP (R3)
      #  - bdd, replique : PostgreSQL ne démarre pas seul au boot ; le script
      #    décide d'abord du rôle du nœud (évite deux primaires après une bascule)
                     env: ENV_PROVISION, run: (%w[lb bdd replique].include?(n["role"]) ? "always" : "once")
    end
  end
end
