#!/usr/bin/env bash
# =============================================================================
#  Proxmox LXC Installer fuer Tactical RMM  (Community Script)
#  https://github.com/DEIN-GITHUB-USER/tacticalrmm-proxmox
#
#  Aufruf auf dem Proxmox-Host als root:
#    wget -qO /tmp/trmm-install.sh https://raw.githubusercontent.com/DEIN-GITHUB-USER/tacticalrmm-proxmox/main/tacticalrmm.sh && bash /tmp/trmm-install.sh
#
#  DISCLAIMER: Dieses Script ist ein unabhaengiges Community-Projekt und steht
#  in keiner Verbindung zu AmidaWare LLC. "Tactical RMM" ist eine eingetragene
#  Marke von AmidaWare LLC. Das Script laedt die offizielle Tactical RMM Software
#  herunter und installiert sie gemaess der oeffentlichen Installationsdokumentation
#  unter https://docs.tacticalrmm.com - ohne diese zu veraendern.
# =============================================================================

set -eo pipefail

# --- Farben -------------------------------------------------------------------
YW=$'\033[33m'
BL=$'\033[36m'
RD=$'\033[01;31m'
GN=$'\033[1;92m'
CL=$'\033[m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
BFR=$'\r\033[K'
HOLD=" "
CM="${GN}OK${CL}"
CROSS="${RD}FEHLER${CL}"
INFO="${BL}i${CL}"
WARN="${YW}!${CL}"

# --- GitHub-Basis-URL (DEIN-GITHUB-USER ersetzen!) ----------------------------
GITHUB_RAW="https://raw.githubusercontent.com/yodaeichen/tacticalrmm-proxmox/main"

# --- Globale Variablen --------------------------------------------------------
CTID=""
CT_HOSTNAME="tacticalrmm"
CORES="2"
RAM="4096"
SWAP="512"
DISK="50"
BRIDGE="vmbr0"
VLAN=""
IP="dhcp"
GW=""
DNS="8.8.8.8"
UNPRIVILEGED="1"
START_CT="yes"
STORAGE_CT=""
STORAGE_TMPL=""
DEBIAN_VERSION=""
DEBIAN_CODENAME=""
TMPL_FILE=""
ROOT_PASS=""

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# --- Hilfsfunktionen ----------------------------------------------------------
msg_info()  { local msg="$1"; echo -ne " ${HOLD} ${YW}${msg}...${CL}"; }
msg_ok()    { local msg="$1"; echo -e "${BFR} ${CM} ${GN}${msg}${CL}"; }
msg_error() { local msg="$1"; echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"; exit 1; }
msg_warn()  { local msg="$1"; echo -e " ${WARN} ${YW}${msg}${CL}"; }
divider()   { echo -e "${DIM}$(printf -- '-%.0s' {1..62})${CL}"; }

prompt() {
  local display="$1" varname="$2" default="${3:-}"
  if [[ -n "$default" ]]; then
    echo -ne " ${YW}${display}${CL} [${default}]: "
  else
    echo -ne " ${YW}${display}${CL}: "
  fi
  local input
  read -r input
  printf -v "$varname" '%s' "${input:-$default}"
}

header_info() {
  clear
  echo ""
  echo -e "${BL}${BOLD}  ######   #####  ##   ## ##   ## ##   ##${CL}"
  echo -e "${BL}${BOLD}    ##    ##   ## ### ### ### ### ### ###${CL}"
  echo -e "${BL}${BOLD}    ##    #######  ## #  ##  ## #  ## # ##${CL}"
  echo -e "${BL}${BOLD}    ##    ##   ##  ## #  ##  ## #  ## # ##${CL}"
  echo -e "${BL}${BOLD}    ##    ##   ##  ##    ##    ##  ##   ##${CL}"
  echo ""
  echo -e "  ${BOLD}Proxmox LXC Installer fuer Tactical RMM${CL}"
  echo -e "  ${DIM}Community Script - kein offizielles AmidaWare-Projekt${CL}"
  echo ""
}

# --- Proxmox pruefen ----------------------------------------------------------
check_proxmox() {
  msg_info "Pruefe Proxmox-Umgebung"
  if ! command -v pct &>/dev/null; then
    msg_error "Muss auf einem Proxmox VE Host ausgefuehrt werden!"
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "Bitte als root ausfuehren!"
  fi
  local pve_raw
  pve_raw=$(pveversion 2>/dev/null | head -1 || true)
  local PVE_VERSION="" PVE_MAJOR=0
  if [[ "$pve_raw" =~ pve-manager/([0-9]+)\.([0-9]+) ]]; then
    PVE_MAJOR="${BASH_REMATCH[1]}"
    PVE_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  fi
  if [[ -z "$PVE_VERSION" ]]; then
    msg_warn "Proxmox-Version nicht ermittelbar - fahre fort."
  elif [[ "$PVE_MAJOR" -lt 7 ]]; then
    msg_error "Proxmox VE 7.0+ erforderlich (erkannt: $PVE_VERSION)"
  else
    msg_ok "Proxmox VE $PVE_VERSION"
  fi
}

# --- OS-Auswahl ---------------------------------------------------------------
select_os_version() {
  echo ""
  echo -e " ${BOLD}Betriebssystem waehlen:${CL}"
  echo ""
  echo -e "  ${BOLD}1)${CL} ${GN}Debian 12 (Bookworm)${CL}  ${GN}<-- Empfohlen${CL}"
  echo -e "     ${DIM}Offiziell unterstuetzt von Tactical RMM${CL}"
  echo ""
  echo -e "  ${BOLD}2)${CL} ${YW}Debian 13 (Trixie)${CL}   ${WARN} Experimentell${CL}"
  echo -e "     ${DIM}Noch nicht offiziell unterstuetzt - Python 3.13 / PostgreSQL 17${CL}"
  echo ""
  echo -ne " Auswahl [1/2, Enter = 1]: "
  read -r os_choice
  os_choice="${os_choice:-1}"
  case "$os_choice" in
    2)
      DEBIAN_VERSION="13"
      DEBIAN_CODENAME="trixie"
      echo ""
      echo -ne " Wirklich Debian 13 verwenden? [j/N]: "
      read -r c13; c13="${c13:-N}"
      if [[ "${c13,,}" != "j" ]]; then
        msg_warn "Zurueck zur OS-Auswahl."
        select_os_version; return
      fi
      msg_ok "OS: Debian 13 Trixie (experimentell)"
      ;;
    *)
      DEBIAN_VERSION="12"
      DEBIAN_CODENAME="bookworm"
      msg_ok "OS: Debian 12 Bookworm (empfohlen)"
      ;;
  esac
}

# --- Storage-Hilfsfunktionen --------------------------------------------------
_get_all_storages() {
  pvesm status 2>/dev/null | awk 'NR>1 {print $1}' || true
}

_get_storages_with_content() {
  local content_type="$1"
  local stor
  while IFS= read -r stor; do
    if pvesm status --storage "$stor" 2>/dev/null | grep -q "$content_type"; then
      echo "$stor"
    fi
  done < <(_get_all_storages)
}

_pick_storage() {
  local label="$1" varname="$2" content_filter="${3:-}"
  local -a STORAGES=()

  if [[ -n "$content_filter" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && STORAGES+=("$line")
    done < <(_get_storages_with_content "$content_filter")
  fi

  # Fallback: alle Storages
  if [[ ${#STORAGES[@]} -eq 0 ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && STORAGES+=("$line")
    done < <(_get_all_storages)
  fi

  if [[ ${#STORAGES[@]} -eq 0 ]]; then
    msg_error "Kein Storage gefunden! Proxmox-Storage-Konfiguration pruefen."
  elif [[ ${#STORAGES[@]} -eq 1 ]]; then
    printf -v "$varname" '%s' "${STORAGES[0]}"
    msg_ok "${label}: ${STORAGES[0]}"
  else
    echo ""
    echo -e " ${YW}${label} - Storage waehlen:${CL}"
    local i=1
    for s in "${STORAGES[@]}"; do
      local stype
      stype=$(pvesm status --storage "$s" 2>/dev/null | awk 'NR>1 {print $2}' || echo "")
      echo -e "  ${BOLD}${i})${CL} ${s} ${DIM}(${stype})${CL}"
      ((i++))
    done
    echo ""
    echo -ne " Auswahl [1-${#STORAGES[@]}]: "
    local choice
    read -r choice
    choice="${choice:-1}"
    local idx=0
    if [[ "$choice" -ge 1 && "$choice" -le ${#STORAGES[@]} ]] 2>/dev/null; then
      idx=$((choice-1))
    fi
    printf -v "$varname" '%s' "${STORAGES[$idx]}"
    msg_ok "${label}: ${STORAGES[$idx]}"
  fi
}

select_storage_ct() {
  echo ""
  echo -e " ${DIM}Storage fuer die CT-Rootdisk:${CL}"
  _pick_storage "CT-Rootdisk Storage" STORAGE_CT "rootdir"
}

select_storage_tmpl() {
  echo ""
  # Pruefen ob dedizierter Template-Storage existiert
  local -a TMPL_STORAGES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && TMPL_STORAGES+=("$line")
  done < <(_get_storages_with_content "vztmpl")

  if [[ ${#TMPL_STORAGES[@]} -eq 0 ]]; then
    msg_warn "Kein Storage mit 'vztmpl' gefunden - nutze CT-Storage auch fuer Templates."
    STORAGE_TMPL="$STORAGE_CT"
  elif [[ ${#TMPL_STORAGES[@]} -eq 1 ]]; then
    STORAGE_TMPL="${TMPL_STORAGES[0]}"
    msg_ok "Template-Storage: ${STORAGE_TMPL}"
  else
    echo -e " ${DIM}Storage fuer Debian-Template (Download):${CL}"
    _pick_storage "Template-Storage" STORAGE_TMPL "vztmpl"
  fi
}

# --- Netzwerk-Konfiguration ---------------------------------------------------
configure_network() {
  echo ""
  echo -e " ${BOLD}Netzwerk-Konfiguration:${CL}"
  echo ""
  echo -e "  ${BOLD}1)${CL} DHCP (automatisch)"
  echo -e "  ${BOLD}2)${CL} Statische IP"
  echo ""
  echo -ne " Auswahl [1/2, Enter = 1]: "
  read -r net_choice
  net_choice="${net_choice:-1}"
  if [[ "$net_choice" == "2" ]]; then
    prompt "IP-Adresse (z.B. 192.168.1.100/24)" IP ""
    prompt "Gateway   (z.B. 192.168.1.1)" GW ""
    prompt "DNS-Server" DNS "8.8.8.8"
    msg_ok "Statische IP: ${IP} via ${GW}"
  else
    IP="dhcp"; GW=""; DNS="8.8.8.8"
    msg_ok "Netzwerk: DHCP"
  fi
}

# --- Template ermitteln und herunterladen -------------------------------------
fetch_template() {
  msg_info "Suche Debian ${DEBIAN_VERSION} LXC-Template"

  # Bereits lokal vorhanden?
  local existing
  existing=$(pveam list "$STORAGE_TMPL" 2>/dev/null \
    | awk '{print $1}' \
    | grep "debian-${DEBIAN_VERSION}" \
    | grep "standard" \
    | sort -V | tail -1 || true)

  if [[ -n "$existing" ]]; then
    TMPL_FILE="${existing}"
    msg_ok "Template vorhanden: $(basename "${TMPL_FILE}")"
    return
  fi

  # Katalog aktualisieren und herunterladen
  msg_info "Aktualisiere Template-Katalog"
  pveam update >/dev/null 2>&1 || true

  local tmpl_name
  tmpl_name=$(pveam available --section system 2>/dev/null \
    | awk '{print $2}' \
    | grep "debian-${DEBIAN_VERSION}" \
    | grep "standard" \
    | sort -V | tail -1 || true)

  if [[ -z "$tmpl_name" ]]; then
    msg_error "Kein Debian ${DEBIAN_VERSION} Standard-Template im Proxmox-Katalog gefunden!"
  fi

  msg_info "Lade Template: ${tmpl_name}"
  pveam download "$STORAGE_TMPL" "$tmpl_name" >/dev/null 2>&1 \
    || msg_error "Template-Download fehlgeschlagen!"

  TMPL_FILE="${STORAGE_TMPL}:vztmpl/${tmpl_name}"
  msg_ok "Template geladen: ${tmpl_name}"
}

# --- Modus: Installation ------------------------------------------------------
mode_install() {
  echo ""
  divider
  echo -e " ${BOLD}${GN}TACTICAL RMM - LXC CONTAINER ERSTELLEN${CL}"
  divider
  echo -e " ${DIM}Erstellt einen Debian LXC Container und bereitet Tactical RMM vor.${CL}"
  echo -e " ${WARN} Tactical RMM benoetigt 3 DNS A-Records (rmm/api/mesh) auf deine Domain!"
  echo ""

  # OS
  select_os_version

  # CT-ID
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
  prompt "CT-ID" CTID "$next_id"

  # Hostname
  prompt "Hostname" CT_HOSTNAME "tacticalrmm"

  # CPU
  prompt "CPU-Kerne" CORES "2"

  # RAM
  prompt "RAM in MB" RAM "4096"
  if [[ "$RAM" -lt 4096 ]] 2>/dev/null; then
    msg_warn "Mindestens 4096 MB empfohlen - TRMM kann sonst instabil werden."
    echo -ne " Trotzdem fortfahren? [j/N]: "
    read -r c; c="${c:-N}"
    [[ "${c,,}" != "j" ]] && msg_error "Abgebrochen."
  fi

  # Swap
  prompt "Swap in MB" SWAP "512"

  # Disk
  prompt "Disk in GB" DISK "50"

  # Bridge
  prompt "Netzwerk-Bridge" BRIDGE "vmbr0"

  # VLAN
  echo -ne " ${YW}VLAN-Tag${CL} (leer = keiner): "
  read -r VLAN; VLAN="${VLAN:-}"

  # Netzwerk
  configure_network

  # Privilegiert / Unprivilegiert
  echo ""
  echo -ne " ${YW}Unprivilegierten Container?${CL} (empfohlen) [J/n]: "
  read -r _unpriv; _unpriv="${_unpriv:-J}"
  [[ "${_unpriv,,}" == "n" ]] && UNPRIVILEGED="0" || UNPRIVILEGED="1"

  # Storage Rootdisk
  select_storage_ct

  # Storage Template
  select_storage_tmpl

  # Autostart
  echo -ne " ${YW}Container nach Erstellung starten?${CL} [J/n]: "
  read -r _start; _start="${_start:-J}"
  [[ "${_start,,}" == "n" ]] && START_CT="no" || START_CT="yes"

  # Zusammenfassung
  echo ""
  divider
  echo -e " ${BOLD}Zusammenfassung${CL}"
  divider
  printf "  %-20s ${BOLD}%s${CL}\n"    "CT-ID:"          "$CTID"
  printf "  %-20s ${BOLD}%s${CL}\n"    "OS:"             "Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Hostname:"       "$CT_HOSTNAME"
  printf "  %-20s ${BOLD}%s${CL}\n"    "CPU-Kerne:"      "$CORES"
  printf "  %-20s ${BOLD}%s MB${CL}\n" "RAM:"            "$RAM"
  printf "  %-20s ${BOLD}%s MB${CL}\n" "Swap:"           "$SWAP"
  printf "  %-20s ${BOLD}%s GB${CL}\n" "Disk:"           "$DISK"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Bridge:"         "$BRIDGE"
  [[ -n "$VLAN" ]] && printf "  %-20s ${BOLD}%s${CL}\n" "VLAN:" "$VLAN"
  printf "  %-20s ${BOLD}%s${CL}\n"    "IP:"             "$IP"
  [[ -n "$GW" ]]   && printf "  %-20s ${BOLD}%s${CL}\n" "Gateway:" "$GW"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Unprivilegiert:" "$([[ "$UNPRIVILEGED" == "1" ]] && echo "ja" || echo "nein")"
  printf "  %-20s ${BOLD}%s${CL}\n"    "CT-Storage:"     "$STORAGE_CT"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Tmpl-Storage:"   "$STORAGE_TMPL"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Autostart:"      "$START_CT"
  echo ""
  echo -ne " Jetzt erstellen? [J/n]: "
  read -r confirm; confirm="${confirm:-J}"
  [[ "${confirm,,}" == "n" ]] && msg_error "Abgebrochen."

  _do_create
}

# --- Container erstellen und konfigurieren ------------------------------------
_do_create() {
  fetch_template

  ROOT_PASS=$(tr -dc 'A-Za-z0-9@#%^' </dev/urandom | head -c 20)

  # net0-Argument zusammenbauen
  local net0_arg="name=eth0,bridge=${BRIDGE}"
  [[ -n "$VLAN" ]] && net0_arg="${net0_arg},tag=${VLAN}"
  if [[ "$IP" == "dhcp" ]]; then
    net0_arg="${net0_arg},ip=dhcp"
  else
    net0_arg="${net0_arg},ip=${IP}"
    [[ -n "$GW" ]] && net0_arg="${net0_arg},gw=${GW}"
  fi

  # Container anlegen
  msg_info "Erstelle LXC Container ${CTID}"
  pct create "$CTID" "$TMPL_FILE" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap "$SWAP" \
    --rootfs "${STORAGE_CT}:${DISK}" \
    --net0 "$net0_arg" \
    --nameserver "$DNS" \
    --unprivileged "$UNPRIVILEGED" \
    --features nesting=1 \
    --ostype debian \
    --password "$ROOT_PASS" \
    --onboot 1 \
    --start 0
  msg_ok "Container ${CTID} angelegt"

  # Starten fuer Erstkonfiguration
  msg_info "Starte Container fuer Erstkonfiguration"
  pct start "$CTID"

  # Warten bis Container bereit ist
  local retries=0
  while ! pct exec "$CTID" -- true 2>/dev/null; do
    sleep 2
    ((retries++))
    [[ $retries -gt 15 ]] && msg_error "Container antwortet nicht nach 30 Sekunden!"
  done
  msg_ok "Container gestartet"

  # System-Pakete installieren
  msg_info "Installiere System-Pakete"
  pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null
    apt-get install -yq \
      curl wget sudo ufw git htop ncdu \
      openssh-server 2>/dev/null
    systemctl enable ssh 2>/dev/null
  " || msg_error "Paket-Installation fehlgeschlagen!"
  msg_ok "System-Pakete installiert"

  # Firewall konfigurieren
  msg_info "Konfiguriere UFW-Firewall"
  pct exec "$CTID" -- bash -c "
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow https
    ufw --force enable
  " >/dev/null 2>&1
  msg_ok "Firewall konfiguriert"

  # tactical-User anlegen
  msg_info "Lege tactical-User an"
  pct exec "$CTID" -- bash -c "
    useradd -m -G sudo -s /bin/bash tactical 2>/dev/null || true
    echo 'tactical ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tactical
    chmod 0440 /etc/sudoers.d/tactical
  "
  msg_ok "User 'tactical' angelegt"

  # TRMM-Installationsscript herunterladen
  msg_info "Lade Tactical RMM Installationsscript"
  pct exec "$CTID" -- bash -c "
    curl -fsSL https://raw.githubusercontent.com/amidaware/tacticalrmm/master/install.sh \
      -o /home/tactical/install.sh
    chown tactical:tactical /home/tactical/install.sh
    chmod +x /home/tactical/install.sh
  " || msg_warn "TRMM-Script konnte nicht geladen werden (manuell nachholen)."
  msg_ok "TRMM-Installationsscript bereit"

  # Hilfstools installieren
  msg_info "Installiere Hilfstools (trmm-update, trmm-backup)"
  pct exec "$CTID" -- bash -c "
    curl -fsSL ${GITHUB_RAW}/scripts/trmm-update.sh -o /usr/local/bin/trmm-update
    curl -fsSL ${GITHUB_RAW}/scripts/trmm-backup.sh -o /usr/local/bin/trmm-backup
    chmod +x /usr/local/bin/trmm-update /usr/local/bin/trmm-backup
    mkdir -p /opt/trmm-backups
    echo '0 2 * * * tactical /usr/local/bin/trmm-backup --auto >> /var/log/trmm-backup.log 2>&1' >> /etc/crontab
  " || msg_warn "Hilfstools konnten nicht installiert werden."
  msg_ok "Hilfstools installiert"

  # MOTD schreiben: Datei lokal erzeugen, dann per pct push in Container kopieren
  # Kein Heredoc hier - wuerde von der aeusseren bash-Instanz gelesen werden!
  msg_info "Setze MOTD"
  local motd_file="${TEMP_DIR}/motd"
  {
    echo ""
    echo "  +--------------------------------------------------------------+"
    echo "  |        TACTICAL RMM - Bereit zur Installation                |"
    echo "  +--------------------------------------------------------------+"
    echo "  |  Schritt 1: DNS A-Records erstellen (alle -> CT-IP)         |"
    echo "  |    rmm.deine-domain.de                                       |"
    echo "  |    api.deine-domain.de                                       |"
    echo "  |    mesh.deine-domain.de                                      |"
    echo "  |                                                              |"
    echo "  |  Schritt 2: Als tactical-User einloggen:                     |"
    echo "  |    su - tactical                                             |"
    echo "  |    ./install.sh                                              |"
    echo "  |                                                              |"
    echo "  |  Nach der Installation:                                      |"
    echo "  |    trmm-update   Tactical RMM aktualisieren                  |"
    echo "  |    trmm-backup   Manuelles Backup erstellen                  |"
    echo "  |                                                              |"
    echo "  |  Doku: https://docs.tacticalrmm.com/install_server/          |"
    echo "  +--------------------------------------------------------------+"
    echo ""
  } > "$motd_file"
  pct push "$CTID" "$motd_file" /etc/motd
  msg_ok "MOTD gesetzt"

  # Container ggf. stoppen
  if [[ "$START_CT" != "yes" ]]; then
    msg_info "Stoppe Container"
    pct stop "$CTID"
    msg_ok "Container gestoppt"
  fi

  # IP ermitteln
  local CT_IP=""
  CT_IP=$(pct exec "$CTID" -- bash -c \
    "ip -4 addr show eth0 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1 | head -1" \
    2>/dev/null || true)

  # Abschluss-Ausgabe
  echo ""
  divider
  echo -e " ${GN}${BOLD}Container erfolgreich erstellt!${CL}"
  divider
  echo ""
  printf "  %-20s ${BOLD}%s${CL}\n" "CT-ID:"       "$CTID"
  printf "  %-20s ${BOLD}%s${CL}\n" "OS:"          "Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
  printf "  %-20s ${BOLD}%s${CL}\n" "IP-Adresse:"  "${CT_IP:-siehe Proxmox GUI}"
  printf "  %-20s ${BOLD}%s${CL}\n" "SSH-User:"    "tactical"
  printf "  %-20s ${BOLD}${RD}%s${CL}  ${YW}<-- JETZT NOTIEREN!${CL}\n" "Root-Passwort:" "$ROOT_PASS"
  echo ""
  echo -e " ${YW}Naechste Schritte:${CL}"
  echo -e "  1. DNS A-Records: ${BL}rmm / api / mesh${CL} -> ${CT_IP:-CT-IP}"
  echo -e "  2. SSH:           ${BL}ssh tactical@${CT_IP:-<CT-IP>}${CL}"
  echo -e "  3. Installation:  ${BL}./install.sh${CL}"
  echo ""
  echo -e " ${DIM}Installierte Hilfstools:${CL}"
  echo -e "  ${BL}trmm-update${CL}  - Tactical RMM aktualisieren"
  echo -e "  ${BL}trmm-backup${CL}  - Manuelles Backup (Cron taeglich 02:00)"
  echo ""
  divider
  echo ""
}

# --- Modus: Update ------------------------------------------------------------
mode_update() {
  echo ""
  divider
  echo -e " ${BOLD}${BL}TACTICAL RMM AKTUALISIEREN${CL}"
  divider

  # TRMM-Container suchen
  local -a TRMM_CTS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && TRMM_CTS+=("$line")
  done < <(pct list 2>/dev/null | awk 'NR>1 {print $1, $3}' | grep -i "tactical\|trmm" || true)

  if [[ ${#TRMM_CTS[@]} -eq 0 ]]; then
    msg_warn "Kein Container mit 'tactical' oder 'trmm' im Namen gefunden."
    echo -e " Alle Container:"
    pct list 2>/dev/null | awk 'NR>1 {printf "  %-6s %-20s %s\n", $1, $3, $2}'
  else
    echo -e " ${GN}Gefundene TRMM-Container:${CL}"
    for ct in "${TRMM_CTS[@]}"; do echo "  $ct"; done
  fi
  echo ""

  prompt "CT-ID des TRMM-Containers" TARGET_CTID ""
  [[ -z "$TARGET_CTID" ]] && msg_error "Keine CT-ID eingegeben."

  local ct_status
  ct_status=$(pct status "$TARGET_CTID" 2>/dev/null | awk '{print $2}' || echo "unknown")
  if [[ "$ct_status" != "running" ]]; then
    msg_warn "Container ${TARGET_CTID} laeuft nicht (Status: ${ct_status})"
    echo -ne " Container jetzt starten? [J/n]: "
    read -r s; s="${s:-J}"
    if [[ "${s,,}" != "n" ]]; then
      msg_info "Starte Container ${TARGET_CTID}"
      pct start "$TARGET_CTID"
      sleep 5
      msg_ok "Container gestartet"
    else
      msg_error "Abgebrochen."
    fi
  fi

  echo ""
  echo -e " ${INFO} Fuehre Update im Container ${TARGET_CTID} aus..."
  echo ""

  pct exec "$TARGET_CTID" -- bash -c \
    "curl -fsSL ${GITHUB_RAW}/scripts/trmm-update.sh | bash" \
    || msg_error "Update fehlgeschlagen!"

  echo ""
  msg_ok "Update abgeschlossen!"
  divider
  echo ""
}

# --- Modus: Backup ------------------------------------------------------------
mode_backup() {
  echo ""
  divider
  echo -e " ${BOLD}${YW}BACKUP ERSTELLEN${CL}"
  divider
  echo -e " ${DIM}Erstellt einen Proxmox-CT-Snapshot und ein TRMM-App-Backup.${CL}"
  echo ""

  echo -e " Alle Container:"
  pct list 2>/dev/null | awk 'NR>1 {printf "  %-6s %-20s %s\n", $1, $3, $2}'
  echo ""

  prompt "CT-ID des TRMM-Containers" TARGET_CTID ""
  [[ -z "$TARGET_CTID" ]] && msg_error "Keine CT-ID eingegeben."

  local ts; ts=$(date +%Y%m%d_%H%M%S)
  local snap_name="trmm-bkp-${ts}"

  echo ""
  echo -e " ${INFO} Snapshot-Name: ${BOLD}${snap_name}${CL}"
  echo ""
  echo -ne " Backup jetzt starten? [J/n]: "
  read -r confirm; confirm="${confirm:-J}"
  [[ "${confirm,,}" == "n" ]] && msg_error "Abgebrochen."

  # Proxmox CT-Snapshot
  msg_info "Erstelle Proxmox CT-Snapshot"
  if pct snapshot "$TARGET_CTID" "$snap_name" \
      --description "Tactical RMM Backup ${ts}" 2>/dev/null; then
    msg_ok "Snapshot erstellt: ${snap_name}"
  else
    msg_warn "Snapshot fehlgeschlagen (Storage unterstuetzt kein Snapshots?). Weiter mit App-Backup."
  fi

  # App-Backup im Container
  local ct_status
  ct_status=$(pct status "$TARGET_CTID" 2>/dev/null | awk '{print $2}' || echo "unknown")
  if [[ "$ct_status" == "running" ]]; then
    msg_info "Starte App-Backup im Container"
    pct exec "$TARGET_CTID" -- bash -c \
      "command -v trmm-backup >/dev/null && trmm-backup --auto || echo 'trmm-backup nicht gefunden'" \
      2>/dev/null && msg_ok "App-Backup abgeschlossen" \
      || msg_warn "App-Backup fehlgeschlagen."
  else
    msg_warn "Container laeuft nicht - App-Backup uebersprungen."
  fi

  # Snapshots anzeigen
  echo ""
  echo -e " ${GN}Vorhandene Snapshots fuer CT ${TARGET_CTID}:${CL}"
  pct listsnapshot "$TARGET_CTID" 2>/dev/null | grep -v "^->" || echo "  (keine)"
  echo ""
  divider
  echo -e " ${CM} Backup abgeschlossen!"
  echo ""
}

# --- Hauptmenu ----------------------------------------------------------------
select_mode() {
  echo ""
  divider
  echo -e " ${BOLD}Was moechtest du tun?${CL}"
  divider
  echo ""
  echo -e "  ${BOLD}1)${CL} ${GN}Neuen LXC Container erstellen${CL}  - Debian 12/13 + TRMM-Vorbereitung"
  echo -e "  ${BOLD}2)${CL} ${BL}Tactical RMM aktualisieren${CL}     - Update auf bestehendem Container"
  echo -e "  ${BOLD}3)${CL} ${YW}Backup erstellen${CL}               - Snapshot + App-Backup"
  echo -e "  ${BOLD}4)${CL} ${DIM}Beenden${CL}"
  echo ""
  echo -ne " Auswahl [1-4]: "
  read -r MODE; MODE="${MODE:-}"
  case "$MODE" in
    1) mode_install ;;
    2) mode_update ;;
    3) mode_backup ;;
    4) echo -e "\n Auf Wiedersehen!\n"; exit 0 ;;
    *) msg_warn "Ungueltige Auswahl."; select_mode ;;
  esac
}

# --- Hauptprogramm ------------------------------------------------------------
header_info
check_proxmox
select_mode#!/usr/bin/env bash
# =============================================================================
#  Proxmox LXC Installer fuer Tactical RMM  (Community Script)
#  https://github.com/DEIN-GITHUB-USER/tacticalrmm-proxmox
#
#  Aufruf auf dem Proxmox-Host als root:
#    wget -qO /tmp/trmm-install.sh https://raw.githubusercontent.com/DEIN-GITHUB-USER/tacticalrmm-proxmox/main/tacticalrmm.sh && bash /tmp/trmm-install.sh
#
#  DISCLAIMER: Dieses Script ist ein unabhaengiges Community-Projekt und steht
#  in keiner Verbindung zu AmidaWare LLC. "Tactical RMM" ist eine eingetragene
#  Marke von AmidaWare LLC. Das Script laedt die offizielle Tactical RMM Software
#  herunter und installiert sie gemaess der oeffentlichen Installationsdokumentation
#  unter https://docs.tacticalrmm.com - ohne diese zu veraendern.
# =============================================================================

set -eo pipefail

# --- Farben -------------------------------------------------------------------
YW=$'\033[33m'
BL=$'\033[36m'
RD=$'\033[01;31m'
GN=$'\033[1;92m'
CL=$'\033[m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
BFR=$'\r\033[K'
HOLD=" "
CM="${GN}OK${CL}"
CROSS="${RD}FEHLER${CL}"
INFO="${BL}i${CL}"
WARN="${YW}!${CL}"

# --- GitHub-Basis-URL (DEIN-GITHUB-USER ersetzen!) ----------------------------
GITHUB_RAW="https://raw.githubusercontent.com/yodaeichen/tacticalrmm-proxmox/main"

# --- Globale Variablen --------------------------------------------------------
CTID=""
CT_HOSTNAME="tacticalrmm"
CORES="2"
RAM="4096"
SWAP="512"
DISK="50"
BRIDGE="vmbr0"
VLAN=""
IP="dhcp"
GW=""
DNS="8.8.8.8"
UNPRIVILEGED="1"
START_CT="yes"
STORAGE_CT=""
STORAGE_TMPL=""
DEBIAN_VERSION=""
DEBIAN_CODENAME=""
TMPL_FILE=""
ROOT_PASS=""

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# --- Hilfsfunktionen ----------------------------------------------------------
msg_info()  { local msg="$1"; echo -ne " ${HOLD} ${YW}${msg}...${CL}"; }
msg_ok()    { local msg="$1"; echo -e "${BFR} ${CM} ${GN}${msg}${CL}"; }
msg_error() { local msg="$1"; echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"; exit 1; }
msg_warn()  { local msg="$1"; echo -e " ${WARN} ${YW}${msg}${CL}"; }
divider()   { echo -e "${DIM}$(printf -- '-%.0s' {1..62})${CL}"; }

prompt() {
  local display="$1" varname="$2" default="${3:-}"
  if [[ -n "$default" ]]; then
    echo -ne " ${YW}${display}${CL} [${default}]: "
  else
    echo -ne " ${YW}${display}${CL}: "
  fi
  local input
  read -r input
  printf -v "$varname" '%s' "${input:-$default}"
}

header_info() {
  clear
  echo -e "${BL}"
  cat <<"BANNER"
  ████████╗██████╗ ███╗   ███╗███╗   ███╗
     ██╔══╝██╔══██╗████╗ ████║████╗ ████║
     ██║   ██████╔╝██╔████╔██║██╔████╔██║
     ██║   ██╔══██╗██║╚██╔╝██║██║╚██╔╝██║
     ██║   ██║  ██║██║ ╚═╝ ██║██║ ╚═╝ ██║
     ╚═╝   ╚═╝  ╚═╝╚═╝     ╚═╝╚═╝     ╚═╝
BANNER
  echo -e "${CL}"
  echo -e "  ${BOLD}Proxmox LXC Installer fuer Tactical RMM${CL}"
  echo -e "  ${DIM}Community Script - kein offizielles AmidaWare-Projekt${CL}"
  echo ""
}

# --- Proxmox pruefen ----------------------------------------------------------
check_proxmox() {
  msg_info "Pruefe Proxmox-Umgebung"
  if ! command -v pct &>/dev/null; then
    msg_error "Muss auf einem Proxmox VE Host ausgefuehrt werden!"
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "Bitte als root ausfuehren!"
  fi
  local pve_raw
  pve_raw=$(pveversion 2>/dev/null | head -1 || true)
  local PVE_VERSION="" PVE_MAJOR=0
  if [[ "$pve_raw" =~ pve-manager/([0-9]+)\.([0-9]+) ]]; then
    PVE_MAJOR="${BASH_REMATCH[1]}"
    PVE_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  fi
  if [[ -z "$PVE_VERSION" ]]; then
    msg_warn "Proxmox-Version nicht ermittelbar - fahre fort."
  elif [[ "$PVE_MAJOR" -lt 7 ]]; then
    msg_error "Proxmox VE 7.0+ erforderlich (erkannt: $PVE_VERSION)"
  else
    msg_ok "Proxmox VE $PVE_VERSION"
  fi
}

# --- OS-Auswahl ---------------------------------------------------------------
select_os_version() {
  echo ""
  echo -e " ${BOLD}Betriebssystem waehlen:${CL}"
  echo ""
  echo -e "  ${BOLD}1)${CL} ${GN}Debian 12 (Bookworm)${CL}  ${GN}<-- Empfohlen${CL}"
  echo -e "     ${DIM}Offiziell unterstuetzt von Tactical RMM${CL}"
  echo ""
  echo -e "  ${BOLD}2)${CL} ${YW}Debian 13 (Trixie)${CL}   ${WARN} Experimentell${CL}"
  echo -e "     ${DIM}Noch nicht offiziell unterstuetzt - Python 3.13 / PostgreSQL 17${CL}"
  echo ""
  echo -ne " Auswahl [1/2, Enter = 1]: "
  read -r os_choice
  os_choice="${os_choice:-1}"
  case "$os_choice" in
    2)
      DEBIAN_VERSION="13"
      DEBIAN_CODENAME="trixie"
      echo ""
      echo -ne " Wirklich Debian 13 verwenden? [j/N]: "
      read -r c13; c13="${c13:-N}"
      if [[ "${c13,,}" != "j" ]]; then
        msg_warn "Zurueck zur OS-Auswahl."
        select_os_version; return
      fi
      msg_ok "OS: Debian 13 Trixie (experimentell)"
      ;;
    *)
      DEBIAN_VERSION="12"
      DEBIAN_CODENAME="bookworm"
      msg_ok "OS: Debian 12 Bookworm (empfohlen)"
      ;;
  esac
}

# --- Storage-Hilfsfunktionen --------------------------------------------------
_get_all_storages() {
  pvesm status 2>/dev/null | awk 'NR>1 {print $1}' || true
}

_get_storages_with_content() {
  local content_type="$1"
  local stor
  while IFS= read -r stor; do
    if pvesm status --storage "$stor" 2>/dev/null | grep -q "$content_type"; then
      echo "$stor"
    fi
  done < <(_get_all_storages)
}

_pick_storage() {
  local label="$1" varname="$2" content_filter="${3:-}"
  local -a STORAGES=()

  if [[ -n "$content_filter" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && STORAGES+=("$line")
    done < <(_get_storages_with_content "$content_filter")
  fi

  # Fallback: alle Storages
  if [[ ${#STORAGES[@]} -eq 0 ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && STORAGES+=("$line")
    done < <(_get_all_storages)
  fi

  if [[ ${#STORAGES[@]} -eq 0 ]]; then
    msg_error "Kein Storage gefunden! Proxmox-Storage-Konfiguration pruefen."
  elif [[ ${#STORAGES[@]} -eq 1 ]]; then
    printf -v "$varname" '%s' "${STORAGES[0]}"
    msg_ok "${label}: ${STORAGES[0]}"
  else
    echo ""
    echo -e " ${YW}${label} - Storage waehlen:${CL}"
    local i=1
    for s in "${STORAGES[@]}"; do
      local stype
      stype=$(pvesm status --storage "$s" 2>/dev/null | awk 'NR>1 {print $2}' || echo "")
      echo -e "  ${BOLD}${i})${CL} ${s} ${DIM}(${stype})${CL}"
      ((i++))
    done
    echo ""
    echo -ne " Auswahl [1-${#STORAGES[@]}]: "
    local choice
    read -r choice
    choice="${choice:-1}"
    local idx=0
    if [[ "$choice" -ge 1 && "$choice" -le ${#STORAGES[@]} ]] 2>/dev/null; then
      idx=$((choice-1))
    fi
    printf -v "$varname" '%s' "${STORAGES[$idx]}"
    msg_ok "${label}: ${STORAGES[$idx]}"
  fi
}

select_storage_ct() {
  echo ""
  echo -e " ${DIM}Storage fuer die CT-Rootdisk:${CL}"
  _pick_storage "CT-Rootdisk Storage" STORAGE_CT "rootdir"
}

select_storage_tmpl() {
  echo ""
  # Pruefen ob dedizierter Template-Storage existiert
  local -a TMPL_STORAGES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && TMPL_STORAGES+=("$line")
  done < <(_get_storages_with_content "vztmpl")

  if [[ ${#TMPL_STORAGES[@]} -eq 0 ]]; then
    msg_warn "Kein Storage mit 'vztmpl' gefunden - nutze CT-Storage auch fuer Templates."
    STORAGE_TMPL="$STORAGE_CT"
  elif [[ ${#TMPL_STORAGES[@]} -eq 1 ]]; then
    STORAGE_TMPL="${TMPL_STORAGES[0]}"
    msg_ok "Template-Storage: ${STORAGE_TMPL}"
  else
    echo -e " ${DIM}Storage fuer Debian-Template (Download):${CL}"
    _pick_storage "Template-Storage" STORAGE_TMPL "vztmpl"
  fi
}

# --- Netzwerk-Konfiguration ---------------------------------------------------
configure_network() {
  echo ""
  echo -e " ${BOLD}Netzwerk-Konfiguration:${CL}"
  echo ""
  echo -e "  ${BOLD}1)${CL} DHCP (automatisch)"
  echo -e "  ${BOLD}2)${CL} Statische IP"
  echo ""
  echo -ne " Auswahl [1/2, Enter = 1]: "
  read -r net_choice
  net_choice="${net_choice:-1}"
  if [[ "$net_choice" == "2" ]]; then
    prompt "IP-Adresse (z.B. 192.168.1.100/24)" IP ""
    prompt "Gateway   (z.B. 192.168.1.1)" GW ""
    prompt "DNS-Server" DNS "8.8.8.8"
    msg_ok "Statische IP: ${IP} via ${GW}"
  else
    IP="dhcp"; GW=""; DNS="8.8.8.8"
    msg_ok "Netzwerk: DHCP"
  fi
}

# --- Template ermitteln und herunterladen -------------------------------------
fetch_template() {
  msg_info "Suche Debian ${DEBIAN_VERSION} LXC-Template"

  # Bereits lokal vorhanden?
  local existing
  existing=$(pveam list "$STORAGE_TMPL" 2>/dev/null \
    | awk '{print $1}' \
    | grep "debian-${DEBIAN_VERSION}" \
    | grep "standard" \
    | sort -V | tail -1 || true)

  if [[ -n "$existing" ]]; then
    TMPL_FILE="${existing}"
    msg_ok "Template vorhanden: $(basename "${TMPL_FILE}")"
    return
  fi

  # Katalog aktualisieren und herunterladen
  msg_info "Aktualisiere Template-Katalog"
  pveam update >/dev/null 2>&1 || true

  local tmpl_name
  tmpl_name=$(pveam available --section system 2>/dev/null \
    | awk '{print $2}' \
    | grep "debian-${DEBIAN_VERSION}" \
    | grep "standard" \
    | sort -V | tail -1 || true)

  if [[ -z "$tmpl_name" ]]; then
    msg_error "Kein Debian ${DEBIAN_VERSION} Standard-Template im Proxmox-Katalog gefunden!"
  fi

  msg_info "Lade Template: ${tmpl_name}"
  pveam download "$STORAGE_TMPL" "$tmpl_name" >/dev/null 2>&1 \
    || msg_error "Template-Download fehlgeschlagen!"

  TMPL_FILE="${STORAGE_TMPL}:vztmpl/${tmpl_name}"
  msg_ok "Template geladen: ${tmpl_name}"
}

# --- Modus: Installation ------------------------------------------------------
mode_install() {
  echo ""
  divider
  echo -e " ${BOLD}${GN}TACTICAL RMM - LXC CONTAINER ERSTELLEN${CL}"
  divider
  echo -e " ${DIM}Erstellt einen Debian LXC Container und bereitet Tactical RMM vor.${CL}"
  echo -e " ${WARN} Tactical RMM benoetigt 3 DNS A-Records (rmm/api/mesh) auf deine Domain!"
  echo ""

  # OS
  select_os_version

  # CT-ID
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
  prompt "CT-ID" CTID "$next_id"

  # Hostname
  prompt "Hostname" CT_HOSTNAME "tacticalrmm"

  # CPU
  prompt "CPU-Kerne" CORES "2"

  # RAM
  prompt "RAM in MB" RAM "4096"
  if [[ "$RAM" -lt 4096 ]] 2>/dev/null; then
    msg_warn "Mindestens 4096 MB empfohlen - TRMM kann sonst instabil werden."
    echo -ne " Trotzdem fortfahren? [j/N]: "
    read -r c; c="${c:-N}"
    [[ "${c,,}" != "j" ]] && msg_error "Abgebrochen."
  fi

  # Swap
  prompt "Swap in MB" SWAP "512"

  # Disk
  prompt "Disk in GB" DISK "50"

  # Bridge
  prompt "Netzwerk-Bridge" BRIDGE "vmbr0"

  # VLAN
  echo -ne " ${YW}VLAN-Tag${CL} (leer = keiner): "
  read -r VLAN; VLAN="${VLAN:-}"

  # Netzwerk
  configure_network

  # Privilegiert / Unprivilegiert
  echo ""
  echo -ne " ${YW}Unprivilegierten Container?${CL} (empfohlen) [J/n]: "
  read -r _unpriv; _unpriv="${_unpriv:-J}"
  [[ "${_unpriv,,}" == "n" ]] && UNPRIVILEGED="0" || UNPRIVILEGED="1"

  # Storage Rootdisk
  select_storage_ct

  # Storage Template
  select_storage_tmpl

  # Autostart
  echo -ne " ${YW}Container nach Erstellung starten?${CL} [J/n]: "
  read -r _start; _start="${_start:-J}"
  [[ "${_start,,}" == "n" ]] && START_CT="no" || START_CT="yes"

  # Zusammenfassung
  echo ""
  divider
  echo -e " ${BOLD}Zusammenfassung${CL}"
  divider
  printf "  %-20s ${BOLD}%s${CL}\n"    "CT-ID:"          "$CTID"
  printf "  %-20s ${BOLD}%s${CL}\n"    "OS:"             "Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Hostname:"       "$CT_HOSTNAME"
  printf "  %-20s ${BOLD}%s${CL}\n"    "CPU-Kerne:"      "$CORES"
  printf "  %-20s ${BOLD}%s MB${CL}\n" "RAM:"            "$RAM"
  printf "  %-20s ${BOLD}%s MB${CL}\n" "Swap:"           "$SWAP"
  printf "  %-20s ${BOLD}%s GB${CL}\n" "Disk:"           "$DISK"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Bridge:"         "$BRIDGE"
  [[ -n "$VLAN" ]] && printf "  %-20s ${BOLD}%s${CL}\n" "VLAN:" "$VLAN"
  printf "  %-20s ${BOLD}%s${CL}\n"    "IP:"             "$IP"
  [[ -n "$GW" ]]   && printf "  %-20s ${BOLD}%s${CL}\n" "Gateway:" "$GW"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Unprivilegiert:" "$([[ "$UNPRIVILEGED" == "1" ]] && echo "ja" || echo "nein")"
  printf "  %-20s ${BOLD}%s${CL}\n"    "CT-Storage:"     "$STORAGE_CT"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Tmpl-Storage:"   "$STORAGE_TMPL"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Autostart:"      "$START_CT"
  echo ""
  echo -ne " Jetzt erstellen? [J/n]: "
  read -r confirm; confirm="${confirm:-J}"
  [[ "${confirm,,}" == "n" ]] && msg_error "Abgebrochen."

  _do_create
}

# --- Container erstellen und konfigurieren ------------------------------------
_do_create() {
  fetch_template

  ROOT_PASS=$(tr -dc 'A-Za-z0-9@#%^' </dev/urandom | head -c 20)

  # net0-Argument zusammenbauen
  local net0_arg="name=eth0,bridge=${BRIDGE}"
  [[ -n "$VLAN" ]] && net0_arg="${net0_arg},tag=${VLAN}"
  if [[ "$IP" == "dhcp" ]]; then
    net0_arg="${net0_arg},ip=dhcp"
  else
    net0_arg="${net0_arg},ip=${IP}"
    [[ -n "$GW" ]] && net0_arg="${net0_arg},gw=${GW}"
  fi

  # Container anlegen
  msg_info "Erstelle LXC Container ${CTID}"
  pct create "$CTID" "$TMPL_FILE" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap "$SWAP" \
    --rootfs "${STORAGE_CT}:${DISK}" \
    --net0 "$net0_arg" \
    --nameserver "$DNS" \
    --unprivileged "$UNPRIVILEGED" \
    --features nesting=1 \
    --ostype debian \
    --password "$ROOT_PASS" \
    --onboot 1 \
    --start 0
  msg_ok "Container ${CTID} angelegt"

  # Starten fuer Erstkonfiguration
  msg_info "Starte Container fuer Erstkonfiguration"
  pct start "$CTID"

  # Warten bis Container bereit ist
  local retries=0
  while ! pct exec "$CTID" -- true 2>/dev/null; do
    sleep 2
    ((retries++))
    [[ $retries -gt 15 ]] && msg_error "Container antwortet nicht nach 30 Sekunden!"
  done
  msg_ok "Container gestartet"

  # System-Pakete installieren
  msg_info "Installiere System-Pakete"
  pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null
    apt-get install -yq \
      curl wget sudo ufw git htop ncdu \
      openssh-server 2>/dev/null
    systemctl enable ssh 2>/dev/null
  " || msg_error "Paket-Installation fehlgeschlagen!"
  msg_ok "System-Pakete installiert"

  # Firewall konfigurieren
  msg_info "Konfiguriere UFW-Firewall"
  pct exec "$CTID" -- bash -c "
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow https
    ufw --force enable
  " >/dev/null 2>&1
  msg_ok "Firewall konfiguriert"

  # tactical-User anlegen
  msg_info "Lege tactical-User an"
  pct exec "$CTID" -- bash -c "
    useradd -m -G sudo -s /bin/bash tactical 2>/dev/null || true
    echo 'tactical ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tactical
    chmod 0440 /etc/sudoers.d/tactical
  "
  msg_ok "User 'tactical' angelegt"

  # TRMM-Installationsscript herunterladen
  msg_info "Lade Tactical RMM Installationsscript"
  pct exec "$CTID" -- bash -c "
    curl -fsSL https://raw.githubusercontent.com/amidaware/tacticalrmm/master/install.sh \
      -o /home/tactical/install.sh
    chown tactical:tactical /home/tactical/install.sh
    chmod +x /home/tactical/install.sh
  " || msg_warn "TRMM-Script konnte nicht geladen werden (manuell nachholen)."
  msg_ok "TRMM-Installationsscript bereit"

  # Hilfstools installieren
  msg_info "Installiere Hilfstools (trmm-update, trmm-backup)"
  pct exec "$CTID" -- bash -c "
    curl -fsSL ${GITHUB_RAW}/scripts/trmm-update.sh -o /usr/local/bin/trmm-update
    curl -fsSL ${GITHUB_RAW}/scripts/trmm-backup.sh -o /usr/local/bin/trmm-backup
    chmod +x /usr/local/bin/trmm-update /usr/local/bin/trmm-backup
    mkdir -p /opt/trmm-backups
    echo '0 2 * * * tactical /usr/local/bin/trmm-backup --auto >> /var/log/trmm-backup.log 2>&1' >> /etc/crontab
  " || msg_warn "Hilfstools konnten nicht installiert werden."
  msg_ok "Hilfstools installiert"

  # MOTD schreiben: Datei lokal erzeugen, dann per pct push in Container kopieren
  # Kein Heredoc hier - wuerde von der aeusseren bash-Instanz gelesen werden!
  msg_info "Setze MOTD"
  local motd_file="${TEMP_DIR}/motd"
  {
    echo ""
    echo "  +--------------------------------------------------------------+"
    echo "  |        TACTICAL RMM - Bereit zur Installation                |"
    echo "  +--------------------------------------------------------------+"
    echo "  |  Schritt 1: DNS A-Records erstellen (alle -> CT-IP)         |"
    echo "  |    rmm.deine-domain.de                                       |"
    echo "  |    api.deine-domain.de                                       |"
    echo "  |    mesh.deine-domain.de                                      |"
    echo "  |                                                              |"
    echo "  |  Schritt 2: Als tactical-User einloggen:                     |"
    echo "  |    su - tactical                                             |"
    echo "  |    ./install.sh                                              |"
    echo "  |                                                              |"
    echo "  |  Nach der Installation:                                      |"
    echo "  |    trmm-update   Tactical RMM aktualisieren                  |"
    echo "  |    trmm-backup   Manuelles Backup erstellen                  |"
    echo "  |                                                              |"
    echo "  |  Doku: https://docs.tacticalrmm.com/install_server/          |"
    echo "  +--------------------------------------------------------------+"
    echo ""
  } > "$motd_file"
  pct push "$CTID" "$motd_file" /etc/motd
  msg_ok "MOTD gesetzt"

  # Container ggf. stoppen
  if [[ "$START_CT" != "yes" ]]; then
    msg_info "Stoppe Container"
    pct stop "$CTID"
    msg_ok "Container gestoppt"
  fi

  # IP ermitteln
  local CT_IP=""
  CT_IP=$(pct exec "$CTID" -- bash -c \
    "ip -4 addr show eth0 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1 | head -1" \
    2>/dev/null || true)

  # Abschluss-Ausgabe
  echo ""
  divider
  echo -e " ${GN}${BOLD}Container erfolgreich erstellt!${CL}"
  divider
  echo ""
  printf "  %-20s ${BOLD}%s${CL}\n" "CT-ID:"       "$CTID"
  printf "  %-20s ${BOLD}%s${CL}\n" "OS:"          "Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
  printf "  %-20s ${BOLD}%s${CL}\n" "IP-Adresse:"  "${CT_IP:-siehe Proxmox GUI}"
  printf "  %-20s ${BOLD}%s${CL}\n" "SSH-User:"    "tactical"
  printf "  %-20s ${BOLD}${RD}%s${CL}  ${YW}<-- JETZT NOTIEREN!${CL}\n" "Root-Passwort:" "$ROOT_PASS"
  echo ""
  echo -e " ${YW}Naechste Schritte:${CL}"
  echo -e "  1. DNS A-Records: ${BL}rmm / api / mesh${CL} -> ${CT_IP:-CT-IP}"
  echo -e "  2. SSH:           ${BL}ssh tactical@${CT_IP:-<CT-IP>}${CL}"
  echo -e "  3. Installation:  ${BL}./install.sh${CL}"
  echo ""
  echo -e " ${DIM}Installierte Hilfstools:${CL}"
  echo -e "  ${BL}trmm-update${CL}  - Tactical RMM aktualisieren"
  echo -e "  ${BL}trmm-backup${CL}  - Manuelles Backup (Cron taeglich 02:00)"
  echo ""
  divider
  echo ""
}

# --- Modus: Update ------------------------------------------------------------
mode_update() {
  echo ""
  divider
  echo -e " ${BOLD}${BL}TACTICAL RMM AKTUALISIEREN${CL}"
  divider

  # TRMM-Container suchen
  local -a TRMM_CTS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && TRMM_CTS+=("$line")
  done < <(pct list 2>/dev/null | awk 'NR>1 {print $1, $3}' | grep -i "tactical\|trmm" || true)

  if [[ ${#TRMM_CTS[@]} -eq 0 ]]; then
    msg_warn "Kein Container mit 'tactical' oder 'trmm' im Namen gefunden."
    echo -e " Alle Container:"
    pct list 2>/dev/null | awk 'NR>1 {printf "  %-6s %-20s %s\n", $1, $3, $2}'
  else
    echo -e " ${GN}Gefundene TRMM-Container:${CL}"
    for ct in "${TRMM_CTS[@]}"; do echo "  $ct"; done
  fi
  echo ""

  prompt "CT-ID des TRMM-Containers" TARGET_CTID ""
  [[ -z "$TARGET_CTID" ]] && msg_error "Keine CT-ID eingegeben."

  local ct_status
  ct_status=$(pct status "$TARGET_CTID" 2>/dev/null | awk '{print $2}' || echo "unknown")
  if [[ "$ct_status" != "running" ]]; then
    msg_warn "Container ${TARGET_CTID} laeuft nicht (Status: ${ct_status})"
    echo -ne " Container jetzt starten? [J/n]: "
    read -r s; s="${s:-J}"
    if [[ "${s,,}" != "n" ]]; then
      msg_info "Starte Container ${TARGET_CTID}"
      pct start "$TARGET_CTID"
      sleep 5
      msg_ok "Container gestartet"
    else
      msg_error "Abgebrochen."
    fi
  fi

  echo ""
  echo -e " ${INFO} Fuehre Update im Container ${TARGET_CTID} aus..."
  echo ""

  pct exec "$TARGET_CTID" -- bash -c \
    "curl -fsSL ${GITHUB_RAW}/scripts/trmm-update.sh | bash" \
    || msg_error "Update fehlgeschlagen!"

  echo ""
  msg_ok "Update abgeschlossen!"
  divider
  echo ""
}

# --- Modus: Backup ------------------------------------------------------------
mode_backup() {
  echo ""
  divider
  echo -e " ${BOLD}${YW}BACKUP ERSTELLEN${CL}"
  divider
  echo -e " ${DIM}Erstellt einen Proxmox-CT-Snapshot und ein TRMM-App-Backup.${CL}"
  echo ""

  echo -e " Alle Container:"
  pct list 2>/dev/null | awk 'NR>1 {printf "  %-6s %-20s %s\n", $1, $3, $2}'
  echo ""

  prompt "CT-ID des TRMM-Containers" TARGET_CTID ""
  [[ -z "$TARGET_CTID" ]] && msg_error "Keine CT-ID eingegeben."

  local ts; ts=$(date +%Y%m%d_%H%M%S)
  local snap_name="trmm-bkp-${ts}"

  echo ""
  echo -e " ${INFO} Snapshot-Name: ${BOLD}${snap_name}${CL}"
  echo ""
  echo -ne " Backup jetzt starten? [J/n]: "
  read -r confirm; confirm="${confirm:-J}"
  [[ "${confirm,,}" == "n" ]] && msg_error "Abgebrochen."

  # Proxmox CT-Snapshot
  msg_info "Erstelle Proxmox CT-Snapshot"
  if pct snapshot "$TARGET_CTID" "$snap_name" \
      --description "Tactical RMM Backup ${ts}" 2>/dev/null; then
    msg_ok "Snapshot erstellt: ${snap_name}"
  else
    msg_warn "Snapshot fehlgeschlagen (Storage unterstuetzt kein Snapshots?). Weiter mit App-Backup."
  fi

  # App-Backup im Container
  local ct_status
  ct_status=$(pct status "$TARGET_CTID" 2>/dev/null | awk '{print $2}' || echo "unknown")
  if [[ "$ct_status" == "running" ]]; then
    msg_info "Starte App-Backup im Container"
    pct exec "$TARGET_CTID" -- bash -c \
      "command -v trmm-backup >/dev/null && trmm-backup --auto || echo 'trmm-backup nicht gefunden'" \
      2>/dev/null && msg_ok "App-Backup abgeschlossen" \
      || msg_warn "App-Backup fehlgeschlagen."
  else
    msg_warn "Container laeuft nicht - App-Backup uebersprungen."
  fi

  # Snapshots anzeigen
  echo ""
  echo -e " ${GN}Vorhandene Snapshots fuer CT ${TARGET_CTID}:${CL}"
  pct listsnapshot "$TARGET_CTID" 2>/dev/null | grep -v "^->" || echo "  (keine)"
  echo ""
  divider
  echo -e " ${CM} Backup abgeschlossen!"
  echo ""
}

# --- Hauptmenu ----------------------------------------------------------------
select_mode() {
  echo ""
  divider
  echo -e " ${BOLD}Was moechtest du tun?${CL}"
  divider
  echo ""
  echo -e "  ${BOLD}1)${CL} ${GN}Neuen LXC Container erstellen${CL}  - Debian 12/13 + TRMM-Vorbereitung"
  echo -e "  ${BOLD}2)${CL} ${BL}Tactical RMM aktualisieren${CL}     - Update auf bestehendem Container"
  echo -e "  ${BOLD}3)${CL} ${YW}Backup erstellen${CL}               - Snapshot + App-Backup"
  echo -e "  ${BOLD}4)${CL} ${DIM}Beenden${CL}"
  echo ""
  echo -ne " Auswahl [1-4]: "
  read -r MODE; MODE="${MODE:-}"
  case "$MODE" in
    1) mode_install ;;
    2) mode_update ;;
    3) mode_backup ;;
    4) echo -e "\n Auf Wiedersehen!\n"; exit 0 ;;
    *) msg_warn "Ungueltige Auswahl."; select_mode ;;
  esac
}

# --- Hauptprogramm ------------------------------------------------------------
header_info
check_proxmox
select_mode#!/usr/bin/env bash
# =============================================================================
#  Proxmox LXC Installer fuer Tactical RMM  (Community Script)
#  https://github.com/DEIN-GITHUB-USER/tacticalrmm-proxmox
#
#  Aufruf auf dem Proxmox-Host als root:
#    wget -qO /tmp/trmm-install.sh https://raw.githubusercontent.com/DEIN-GITHUB-USER/tacticalrmm-proxmox/main/tacticalrmm.sh && bash /tmp/trmm-install.sh
#
#  DISCLAIMER: Dieses Script ist ein unabhaengiges Community-Projekt und steht
#  in keiner Verbindung zu AmidaWare LLC. "Tactical RMM" ist eine eingetragene
#  Marke von AmidaWare LLC. Das Script laedt die offizielle Tactical RMM Software
#  herunter und installiert sie gemaess der oeffentlichen Installationsdokumentation
#  unter https://docs.tacticalrmm.com - ohne diese zu veraendern.
# =============================================================================

set -eo pipefail

# --- Farben -------------------------------------------------------------------
YW=$'\033[33m'
BL=$'\033[36m'
RD=$'\033[01;31m'
GN=$'\033[1;92m'
CL=$'\033[m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
BFR=$'\r\033[K'
HOLD=" "
CM="${GN}OK${CL}"
CROSS="${RD}FEHLER${CL}"
INFO="${BL}i${CL}"
WARN="${YW}!${CL}"

# --- GitHub-Basis-URL (DEIN-GITHUB-USER ersetzen!) ----------------------------
GITHUB_RAW="https://raw.githubusercontent.com/yodaeichen/tacticalrmm-proxmox/main"

# --- Globale Variablen --------------------------------------------------------
CTID=""
CT_HOSTNAME="tacticalrmm"
CORES="2"
RAM="4096"
SWAP="512"
DISK="50"
BRIDGE="vmbr0"
VLAN=""
IP="dhcp"
GW=""
DNS="8.8.8.8"
UNPRIVILEGED="1"
START_CT="yes"
STORAGE_CT=""
STORAGE_TMPL=""
DEBIAN_VERSION=""
DEBIAN_CODENAME=""
TMPL_FILE=""
ROOT_PASS=""

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# --- Hilfsfunktionen ----------------------------------------------------------
msg_info()  { local msg="$1"; echo -ne " ${HOLD} ${YW}${msg}...${CL}"; }
msg_ok()    { local msg="$1"; echo -e "${BFR} ${CM} ${GN}${msg}${CL}"; }
msg_error() { local msg="$1"; echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"; exit 1; }
msg_warn()  { local msg="$1"; echo -e " ${WARN} ${YW}${msg}${CL}"; }
divider()   { echo -e "${DIM}$(printf -- '-%.0s' {1..62})${CL}"; }

prompt() {
  local display="$1" varname="$2" default="${3:-}"
  if [[ -n "$default" ]]; then
    echo -ne " ${YW}${display}${CL} [${default}]: "
  else
    echo -ne " ${YW}${display}${CL}: "
  fi
  local input
  read -r input
  printf -v "$varname" '%s' "${input:-$default}"
}

header_info() {
  clear
  echo -e "${BL}"
  cat <<"BANNER"
  ████████╗██████╗ ███╗   ███╗███╗   ███╗
     ██╔══╝██╔══██╗████╗ ████║████╗ ████║
     ██║   ██████╔╝██╔████╔██║██╔████╔██║
     ██║   ██╔══██╗██║╚██╔╝██║██║╚██╔╝██║
     ██║   ██║  ██║██║ ╚═╝ ██║██║ ╚═╝ ██║
     ╚═╝   ╚═╝  ╚═╝╚═╝     ╚═╝╚═╝     ╚═╝
BANNER
  echo -e "${CL}"
  echo -e "  ${BOLD}Proxmox LXC Installer fuer Tactical RMM${CL}"
  echo -e "  ${DIM}Community Script - kein offizielles AmidaWare-Projekt${CL}"
  echo ""
}

# --- Proxmox pruefen ----------------------------------------------------------
check_proxmox() {
  msg_info "Pruefe Proxmox-Umgebung"
  if ! command -v pct &>/dev/null; then
    msg_error "Muss auf einem Proxmox VE Host ausgefuehrt werden!"
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "Bitte als root ausfuehren!"
  fi
  local pve_raw
  pve_raw=$(pveversion 2>/dev/null | head -1 || true)
  local PVE_VERSION="" PVE_MAJOR=0
  if [[ "$pve_raw" =~ pve-manager/([0-9]+)\.([0-9]+) ]]; then
    PVE_MAJOR="${BASH_REMATCH[1]}"
    PVE_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  fi
  if [[ -z "$PVE_VERSION" ]]; then
    msg_warn "Proxmox-Version nicht ermittelbar - fahre fort."
  elif [[ "$PVE_MAJOR" -lt 7 ]]; then
    msg_error "Proxmox VE 7.0+ erforderlich (erkannt: $PVE_VERSION)"
  else
    msg_ok "Proxmox VE $PVE_VERSION"
  fi
}

# --- OS-Auswahl ---------------------------------------------------------------
select_os_version() {
  echo ""
  echo -e " ${BOLD}Betriebssystem waehlen:${CL}"
  echo ""
  echo -e "  ${BOLD}1)${CL} ${GN}Debian 12 (Bookworm)${CL}  ${GN}<-- Empfohlen${CL}"
  echo -e "     ${DIM}Offiziell unterstuetzt von Tactical RMM${CL}"
  echo ""
  echo -e "  ${BOLD}2)${CL} ${YW}Debian 13 (Trixie)${CL}   ${WARN} Experimentell${CL}"
  echo -e "     ${DIM}Noch nicht offiziell unterstuetzt - Python 3.13 / PostgreSQL 17${CL}"
  echo ""
  echo -ne " Auswahl [1/2, Enter = 1]: "
  read -r os_choice
  os_choice="${os_choice:-1}"
  case "$os_choice" in
    2)
      DEBIAN_VERSION="13"
      DEBIAN_CODENAME="trixie"
      echo ""
      echo -ne " Wirklich Debian 13 verwenden? [j/N]: "
      read -r c13; c13="${c13:-N}"
      if [[ "${c13,,}" != "j" ]]; then
        msg_warn "Zurueck zur OS-Auswahl."
        select_os_version; return
      fi
      msg_ok "OS: Debian 13 Trixie (experimentell)"
      ;;
    *)
      DEBIAN_VERSION="12"
      DEBIAN_CODENAME="bookworm"
      msg_ok "OS: Debian 12 Bookworm (empfohlen)"
      ;;
  esac
}

# --- Storage-Hilfsfunktionen --------------------------------------------------
_get_all_storages() {
  pvesm status 2>/dev/null | awk 'NR>1 {print $1}' || true
}

_get_storages_with_content() {
  local content_type="$1"
  local stor
  while IFS= read -r stor; do
    if pvesm status --storage "$stor" 2>/dev/null | grep -q "$content_type"; then
      echo "$stor"
    fi
  done < <(_get_all_storages)
}

_pick_storage() {
  local label="$1" varname="$2" content_filter="${3:-}"
  local -a STORAGES=()

  if [[ -n "$content_filter" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && STORAGES+=("$line")
    done < <(_get_storages_with_content "$content_filter")
  fi

  # Fallback: alle Storages
  if [[ ${#STORAGES[@]} -eq 0 ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && STORAGES+=("$line")
    done < <(_get_all_storages)
  fi

  if [[ ${#STORAGES[@]} -eq 0 ]]; then
    msg_error "Kein Storage gefunden! Proxmox-Storage-Konfiguration pruefen."
  elif [[ ${#STORAGES[@]} -eq 1 ]]; then
    printf -v "$varname" '%s' "${STORAGES[0]}"
    msg_ok "${label}: ${STORAGES[0]}"
  else
    echo ""
    echo -e " ${YW}${label} - Storage waehlen:${CL}"
    local i=1
    for s in "${STORAGES[@]}"; do
      local stype
      stype=$(pvesm status --storage "$s" 2>/dev/null | awk 'NR>1 {print $2}' || echo "")
      echo -e "  ${BOLD}${i})${CL} ${s} ${DIM}(${stype})${CL}"
      ((i++))
    done
    echo ""
    echo -ne " Auswahl [1-${#STORAGES[@]}]: "
    local choice
    read -r choice
    choice="${choice:-1}"
    local idx=0
    if [[ "$choice" -ge 1 && "$choice" -le ${#STORAGES[@]} ]] 2>/dev/null; then
      idx=$((choice-1))
    fi
    printf -v "$varname" '%s' "${STORAGES[$idx]}"
    msg_ok "${label}: ${STORAGES[$idx]}"
  fi
}

select_storage_ct() {
  echo ""
  echo -e " ${DIM}Storage fuer die CT-Rootdisk:${CL}"
  _pick_storage "CT-Rootdisk Storage" STORAGE_CT "rootdir"
}

select_storage_tmpl() {
  echo ""
  # Pruefen ob dedizierter Template-Storage existiert
  local -a TMPL_STORAGES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && TMPL_STORAGES+=("$line")
  done < <(_get_storages_with_content "vztmpl")

  if [[ ${#TMPL_STORAGES[@]} -eq 0 ]]; then
    msg_warn "Kein Storage mit 'vztmpl' gefunden - nutze CT-Storage auch fuer Templates."
    STORAGE_TMPL="$STORAGE_CT"
  elif [[ ${#TMPL_STORAGES[@]} -eq 1 ]]; then
    STORAGE_TMPL="${TMPL_STORAGES[0]}"
    msg_ok "Template-Storage: ${STORAGE_TMPL}"
  else
    echo -e " ${DIM}Storage fuer Debian-Template (Download):${CL}"
    _pick_storage "Template-Storage" STORAGE_TMPL "vztmpl"
  fi
}

# --- Netzwerk-Konfiguration ---------------------------------------------------
configure_network() {
  echo ""
  echo -e " ${BOLD}Netzwerk-Konfiguration:${CL}"
  echo ""
  echo -e "  ${BOLD}1)${CL} DHCP (automatisch)"
  echo -e "  ${BOLD}2)${CL} Statische IP"
  echo ""
  echo -ne " Auswahl [1/2, Enter = 1]: "
  read -r net_choice
  net_choice="${net_choice:-1}"
  if [[ "$net_choice" == "2" ]]; then
    prompt "IP-Adresse (z.B. 192.168.1.100/24)" IP ""
    prompt "Gateway   (z.B. 192.168.1.1)" GW ""
    prompt "DNS-Server" DNS "8.8.8.8"
    msg_ok "Statische IP: ${IP} via ${GW}"
  else
    IP="dhcp"; GW=""; DNS="8.8.8.8"
    msg_ok "Netzwerk: DHCP"
  fi
}

# --- Template ermitteln und herunterladen -------------------------------------
fetch_template() {
  msg_info "Suche Debian ${DEBIAN_VERSION} LXC-Template"

  # Bereits lokal vorhanden?
  local existing
  existing=$(pveam list "$STORAGE_TMPL" 2>/dev/null \
    | awk '{print $1}' \
    | grep "debian-${DEBIAN_VERSION}" \
    | grep "standard" \
    | sort -V | tail -1 || true)

  if [[ -n "$existing" ]]; then
    TMPL_FILE="${existing}"
    msg_ok "Template vorhanden: $(basename "${TMPL_FILE}")"
    return
  fi

  # Katalog aktualisieren und herunterladen
  msg_info "Aktualisiere Template-Katalog"
  pveam update >/dev/null 2>&1 || true

  local tmpl_name
  tmpl_name=$(pveam available --section system 2>/dev/null \
    | awk '{print $2}' \
    | grep "debian-${DEBIAN_VERSION}" \
    | grep "standard" \
    | sort -V | tail -1 || true)

  if [[ -z "$tmpl_name" ]]; then
    msg_error "Kein Debian ${DEBIAN_VERSION} Standard-Template im Proxmox-Katalog gefunden!"
  fi

  msg_info "Lade Template: ${tmpl_name}"
  pveam download "$STORAGE_TMPL" "$tmpl_name" >/dev/null 2>&1 \
    || msg_error "Template-Download fehlgeschlagen!"

  TMPL_FILE="${STORAGE_TMPL}:vztmpl/${tmpl_name}"
  msg_ok "Template geladen: ${tmpl_name}"
}

# --- Modus: Installation ------------------------------------------------------
mode_install() {
  echo ""
  divider
  echo -e " ${BOLD}${GN}TACTICAL RMM - LXC CONTAINER ERSTELLEN${CL}"
  divider
  echo -e " ${DIM}Erstellt einen Debian LXC Container und bereitet Tactical RMM vor.${CL}"
  echo -e " ${WARN} Tactical RMM benoetigt 3 DNS A-Records (rmm/api/mesh) auf deine Domain!"
  echo ""

  # OS
  select_os_version

  # CT-ID
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
  prompt "CT-ID" CTID "$next_id"

  # Hostname
  prompt "Hostname" CT_HOSTNAME "tacticalrmm"

  # CPU
  prompt "CPU-Kerne" CORES "2"

  # RAM
  prompt "RAM in MB" RAM "4096"
  if [[ "$RAM" -lt 4096 ]] 2>/dev/null; then
    msg_warn "Mindestens 4096 MB empfohlen - TRMM kann sonst instabil werden."
    echo -ne " Trotzdem fortfahren? [j/N]: "
    read -r c; c="${c:-N}"
    [[ "${c,,}" != "j" ]] && msg_error "Abgebrochen."
  fi

  # Swap
  prompt "Swap in MB" SWAP "512"

  # Disk
  prompt "Disk in GB" DISK "50"

  # Bridge
  prompt "Netzwerk-Bridge" BRIDGE "vmbr0"

  # VLAN
  echo -ne " ${YW}VLAN-Tag${CL} (leer = keiner): "
  read -r VLAN; VLAN="${VLAN:-}"

  # Netzwerk
  configure_network

  # Privilegiert / Unprivilegiert
  echo ""
  echo -ne " ${YW}Unprivilegierten Container?${CL} (empfohlen) [J/n]: "
  read -r _unpriv; _unpriv="${_unpriv:-J}"
  [[ "${_unpriv,,}" == "n" ]] && UNPRIVILEGED="0" || UNPRIVILEGED="1"

  # Storage Rootdisk
  select_storage_ct

  # Storage Template
  select_storage_tmpl

  # Autostart
  echo -ne " ${YW}Container nach Erstellung starten?${CL} [J/n]: "
  read -r _start; _start="${_start:-J}"
  [[ "${_start,,}" == "n" ]] && START_CT="no" || START_CT="yes"

  # Zusammenfassung
  echo ""
  divider
  echo -e " ${BOLD}Zusammenfassung${CL}"
  divider
  printf "  %-20s ${BOLD}%s${CL}\n"    "CT-ID:"          "$CTID"
  printf "  %-20s ${BOLD}%s${CL}\n"    "OS:"             "Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Hostname:"       "$CT_HOSTNAME"
  printf "  %-20s ${BOLD}%s${CL}\n"    "CPU-Kerne:"      "$CORES"
  printf "  %-20s ${BOLD}%s MB${CL}\n" "RAM:"            "$RAM"
  printf "  %-20s ${BOLD}%s MB${CL}\n" "Swap:"           "$SWAP"
  printf "  %-20s ${BOLD}%s GB${CL}\n" "Disk:"           "$DISK"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Bridge:"         "$BRIDGE"
  [[ -n "$VLAN" ]] && printf "  %-20s ${BOLD}%s${CL}\n" "VLAN:" "$VLAN"
  printf "  %-20s ${BOLD}%s${CL}\n"    "IP:"             "$IP"
  [[ -n "$GW" ]]   && printf "  %-20s ${BOLD}%s${CL}\n" "Gateway:" "$GW"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Unprivilegiert:" "$([[ "$UNPRIVILEGED" == "1" ]] && echo "ja" || echo "nein")"
  printf "  %-20s ${BOLD}%s${CL}\n"    "CT-Storage:"     "$STORAGE_CT"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Tmpl-Storage:"   "$STORAGE_TMPL"
  printf "  %-20s ${BOLD}%s${CL}\n"    "Autostart:"      "$START_CT"
  echo ""
  echo -ne " Jetzt erstellen? [J/n]: "
  read -r confirm; confirm="${confirm:-J}"
  [[ "${confirm,,}" == "n" ]] && msg_error "Abgebrochen."

  _do_create
}

# --- Container erstellen und konfigurieren ------------------------------------
_do_create() {
  fetch_template

  ROOT_PASS=$(tr -dc 'A-Za-z0-9@#%^' </dev/urandom | head -c 20)

  # net0-Argument zusammenbauen
  local net0_arg="name=eth0,bridge=${BRIDGE}"
  [[ -n "$VLAN" ]] && net0_arg="${net0_arg},tag=${VLAN}"
  if [[ "$IP" == "dhcp" ]]; then
    net0_arg="${net0_arg},ip=dhcp"
  else
    net0_arg="${net0_arg},ip=${IP}"
    [[ -n "$GW" ]] && net0_arg="${net0_arg},gw=${GW}"
  fi

  # Container anlegen
  msg_info "Erstelle LXC Container ${CTID}"
  pct create "$CTID" "$TMPL_FILE" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap "$SWAP" \
    --rootfs "${STORAGE_CT}:${DISK}" \
    --net0 "$net0_arg" \
    --nameserver "$DNS" \
    --unprivileged "$UNPRIVILEGED" \
    --features nesting=1 \
    --ostype debian \
    --password "$ROOT_PASS" \
    --onboot 1 \
    --start 0
  msg_ok "Container ${CTID} angelegt"

  # Starten fuer Erstkonfiguration
  msg_info "Starte Container fuer Erstkonfiguration"
  pct start "$CTID"

  # Warten bis Container bereit ist
  local retries=0
  while ! pct exec "$CTID" -- true 2>/dev/null; do
    sleep 2
    ((retries++))
    [[ $retries -gt 15 ]] && msg_error "Container antwortet nicht nach 30 Sekunden!"
  done
  msg_ok "Container gestartet"

  # System-Pakete installieren
  msg_info "Installiere System-Pakete"
  pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null
    apt-get install -yq \
      curl wget sudo ufw git htop ncdu \
      openssh-server 2>/dev/null
    systemctl enable ssh 2>/dev/null
  " || msg_error "Paket-Installation fehlgeschlagen!"
  msg_ok "System-Pakete installiert"

  # Firewall konfigurieren
  msg_info "Konfiguriere UFW-Firewall"
  pct exec "$CTID" -- bash -c "
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow https
    ufw --force enable
  " >/dev/null 2>&1
  msg_ok "Firewall konfiguriert"

  # tactical-User anlegen
  msg_info "Lege tactical-User an"
  pct exec "$CTID" -- bash -c "
    useradd -m -G sudo -s /bin/bash tactical 2>/dev/null || true
    echo 'tactical ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tactical
    chmod 0440 /etc/sudoers.d/tactical
  "
  msg_ok "User 'tactical' angelegt"

  # TRMM-Installationsscript herunterladen
  msg_info "Lade Tactical RMM Installationsscript"
  pct exec "$CTID" -- bash -c "
    curl -fsSL https://raw.githubusercontent.com/amidaware/tacticalrmm/master/install.sh \
      -o /home/tactical/install.sh
    chown tactical:tactical /home/tactical/install.sh
    chmod +x /home/tactical/install.sh
  " || msg_warn "TRMM-Script konnte nicht geladen werden (manuell nachholen)."
  msg_ok "TRMM-Installationsscript bereit"

  # Hilfstools installieren
  msg_info "Installiere Hilfstools (trmm-update, trmm-backup)"
  pct exec "$CTID" -- bash -c "
    curl -fsSL ${GITHUB_RAW}/scripts/trmm-update.sh -o /usr/local/bin/trmm-update
    curl -fsSL ${GITHUB_RAW}/scripts/trmm-backup.sh -o /usr/local/bin/trmm-backup
    chmod +x /usr/local/bin/trmm-update /usr/local/bin/trmm-backup
    mkdir -p /opt/trmm-backups
    echo '0 2 * * * tactical /usr/local/bin/trmm-backup --auto >> /var/log/trmm-backup.log 2>&1' >> /etc/crontab
  " || msg_warn "Hilfstools konnten nicht installiert werden."
  msg_ok "Hilfstools installiert"

  # MOTD schreiben
  msg_info "Setze MOTD"
  pct exec "$CTID" -- bash -c "cat > /etc/motd" << 'MOTD'

  +--------------------------------------------------------------+
  |        TACTICAL RMM - Bereit zur Installation                |
  +--------------------------------------------------------------+
  |  Schritt 1: DNS A-Records erstellen (alle -> CT-IP)         |
  |    rmm.deine-domain.de                                       |
  |    api.deine-domain.de                                       |
  |    mesh.deine-domain.de                                      |
  |                                                              |
  |  Schritt 2: Als tactical-User einloggen:                     |
  |    su - tactical                                             |
  |    ./install.sh                                              |
  |                                                              |
  |  Nach der Installation:                                      |
  |    trmm-update   Tactical RMM aktualisieren                  |
  |    trmm-backup   Manuelles Backup erstellen                  |
  |                                                              |
  |  Doku: https://docs.tacticalrmm.com/install_server/          |
  +--------------------------------------------------------------+

MOTD
  msg_ok "MOTD gesetzt"

  # Container ggf. stoppen
  if [[ "$START_CT" != "yes" ]]; then
    msg_info "Stoppe Container"
    pct stop "$CTID"
    msg_ok "Container gestoppt"
  fi

  # IP ermitteln
  local CT_IP=""
  CT_IP=$(pct exec "$CTID" -- bash -c \
    "ip -4 addr show eth0 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1 | head -1" \
    2>/dev/null || true)

  # Abschluss-Ausgabe
  echo ""
  divider
  echo -e " ${GN}${BOLD}Container erfolgreich erstellt!${CL}"
  divider
  echo ""
  printf "  %-20s ${BOLD}%s${CL}\n" "CT-ID:"       "$CTID"
  printf "  %-20s ${BOLD}%s${CL}\n" "OS:"          "Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
  printf "  %-20s ${BOLD}%s${CL}\n" "IP-Adresse:"  "${CT_IP:-siehe Proxmox GUI}"
  printf "  %-20s ${BOLD}%s${CL}\n" "SSH-User:"    "tactical"
  printf "  %-20s ${BOLD}${RD}%s${CL}  ${YW}<-- JETZT NOTIEREN!${CL}\n" "Root-Passwort:" "$ROOT_PASS"
  echo ""
  echo -e " ${YW}Naechste Schritte:${CL}"
  echo -e "  1. DNS A-Records: ${BL}rmm / api / mesh${CL} -> ${CT_IP:-CT-IP}"
  echo -e "  2. SSH:           ${BL}ssh tactical@${CT_IP:-<CT-IP>}${CL}"
  echo -e "  3. Installation:  ${BL}./install.sh${CL}"
  echo ""
  echo -e " ${DIM}Installierte Hilfstools:${CL}"
  echo -e "  ${BL}trmm-update${CL}  - Tactical RMM aktualisieren"
  echo -e "  ${BL}trmm-backup${CL}  - Manuelles Backup (Cron taeglich 02:00)"
  echo ""
  divider
  echo ""
}

# --- Modus: Update ------------------------------------------------------------
mode_update() {
  echo ""
  divider
  echo -e " ${BOLD}${BL}TACTICAL RMM AKTUALISIEREN${CL}"
  divider

  # TRMM-Container suchen
  local -a TRMM_CTS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && TRMM_CTS+=("$line")
  done < <(pct list 2>/dev/null | awk 'NR>1 {print $1, $3}' | grep -i "tactical\|trmm" || true)

  if [[ ${#TRMM_CTS[@]} -eq 0 ]]; then
    msg_warn "Kein Container mit 'tactical' oder 'trmm' im Namen gefunden."
    echo -e " Alle Container:"
    pct list 2>/dev/null | awk 'NR>1 {printf "  %-6s %-20s %s\n", $1, $3, $2}'
  else
    echo -e " ${GN}Gefundene TRMM-Container:${CL}"
    for ct in "${TRMM_CTS[@]}"; do echo "  $ct"; done
  fi
  echo ""

  prompt "CT-ID des TRMM-Containers" TARGET_CTID ""
  [[ -z "$TARGET_CTID" ]] && msg_error "Keine CT-ID eingegeben."

  local ct_status
  ct_status=$(pct status "$TARGET_CTID" 2>/dev/null | awk '{print $2}' || echo "unknown")
  if [[ "$ct_status" != "running" ]]; then
    msg_warn "Container ${TARGET_CTID} laeuft nicht (Status: ${ct_status})"
    echo -ne " Container jetzt starten? [J/n]: "
    read -r s; s="${s:-J}"
    if [[ "${s,,}" != "n" ]]; then
      msg_info "Starte Container ${TARGET_CTID}"
      pct start "$TARGET_CTID"
      sleep 5
      msg_ok "Container gestartet"
    else
      msg_error "Abgebrochen."
    fi
  fi

  echo ""
  echo -e " ${INFO} Fuehre Update im Container ${TARGET_CTID} aus..."
  echo ""

  pct exec "$TARGET_CTID" -- bash -c \
    "curl -fsSL ${GITHUB_RAW}/scripts/trmm-update.sh | bash" \
    || msg_error "Update fehlgeschlagen!"

  echo ""
  msg_ok "Update abgeschlossen!"
  divider
  echo ""
}

# --- Modus: Backup ------------------------------------------------------------
mode_backup() {
  echo ""
  divider
  echo -e " ${BOLD}${YW}BACKUP ERSTELLEN${CL}"
  divider
  echo -e " ${DIM}Erstellt einen Proxmox-CT-Snapshot und ein TRMM-App-Backup.${CL}"
  echo ""

  echo -e " Alle Container:"
  pct list 2>/dev/null | awk 'NR>1 {printf "  %-6s %-20s %s\n", $1, $3, $2}'
  echo ""

  prompt "CT-ID des TRMM-Containers" TARGET_CTID ""
  [[ -z "$TARGET_CTID" ]] && msg_error "Keine CT-ID eingegeben."

  local ts; ts=$(date +%Y%m%d_%H%M%S)
  local snap_name="trmm-bkp-${ts}"

  echo ""
  echo -e " ${INFO} Snapshot-Name: ${BOLD}${snap_name}${CL}"
  echo ""
  echo -ne " Backup jetzt starten? [J/n]: "
  read -r confirm; confirm="${confirm:-J}"
  [[ "${confirm,,}" == "n" ]] && msg_error "Abgebrochen."

  # Proxmox CT-Snapshot
  msg_info "Erstelle Proxmox CT-Snapshot"
  if pct snapshot "$TARGET_CTID" "$snap_name" \
      --description "Tactical RMM Backup ${ts}" 2>/dev/null; then
    msg_ok "Snapshot erstellt: ${snap_name}"
  else
    msg_warn "Snapshot fehlgeschlagen (Storage unterstuetzt kein Snapshots?). Weiter mit App-Backup."
  fi

  # App-Backup im Container
  local ct_status
  ct_status=$(pct status "$TARGET_CTID" 2>/dev/null | awk '{print $2}' || echo "unknown")
  if [[ "$ct_status" == "running" ]]; then
    msg_info "Starte App-Backup im Container"
    pct exec "$TARGET_CTID" -- bash -c \
      "command -v trmm-backup >/dev/null && trmm-backup --auto || echo 'trmm-backup nicht gefunden'" \
      2>/dev/null && msg_ok "App-Backup abgeschlossen" \
      || msg_warn "App-Backup fehlgeschlagen."
  else
    msg_warn "Container laeuft nicht - App-Backup uebersprungen."
  fi

  # Snapshots anzeigen
  echo ""
  echo -e " ${GN}Vorhandene Snapshots fuer CT ${TARGET_CTID}:${CL}"
  pct listsnapshot "$TARGET_CTID" 2>/dev/null | grep -v "^->" || echo "  (keine)"
  echo ""
  divider
  echo -e " ${CM} Backup abgeschlossen!"
  echo ""
}

# --- Hauptmenu ----------------------------------------------------------------
select_mode() {
  echo ""
  divider
  echo -e " ${BOLD}Was moechtest du tun?${CL}"
  divider
  echo ""
  echo -e "  ${BOLD}1)${CL} ${GN}Neuen LXC Container erstellen${CL}  - Debian 12/13 + TRMM-Vorbereitung"
  echo -e "  ${BOLD}2)${CL} ${BL}Tactical RMM aktualisieren${CL}     - Update auf bestehendem Container"
  echo -e "  ${BOLD}3)${CL} ${YW}Backup erstellen${CL}               - Snapshot + App-Backup"
  echo -e "  ${BOLD}4)${CL} ${DIM}Beenden${CL}"
  echo ""
  echo -ne " Auswahl [1-4]: "
  read -r MODE; MODE="${MODE:-}"
  case "$MODE" in
    1) mode_install ;;
    2) mode_update ;;
    3) mode_backup ;;
    4) echo -e "\n Auf Wiedersehen!\n"; exit 0 ;;
    *) msg_warn "Ungueltige Auswahl."; select_mode ;;
  esac
}

# --- Hauptprogramm ------------------------------------------------------------
header_info
check_proxmox
select_mode
