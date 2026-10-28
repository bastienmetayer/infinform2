"""Tests unitaires de l'API CrazyDev (exécutés par la CI avant tout déploiement)."""


# ───────────────────────────── Données ─────────────────────────────

def test_annonces_ont_des_id_uniques(annonces_json):
    ids = [a["id"] for a in annonces_json]
    assert len(ids) == len(set(ids))


def test_annonces_ont_un_titre(annonces_json):
    assert all(a.get("titre") for a in annonces_json)


def test_formulaires_ont_un_type(forms_json):
    assert all(f.get("type") for f in forms_json)


# ───────────────────────────── /api/annonces ─────────────────────────────

def test_liste_des_annonces(client, annonces_json):
    r = client.get("/api/annonces")
    assert r.status_code == 200
    assert r.json() == annonces_json


def test_annonce_par_id(client, annonces_json):
    premiere = annonces_json[0]
    r = client.get(f"/api/annonces/{premiere['id']}")
    assert r.status_code == 200
    assert r.json() == premiere


def test_annonce_inexistante(client):
    r = client.get("/api/annonces/999999")
    assert r.status_code == 404


# ───────────────────────────── /api/form ─────────────────────────────

def test_formulaire_par_defaut(client):
    r = client.get("/api/form")
    assert r.status_code == 200
    assert "type" in r.json()


def test_formulaire_par_type(client, forms_json):
    for form in forms_json:
        r = client.get("/api/form", params={"type": form["type"]})
        assert r.status_code == 200
        assert r.json()["type"] == form["type"]


def test_formulaire_type_inconnu(client):
    r = client.get("/api/form", params={"type": "type-qui-n-existe-pas"})
    assert r.status_code == 404
