#!/usr/bin/env bash
# =============================================================================
#  drive-backup · Consultar y descargar backups desde Drive
#
#  ./restore.sh list [servidor]                  Lista los backups en Drive
#  ./restore.sh latest [destino] [servidor]      Descarga el backup más reciente
#  ./restore.sh get <AAAA-MM-DD_HHMMSS> [destino] [servidor]
#
#  Por defecto usa el SERVER_NAME de config.env y descarga en ./restore/<backup>.
#  Solo DESCARGA y verifica checksums: restaurar la base/archivos es manual
#  (ver README, sección "Restaurar").
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export DRIVE_BACKUP_HOME="$SCRIPT_DIR"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

cmd="${1:-}"; shift || true

base_for() {
  local server="${1:-$SERVER_NAME}"
  printf '%s%s%s' "$REMOTE" "${DRIVE_PATH:+$DRIVE_PATH/}" "$server"
}

download() {
  local run_id="$1" dest="${2:-$SCRIPT_DIR/restore/$1}" server="${3:-}"
  local src; src="$(base_for "$server")/$run_id"
  log_info "Descargando $src → $dest"
  mkdir -p "$dest"
  rclone copy "$src" "$dest" --create-empty-src-dirs --transfers 4 --stats-one-line --stats 30s -v "${RCLONE_COMMON_FLAGS[@]}"
  if [[ -f "$dest/SHA256SUMS" ]]; then
    log_info "Verificando checksums ..."
    (cd "$dest" && sha256sum -c --quiet SHA256SUMS) && log_info "Checksums OK"
  else
    log_warn "El backup no trae SHA256SUMS; no se puede verificar"
  fi
  log_info "Listo: $dest"
  [[ -f "$dest/MANIFEST.txt" ]] && cat "$dest/MANIFEST.txt" >&2
  return 0
}

case "$cmd" in
  list)
    setup_remote
    rclone lsf "$(base_for "${1:-}")" --dirs-only "${RCLONE_COMMON_FLAGS[@]}" | sed 's#/$##' | sort
    ;;
  latest)
    setup_remote
    last="$(rclone lsf "$(base_for "${2:-}")" --dirs-only "${RCLONE_COMMON_FLAGS[@]}" | sed 's#/$##' | sort | tail -n1)"
    [[ -n "$last" ]] || die "No hay backups en $(base_for "${2:-}")"
    download "$last" "${1:-}" "${2:-}"
    ;;
  get)
    [[ -n "${1:-}" ]] || die "Uso: ./restore.sh get <AAAA-MM-DD_HHMMSS> [destino] [servidor]"
    setup_remote
    download "$1" "${2:-}" "${3:-}"
    ;;
  *)
    sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
