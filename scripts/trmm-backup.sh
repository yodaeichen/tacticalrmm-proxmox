#!/usr/bin/env bash
# =============================================================================
#  trmm-backup.sh – Tactical RMM Backup-Hilfscript  (Community Script)
#  Wird in /usr/local/bin/trmm-backup installiert (via Cloud-Init)
#
#  DISCLAIMER: Dieses Script ist ein unabhängiges Community-Projekt und steht
#  in keiner Verbindung zu AmidaWare LLC. "Tactical RMM" ist eine eingetragene
#  Marke von AmidaWare LLC.
#
#  Aufruf in der TRMM-VM:
#    sudo trmm-backup           – Interaktiv
#    sudo trmm-backup --auto    – Automatisch (für Cron), kein Bestätigungsdialog
#    sudo trmm-backup --list    – Vorhandene Backups anzeigen
#    sudo trmm-backup --restore – Backup wiederherstellen
#
#  Backup-Ziel: /opt/trmm-backups/ (lokal in der VM)
#  Retention:   7 Backups (älteste werden automatisch gelöscht)
# =============================================================================

set -euo pipefail

# ─── Farben ───────────────────────────────────────────────────────────────────
YW="\033[33m"; BL="\033[36m"; RD="\033[01;31m"
GN="\033[1;92m"; CL="\033[m"; BOLD="\033[1m"; DIM="\033[2m"
BFR="\\r\\033[K"; HOLD=" "
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"; INFO="${BL}ℹ${CL}"; WARN="${YW}⚠${CL}"

msg_info()  { local msg="$1"; echo -ne " ${HOLD} ${YW}${msg}...${CL}"; }
msg_ok()    { local msg="$1"; echo -e "${BFR} ${CM} ${GN}${msg}${CL}"; }
msg_error() { local msg="$1"; echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"; exit 1; }
msg_warn()  { local msg="$1"; echo -e " ${WARN} ${YW}${msg}${CL}"; }
divider()   { echo -e "${DIM}$(printf '━%.0s' {1..58})${CL}"; }

# ─── Konfiguration ────────────────────────────────────────────────────────────
BACKUP_BASE="/opt/trmm-backups"
RETENTION=7          # Anzahl Backups die behalten werden
TRMM_USER="tactical"
DB_NAME="tacticalrmm"
TS=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${BACKUP_BASE}/${TS}"
AUTO_MODE=false
LIST_MODE=false
RESTORE_MODE=false

# ─── Argumente auswerten ──────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --auto)    AUTO_MODE=true ;;
    --list)    LIST_MODE=true ;;
    --restore) RESTORE_MODE=true ;;
  esac
done

# ─── Root-Check ───────────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

# ─── Header (nicht im Auto-Modus) ─────────────────────────────────────────────
if [[ "$AUTO_MODE" == false ]]; then
  clear
  echo ""
  echo -e " ${BOLD}${YW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo -e " ${BOLD}   Tactical RMM – Backup  ${DIM}(Community Script)${CL}"
  echo -e " ${DIM}   $(date '+%d.%m.%Y %H:%M:%S')${CL}"
  echo -e " ${BOLD}${YW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo ""
fi

# ─── Backup-Liste anzeigen ────────────────────────────────────────────────────
list_backups() {
  echo ""
  divider
  echo -e " ${BOLD}Vorhandene Backups in ${BACKUP_BASE}:${CL}"
  divider

  if [[ ! -d "$BACKUP_BASE" ]] || [[ -z "$(ls -A "$BACKUP_BASE" 2>/dev/null)" ]]; then
    echo -e " ${DIM}Keine Backups gefunden.${CL}"
    echo ""
    return
  fi

  local count=0
  while IFS= read -r dir; do
    if [[ -d "$dir" ]]; then
      local size; size=$(du -sh "$dir" 2>/dev/null | cut -f1)
      local date_str; date_str=$(basename "$dir" | sed 's/_/ /; s/\(..\)\(..\)\(..\)$/\1:\2:\3/')
      printf "  ${BL}%-20s${CL}  %s\n" "$(basename "$dir")" "${size}"
      count=$((count + 1))
    fi
  done < <(ls -d "${BACKUP_BASE}"/[0-9]* 2>/dev/null | sort -r)

  echo ""
  echo -e "  ${DIM}${count} Backup(s) gesamt | Retention: ${RETENTION}${CL}"
  divider
  echo ""
}

# ─── TRMM-Installation prüfen ─────────────────────────────────────────────────
check_trmm() {
  if [[ ! -d /rmm ]]; then
    msg_error "Tactical RMM nicht gefunden (/rmm fehlt)!"
  fi
}

# ─── Datenbank sichern ────────────────────────────────────────────────────────
backup_database() {
  msg_info "Sichere PostgreSQL-Datenbank (${DB_NAME})"
  if sudo -u postgres pg_dump "$DB_NAME" 2>/dev/null | gzip > "${BACKUP_DIR}/db.sql.gz"; then
    local size; size=$(du -sh "${BACKUP_DIR}/db.sql.gz" | cut -f1)
    msg_ok "Datenbank gesichert (${size})"
  else
    msg_warn "Datenbank-Backup fehlgeschlagen!"
    touch "${BACKUP_DIR}/db.sql.gz.FAILED"
  fi
}

# ─── Konfigurationsdateien sichern ────────────────────────────────────────────
backup_config() {
  msg_info "Sichere Konfigurationsdateien"
  local conf_dir="${BACKUP_DIR}/config"
  mkdir -p "$conf_dir"

  local files=(
    "/rmm/api/tacticalrmm/local_settings.py"
    "/rmm/api/tacticalrmm/settings.py"
    "/etc/nginx/sites-available/rmm.conf"
    "/etc/nginx/sites-available/meshcentral.conf"
    "/etc/nginx/sites-available/frontend.conf"
    "/meshcentral/meshcentral-data/config.json"
    "/etc/letsencrypt"
  )

  for f in "${files[@]}"; do
    if [[ -e "$f" ]]; then
      # Verzeichnisstruktur beibehalten
      local dest_dir="${conf_dir}$(dirname "$f")"
      mkdir -p "$dest_dir"
      cp -a "$f" "$dest_dir/" 2>/dev/null || true
    fi
  done
  msg_ok "Konfiguration gesichert"
}

# ─── MeshCentral-Daten sichern ────────────────────────────────────────────────
backup_meshcentral() {
  msg_info "Sichere MeshCentral-Daten"
  if [[ -d /meshcentral/meshcentral-data ]]; then
    tar -czf "${BACKUP_DIR}/meshcentral-data.tar.gz" \
      -C /meshcentral meshcentral-data 2>/dev/null \
      && msg_ok "MeshCentral-Daten gesichert" \
      || msg_warn "MeshCentral-Backup fehlgeschlagen"
  else
    msg_warn "MeshCentral-Daten nicht gefunden (übersprungen)"
  fi
}

# ─── Codebase sichern (optional, groß) ───────────────────────────────────────
backup_codebase() {
  msg_info "Sichere TRMM-Codebase"
  # Nur wichtige Teile, kein virtualenv
  tar -czf "${BACKUP_DIR}/rmm-api.tar.gz" \
    --exclude='/rmm/api/env' \
    --exclude='/rmm/api/.git' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    -C / rmm/api 2>/dev/null \
    && msg_ok "TRMM-API gesichert" \
    || msg_warn "Codebase-Backup fehlgeschlagen"
}

# ─── Backup-Manifest erstellen ────────────────────────────────────────────────
create_manifest() {
  local version=""
  [[ -f /rmm/api/tacticalrmm/settings.py ]] && \
    version=$(grep -oP "(?<=TRMM_VERSION = \")[^\"]*" /rmm/api/tacticalrmm/settings.py 2>/dev/null || echo "unbekannt")

  cat > "${BACKUP_DIR}/MANIFEST.txt" <<MANIFEST
Tactical RMM Backup
===================
Datum:      $(date '+%d.%m.%Y %H:%M:%S')
Hostname:   $(hostname)
TRMM-Ver.:  ${version:-unbekannt}
OS:         $(lsb_release -ds 2>/dev/null || uname -sr)

Enthaltene Dateien:
$(ls -lh "${BACKUP_DIR}" 2>/dev/null)

Backup erstellt von: trmm-backup.sh
MANIFEST
  msg_ok "Manifest erstellt"
}

# ─── Alte Backups bereinigen ──────────────────────────────────────────────────
cleanup_old_backups() {
  msg_info "Bereinige alte Backups (Retention: ${RETENTION})"
  local dirs=()
  while IFS= read -r d; do
    dirs+=("$d")
  done < <(ls -d "${BACKUP_BASE}"/[0-9]* 2>/dev/null | sort)

  local count=${#dirs[@]}
  if [[ $count -gt $RETENTION ]]; then
    local to_delete=$((count - RETENTION))
    for ((i=0; i<to_delete; i++)); do
      rm -rf "${dirs[$i]}"
    done
    msg_ok "${to_delete} alte(s) Backup(s) gelöscht"
  else
    msg_ok "Keine alten Backups zu löschen (${count}/${RETENTION})"
  fi
}

# ─── Backup wiederherstellen ──────────────────────────────────────────────────
restore_backup() {
  echo ""
  divider
  echo -e " ${BOLD}${RD}BACKUP WIEDERHERSTELLEN${CL}"
  divider
  echo -e " ${WARN} Dies überschreibt die aktuelle TRMM-Installation!"
  echo ""

  list_backups

  local -a BACKUPS=()
  while IFS= read -r d; do
    BACKUPS+=("$(basename "$d")")
  done < <(ls -d "${BACKUP_BASE}"/[0-9]* 2>/dev/null | sort -r)

  if [[ ${#BACKUPS[@]} -eq 0 ]]; then
    msg_error "Keine Backups vorhanden!"
  fi

  echo -e " Verfügbare Backups:"
  PS3=" Auswahl: "
  select b in "${BACKUPS[@]}"; do
    [[ -n "$b" ]] && { RESTORE_TARGET="${BACKUP_BASE}/${b}"; break; }
  done

  echo ""
  echo -e " ${WARN} Backup ${BOLD}$(basename "$RESTORE_TARGET")${CL} wiederherstellen?"
  read -rp " Fortfahren? [ja/N]: " confirm
  [[ "${confirm}" != "ja" ]] && { echo " Abgebrochen."; exit 0; }

  # Services stoppen
  msg_info "Stoppe TRMM-Services"
  for svc in rmm daphne celery celerybeat meshcentral; do
    systemctl stop "${svc}.service" 2>/dev/null || true
  done
  msg_ok "Services gestoppt"

  # Datenbank wiederherstellen
  if [[ -f "${RESTORE_TARGET}/db.sql.gz" ]]; then
    msg_info "Stelle Datenbank wieder her"
    sudo -u postgres dropdb "$DB_NAME" --if-exists 2>/dev/null || true
    sudo -u postgres createdb "$DB_NAME" 2>/dev/null
    zcat "${RESTORE_TARGET}/db.sql.gz" | sudo -u postgres psql "$DB_NAME" >/dev/null 2>&1
    msg_ok "Datenbank wiederhergestellt"
  else
    msg_warn "Keine Datenbank im Backup gefunden"
  fi

  # Konfiguration wiederherstellen
  if [[ -d "${RESTORE_TARGET}/config" ]]; then
    msg_info "Stelle Konfiguration wieder her"
    cp -a "${RESTORE_TARGET}/config/rmm/api/tacticalrmm/local_settings.py" \
      /rmm/api/tacticalrmm/ 2>/dev/null || true
    msg_ok "Konfiguration wiederhergestellt"
  fi

  # Services starten
  msg_info "Starte Services neu"
  for svc in meshcentral rmm daphne celery celerybeat nginx; do
    systemctl start "${svc}.service" 2>/dev/null || true
  done
  msg_ok "Services gestartet"

  echo ""
  msg_ok "Wiederherstellung abgeschlossen!"
  echo ""
}

# ─── Hauptprogramm ────────────────────────────────────────────────────────────

# Modus: Liste anzeigen
if [[ "$LIST_MODE" == true ]]; then
  list_backups
  exit 0
fi

# Modus: Wiederherstellen
if [[ "$RESTORE_MODE" == true ]]; then
  restore_backup
  exit 0
fi

# Modus: Backup erstellen
check_trmm

if [[ "$AUTO_MODE" == false ]]; then
  echo -e " ${INFO} Backup-Inhalt:"
  echo -e "   • PostgreSQL-Datenbank"
  echo -e "   • Nginx-Konfiguration"
  echo -e "   • TRMM local_settings.py"
  echo -e "   • Let's Encrypt Zertifikate"
  echo -e "   • MeshCentral-Daten"
  echo -e "   • TRMM-API-Codebase"
  echo -e " ${INFO} Ziel: ${BOLD}${BACKUP_BASE}/${TS}${CL}"
  echo -e " ${INFO} Retention: ${BOLD}${RETENTION} Backups${CL}"
  echo ""
  read -rp " Backup jetzt erstellen? [J/n]: " confirm
  [[ "${confirm,,}" == "n" ]] && { echo " Abgebrochen."; exit 0; }
  echo ""
fi

# Backup-Verzeichnis anlegen
mkdir -p "$BACKUP_DIR"
[[ "$AUTO_MODE" == true ]] && echo "[$(date '+%d.%m.%Y %H:%M')] Starte automatisches Backup..."

backup_database
backup_config
backup_meshcentral
backup_codebase
create_manifest
cleanup_old_backups

# Abschluss
local_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)

if [[ "$AUTO_MODE" == true ]]; then
  echo "[$(date '+%d.%m.%Y %H:%M')] Backup abgeschlossen: ${BACKUP_DIR} (${local_size})"
else
  echo ""
  divider
  echo -e " ${CM} ${BOLD}Backup erfolgreich erstellt!${CL}"
  divider
  echo -e "  Pfad:    ${BOLD}${BACKUP_DIR}${CL}"
  echo -e "  Größe:   ${BOLD}${local_size}${CL}"
  echo ""
  list_backups
fi#!/usr/bin/env bash
# =============================================================================
#  trmm-backup.sh – Tactical RMM Backup-Hilfscript  (Community Script)
#  Wird in /usr/local/bin/trmm-backup installiert (via Cloud-Init)
#
#  DISCLAIMER: Dieses Script ist ein unabhängiges Community-Projekt und steht
#  in keiner Verbindung zu AmidaWare LLC. "Tactical RMM" ist eine eingetragene
#  Marke von AmidaWare LLC.
#
#  Aufruf in der TRMM-VM:
#    sudo trmm-backup           – Interaktiv
#    sudo trmm-backup --auto    – Automatisch (für Cron), kein Bestätigungsdialog
#    sudo trmm-backup --list    – Vorhandene Backups anzeigen
#    sudo trmm-backup --restore – Backup wiederherstellen
#
#  Backup-Ziel: /opt/trmm-backups/ (lokal in der VM)
#  Retention:   7 Backups (älteste werden automatisch gelöscht)
# =============================================================================

set -euo pipefail

# ─── Farben ───────────────────────────────────────────────────────────────────
YW="\033[33m"; BL="\033[36m"; RD="\033[01;31m"
GN="\033[1;92m"; CL="\033[m"; BOLD="\033[1m"; DIM="\033[2m"
BFR="\\r\\033[K"; HOLD=" "
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"; INFO="${BL}ℹ${CL}"; WARN="${YW}⚠${CL}"

msg_info()  { local msg="$1"; echo -ne " ${HOLD} ${YW}${msg}...${CL}"; }
msg_ok()    { local msg="$1"; echo -e "${BFR} ${CM} ${GN}${msg}${CL}"; }
msg_error() { local msg="$1"; echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"; exit 1; }
msg_warn()  { local msg="$1"; echo -e " ${WARN} ${YW}${msg}${CL}"; }
divider()   { echo -e "${DIM}$(printf '━%.0s' {1..58})${CL}"; }

# ─── Konfiguration ────────────────────────────────────────────────────────────
BACKUP_BASE="/opt/trmm-backups"
RETENTION=7          # Anzahl Backups die behalten werden
TRMM_USER="tactical"
DB_NAME="tacticalrmm"
TS=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${BACKUP_BASE}/${TS}"
AUTO_MODE=false
LIST_MODE=false
RESTORE_MODE=false

# ─── Argumente auswerten ──────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --auto)    AUTO_MODE=true ;;
    --list)    LIST_MODE=true ;;
    --restore) RESTORE_MODE=true ;;
  esac
done

# ─── Root-Check ───────────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

# ─── Header (nicht im Auto-Modus) ─────────────────────────────────────────────
if [[ "$AUTO_MODE" == false ]]; then
  clear
  echo ""
  echo -e " ${BOLD}${YW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo -e " ${BOLD}   Tactical RMM – Backup  ${DIM}(Community Script)${CL}"
  echo -e " ${DIM}   $(date '+%d.%m.%Y %H:%M:%S')${CL}"
  echo -e " ${BOLD}${YW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo ""
fi

# ─── Backup-Liste anzeigen ────────────────────────────────────────────────────
list_backups() {
  echo ""
  divider
  echo -e " ${BOLD}Vorhandene Backups in ${BACKUP_BASE}:${CL}"
  divider

  if [[ ! -d "$BACKUP_BASE" ]] || [[ -z "$(ls -A "$BACKUP_BASE" 2>/dev/null)" ]]; then
    echo -e " ${DIM}Keine Backups gefunden.${CL}"
    echo ""
    return
  fi

  local count=0
  while IFS= read -r dir; do
    if [[ -d "$dir" ]]; then
      local size; size=$(du -sh "$dir" 2>/dev/null | cut -f1)
      local date_str; date_str=$(basename "$dir" | sed 's/_/ /; s/\(..\)\(..\)\(..\)$/\1:\2:\3/')
      printf "  ${BL}%-20s${CL}  %s\n" "$(basename "$dir")" "${size}"
      count=$((count + 1))
    fi
  done < <(ls -d "${BACKUP_BASE}"/[0-9]* 2>/dev/null | sort -r)

  echo ""
  echo -e "  ${DIM}${count} Backup(s) gesamt | Retention: ${RETENTION}${CL}"
  divider
  echo ""
}

# ─── TRMM-Installation prüfen ─────────────────────────────────────────────────
check_trmm() {
  if [[ ! -d /rmm ]]; then
    msg_error "Tactical RMM nicht gefunden (/rmm fehlt)!"
  fi
}

# ─── Datenbank sichern ────────────────────────────────────────────────────────
backup_database() {
  msg_info "Sichere PostgreSQL-Datenbank (${DB_NAME})"
  if sudo -u postgres pg_dump "$DB_NAME" 2>/dev/null | gzip > "${BACKUP_DIR}/db.sql.gz"; then
    local size; size=$(du -sh "${BACKUP_DIR}/db.sql.gz" | cut -f1)
    msg_ok "Datenbank gesichert (${size})"
  else
    msg_warn "Datenbank-Backup fehlgeschlagen!"
    touch "${BACKUP_DIR}/db.sql.gz.FAILED"
  fi
}

# ─── Konfigurationsdateien sichern ────────────────────────────────────────────
backup_config() {
  msg_info "Sichere Konfigurationsdateien"
  local conf_dir="${BACKUP_DIR}/config"
  mkdir -p "$conf_dir"

  local files=(
    "/rmm/api/tacticalrmm/local_settings.py"
    "/rmm/api/tacticalrmm/settings.py"
    "/etc/nginx/sites-available/rmm.conf"
    "/etc/nginx/sites-available/meshcentral.conf"
    "/etc/nginx/sites-available/frontend.conf"
    "/meshcentral/meshcentral-data/config.json"
    "/etc/letsencrypt"
  )

  for f in "${files[@]}"; do
    if [[ -e "$f" ]]; then
      # Verzeichnisstruktur beibehalten
      local dest_dir="${conf_dir}$(dirname "$f")"
      mkdir -p "$dest_dir"
      cp -a "$f" "$dest_dir/" 2>/dev/null || true
    fi
  done
  msg_ok "Konfiguration gesichert"
}

# ─── MeshCentral-Daten sichern ────────────────────────────────────────────────
backup_meshcentral() {
  msg_info "Sichere MeshCentral-Daten"
  if [[ -d /meshcentral/meshcentral-data ]]; then
    tar -czf "${BACKUP_DIR}/meshcentral-data.tar.gz" \
      -C /meshcentral meshcentral-data 2>/dev/null \
      && msg_ok "MeshCentral-Daten gesichert" \
      || msg_warn "MeshCentral-Backup fehlgeschlagen"
  else
    msg_warn "MeshCentral-Daten nicht gefunden (übersprungen)"
  fi
}

# ─── Codebase sichern (optional, groß) ───────────────────────────────────────
backup_codebase() {
  msg_info "Sichere TRMM-Codebase"
  # Nur wichtige Teile, kein virtualenv
  tar -czf "${BACKUP_DIR}/rmm-api.tar.gz" \
    --exclude='/rmm/api/env' \
    --exclude='/rmm/api/.git' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    -C / rmm/api 2>/dev/null \
    && msg_ok "TRMM-API gesichert" \
    || msg_warn "Codebase-Backup fehlgeschlagen"
}

# ─── Backup-Manifest erstellen ────────────────────────────────────────────────
create_manifest() {
  local version=""
  [[ -f /rmm/api/tacticalrmm/settings.py ]] && \
    version=$(grep -oP "(?<=TRMM_VERSION = \")[^\"]*" /rmm/api/tacticalrmm/settings.py 2>/dev/null || echo "unbekannt")

  cat > "${BACKUP_DIR}/MANIFEST.txt" <<MANIFEST
Tactical RMM Backup
===================
Datum:      $(date '+%d.%m.%Y %H:%M:%S')
Hostname:   $(hostname)
TRMM-Ver.:  ${version:-unbekannt}
OS:         $(lsb_release -ds 2>/dev/null || uname -sr)

Enthaltene Dateien:
$(ls -lh "${BACKUP_DIR}" 2>/dev/null)

Backup erstellt von: trmm-backup.sh
MANIFEST
  msg_ok "Manifest erstellt"
}

# ─── Alte Backups bereinigen ──────────────────────────────────────────────────
cleanup_old_backups() {
  msg_info "Bereinige alte Backups (Retention: ${RETENTION})"
  local dirs=()
  while IFS= read -r d; do
    dirs+=("$d")
  done < <(ls -d "${BACKUP_BASE}"/[0-9]* 2>/dev/null | sort)

  local count=${#dirs[@]}
  if [[ $count -gt $RETENTION ]]; then
    local to_delete=$((count - RETENTION))
    for ((i=0; i<to_delete; i++)); do
      rm -rf "${dirs[$i]}"
    done
    msg_ok "${to_delete} alte(s) Backup(s) gelöscht"
  else
    msg_ok "Keine alten Backups zu löschen (${count}/${RETENTION})"
  fi
}

# ─── Backup wiederherstellen ──────────────────────────────────────────────────
restore_backup() {
  echo ""
  divider
  echo -e " ${BOLD}${RD}BACKUP WIEDERHERSTELLEN${CL}"
  divider
  echo -e " ${WARN} Dies überschreibt die aktuelle TRMM-Installation!"
  echo ""

  list_backups

  local -a BACKUPS=()
  while IFS= read -r d; do
    BACKUPS+=("$(basename "$d")")
  done < <(ls -d "${BACKUP_BASE}"/[0-9]* 2>/dev/null | sort -r)

  if [[ ${#BACKUPS[@]} -eq 0 ]]; then
    msg_error "Keine Backups vorhanden!"
  fi

  echo -e " Verfügbare Backups:"
  PS3=" Auswahl: "
  select b in "${BACKUPS[@]}"; do
    [[ -n "$b" ]] && { RESTORE_TARGET="${BACKUP_BASE}/${b}"; break; }
  done

  echo ""
  echo -e " ${WARN} Backup ${BOLD}$(basename "$RESTORE_TARGET")${CL} wiederherstellen?"
  read -rp " Fortfahren? [ja/N]: " confirm
  [[ "${confirm}" != "ja" ]] && { echo " Abgebrochen."; exit 0; }

  # Services stoppen
  msg_info "Stoppe TRMM-Services"
  for svc in rmm daphne celery celerybeat meshcentral; do
    systemctl stop "${svc}.service" 2>/dev/null || true
  done
  msg_ok "Services gestoppt"

  # Datenbank wiederherstellen
  if [[ -f "${RESTORE_TARGET}/db.sql.gz" ]]; then
    msg_info "Stelle Datenbank wieder her"
    sudo -u postgres dropdb "$DB_NAME" --if-exists 2>/dev/null || true
    sudo -u postgres createdb "$DB_NAME" 2>/dev/null
    zcat "${RESTORE_TARGET}/db.sql.gz" | sudo -u postgres psql "$DB_NAME" >/dev/null 2>&1
    msg_ok "Datenbank wiederhergestellt"
  else
    msg_warn "Keine Datenbank im Backup gefunden"
  fi

  # Konfiguration wiederherstellen
  if [[ -d "${RESTORE_TARGET}/config" ]]; then
    msg_info "Stelle Konfiguration wieder her"
    cp -a "${RESTORE_TARGET}/config/rmm/api/tacticalrmm/local_settings.py" \
      /rmm/api/tacticalrmm/ 2>/dev/null || true
    msg_ok "Konfiguration wiederhergestellt"
  fi

  # Services starten
  msg_info "Starte Services neu"
  for svc in meshcentral rmm daphne celery celerybeat nginx; do
    systemctl start "${svc}.service" 2>/dev/null || true
  done
  msg_ok "Services gestartet"

  echo ""
  msg_ok "Wiederherstellung abgeschlossen!"
  echo ""
}

# ─── Hauptprogramm ────────────────────────────────────────────────────────────

# Modus: Liste anzeigen
if [[ "$LIST_MODE" == true ]]; then
  list_backups
  exit 0
fi

# Modus: Wiederherstellen
if [[ "$RESTORE_MODE" == true ]]; then
  restore_backup
  exit 0
fi

# Modus: Backup erstellen
check_trmm

if [[ "$AUTO_MODE" == false ]]; then
  echo -e " ${INFO} Backup-Inhalt:"
  echo -e "   • PostgreSQL-Datenbank"
  echo -e "   • Nginx-Konfiguration"
  echo -e "   • TRMM local_settings.py"
  echo -e "   • Let's Encrypt Zertifikate"
  echo -e "   • MeshCentral-Daten"
  echo -e "   • TRMM-API-Codebase"
  echo -e " ${INFO} Ziel: ${BOLD}${BACKUP_BASE}/${TS}${CL}"
  echo -e " ${INFO} Retention: ${BOLD}${RETENTION} Backups${CL}"
  echo ""
  read -rp " Backup jetzt erstellen? [J/n]: " confirm
  [[ "${confirm,,}" == "n" ]] && { echo " Abgebrochen."; exit 0; }
  echo ""
fi

# Backup-Verzeichnis anlegen
mkdir -p "$BACKUP_DIR"
[[ "$AUTO_MODE" == true ]] && echo "[$(date '+%d.%m.%Y %H:%M')] Starte automatisches Backup..."

backup_database
backup_config
backup_meshcentral
backup_codebase
create_manifest
cleanup_old_backups

# Abschluss
local_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)

if [[ "$AUTO_MODE" == true ]]; then
  echo "[$(date '+%d.%m.%Y %H:%M')] Backup abgeschlossen: ${BACKUP_DIR} (${local_size})"
else
  echo ""
  divider
  echo -e " ${CM} ${BOLD}Backup erfolgreich erstellt!${CL}"
  divider
  echo -e "  Pfad:    ${BOLD}${BACKUP_DIR}${CL}"
  echo -e "  Größe:   ${BOLD}${local_size}${CL}"
  echo ""
  list_backups
fi
