import json
import os
import sys
from pathlib import Path

import pytest

BACKEND_DIR = Path(__file__).resolve().parent.parent
FRONTEND_JSON = BACKEND_DIR.parent / "frontend" / "json"
sys.path.insert(0, str(BACKEND_DIR))

from build_db import build_db  # noqa: E402


@pytest.fixture(scope="session")
def client(tmp_path_factory):
    """Client HTTP de test branché sur une base SQLite temporaire, construite depuis les JSON."""
    db_path = tmp_path_factory.mktemp("db") / "test.db"
    build_db(str(db_path))
    # main.py lit le chemin de la base à l'import : on le fixe avant de l'importer
    os.environ["INFINI_DB_PATH"] = str(db_path)

    from fastapi.testclient import TestClient
    import main

    with TestClient(main.app) as c:
        yield c


@pytest.fixture(scope="session")
def annonces_json():
    return json.loads((FRONTEND_JSON / "annonces.json").read_text(encoding="utf-8"))


@pytest.fixture(scope="session")
def forms_json():
    forms = json.loads((FRONTEND_JSON / "form.json").read_text(encoding="utf-8"))
    return forms if isinstance(forms, list) else [forms]
