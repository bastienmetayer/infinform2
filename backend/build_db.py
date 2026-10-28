"""Construit la base SQLite à partir des JSON du front (source de vérité).

Usage : python build_db.py <chemin/vers/infini_db.db>

Utilisé par le script de déploiement (une base neuve par release)
et par les tests (une base temporaire par session de tests).
"""
import json
import os
import sqlite3
import sys
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
FRONTEND_JSON = BASE_DIR.parent / "frontend" / "json"


def build_db(db_path):
    # DDL seule : les INSERT legacy de schema.sql sont ignorés
    ddl = (BASE_DIR / "schema.sql").read_text(encoding="utf-8").split("INSERT INTO")[0]
    if os.path.exists(db_path):
        os.remove(db_path)

    conn = sqlite3.connect(db_path)
    try:
        conn.executescript(ddl)
        annonces = json.loads((FRONTEND_JSON / "annonces.json").read_text(encoding="utf-8"))
        for a in annonces:
            conn.execute("INSERT INTO annonces (data) VALUES (?)", (json.dumps(a, ensure_ascii=False),))
        forms = json.loads((FRONTEND_JSON / "form.json").read_text(encoding="utf-8"))
        if isinstance(forms, dict):
            forms = [forms]
        for f in forms:
            conn.execute("INSERT INTO formulaires (data) VALUES (?)", (json.dumps(f, ensure_ascii=False),))
        conn.commit()
    finally:
        conn.close()
    return len(annonces), len(forms)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage : python build_db.py <chemin/vers/infini_db.db>")
    nb_annonces, nb_forms = build_db(sys.argv[1])
    print(f"Base créée : {sys.argv[1]} ({nb_annonces} annonces, {nb_forms} formulaires)")
