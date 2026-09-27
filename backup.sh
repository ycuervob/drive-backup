#!/usr/bin/env bash
# =============================================================================
#  drive-backup · Orquestador
#
#  1. Ejecuta db.sh y files.sh (cada uno deja lo suyo en su carpeta)
#  2. Empaqueta TODO en UN SOLO archivo:  BackUp_<servidor>_<fecha>.zip
#  3. Sube ese único archivo a Google Drive con rclone y lo verifica
#  4. Aplica retención local y remota, y notifica
#
#  Uso: ./backup.sh [opciones]      (./backup.sh --help)
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export DRIVE_BACKUP_HOME="$SCRIPT_DIR"

usage() {
  cat <<EOF
Uso: $(basename "$0") [opciones]

  -c, --config ARCHIVO   Usa otro archivo de configuración (por defecto: config.env)
      --only-db          Ejecuta solo db.sh
      --only-files       Ejecuta solo files.sh
      --no-upload        Genera el backup local pero no lo sube a Drive
      --dry-run          Genera el backup y simula la subida/borrados en Drive
      --test             Solo prueba la conexión con Drive (escribe y borra un archivo)
  -h, --help             Muestra esta ayuda
EOF
}

# -----------------------------------------------------------------------------
# Argumentos
# -----------------------------------------------------------------------------
ONLY=""; NO_UPLOAD=false; DRY_RUN=false; TEST_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)  CONFIG_FILE="$(readlink -f "$2")"; export CONFIG_FILE; shift 2 ;;
    --only-db)    ONLY="db"; shift ;;
    --only-files) ONLY="files"; shift ;;
    --no-upload)  NO_UPLOAD=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --test)       TEST_ONLY=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; usage; exit 2 ;;
  esac
done

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

# -----------------------------------------------------------------------------
# Notificaciones
# -----------------------------------------------------------------------------
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"; s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

notify() {
  local status="$1" message="$2"
  case "$NOTIFY_ON" in
    never) return 0 ;;
    error) [[ "$status" == "OK" ]] && return 0 ;;
  esac
  local subject="[drive-backup] $SERVER_NAME: $status"
  local body="$subject"$'\n'"$message"

  if [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]] && command -v curl >/dev/null 2>&1; then
    local esc; esc="$(json_escape "$body")"
    curl -fsS -m 20 -H 'Content-Type: application/json' \
      -d "{\"text\":\"$esc\",\"content\":\"$esc\"}" "$NOTIFY_WEBHOOK_URL" >/dev/null 2>&1 \
      || log_warn "No se pudo enviar la notificación al webhook"
  fi
  if [[ -n "${NOTIFY_EMAIL:-}" ]]; then
    if command -v mail >/dev/null 2>&1; then
      printf '%s\n\nLog: %s\n' "$message" "${LOG_FILE:-}" | mail -s "$subject" "$NOTIFY_EMAIL" \
        || log_warn "No se pudo enviar el correo de notificación"
    else
      log_warn "NOTIFY_EMAIL está configurado pero no existe el comando 'mail'"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Modo --test: probar conexión con Drive
# -----------------------------------------------------------------------------
if $TEST_ONLY; then
  setup_remote
  log_info "Probando conexión con $REMOTE_BASE ..."
  test_file="$REMOTE_BASE/.drive-backup-test-$$"
  rclone mkdir "$REMOTE_BASE" "${RCLONE_COMMON_FLAGS[@]}"
  echo "drive-backup test $(date)" | rclone rcat "$test_file" "${RCLONE_COMMON_FLAGS[@]}"
  rclone deletefile "$test_file" --drive-use-trash=false
  log_info "Conexión OK. Contenido actual de $REMOTE_BASE:"
  rclone lsf "$REMOTE_BASE" --files-only "${RCLONE_COMMON_FLAGS[@]}" | sort | tail -n 10 >&2 || true
  exit 0
fi

# -----------------------------------------------------------------------------
# Preparación
# -----------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR" "$LOG_DIR" 2>/dev/null \
  || die "No se pudo crear $BACKUP_DIR o $LOG_DIR (¿permisos? ejecuta como root o cambia las rutas en config.env)"

case "$ARCHIVE_FORMAT" in
  zip)    ARCHIVE_EXT="zip";    require_cmd zip ;;
  tar.gz) ARCHIVE_EXT="tar.gz"; require_cmd tar gzip ;;
  *) die "ARCHIVE_FORMAT='$ARCHIVE_FORMAT' no válido. Usa: zip | tar.gz" ;;
esac

# Una sola fecha para todo el backup
RUN_ID="$(date +%F_%H%M%S)"
archive_name() { printf '%s_%s_%s.%s' "$ARCHIVE_PREFIX" "$SERVER_NAME" "$1" "$ARCHIVE_EXT"; }
while [[ -e "$BACKUP_DIR/$(archive_name "$RUN_ID")" ]]; do sleep 1; RUN_ID="$(date +%F_%H%M%S)"; done

ARCHIVE_NAME="$(archive_name "$RUN_ID")"
ARCHIVE="$BACKUP_DIR/$ARCHIVE_NAME"
WORK_DIR="$BACKUP_DIR/.work_$RUN_ID"          # temporal: se borra al terminar
LOG_FILE="$LOG_DIR/$RUN_ID.log"
export RUN_ID SERVER_NAME
export STAMP="$RUN_ID"
export DB_OUT_DIR="$WORK_DIR/db"
export FILES_OUT_DIR="$WORK_DIR/files"

# Todo lo que se imprima (también desde db.sh y files.sh) va a pantalla y al log
exec > >(tee -a "$LOG_FILE") 2>&1

# Evitar dos ejecuciones simultáneas
if command -v flock >/dev/null 2>&1; then
  exec 9>"$BACKUP_DIR/.lock"
  flock -n 9 || die "Ya hay otro backup en ejecución (lock: $BACKUP_DIR/.lock)"
else
  log_warn "flock no disponible: no se protege contra ejecuciones simultáneas"
fi

START_TS=$(date +%s)
FINAL_STATUS=""
SUMMARY=()

on_exit() {
  local rc=$?
  rm -rf -- "$WORK_DIR" "$ARCHIVE.part"
  if [[ -z "$FINAL_STATUS" ]]; then
    log_error "El backup terminó inesperadamente (código $rc)"
    notify "ERROR" "El backup terminó inesperadamente (código $rc). Revisa el log: $LOG_FILE"
  fi
}
trap on_exit EXIT

log_info "===== drive-backup · $SERVER_NAME · $RUN_ID ====="
log_info "Config: $CONFIG_FILE"
$DRY_RUN   && log_warn "Modo --dry-run: no se subirá ni borrará nada en Drive"
$NO_UPLOAD && log_warn "Modo --no-upload: el backup se queda solo en local"

UPLOAD_ENABLED=true
{ $NO_UPLOAD; } && UPLOAD_ENABLED=false
if $UPLOAD_ENABLED; then
  setup_remote
  log_info "Destino: $REMOTE_BASE/$ARCHIVE_NAME"
fi

# Espacio libre
if [[ "${MIN_FREE_MB:-0}" -gt 0 ]]; then
  free_mb=$(df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}')
  if [[ "$free_mb" -lt "$MIN_FREE_MB" ]]; then
    FINAL_STATUS="ERROR"
    log_error "Espacio libre insuficiente en $BACKUP_DIR: ${free_mb}MB < ${MIN_FREE_MB}MB"
    notify "ERROR" "Espacio libre insuficiente en $BACKUP_DIR: ${free_mb}MB (mínimo ${MIN_FREE_MB}MB)"
    exit 1
  fi
fi

mkdir -p "$DB_OUT_DIR" "$FILES_OUT_DIR"

# -----------------------------------------------------------------------------
# Paso 1: ejecutar db.sh y files.sh
# -----------------------------------------------------------------------------
FAILED_STEPS=()

run_step() {
  local name="$1" script="$SCRIPT_DIR/$1.sh"
  if [[ ! -f "$script" ]]; then
    log_error "No existe $script. Créalo con: cp $name.sh.example $name.sh"
    FAILED_STEPS+=("$name"); SUMMARY+=("$name: NO EXISTE"); return 0
  fi
  log_info "---- Ejecutando $name.sh ----"
  local t0=$SECONDS rc=0
  LOG_TAG="$name" bash "$script" || rc=$?
  local dt=$((SECONDS - t0))
  if [[ $rc -eq 0 ]]; then
    log_info "$name.sh terminó OK en ${dt}s"
    SUMMARY+=("$name: OK (${dt}s)")
  else
    log_error "$name.sh falló con código $rc (${dt}s)"
    FAILED_STEPS+=("$name"); SUMMARY+=("$name: ERROR código $rc")
  fi
}

if [[ "$ONLY" != "files" ]] && is_true "$ENABLE_DB"; then run_step db; fi
if [[ "$ONLY" != "db" ]] && is_true "$ENABLE_FILES"; then run_step files; fi

# Quitar db/ o files/ si quedaron vacías (por ejemplo si ENABLE_DB=false)
find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -empty -delete

FILE_COUNT=$(find "$WORK_DIR" -type f | wc -l)
if [[ "$FILE_COUNT" -eq 0 ]]; then
  FINAL_STATUS="ERROR"
  log_error "No se generó ningún archivo de backup"
  notify "ERROR" "No se generó ningún archivo de backup."$'\n'"$(printf '%s\n' "${SUMMARY[@]}")"$'\n'"Log: $LOG_FILE"
  exit 1
fi

# -----------------------------------------------------------------------------
# Paso 2: empaquetar todo en UN SOLO archivo
# -----------------------------------------------------------------------------
{
  echo "servidor:   $SERVER_NAME"
  echo "backup:     $RUN_ID"
  echo "fecha:      $(date -R)"
  echo "pasos:"
  printf '  - %s\n' "${SUMMARY[@]}"
  echo "contenido:"
  (cd "$WORK_DIR" && find . -type f -printf '  %P  (%s bytes)\n' | sort)
} > "$WORK_DIR/MANIFEST.txt"

log_info "Empaquetando en $ARCHIVE_NAME ..."
if [[ "$ARCHIVE_FORMAT" == "zip" ]]; then
  (cd "$WORK_DIR" && zip -qry "$ARCHIVE.part" .)
else
  tar -czf "$ARCHIVE.part" -C "$WORK_DIR" .
fi
mv -f -- "$ARCHIVE.part" "$ARCHIVE"
rm -rf -- "$WORK_DIR"
log_info "Backup local listo: $ARCHIVE ($(human_size "$ARCHIVE"))"

# -----------------------------------------------------------------------------
# Paso 3: subir el archivo a Drive
# -----------------------------------------------------------------------------
UPLOAD_OK=false
if ! $UPLOAD_ENABLED; then
  log_info "Subida omitida (--no-upload)"
elif [[ ${#FAILED_STEPS[@]} -gt 0 ]] && ! is_true "$UPLOAD_ON_PARTIAL_FAILURE"; then
  log_error "Hubo fallos en: ${FAILED_STEPS[*]}. No se sube (UPLOAD_ON_PARTIAL_FAILURE=false)"
else
  DEST="$REMOTE_BASE/$ARCHIVE_NAME"
  rclone_flags=("${RCLONE_COMMON_FLAGS[@]}" --retries 5 --low-level-retries 20 --stats-one-line --stats 1m -v)
  $DRY_RUN && rclone_flags+=(--dry-run)
  # shellcheck disable=SC2206
  [[ -n "${RCLONE_EXTRA_FLAGS:-}" ]] && rclone_flags+=($RCLONE_EXTRA_FLAGS)

  log_info "Subiendo a $DEST ..."
  t0=$SECONDS
  if rclone copyto "$ARCHIVE" "$DEST" "${rclone_flags[@]}"; then
    UPLOAD_OK=true
    log_info "Subida completada en $((SECONDS - t0))s"
    if is_true "$VERIFY_UPLOAD" && ! $DRY_RUN; then
      log_info "Verificando checksum en Drive ..."
      local_md5="$(md5sum "$ARCHIVE" | awk '{print $1}')"
      remote_md5="$(rclone md5sum "$DEST" "${RCLONE_COMMON_FLAGS[@]}" 2>/dev/null | awk '{print $1}')"
      if [[ -n "$remote_md5" && "$local_md5" == "$remote_md5" ]]; then
        log_info "Verificación OK (md5 $local_md5)"
      else
        UPLOAD_OK=false
        log_error "La verificación falló: local=$local_md5 Drive=${remote_md5:-desconocido}"
      fi
    fi
  else
    log_error "Falló la subida a Drive"
  fi
  $UPLOAD_OK && SUMMARY+=("subida: OK") || SUMMARY+=("subida: ERROR")
fi

# -----------------------------------------------------------------------------
# Paso 4: retención (se decide por la fecha que va en el nombre del archivo)
# -----------------------------------------------------------------------------
# Devuelve la fecha AAAA-MM-DD_HHMMSS si el nombre es un backup de este servidor
backup_date_of() {
  local n="$1" pre="${ARCHIVE_PREFIX}_${SERVER_NAME}_"
  [[ "$n" == "$pre"* ]] || return 1
  n="${n#"$pre"}"; n="${n%.zip}"; n="${n%.tar.gz}"
  [[ "$n" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]] || return 1
  printf '%s' "$n"
}

# Remota: solo si la subida de hoy salió bien (nunca se borra lo viejo si lo nuevo falló)
if $UPLOAD_OK && [[ "$REMOTE_RETENTION_DAYS" -gt 0 ]]; then
  log_info "Retención remota: borrando backups de más de $REMOTE_RETENTION_DAYS días en $REMOTE_BASE"
  cutoff="$(date -d "-${REMOTE_RETENTION_DAYS} days" +%F_%H%M%S)"
  del_flags=("${RCLONE_COMMON_FLAGS[@]}")
  $DRY_RUN && del_flags+=(--dry-run)
  if remote_files="$(rclone lsf "$REMOTE_BASE" --files-only "${RCLONE_COMMON_FLAGS[@]}")"; then
    while IFS= read -r f; do
      [[ -n "$f" && "$f" != "$ARCHIVE_NAME" ]] || continue
      d="$(backup_date_of "$f")" || continue
      [[ "$d" < "$cutoff" ]] || continue
      if rclone deletefile "$REMOTE_BASE/$f" "${del_flags[@]}"; then
        log_info "  borrado en Drive: $f"
      else
        log_warn "  no se pudo borrar en Drive: $f"
      fi
    done <<< "$remote_files"
  else
    log_warn "No se pudo listar $REMOTE_BASE para aplicar la retención remota"
  fi
fi

# Local: si se subió bien (o no se pidió subir), se limpian los backups viejos
if ! $DRY_RUN && { $UPLOAD_OK || ! $UPLOAD_ENABLED; }; then
  if [[ "$LOCAL_RETENTION_DAYS" -eq 0 ]] && $UPLOAD_OK; then
    rm -f -- "$ARCHIVE"
    log_info "Retención local: copia local borrada (LOCAL_RETENTION_DAYS=0)"
  elif [[ "$LOCAL_RETENTION_DAYS" -gt 0 ]]; then
    cutoff_local="$(date -d "-${LOCAL_RETENTION_DAYS} days" +%F_%H%M%S)"
    for f in "$BACKUP_DIR"/*; do
      [[ -f "$f" ]] || continue
      name="$(basename "$f")"
      [[ "$name" != "$ARCHIVE_NAME" ]] || continue
      d="$(backup_date_of "$name")" || continue
      if [[ "$d" < "$cutoff_local" ]]; then rm -f -- "$f"; log_info "  borrado local: $name"; fi
    done
  fi
else
  log_warn "No se aplica retención local (la subida no se completó); los backups locales se conservan"
fi

# Restos de ejecuciones interrumpidas y logs viejos
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '.work_*' -mtime +0 -exec rm -rf -- {} + 2>/dev/null || true
find "$LOG_DIR" -maxdepth 1 -type f -name '*.log' -mtime "+$LOG_RETENTION_DAYS" -delete 2>/dev/null || true

# -----------------------------------------------------------------------------
# Resultado
# -----------------------------------------------------------------------------
ELAPSED=$(( $(date +%s) - START_TS ))
if [[ ${#FAILED_STEPS[@]} -eq 0 ]] && { $UPLOAD_OK || ! $UPLOAD_ENABLED || $DRY_RUN; }; then
  FINAL_STATUS="OK"
elif $UPLOAD_OK; then
  FINAL_STATUS="PARCIAL"
else
  FINAL_STATUS="ERROR"
fi

MSG="Backup $ARCHIVE_NAME: $FINAL_STATUS en ${ELAPSED}s"$'\n'"$(printf '%s\n' "${SUMMARY[@]}")"
log_info "===== Resultado: $FINAL_STATUS (${ELAPSED}s) ====="
notify "$FINAL_STATUS" "$MSG"$'\n'"Log: $LOG_FILE"

[[ "$FINAL_STATUS" == "OK" ]] && exit 0 || exit 1
