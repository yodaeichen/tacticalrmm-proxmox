#!/usr/bin/env bash
# =============================================================================
#  trmm-update.sh – Tactical RMM Update-Hilfscript  (Community Script)
#  Wird in /usr/local/bin/trmm-update installiert (via Cloud-Init)
#
#  DISCLAIMER: Dieses Script ist ein unabhängiges Community-Projekt und steht
#  in keiner Verbindung zu AmidaWare LLC. Es ruft das offizielle Update-Script
#  von amidaware/tacticalrmm auf GitHub auf, ohne es zu verändern.
#
#  Aufruf in der TRMM-VM:
#    sudo trmm-update
#
#  Oder direkt vom Proxmox-Host via SSH:
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/DEIN-GITHUB-USER/tacticalrmm-proxmox/main/scripts/trmm-update.sh)"
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

# ─── Root-Check ───────────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

# ─── Header ───────────────────────────────────────────────────────────────────
clear
echo ""
echo -e " ${BOLD}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e " ${BOLD}   Tactical RMM – Update  ${DIM}(Community Script)${CL}"
echo -e " ${DIM}   $(date '+%d.%m.%Y %H:%M:%S')${CL}"
echo -e " ${BOLD}${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo ""

# ─── TRMM-Installation prüfen ─────────────────────────────────────────────────
check_trmm_installed() {
  if [[ ! -f /rmm/api/tacticalrmm/settings.py ]] && [[ ! -d /rmm ]]; then
    msg_error "Tactical RMM ist nicht installiert! (/rmm nicht gefunden)"
  fi
  if ! id tactical &>/dev/null; then
    msg_error "User 'tactical' nicht gefunden. TRMM korrekt installiert?"
  fi
}

# ─── Services stoppen ─────────────────────────────────────────────────────────
stop_services() {
  msg_info "Stoppe TRMM-Services"
  local services=(
    "rmm.service"
    "daphne.service"
    "celery.service"
    "celerybeat.service"
    "meshcentral.service"
  )
  for svc in "${services[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      systemctl stop "$svc" 2>/dev/null || true
    fi
  done
  msg_ok "Services gestoppt"
}

# ─── Backup vor Update ────────────────────────────────────────────────────────
pre_update_backup() {
  msg_info "Erstelle Pre-Update-Backup"
  local backup_dir="/opt/trmm-backups/pre-update-$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$backup_dir"

  # Datenbank-Backup
  if command -v pg_dump &>/dev/null && sudo -u postgres pg_dump tacticalrmm > "${backup_dir}/db.sql" 2>/dev/null; then
    gzip "${backup_dir}/db.sql"
    msg_ok "Datenbank gesichert: ${backup_dir}/db.sql.gz"
  else
    msg_warn "Datenbank-Backup fehlgeschlagen – Update wird trotzdem fortgesetzt."
  fi

  # Konfigurationsdateien
  local conf_backup="${backup_dir}/config"
  mkdir -p "$conf_backup"
  [[ -f /rmm/api/tacticalrmm/local_settings.py ]] && \
    cp /rmm/api/tacticalrmm/local_settings.py "$conf_backup/" 2>/dev/null || true
  [[ -f /etc/nginx/sites-available/rmm.conf ]] && \
    cp /etc/nginx/sites-available/rmm.conf "$conf_backup/" 2>/dev/null || true
  [[ -f /etc/nginx/sites-available/meshcentral.conf ]] && \
    cp /etc/nginx/sites-available/meshcentral.conf "$conf_backup/" 2>/dev/null || true

  msg_ok "Pre-Update-Backup: ${backup_dir}"
  echo "$backup_dir"
}

# ─── Offizielles TRMM-Update ──────────────────────────────────────────────────
run_official_update() {
  msg_info "Lade offizielles Update-Script"
  local update_script="/tmp/trmm_update_$$.sh"
  if ! curl -fsSL https://raw.githubusercontent.com/amidaware/tacticalrmm/master/update.sh \
    -o "$update_script" 2>/dev/null; then
    msg_error "Konnte Update-Script nicht herunterladen!"
  fi
  chmod +x "$update_script"
  msg_ok "Update-Script geladen"

  echo ""
  divider
  echo -e " ${BL}Führe offizielles TRMM-Update aus...${CL}"
  divider
  echo ""

  # Als tactical-User ausführen (wie von TRMM vorgeschrieben)
  if sudo -u tactical bash "$update_script"; then
    rm -f "$update_script"
    return 0
  else
    rm -f "$update_script"
    return 1
  fi
}

# ─── Services neu starten ─────────────────────────────────────────────────────
start_services() {
  msg_info "Starte TRMM-Services neu"
  local services=(
    "meshcentral.service"
    "rmm.service"
    "daphne.service"
    "celery.service"
    "celerybeat.service"
    "nginx.service"
  )
  for svc in "${services[@]}"; do
    if systemctl list-unit-files "$svc" &>/dev/null; then
      systemctl start "$svc" 2>/dev/null || true
      sleep 1
    fi
  done
  msg_ok "Services gestartet"
}

# ─── Status-Check ─────────────────────────────────────────────────────────────
check_services_status() {
  echo ""
  divider
  echo -e " ${BOLD}Service-Status nach Update:${CL}"
  divider
  local services=("rmm" "daphne" "celery" "celerybeat" "meshcentral" "nginx")
  for svc in "${services[@]}"; do
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
      printf "  ${CM} %-18s ${GN}aktiv${CL}\n" "${svc}"
    elif systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
      printf "  ${CROSS} %-18s ${RD}INAKTIV${CL}\n" "${svc}"
    fi
  done

  # TRMM-Version ermitteln
  local version=""
  if [[ -f /rmm/api/tacticalrmm/settings.py ]]; then
    version=$(grep -oP "(?<=TRMM_VERSION = \")[^\"]*" /rmm/api/tacticalrmm/settings.py 2>/dev/null || echo "unbekannt")
  fi
  echo ""
  [[ -n "$version" ]] && echo -e "  ${INFO} Installierte Version: ${BOLD}${version}${CL}"
  divider
  echo ""
}

# ─── Hauptprogramm ────────────────────────────────────────────────────────────
check_trmm_installed

echo -e " ${INFO} Dieses Script:"
echo -e "   1. Erstellt ein Pre-Update-Backup"
echo -e "   2. Führt das offizielle TRMM-Update aus"
echo -e "   3. Zeigt den Service-Status danach"
echo ""
read -rp " Update jetzt starten? [J/n]: " confirm
[[ "${confirm,,}" == "n" ]] && { echo " Abgebrochen."; exit 0; }
echo ""

backup_dir=$(pre_update_backup)

if run_official_update; then
  msg_ok "Update erfolgreich abgeschlossen!"
  start_services
  check_services_status
  echo -e " ${DIM}Pre-Update-Backup verfügbar unter: ${backup_dir}${CL}"
  echo ""
else
  msg_error "Update fehlgeschlagen! Backup verfügbar: ${backup_dir}"
fi
