#!/usr/bin/env bash
# =============================================================================
#  drive-backup · Consultar y descargar backups desde Drive
#
#  ./restore.sh list [servidor]                       Lista los backups en Drive
#  ./restore.sh latest [destino] [servidor]           Descarga el más reciente
#  ./restore.sh get <archivo|AAAA-MM-DD_HHMMSS> [destino] [servidor]
#
#  Por defecto usa el SERVER_NAME de config.env y descarga en ./restore/.
#  Solo DESCARGA el archivo y comprueba que no esté dañado; restaurar la base
#  o los archivos es manual (depende de cómo los generaron db.sh y files.sh).
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export DRIVE_BACKUP_HOME="$SCRIPT_DIR"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

cmd="${1:-}"; shift || true

base_for() { printf '%s%s%s' "$REMOTE" "${DRIVE_PATH:+$DRIVE_PATH/}" "${1:-$SERVER_NAME}"; }

list_backups() {
  local server="${1:-$SERVER_NAME}"
  rclone lsf "$(base_for "$server")" --files-only "${RCLONE_COMMON_FLAGS[@]}" \
    | grep -E "^${ARCHIVE_PREFIX}_.+_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.(zip|tar\.gz|tar)$" \
    | sort || true
}

download() {
  local name="$1" dest="${2:-$SCRIPT_DIR/restore}" server="${3:-}"
  local src; src="$(base_for "$server")/$name"
  mkdir -p "$dest"
  log_info "Descargando $src → $dest/"
  rclone copyto "$src" "$dest/$name" --stats-one-line --stats 30s -v "${RCLONE_COMMON_FLAGS[@]}"

  log_info "Comprobando el archivo ..."
  case "$name" in
    *.zip)    unzip -tq "$dest/$name" >/dev/null ;;
    *.tar.gz) tar -tzf "$dest/$name" >/dev/null ;;
    *.tar)    tar -tf  "$dest/$name" >/dev/null ;;
  esac
  log_info "Archivo OK: $dest/$name ($(human_size "$dest/$name"))"
  case "$name" in
    *.zip)    log_info "Para extraerlo: unzip '$dest/$name' -d '$dest/${name%.zip}'" ;;
    *.tar.gz) log_info "Para extraerlo (como root, conserva permisos y xattrs): mkdir -p '$dest/${name%.tar.gz}' && tar --xattrs --xattrs-include='*' --acls -xzpf '$dest/$name' -C '$dest/${name%.tar.gz}'" ;;
    *.tar)    log_info "Para extraerlo (como root, conserva permisos y xattrs): mkdir -p '$dest/${name%.tar}' && tar --xattrs --xattrs-include='*' --acls -xpf '$dest/$name' -C '$dest/${name%.tar}'" ;;
  esac
}

case "$cmd" in
  list)
    setup_remote
    list_backups "${1:-}"
    ;;
  latest)
    setup_remote
    last="$(list_backups "${2:-}" | tail -n1)"
    [[ -n "$last" ]] || die "No hay backups en $(base_for "${2:-}")"
    download "$last" "${1:-}" "${2:-}"
    ;;
  get)
    [[ -n "${1:-}" ]] || die "Uso: ./restore.sh get <archivo|AAAA-MM-DD_HHMMSS> [destino] [servidor]"
    setup_remote
    name="$1"
    if [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]]; then
      name="$(list_backups "${3:-}" | grep -F "_$1." | head -n1 || true)"
      [[ -n "$name" ]] || die "No hay un backup con fecha $1"
    fi
    download "$name" "${2:-}" "${3:-}"
    ;;
  *)
    sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
