#!/usr/bin/env bash
# setup-android-project.sh
# Prepara un proyecto Android para el pipeline CI de Gitea.
# Lee credenciales de .env en el mismo directorio que el script.
#
# Uso:
#   ./setup-android-project.sh <directorio> <nombre-app> [--private]
#
# Ejemplos:
#   ./setup-android-project.sh ~/Proyectos/movedroid    "MoveDroid"
#   ./setup-android-project.sh ~/Proyectos/pastedrop    "PasteDrop" --private
#   ./setup-android-project.sh ~/Proyectos/silo-android "Silo"

set -euo pipefail

# ─── Colores ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()    { echo -e "${CYAN}[setup]${NC} $*"; }
ok()      { echo -e "${GREEN}[ok]${NC}    $*"; }
skip()    { echo -e "${YELLOW}[skip]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()     { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# ─── Args ───────────────────────────────────────────────────────────────────
PROJECT_DIR="${1:-}"
APP_NAME="${2:-}"
PRIVATE_REPO=false
[[ "${3:-}" == "--private" ]] && PRIVATE_REPO=true

GRADLE_VERSION="8.7"
#SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="/home/daniel/docker/android"
TEMPLATE="$SCRIPT_DIR/build.yml.template"
ENV_FILE="$SCRIPT_DIR/.env"

[[ -z "$PROJECT_DIR" ]] && err "Falta directorio. Uso: $0 <directorio> <nombre-app>"
[[ -z "$APP_NAME"    ]] && err "Falta nombre de app. Uso: $0 <directorio> <nombre-app>"
[[ ! -d "$PROJECT_DIR" ]] && err "El directorio '$PROJECT_DIR' no existe."
[[ ! -f "$TEMPLATE"  ]] && err "No se encontró build.yml.template en $SCRIPT_DIR"

# ─── .env ───────────────────────────────────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    ok ".env cargado."
else
    warn "No se encontró .env en $SCRIPT_DIR"
    warn "Copiá .env.example a .env y completá los valores."
    warn "Continuando sin integración con Gitea API..."
    exit 1
fi

GITEA_URL="${GITEA_URL:-}"
GITEA_USER="${GITEA_USER:-}"
GITEA_TOKEN="${GITEA_TOKEN:-}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-}"

# ─── Helpers API ────────────────────────────────────────────────────────────
gitea_api() {
    local method="$1" path="$2" data="${3:-}"
    if [[ -n "$data" ]]; then
        curl -sf -X "$method" "$GITEA_URL/api/v1$path" \
            -H "Authorization: token $GITEA_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -sf -X "$method" "$GITEA_URL/api/v1$path" \
            -H "Authorization: token $GITEA_TOKEN"
    fi
}

repo_exists() {
    gitea_api GET "/repos/$GITEA_USER/$APP_NAME" &>/dev/null
}

# ─── Encabezado ─────────────────────────────────────────────────────────────
cd "$PROJECT_DIR"
echo ""
echo -e "${BOLD}── Android CI Setup: $APP_NAME ──${NC}"
echo -e "   Directorio: $(pwd)"
echo ""

# ─── 1. Gradle Wrapper ──────────────────────────────────────────────────────
if [[ ! -f "gradlew" ]]; then
    info "Generando Gradle Wrapper $GRADLE_VERSION..."
    if ! command -v gradle &>/dev/null; then
        err "gradle no está en PATH. Instalarlo o correr desde dentro del builder."
    fi
    gradle wrapper --gradle-version "$GRADLE_VERSION" -q
    chmod +x gradlew
    ok "gradlew generado."
else
    chmod +x gradlew
    skip "gradlew ya existe (permisos asegurados)."
fi

# ─── 2. local.properties ────────────────────────────────────────────────────
if [[ ! -f "local.properties" ]]; then
    info "Creando local.properties..."
    echo "sdk.dir=/opt/android-sdk" > local.properties
    ok "local.properties creado."
else
    skip "local.properties ya existe."
fi

# ─── 3. .gitignore ──────────────────────────────────────────────────────────
if ! grep -q "local.properties" ".gitignore" 2>/dev/null; then
    echo "local.properties" >> ".gitignore"
    ok "Agregado 'local.properties' a .gitignore"
fi

if ! grep -q "\.gradle/" ".gitignore" 2>/dev/null; then
    printf "\n.gradle/\nbuild/\n*.apk\n" >> ".gitignore"
    ok "Agregadas entradas de build a .gitignore"
fi

# Nunca ignorar .gitea/
if grep -q "\.gitea" ".gitignore" 2>/dev/null; then
    sed -i '/\.gitea/d' ".gitignore"
    ok "Eliminada entrada .gitea del .gitignore"
fi

# ─── 4. Workflow de Gitea CI ─────────────────────────────────────────────────
WORKFLOW_DIR=".gitea/workflows"
WORKFLOW_FILE="$WORKFLOW_DIR/build.yml"
mkdir -p "$WORKFLOW_DIR"

if [[ ! -f "$WORKFLOW_FILE" ]]; then
    info "Copiando workflow template..."
    cp "$TEMPLATE" "$WORKFLOW_FILE"
    sed -i "s/APP_NAME: \"NombreApp\"/APP_NAME: \"$APP_NAME\"/" "$WORKFLOW_FILE"
    ok "Workflow creado en $WORKFLOW_FILE"
else
    skip "Workflow ya existe en $WORKFLOW_FILE"
fi

# ─── 5. Gitea API ────────────────────────────────────────────────────────────
if [[ -n "$GITEA_TOKEN" && -n "$GITEA_URL" && -n "$GITEA_USER" ]]; then

    # 5a. Crear repo
    if repo_exists; then
        skip "Repo '$APP_NAME' ya existe en Gitea."
    else
        info "Creando repo '$APP_NAME' en Gitea..."
        gitea_api POST "/user/repos" \
            "{\"name\": \"$APP_NAME\", \"private\": $PRIVATE_REPO, \"auto_init\": false, \"has_actions\": true}" \
            > /dev/null
        ok "Repo creado: $GITEA_URL/$GITEA_USER/$APP_NAME"
    fi

    # 5b. Habilitar Actions (por si el repo ya existía sin Actions)
    gitea_api PATCH "/repos/$GITEA_USER/$APP_NAME" \
        '{"has_actions": true}' > /dev/null
    ok "Actions habilitado."

    # 5c. Agregar secret GOTIFY_TOKEN
    if [[ -n "$GOTIFY_TOKEN" ]]; then
        gitea_api PUT "/repos/$GITEA_USER/$APP_NAME/actions/secrets/GOTIFY_TOKEN" \
            "{\"data\": \"$GOTIFY_TOKEN\"}" > /dev/null
        ok "Secret GOTIFY_TOKEN configurado."
    else
        warn "GOTIFY_TOKEN no definido en .env — secret no configurado."
    fi

    # 5d. Configurar remote origin si no apunta a Gitea
    CURRENT_ORIGIN=$(git remote get-url origin 2>/dev/null || echo "")
    GITEA_REMOTE="$GITEA_URL/$GITEA_USER/$APP_NAME.git"

    if [[ "$CURRENT_ORIGIN" != "$GITEA_REMOTE" ]]; then
        if [[ -z "$CURRENT_ORIGIN" ]]; then
            git remote add origin "$GITEA_REMOTE"
            ok "Remote 'origin' agregado → $GITEA_REMOTE"
        else
            git remote set-url origin "$GITEA_REMOTE"
            ok "Remote 'origin' actualizado → $GITEA_REMOTE"
        fi
    else
        skip "Remote 'origin' ya apunta a Gitea."
    fi

else
    warn "Credenciales de Gitea no configuradas — saltando pasos de API."
fi

# ─── 6. Primer commit y push ─────────────────────────────────────────────────
if [[ -n "$GITEA_TOKEN" ]]; then
    info "Preparando primer push..."

    if [[ ! -d ".git" ]]; then
        git init
        git checkout -b main 2>/dev/null || git branch -m main
        ok "Repositorio git inicializado."
    fi

    git add -A
    if git diff --cached --quiet; then
        skip "Nada nuevo para commitear."
    else
        git commit -m "chore: add CI pipeline"
        ok "Commit creado."
    fi

    git push origin main
    ok "Push a Gitea completado. ¡Pipeline activo!"
fi

# ─── Resumen ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}✅ $APP_NAME listo para CI.${NC}"
echo -e "   Repo: $GITEA_URL/$GITEA_USER/$APP_NAME"
echo -e "   Actions: $GITEA_URL/$GITEA_USER/$APP_NAME/actions"
echo ""
