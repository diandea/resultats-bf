"""RÉSULTATS-BF — service applicatif sans état (Flask + gunicorn).

Aucun état local : ni session, ni fichier, ni compteur. Seule une connexion
à la base est mise en cache par processus, pour la performance ; elle est
recréée dès qu'elle est rompue. Tout serveur peut répondre à toute requête.
"""
import os
import re
import socket

import psycopg
from psycopg.rows import dict_row
from flask import Flask, jsonify, request
from werkzeug.exceptions import HTTPException

app = Flask(__name__)
app.json.ensure_ascii = False      # accents lisibles dans les réponses JSON
SERVEUR = socket.gethostname()

# Connexion multi-hôtes : libpq essaie bdd1 puis bdd2 et ne retient que celui
# qui accepte les écritures (le primaire). Après une bascule, la réplique
# promue est trouvée automatiquement, sans modifier la configuration.
PARAMS = dict(
    host=os.environ["DB_HOSTS"], port=5432, dbname="resultats",
    user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"],
    target_session_attrs="read-write", connect_timeout=2,
    application_name=SERVEUR, autocommit=True,
)
MATRICULE = re.compile(r"^[A-Z0-9]{1,12}$")
_connexion = None   # cache technique par processus — pas un état métier


def executer(sql, params=()):
    """Exécute une requête et renvoie (première ligne, hôte de la base).
    Lève psycopg.OperationalError si la base est indisponible."""
    global _connexion
    try:
        if _connexion is None or _connexion.closed:
            _connexion = psycopg.connect(**PARAMS)
        with _connexion.cursor(row_factory=dict_row) as cur:
            cur.execute(sql, params)
            return cur.fetchone(), _connexion.info.host
    except psycopg.OperationalError:
        # Connexion rompue (panne, bascule) : on l'abandonne.
        if _connexion is not None:
            _connexion.close()
        _connexion = None
        raise


@app.get("/resultat")
def resultat():
    matricule = request.args.get("matricule", "").strip().upper()
    if not MATRICULE.match(matricule):
        return jsonify(erreur="paramètre matricule absent ou invalide"), 400
    try:
        ligne, _ = executer(
            "SELECT matricule, nom, serie, moyenne, admis "
            "FROM resultats WHERE matricule = %s", (matricule,))
    except psycopg.Error:
        return jsonify(erreur="base de données indisponible", serveur=SERVEUR), 503
    if ligne is None:
        return jsonify(erreur="matricule inconnu", matricule=matricule), 404
    ligne["moyenne"] = float(ligne["moyenne"])
    ligne["serveur"] = SERVEUR
    return jsonify(ligne)


@app.get("/sante")
def sante():
    """200 seulement si la base répond VRAIMENT — jamais par principe."""
    try:
        _, base = executer("SELECT 1")
        return jsonify(statut="ok", serveur=SERVEUR, base=base), 200
    except psycopg.Error:
        return jsonify(statut="indisponible", serveur=SERVEUR, base=None), 503


@app.get("/info")
def info():
    return jsonify(serveur=SERVEUR)


@app.errorhandler(Exception)
def erreur(e):
    """Toute erreur est renvoyée en JSON : jamais de page blanche ni de trace."""
    if isinstance(e, HTTPException):
        return jsonify(erreur=e.name), e.code
    app.logger.exception(e)
    return jsonify(erreur="erreur interne"), 500