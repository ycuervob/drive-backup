#!/usr/bin/env bash
# =============================================================================
#  drive-backup · Funciones compartidas
#  Lo cargan backup.sh, restore.sh, db.sh y files.sh con:
#      source "<repo>/lib/common.sh"
# =============================================================================

# Evita cargarlo dos veces
[[ -n "${_DRIVE_BACKUP_COMMON_LOADED:-}" ]] && return 0
_DRIVE_BACKUP_COMMON_LOADED=1

DRIVE_BACKUP_HOME="${DRIVE_BACKUP_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG_FILE="${CONFIG_FILE:-$DRIVE_BACKUP_HOME/config.env}"
export DRIVE_BACKUP_HOME CONFIG_FILE

# Nombre interno del remote que se genera para DRIVE_AUTH=token|service_account
_GENERATED_REMOTE="drivebackup"
_GENERATED_RCLONE_CONF="$DRIVE_BACKUP_HOME/.rclone.conf"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
_log() {
  local level="$1"; shift
  local tag="${LOG_TAG:-}"
  printf '%s [%-5s]%s %s\n' "$(date '+%F %T')" "$level" "${tag:+ [$tag]}" "$*" >&2
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }
die()       { log_error "$@"; exit 1; }

# Tamaño legible de un archivo o carpeta
human_size() { du -sh "$1" 2>/dev/null | cut -f1; }

# true/false/1/0/yes/no/si -> retorna 0 si es verdadero
is_true() {
  case "${1,,}" in
    true|1|yes|y|si|sí|on) return 0 ;;
    *) return 1 ;;
  esac
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Falta el comando '$c'. Instálalo antes de continuar."
  done
}

# -----------------------------------------------------------------------------
# Configuración
# -----------------------------------------------------------------------------
load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "No existe $CONFIG_FILE. Ejecuta ./setup.sh o copia config.env.example a config.env"

  # Aviso si el archivo de credenciales es legible por otros usuarios
  local perms
  perms="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo 600)"
  if [[ "${perms: -2}" != "00" ]]; then
    log_warn "$CONFIG_FILE tiene permisos $perms; contiene credenciales. Recomendado: chmod 600 $CONFIG_FILE"
  fi

  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  # Valores por defecto
  : "${SERVER_NAME:=$(hostname -s)}"
  : "${BACKUP_DIR:=/var/log/drive-backup}"
  : "${LOG_DIR:=/var/log/drive-backup}"
  : "${LOCAL_RETENTION_DAYS:=3}"
  : "${LOG_RETENTION_DAYS:=30}"
  : "${MIN_FREE_MB:=0}"
  : "${ARCHIVE_FORMAT:=zip}"
  : "${ARCHIVE_PREFIX:=BackUp}"
  : "${ENABLE_DB:=true}"
  : "${ENABLE_FILES:=true}"
  : "${UPLOAD_ON_PARTIAL_FAILURE:=false}"
  : "${DRIVE_AUTH:=token}"
  : "${DRIVE_PATH:=Backups}"
  : "${REMOTE_RETENTION_DAYS:=30}"
  : "${DRIVE_USE_TRASH:=false}"
  : "${DRIVE_SCOPE:=drive}"
  : "${RCLONE_REMOTE:=gdrive}"
  : "${VERIFY_UPLOAD:=true}"
  : "${NOTIFY_ON:=error}"
  : "${NOTIFY_WEBHOOK_URL:=}" "${NOTIFY_EMAIL:=}" "${RCLONE_BWLIMIT:=}" "${RCLONE_EXTRA_FLAGS:=}"
  : "${DRIVE_CLIENT_ID:=}" "${DRIVE_CLIENT_SECRET:=}" "${DRIVE_TOKEN:=}" "${DRIVE_SERVICE_ACCOUNT_FILE:=}"
  : "${DRIVE_TEAM_DRIVE:=}" "${DRIVE_ROOT_FOLDER_ID:=}" "${RCLONE_CONFIG_FILE:=}"

  DRIVE_PATH="${DRIVE_PATH#/}"; DRIVE_PATH="${DRIVE_PATH%/}"
  return 0
}

# -----------------------------------------------------------------------------
# Remote de Google Drive
#   Deja en la variable REMOTE el prefijo a usar con rclone, ej: "drivebackup:"
#   y en REMOTE_BASE la carpeta del servidor: "drivebackup:Backups/servidor1"
# -----------------------------------------------------------------------------
_ini_line() { [[ -n "$2" ]] && printf '%s = %s\n' "$1" "$2"; return 0; }

setup_remote() {
  require_cmd rclone

  case "$DRIVE_AUTH" in
    token|service_account)
      if [[ "$DRIVE_AUTH" == "token" && -z "${DRIVE_TOKEN:-}" ]]; then
        die "DRIVE_AUTH=token pero DRIVE_TOKEN está vacío en config.env (ver README: 'Obtener el token')."
      fi
      if [[ "$DRIVE_AUTH" == "service_account" && ! -r "${DRIVE_SERVICE_ACCOUNT_FILE:-}" ]]; then
        die "DRIVE_AUTH=service_account pero no se puede leer DRIVE_SERVICE_ACCOUNT_FILE='${DRIVE_SERVICE_ACCOUNT_FILE:-}'"
      fi

      # Se genera un rclone.conf privado del repo. Se regenera solo si config.env
      # cambió, para conservar el token que rclone renueva automáticamente.
      if [[ ! -f "$_GENERATED_RCLONE_CONF" || "$CONFIG_FILE" -nt "$_GENERATED_RCLONE_CONF" ]]; then
        (
          umask 077
          {
            echo "# Generado automáticamente desde config.env. No editar."
            echo "[$_GENERATED_REMOTE]"
            echo "type = drive"
            _ini_line scope               "$DRIVE_SCOPE"
            _ini_line client_id           "${DRIVE_CLIENT_ID:-}"
            _ini_line client_secret       "${DRIVE_CLIENT_SECRET:-}"
            _ini_line team_drive          "${DRIVE_TEAM_DRIVE:-}"
            _ini_line root_folder_id      "${DRIVE_ROOT_FOLDER_ID:-}"
            if [[ "$DRIVE_AUTH" == "token" ]]; then
              _ini_line token "$DRIVE_TOKEN"
            else
              _ini_line service_account_file "$DRIVE_SERVICE_ACCOUNT_FILE"
            fi
          } > "$_GENERATED_RCLONE_CONF"
        )
        log_info "Configuración de rclone generada en $_GENERATED_RCLONE_CONF"
      fi
      export RCLONE_CONFIG="$_GENERATED_RCLONE_CONF"
      REMOTE="${_GENERATED_REMOTE}:"
      ;;
    rclone_remote)
      if [[ -n "${RCLONE_CONFIG_FILE:-}" ]]; then
        [[ -r "$RCLONE_CONFIG_FILE" ]] || die "No se puede leer RCLONE_CONFIG_FILE='$RCLONE_CONFIG_FILE'"
        export RCLONE_CONFIG="$RCLONE_CONFIG_FILE"
      fi
      rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:" \
        || die "El remote '${RCLONE_REMOTE}:' no existe en rclone. Créalo con: rclone config"
      REMOTE="${RCLONE_REMOTE}:"
      ;;
    *)
      die "DRIVE_AUTH='$DRIVE_AUTH' no válido. Usa: token | service_account | rclone_remote"
      ;;
  esac

  REMOTE_BASE="${REMOTE}${DRIVE_PATH:+$DRIVE_PATH/}${SERVER_NAME}"

  # Flags comunes para todas las llamadas a rclone
  RCLONE_COMMON_FLAGS=(--drive-use-trash="$(is_true "$DRIVE_USE_TRASH" && echo true || echo false)")
  [[ -n "${RCLONE_BWLIMIT:-}" ]] && RCLONE_COMMON_FLAGS+=(--bwlimit "$RCLONE_BWLIMIT")
  export REMOTE REMOTE_BASE
}
