#!/usr/bin/env bash
# Déploiement continu de CrazyDev sur le Raspberry Pi.
#
# Un environnement = une branche Git + une URL + une base SQLite + une API :
#   prod     main     https://crazydev.sabneit.fr          API 127.0.0.1:8000
#   preprod  preprod  https://crazydev-preprod.sabneit.fr  API 127.0.0.1:8001
#
# Lancé toutes les 2 min par le timer crazydev-deploy@<env>.timer. Un commit n'est
# déployé que si toute la CI GitHub est verte (tests unitaires compris). Chaque
# version est construite dans sa propre release (code + base), puis le lien
# "current" bascule ; si l'API ou le site ne répondent pas, retour à la release
# précédente.
#
# Usage :
#   deploy.sh <env>              déploie la branche de l'environnement si un nouveau commit est dispo
#   deploy.sh <env> --force      reconstruit et redéploie même si rien n'a changé
#   deploy.sh <env> --ref <sha>  déploie un commit précis
#   deploy.sh <env> --rollback   revient à la release précédente
#   deploy.sh <env> --status     affiche la release en ligne et les releases dispo
#   deploy.sh <env> --skip-ci    déploie sans attendre la CI (urgence / 1er déploiement)

set -Eeuo pipefail

ENV_NAME="${1:-}"
case "$ENV_NAME" in
  prod)    BRANCH=main;    PORT=8000; HOST=crazydev.sabneit.fr ;;
  preprod) BRANCH=preprod; PORT=8001; HOST=crazydev-preprod.sabneit.fr ;;
  *) echo "Usage : $0 <prod|preprod> [--force|--ref <sha>|--rollback|--status|--skip-ci]" >&2; exit 2 ;;
esac
shift

REPO_URL="${REPO_URL:-https://github.com/bastienmetayer/infinform2.git}"
GITHUB_REPO="${GITHUB_REPO:-$(sed -E 's#^https://github\.com/##; s#\.git$##' <<<"$REPO_URL")}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
SERVICE="crazydev-api@$ENV_NAME.service"

ROOT="$HOME/crazydev/$ENV_NAME"
MIRROR="$ROOT/repo.git"
RELEASES="$ROOT/releases"
CURRENT="$ROOT/current"
VENV="$ROOT/venv"

log() { printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$ENV_NAME" "$*"; }
die() { log "ERREUR : $*" >&2; exit 1; }

current_release() { [[ -L "$CURRENT" ]] && basename "$(readlink -f "$CURRENT")" || true; }

# Bascule atomique du lien "current" puis redémarrage de l'API sur la nouvelle release.
switch_to() {
  ln -sfn "$RELEASES/$1" "$CURRENT.tmp"
  mv -T "$CURRENT.tmp" "$CURRENT"
  sudo systemctl restart "$SERVICE"
  log "En ligne : $1"
}

# L'API doit répondre sur /api/annonces et nginx doit servir la page d'accueil.
health_check() {
  local api="000" front
  for _ in $(seq 1 15); do
    api=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/api/annonces" || true)
    [[ "$api" == 200 ]] && break
    sleep 1
  done
  front=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $HOST" http://127.0.0.1/ || true)
  if [[ "$api" == 200 && "$front" == 200 ]]; then
    log "Healthcheck OK (API $api, site $front)"
  else
    log "Healthcheck KO (API $api, site $front)"
    return 1
  fi
}

# Statut CI d'un commit via l'API publique GitHub : success | pending | failure | error.
ci_status() {
  curl -fsS --max-time 15 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$GITHUB_REPO/commits/$1/check-runs?per_page=100" 2>/dev/null \
  | python3 -I -c '
import json, sys
runs = json.load(sys.stdin).get("check_runs", [])
if not runs or any(r["status"] != "completed" for r in runs):
    print("pending")
elif all(r["conclusion"] in ("success", "neutral", "skipped") for r in runs):
    print("success")
else:
    print("failure")
' 2>/dev/null || echo error
}

# Dépendances Python : réinstallées seulement si requirements.txt a changé.
ensure_venv() {
  local req="$1/backend/requirements.txt" hash
  hash=$(sha256sum "$req" | cut -d' ' -f1)
  [[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV"
  if [[ "$(cat "$VENV/.req-hash" 2>/dev/null)" != "$hash" ]]; then
    log "Installation des dépendances Python"
    "$VENV/bin/pip" install --quiet --disable-pip-version-check -r "$req"
    echo "$hash" > "$VENV/.req-hash"
  fi
}

prune_releases() {
  local keep; keep=$(current_release)
  ls -1 "$RELEASES" | sort -r | tail -n +"$((KEEP_RELEASES + 1))" | while read -r rel; do
    [[ "$rel" == "$keep" ]] && continue
    rm -rf "${RELEASES:?}/$rel"
    log "Release supprimée : $rel"
  done
}

cmd_status() {
  log "Branche : $BRANCH | URL : https://$HOST | API : 127.0.0.1:$PORT"
  log "Release en ligne : $(current_release || echo aucune)"
  ls -1 "$RELEASES" 2>/dev/null | sort -r
}

cmd_rollback() {
  local cur prev
  cur=$(current_release)
  prev=$(ls -1 "$RELEASES" | sort -r | grep -vx "$cur" | head -n1 || true)
  [[ -n "$prev" ]] || die "aucune release précédente disponible"
  switch_to "$prev"
  health_check
}

cmd_deploy() {
  local ref="$1" force="$2" skip_ci="$3"

  if [[ -d "$MIRROR" ]]; then
    git --git-dir="$MIRROR" fetch --quiet --prune origin '+refs/heads/*:refs/heads/*'
  else
    log "Clonage initial de $REPO_URL"
    git clone --quiet --mirror "$REPO_URL" "$MIRROR"
  fi

  local sha
  sha=$(git --git-dir="$MIRROR" rev-parse --verify --quiet "$ref^{commit}") || die "référence introuvable : $ref"
  local short=${sha:0:7}

  local cur; cur=$(current_release)
  if [[ "$force" != 1 && "${cur##*-}" == "$short" ]]; then
    log "Déjà à jour ($short), rien à faire."
    return 0
  fi

  if [[ "$skip_ci" == 1 ]]; then
    log "CI ignorée (--skip-ci)"
  else
    case "$(ci_status "$sha")" in
      success) log "CI verte pour $short" ;;
      pending) log "CI pas encore terminée pour $short, nouvel essai au prochain passage."; return 0 ;;
      failure) die "CI en échec pour $short : déploiement bloqué" ;;
      *)       die "statut CI de $short illisible (API GitHub injoignable ?) : déploiement bloqué" ;;
    esac
  fi

  log "Déploiement de $short : $(git --git-dir="$MIRROR" log -1 --format=%s "$sha")"

  local release; release="$(date '+%Y%m%d%H%M%S')-$short"
  local dir="$RELEASES/$release"
  mkdir -p "$dir"
  git --git-dir="$MIRROR" archive "$sha" | tar -x -C "$dir"
  echo "$sha" > "$dir/REVISION"

  ensure_venv "$dir"
  # Base propre à cet environnement et à cette release, reconstruite depuis les JSON du commit
  "$VENV/bin/python" "$dir/backend/build_db.py" "$dir/infini_db.db" | while read -r l; do log "$l"; done

  switch_to "$release"

  if ! health_check; then
    if [[ -n "$cur" ]]; then
      log "Retour automatique à $cur"
      switch_to "$cur"
    fi
    die "déploiement de $short annulé"
  fi

  prune_releases
  log "Déploiement terminé ✔"
}

main() {
  local action=deploy ref="$BRANCH" force=0 skip_ci=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1 ;;
      --skip-ci) skip_ci=1 ;;
      --ref) ref="${2:?--ref attend une valeur}"; shift ;;
      --rollback) action=rollback ;;
      --status) action=status ;;
      *) die "option inconnue : $1" ;;
    esac
    shift
  done

  mkdir -p "$RELEASES"

  # Un seul déploiement à la fois par environnement (timer + lancement manuel).
  exec 9>"$ROOT/.lock"
  flock -n 9 || { log "Un déploiement est déjà en cours."; exit 0; }

  case "$action" in
    deploy) cmd_deploy "$ref" "$force" "$skip_ci" ;;
    rollback) cmd_rollback ;;
    status) cmd_status ;;
  esac
}

main "$@"
