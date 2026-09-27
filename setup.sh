#!/usr/bin/env bash
# =============================================================================
#  drive-backup · Instalación en un servidor
#
#  ./setup.sh                      Revisa dependencias y crea config.env, db.sh y files.sh
#  ./setup.sh --install-rclone     Además instala/actualiza rclone (requiere root)
#  ./setup.sh --cron "0 2 * * *"   Además programa backup.sh en el crontab del usuario actual
#  ./setup.sh --remove-cron        Quita la tarea programada
# =============================================================================
set -Eeuo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CRON_MARK="# drive-backup:$DIR"

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m✘\033[0m %s\n' "$*"; }

INSTALL_RCLONE=false; CRON_EXPR=""; REMOVE_CRON=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-rclone) INSTALL_RCLONE=true; shift ;;
    --cron)           CRON_EXPR="$2"; shift 2 ;;
    --remove-cron)    REMOVE_CRON=true; shift ;;
    -h|--help)        sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; exit 2 ;;
  esac
done

echo "drive-backup · instalación en $(hostname) ($DIR)"
echo

# -----------------------------------------------------------------------------
echo "1) Dependencias"
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  err "Se requiere bash 4.4 o superior (tienes $BASH_VERSION)"; exit 1
fi
ok "bash $BASH_VERSION"

if $INSTALL_RCLONE; then
  [[ $EUID -eq 0 ]] || { err "--install-rclone requiere root (sudo ./setup.sh --install-rclone)"; exit 1; }
  curl -fsSL https://rclone.org/install.sh | bash || true
fi
if command -v rclone >/dev/null 2>&1; then
  ok "rclone $(rclone version 2>/dev/null | head -n1 | awk '{print $2}')"
else
  err "rclone no está instalado. Ejecuta: sudo ./setup.sh --install-rclone"
fi
for c in zip tar gzip flock curl; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"; else warn "$c no encontrado (zip es necesario si ARCHIVE_FORMAT=zip; flock y curl son opcionales)"; fi
done
echo

# -----------------------------------------------------------------------------
echo "2) Archivos locales de este servidor (no se suben a git)"
copy_if_missing() {
  local src="$1" dst="$2" mode="$3"
  if [[ -e "$dst" ]]; then
    ok "$(basename "$dst") ya existe (no se toca)"
  else
    cp "$src" "$dst"; chmod "$mode" "$dst"
    ok "$(basename "$dst") creado desde $(basename "$src")"
  fi
}
copy_if_missing "$DIR/config.env.example"           "$DIR/config.env" 600
copy_if_missing "$DIR/db.sh.example" "$DIR/db.sh"      700
copy_if_missing "$DIR/files.sh.example" "$DIR/files.sh"   700
chmod 600 "$DIR/config.env"
chmod +x "$DIR/backup.sh" "$DIR/restore.sh" "$DIR/setup.sh" "$DIR/db.sh" "$DIR/files.sh"
ok "Permisos ajustados (config.env = 600)"
echo

# -----------------------------------------------------------------------------
if $REMOVE_CRON || [[ -n "$CRON_EXPR" ]]; then
  echo "3) Tarea programada (crontab de $(id -un))"
  current="$(crontab -l 2>/dev/null | grep -vF "$CRON_MARK" || true)"
  if [[ -n "$CRON_EXPR" ]]; then
    line="$CRON_EXPR $DIR/backup.sh >/dev/null 2>&1 $CRON_MARK"
    printf '%s\n%s\n' "$current" "$line" | sed '/^$/d' | crontab -
    ok "Programado: $CRON_EXPR  →  $DIR/backup.sh"
  else
    printf '%s\n' "$current" | sed '/^$/d' | crontab -
    ok "Tarea programada eliminada"
  fi
  echo
fi

# -----------------------------------------------------------------------------
cat <<EOF
Siguientes pasos
  a) Obtén el token de Drive (en tu computador con navegador):
       rclone authorize "drive"
     y pega el JSON en DRIVE_TOKEN dentro de config.env (entre comillas simples).
  b) Edita config.env: rutas, base de datos, retención, notificaciones.
  c) Escribe en db.sh y files.sh los comandos de backup de ESTE servidor
     (traen ejemplos: mysqldump, docker exec, cp, zip, tar...).
  d) Prueba:
       ./backup.sh --test          # conexión con Drive
       ./db.sh && ./files.sh       # generan en ./test-output/
       ./backup.sh --dry-run       # todo el flujo sin subir nada
       ./backup.sh                 # backup real
  e) Programa la ejecución diaria:
       ./setup.sh --cron "0 2 * * *"
EOF
