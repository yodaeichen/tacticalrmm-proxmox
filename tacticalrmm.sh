#!/usr/bin/env bash
# =============================================================================
#  Proxmox VM Installer für Tactical RMM  (Community Script)
#  https://github.com/DEIN-GITHUB-USER/tacticalrmm-proxmox
#
#  Aufruf auf dem Proxmox-Host als root:
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/DEIN-GITHUB-USER/tacticalrmm-proxmox/main/tacticalrmm.sh)"
#
#  DISCLAIMER: Dieses Script ist ein unabhängiges Community-Projekt und steht
#  in keiner Verbindung zu AmidaWare LLC. "Tactical RMM" ist eine eingetragene
#  Marke von AmidaWare LLC. Das Script lädt die offizielle Tactical RMM Software
#  herunter und installiert sie gemäß der öffentlichen Installationsdokumentation
#  unter https://docs.tacticalrmm.com – ohne diese zu verändern.
#
#  WICHTIG: Tactical RMM läuft NUR auf VMs (kein LXC)
#  Quelle: https://docs.tacticalrmm.com/unsupported_guidelines/
# =============================================================================

set -eo pipefail

# ─── Farben mit $'...' – funktioniert in read -p zuverlässig ─────────────────
YW=$'\033[33m'
BL=$'\033[36m'
RD=$'\033[01;31m'
GN=$'\033[1;92m'
CL=$'\033[m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
BFR=$'\r\033[K'
HOLD=" "
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${BL}ℹ${CL}"
WARN="${YW}⚠${CL}"

# ─── GitHub-Basis-URL (DEIN-GITHUB-USER ersetzen!) ────────────────────────────
GITHUB_RAW="https://raw.githubusercontent.com/DEIN-GITHUB-USER/tacticalrmm-proxmox/main"

# ─── Globale Variablen ────────────────────────────────────────────────────────
VMID=""
VM_HOSTNAME="tacticalrmm"
CORES="2"
RAM="4096"
DISK="50"
BRIDGE="vmbr0"
VLAN=""
START_VM="yes"
STORAGE_VM=""      # Storage für VM-Disk (muss images unterstützen)
STORAGE_SNIPPETS="" # Storage für Cloud-Init Snippets (optional)
TACTICAL_PASS=""
TARGET_VMID=""
SSH_USER="tactical"

# OS (wird durch select_os_version gesetzt)
DEBIAN_URL=""
DEBIAN_IMAGE=""
DEBIAN_VERSION=""
DEBIAN_CODENAME=""

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# ─── Hilfsfunktionen ──────────────────────────────────────────────────────────
msg_info()  { local msg="$1"; echo -ne " ${HOLD} ${YW}${msg}...${CL}"; }
msg_ok()    { local msg="$1"; echo -e "${BFR} ${CM} ${GN}${msg}${CL}"; }
msg_error() { local msg="$1"; echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"; exit 1; }
msg_warn()  { local msg="$1"; echo -e " ${WARN} ${YW}${msg}${CL}"; }
divider()   { echo -e "${DIM}$(printf '━%.0s' {1..62})${CL}"; }

# read-Wrapper: gibt farbigen Prompt aus, dann liest ohne Farb-Probleme
prompt() {
  # $1 = Anzeigetext (mit Farbe), $2 = Variablenname, $3 = Default
  local display="$1" varname="$2" default="${3:-}"
  if [[ -n "$default" ]]; then
    echo -ne " ${YW}${display}${CL} [${default}]: "
  else
    echo -ne " ${YW}${display}${CL}: "
  fi
  local input
  read -r input
  # Ergebnis in die gewünschte globale Variable schreiben
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
  echo -e "  ${BOLD}Proxmox VM Installer für Tactical RMM${CL}"
  echo -e "  ${DIM}Community Script – kein offizielles AmidaWare-Projekt${CL}"
  echo ""
}

# ─── Proxmox-Voraussetzungen prüfen ───────────────────────────────────────────
check_proxmox() {
  msg_info "Prüfe Proxmox-Umgebung"
  if ! command -v pvesh &>/dev/null; then
    msg_error "Muss auf einem Proxmox VE Host ausgeführt werden!"
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "Bitte als root ausführen!"
  fi

  local pve_raw
  pve_raw=$(pveversion 2>/dev/null | head -1 || true)
  local PVE_VERSION=""
  local PVE_MAJOR=0

  if [[ "$pve_raw" =~ pve-manager/([0-9]+)\.([0-9]+) ]]; then
    PVE_MAJOR="${BASH_REMATCH[1]}"
    PVE_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  else
    PVE_VERSION=$(echo "$pve_raw" | grep -oP '\d+\.\d+' | head -1 || true)
    PVE_MAJOR=$(echo "$PVE_VERSION" | cut -d'.' -f1 || echo "0")
  fi

  if [[ -z "$PVE_VERSION" ]]; then
    msg_warn "Proxmox-Version konnte nicht ermittelt werden – fahre fort."
  elif [[ "$PVE_MAJOR" -lt 7 ]]; then
    msg_error "Proxmox VE 7.0+ erforderlich (erkannt: $PVE_VERSION)"
  else
    msg_ok "Proxmox VE $PVE_VERSION"
  fi
}

# ─── Modus-Auswahl ────────────────────────────────────────────────────────────
select_mode() {
  echo ""
  divider
  echo -e " ${BOLD}Was möchtest du tun?${CL}"
  divider
  echo ""
  echo -e "  ${BOLD}1)${CL} ${GN}Neue VM installieren${CL}       – Debian 12 VM + TRMM-Vorbereitung"
  echo -e "  ${BOLD}2)${CL} ${BL}Tactical RMM aktualisieren${CL} – Update auf bestehender TRMM-VM"
  echo -e "  ${BOLD}3)${CL} ${YW}Backup erstellen${CL}            – Snapshot + App-Backup einer TRMM-VM"
  echo -e "  ${BOLD}4)${CL} ${DIM}Beenden${CL}"
  echo ""
  echo -ne " Auswahl [1-4]: "
  read -r MODE
  MODE="${MODE:-}"

  case "$MODE" in
    1) mode_install ;;
    2) mode_update ;;
    3) mode_backup ;;
    4) echo -e "\n Auf Wiedersehen!\n"; exit 0 ;;
    *) msg_warn "Ungültige Auswahl – bitte 1, 2, 3 oder 4 eingeben."; select_mode ;;
  esac
}

# ─── OS-Version auswählen ─────────────────────────────────────────────────────
select_os_version() {
  echo ""
  echo -e " ${BOLD}Betriebssystem wählen:${CL}"
  echo ""
  echo -e "  ${BOLD}1)${CL} ${GN}Debian 12 (Bookworm)${CL}  ${GN}← Empfohlen${CL}"
  echo -e "     ${DIM}Offiziell unterstützt von Tactical RMM${CL}"
  echo ""
  echo -e "  ${BOLD}2)${CL} ${YW}Debian 13 (Trixie)${CL}   ${WARN} Experimentell${CL}"
  echo -e "     ${DIM}Noch NICHT offiziell von Tactical RMM unterstützt.${CL}"
  echo -e "     ${DIM}Python 3.13 / PostgreSQL 17 können Probleme verursachen.${CL}"
  echo -e "     ${DIM}Nur für Tests – nicht für Produktion empfohlen!${CL}"
  echo ""
  echo -ne " Auswahl [1/2, Enter = 1]: "
  read -r os_choice
  os_choice="${os_choice:-1}"

  case "$os_choice" in
    2)
      DEBIAN_VERSION="13"
      DEBIAN_CODENAME="trixie"
      DEBIAN_IMAGE="debian-13-genericcloud-amd64.qcow2"
      DEBIAN_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
      echo ""
      echo -e " ${RD}${BOLD}ACHTUNG:${CL} ${YW}Debian 13 ist von Tactical RMM offiziell NICHT unterstützt.${CL}"
      echo -e " ${YW}Das TRMM-Installationsscript kann fehlschlagen.${CL}"
      echo -e " ${YW}Nur auf eigene Gefahr verwenden!${CL}"
      echo ""
      echo -ne " Wirklich Debian 13 verwenden? [j/N]: "
      read -r confirm13
      confirm13="${confirm13:-N}"
      if [[ "${confirm13,,}" != "j" ]]; then
        msg_warn "Zurück zur OS-Auswahl."
        select_os_version
        return
      fi
      msg_ok "OS: Debian 13 Trixie (experimentell)"
      ;;
    *)
      DEBIAN_VERSION="12"
      DEBIAN_CODENAME="bookworm"
      DEBIAN_IMAGE="debian-12-genericcloud-amd64.qcow2"
      DEBIAN_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
      msg_ok "OS: Debian 12 Bookworm (empfohlen)"
      ;;
  esac
}

# ─── Storage-Erkennung: alle aktiven Storages holen ──────────────────────────
_get_all_storages() {
  # Gibt alle aktiven Storages aus, robust gegen PVE-Versionsunterschiede
  local -a result=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && result+=("$line")
  done < <(pvesm status 2>/dev/null | awk 'NR>1 {print $1}' || true)
  printf '%s\n' "${result[@]}"
}

_get_storages_with_content() {
  # Filtert Storages nach unterstütztem Content-Typ
  local content_type="$1"
  local stor
  while IFS= read -r stor; do
    if pvesm status --storage "$stor" 2>/dev/null | grep -q "$content_type"; then
      echo "$stor"
    fi
  done < <(_get_all_storages)
}

_pick_storage() {
  # Zeigt eine nummerierte Liste und lässt den User wählen
  # $1 = Beschreibung, $2 = Ziel-Variable, $3 = Content-Filter (optional)
  local label="$1" varname="$2" content_filter="${3:-}"
  local -a STORAGES=()

  if [[ -n "$content_filter" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && STORAGES+=("$line")
    done < <(_get_storages_with_content "$content_filter")
  fi

  # Fallback: alle Storages wenn Filter nichts liefert
  if [[ ${#STORAGES[@]} -eq 0 ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && STORAGES+=("$line")
    done < <(_get_all_storages)
  fi

  if [[ ${#STORAGES[@]} -eq 0 ]]; then
    msg_error "Kein Storage gefunden! Proxmox-Storage-Konfiguration prüfen."
  elif [[ ${#STORAGES[@]} -eq 1 ]]; then
    printf -v "$varname" '%s' "${STORAGES[0]}"
    msg_ok "${label}: ${STORAGES[0]}"
  else
    echo ""
    echo -e " ${YW}${label} – Storage wählen:${CL}"
    local i=1
    for s in "${STORAGES[@]}"; do
      # Kurz-Info zum Storage anzeigen
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

# ─── Storage-Auswahl für VM-Disk ──────────────────────────────────────────────
select_storage_vm() {
  echo ""
  echo -e " ${DIM}Storage für die VM-Disk (muss 'images' unterstützen):${CL}"
  _pick_storage "VM-Disk Storage" STORAGE_VM "images"
}

# ─── Storage-Auswahl für Cloud-Init Snippets (optional) ───────────────────────
select_storage_snippets() {
  echo ""
  # Prüfen ob Snippets-fähige Storages existieren
  local -a SNIP_STORAGES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && SNIP_STORAGES+=("$line")
  done < <(_get_storages_with_content "snippets")

  if [[ ${#SNIP_STORAGES[@]} -eq 0 ]]; then
    msg_warn "Kein Storage mit 'snippets' gefunden – Cloud-Init ohne custom user-data."
    STORAGE_SNIPPETS=""
    return
  fi

  echo -e " ${DIM}Storage für Cloud-Init Snippets (für MOTD und Erstkonfiguration):${CL}"
  _pick_storage "Snippets Storage" STORAGE_SNIPPETS "snippets"
}

# =============================================================================
#  MODUS 1: INSTALLATION
# =============================================================================

mode_install() {
  echo ""
  divider
  echo -e " ${BOLD}${GN}NEUE VM INSTALLIEREN${CL}"
  divider
  echo -e " ${DIM}Erstellt eine Debian VM und bereitet die Installation von Tactical RMM vor.${CL}"
  echo -e " ${WARN} Tactical RMM benötigt 3 DNS A-Records (rmm/api/mesh) auf deine Domain!"

  # OS-Version
  select_os_version

  # VM-ID
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
  prompt "VM-ID" VMID "$next_id"

  # Hostname
  prompt "Hostname" VM_HOSTNAME "tacticalrmm"

  # CPU
  prompt "CPU-Kerne" CORES "2"

  # RAM
  prompt "RAM in MB" RAM "4096"
  if [[ "$RAM" -lt 4096 ]] 2>/dev/null; then
    msg_warn "Mindestens 4096 MB empfohlen! TRMM kann instabil werden."
    echo -ne " Trotzdem fortfahren? [j/N]: "
    read -r c; c="${c:-N}"
    [[ "${c,,}" != "j" ]] && msg_error "Abgebrochen."
  fi

  # Disk
  prompt "Disk in GB" DISK "50"

  # Bridge
  prompt "Netzwerk-Bridge" BRIDGE "vmbr0"

  # VLAN
  echo -ne " ${YW}VLAN-Tag${CL} (leer = keiner): "
  read -r VLAN
  VLAN="${VLAN:-}"

  # Storage für VM-Disk
  select_storage_vm

  # Storage für Cloud-Init Snippets
  select_storage_snippets

  # Autostart
  echo -ne " ${YW}VM nach Erstellung starten?${CL} [J/n]: "
  read -r _start
  _start="${_start:-J}"
  [[ "${_start,,}" == "n" ]] && START_VM="no" || START_VM="yes"

  # Zusammenfassung
  echo ""
  divider
  echo -e " ${BOLD}Zusammenfassung${CL}"
  divider
  printf "  %-16s ${BOLD}%s${CL}\n"    "VM-ID:"     "$VMID"
  printf "  %-16s ${BOLD}%s${CL}\n"    "OS:"        "Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
  printf "  %-16s ${BOLD}%s${CL}\n"    "Hostname:"  "$VM_HOSTNAME"
  printf "  %-16s ${BOLD}%s${CL}\n"    "CPU-Kerne:" "$CORES"
  printf "  %-16s ${BOLD}%s MB${CL}\n" "RAM:"       "$RAM"
  printf "  %-16s ${BOLD}%s GB${CL}\n" "Disk:"      "$DISK"
  printf "  %-16s ${BOLD}%s${CL}\n"    "Bridge:"    "$BRIDGE"
  [[ -n "$VLAN" ]] && printf "  %-16s ${BOLD}%s${CL}\n" "VLAN:" "$VLAN"
  printf "  %-16s ${BOLD}%s${CL}\n"    "VM-Storage:" "$STORAGE_VM"
  if [[ -n "$STORAGE_SNIPPETS" ]]; then
    printf "  %-16s ${BOLD}%s${CL}\n" "Snippets:" "$STORAGE_SNIPPETS"
  fi
  printf "  %-16s ${BOLD}%s${CL}\n"    "Autostart:" "$START_VM"
  if [[ "$DEBIAN_VERSION" == "13" ]]; then
    echo ""
    echo -e "  ${YW}⚠ Debian 13 ist von Tactical RMM nicht offiziell unterstützt!${CL}"
  fi
  echo ""
  echo -ne " Jetzt erstellen? [J/n]: "
  read -r confirm
  confirm="${confirm:-J}"
  [[ "${confirm,,}" == "n" ]] && msg_error "Abgebrochen."

  _do_install
}

_do_install() {
  TACTICAL_PASS=$(tr -dc 'A-Za-z0-9@#%^' </dev/urandom | head -c 20)
  local hashed_pw
  hashed_pw=$(echo "$TACTICAL_PASS" | openssl passwd -6 -stdin)

  local net0_arg="virtio,bridge=${BRIDGE}"
  [[ -n "$VLAN" ]] && net0_arg="virtio,bridge=${BRIDGE},tag=${VLAN}"

  cat > "$TEMP_DIR/user-data.yml" <<CLOUDINIT
#cloud-config
hostname: ${VM_HOSTNAME}
fqdn: ${VM_HOSTNAME}
manage_etc_hosts: true

users:
  - name: tactical
    gecos: Tactical RMM
    groups: sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: ${hashed_pw}

ssh_pwauth: true
disable_root: false

package_update: true
package_upgrade: true
packages:
  - curl
  - wget
  - sudo
  - ufw
  - git
  - htop
  - ncdu

runcmd:
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow https
  - ufw allow ssh
  - ufw --force enable
  - echo "tactical ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/tactical
  - chmod 0440 /etc/sudoers.d/tactical
  - curl -fsSL https://raw.githubusercontent.com/amidaware/tacticalrmm/master/install.sh -o /home/tactical/install.sh
  - chown tactical:tactical /home/tactical/install.sh
  - chmod +x /home/tactical/install.sh
  - curl -fsSL ${GITHUB_RAW}/scripts/trmm-update.sh -o /usr/local/bin/trmm-update
  - curl -fsSL ${GITHUB_RAW}/scripts/trmm-backup.sh -o /usr/local/bin/trmm-backup
  - chmod +x /usr/local/bin/trmm-update /usr/local/bin/trmm-backup
  - mkdir -p /opt/trmm-backups
  - echo "0 2 * * * tactical /usr/local/bin/trmm-backup --auto >> /var/log/trmm-backup.log 2>&1" >> /etc/crontab
  - |
    cat > /etc/motd << 'MOTD'

    ╔══════════════════════════════════════════════════════════════╗
    ║        TACTICAL RMM – Bereit zur Installation                ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Schritt 1: DNS A-Records erstellen (alle -> VM-IP)         ║
    ║    rmm.deine-domain.de                                       ║
    ║    api.deine-domain.de                                       ║
    ║    mesh.deine-domain.de                                      ║
    ║                                                              ║
    ║  Schritt 2: Als tactical-User einloggen:                     ║
    ║    su - tactical                                             ║
    ║    ./install.sh                                              ║
    ║                                                              ║
    ║  Nach der Installation:                                      ║
    ║    trmm-update   Tactical RMM aktualisieren                  ║
    ║    trmm-backup   Manuelles Backup erstellen                  ║
    ║                                                              ║
    ║  Doku: https://docs.tacticalrmm.com/install_server/          ║
    ╚══════════════════════════════════════════════════════════════╝

MOTD

power_state:
  mode: reboot
  delay: "+1"
  message: "Initialisierung abgeschlossen - Neustart..."
CLOUDINIT

  msg_info "Lade Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME}) Cloud-Image"
  wget -q --show-progress -O "$TEMP_DIR/$DEBIAN_IMAGE" "$DEBIAN_URL" \
    || msg_error "Download fehlgeschlagen: $DEBIAN_URL"
  msg_ok "Debian ${DEBIAN_VERSION} Cloud-Image geladen"

  msg_info "Erstelle VM ${VMID}"
  qm create "$VMID" \
    --name "$VM_HOSTNAME" \
    --ostype l26 \
    --memory "$RAM" \
    --balloon 0 \
    --cores "$CORES" \
    --cpu host \
    --net0 "$net0_arg" \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${STORAGE_VM}:0,pre-enrolled-keys=0" \
    --scsihw virtio-scsi-single \
    --agent enabled=1 \
    --vga serial0 \
    --serial0 socket \
    --onboot 1 \
    --tablet 0 \
    --localtime 1 \
    --tags tacticalrmm
  msg_ok "VM ${VMID} angelegt"

  msg_info "Importiere Disk nach ${STORAGE_VM}"
  qm importdisk "$VMID" "$TEMP_DIR/$DEBIAN_IMAGE" "$STORAGE_VM" --format qcow2 >/dev/null 2>&1
  local disk_ref
  disk_ref=$(qm config "$VMID" | grep "^unused0:" | awk '{print $2}')
  qm set "$VMID" --scsi0 "${disk_ref},discard=on,ssd=1,cache=writethrough"
  qm disk resize "$VMID" scsi0 "${DISK}G" >/dev/null 2>&1
  qm set "$VMID" --boot order=scsi0
  msg_ok "Disk: ${DISK}GB auf ${STORAGE_VM}"

  msg_info "Konfiguriere Cloud-Init"
  qm set "$VMID" --ide2 "${STORAGE_VM}:cloudinit"
  qm set "$VMID" --ipconfig0 ip=dhcp
  qm set "$VMID" --ciuser tactical
  qm set "$VMID" --cipassword "$TACTICAL_PASS"

  if [[ -n "$STORAGE_SNIPPETS" ]]; then
    local snippets_path=""
    snippets_path=$(pvesm path "$STORAGE_SNIPPETS" 2>/dev/null || true)
    if [[ -n "$snippets_path" ]]; then
      mkdir -p "${snippets_path}/snippets"
      cp "$TEMP_DIR/user-data.yml" "${snippets_path}/snippets/trmm-${VMID}-userdata.yml"
      qm set "$VMID" --cicustom "user=${STORAGE_SNIPPETS}:snippets/trmm-${VMID}-userdata.yml" 2>/dev/null || true
      msg_ok "Cloud-Init user-data installiert (${STORAGE_SNIPPETS})"
    else
      msg_ok "Cloud-Init konfiguriert (Basis)"
    fi
  else
    msg_ok "Cloud-Init konfiguriert (Basis)"
  fi

  if [[ "$START_VM" == "yes" ]]; then
    msg_info "Starte VM ${VMID}"
    qm start "$VMID"
    msg_ok "VM ${VMID} läuft"
  fi

  echo ""
  divider
  echo -e " ${GN}${BOLD}✓ VM erfolgreich erstellt!${CL}"
  divider
  echo ""
  printf "  %-16s ${BOLD}%s${CL}\n" "VM-ID:"    "$VMID"
  printf "  %-16s ${BOLD}%s${CL}\n" "OS:"       "Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
  printf "  %-16s ${BOLD}%s${CL}\n" "SSH-User:" "tactical"
  printf "  %-16s ${BOLD}${RD}%s${CL}  ${YW}← JETZT NOTIEREN!${CL}\n" "SSH-Passwort:" "$TACTICAL_PASS"
  echo ""
  echo -e " ${YW}Nächste Schritte:${CL}"
  echo -e "  1. DNS A-Records erstellen: ${BL}rmm / api / mesh${CL} → VM-IP"
  echo -e "  2. SSH: ${BL}ssh tactical@<VM-IP>${CL}"
  echo -e "  3. Installation: ${BL}./install.sh${CL}"
  echo ""
  echo -e " ${DIM}In der VM installierte Hilfstools:${CL}"
  echo -e "  ${BL}trmm-update${CL}  – TRMM aktualisieren"
  echo -e "  ${BL}trmm-backup${CL}  – Manuelles Backup (Cron täglich 02:00)"
  echo ""
  divider
  echo ""
}

# =============================================================================
#  MODUS 2: UPDATE
# =============================================================================

mode_update() {
  echo ""
  divider
  echo -e " ${BOLD}${BL}TACTICAL RMM AKTUALISIEREN${CL}"
  divider
  echo -e " ${DIM}Führt das offizielle Update-Script auf der TRMM-VM aus.${CL}"
  echo ""

  local -a TRMM_VMS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && TRMM_VMS+=("$line")
  done < <(qm list 2>/dev/null | awk 'NR>1 {print $1, $2}' | grep -i "tactical\|trmm" || true)

  if [[ ${#TRMM_VMS[@]} -eq 0 ]]; then
    msg_warn "Keine VM mit 'tactical' oder 'trmm' im Namen gefunden."
    echo -e " Alle VMs:"
    qm list 2>/dev/null | awk 'NR>1 {printf "  %-6s %-20s %s\n", $1, $2, $3}'
  else
    echo -e " ${GN}Gefundene TRMM-VMs:${CL}"
    for vm in "${TRMM_VMS[@]}"; do echo "  $vm"; done
  fi
  echo ""

  prompt "VM-ID der TRMM-VM" TARGET_VMID ""
  [[ -z "$TARGET_VMID" ]] && msg_error "Keine VM-ID eingegeben."

  local vm_status
  vm_status=$(qm status "$TARGET_VMID" 2>/dev/null | awk '{print $2}' || echo "unknown")
  if [[ "$vm_status" != "running" ]]; then
    msg_warn "VM ${TARGET_VMID} läuft nicht (Status: ${vm_status})"
    echo -ne " VM jetzt starten? [J/n]: "
    read -r s; s="${s:-J}"
    if [[ "${s,,}" != "n" ]]; then
      msg_info "Starte VM ${TARGET_VMID}"
      qm start "$TARGET_VMID"
      sleep 15
      msg_ok "VM gestartet"
    else
      msg_error "Abgebrochen."
    fi
  fi

  msg_info "Ermittle VM-IP (warte auf Guest Agent)"
  local VM_IP=""
  local i
  for i in {1..12}; do
    VM_IP=$(qm guest exec "$TARGET_VMID" -- \
      bash -c "ip -4 addr show | grep 'inet ' | grep -v 127 | awk '{print \$2}' | cut -d/ -f1 | head -1" \
      2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data','').strip())" \
      2>/dev/null || true)
    [[ -n "$VM_IP" ]] && break
    sleep 5
  done

  if [[ -z "$VM_IP" ]]; then
    msg_warn "IP nicht automatisch ermittelbar."
    prompt "VM-IP manuell eingeben" VM_IP ""
    [[ -z "$VM_IP" ]] && msg_error "Keine IP eingegeben."
  fi
  msg_ok "VM-IP: ${VM_IP}"

  prompt "SSH-User" SSH_USER "tactical"

  echo ""
  echo -e " ${INFO} Verbinde mit ${VM_IP} und führe Update aus..."
  echo -e " ${DIM}(SSH-Passwort wird abgefragt)${CL}"
  echo ""

  ssh -o StrictHostKeyChecking=accept-new -t "${SSH_USER}@${VM_IP}" \
    "sudo bash -c 'curl -fsSL ${GITHUB_RAW}/scripts/trmm-update.sh | bash'" \
    || msg_error "SSH-Verbindung oder Update fehlgeschlagen!"

  echo ""
  msg_ok "Update abgeschlossen!"
  divider
  echo ""
}

# =============================================================================
#  MODUS 3: BACKUP
# =============================================================================

mode_backup() {
  echo ""
  divider
  echo -e " ${BOLD}${YW}BACKUP ERSTELLEN${CL}"
  divider
  echo -e " ${DIM}Erstellt einen Proxmox-VM-Snapshot und ein TRMM-App-Backup.${CL}"
  echo ""

  echo -e " Alle VMs:"
  qm list 2>/dev/null | awk 'NR>1 {printf "  %-6s %-20s %s\n", $1, $2, $3}'
  echo ""

  prompt "VM-ID der TRMM-VM" TARGET_VMID ""
  [[ -z "$TARGET_VMID" ]] && msg_error "Keine VM-ID eingegeben."

  local ts
  ts=$(date +%Y%m%d_%H%M%S)
  local snap_name="trmm-bkp-${ts}"

  echo ""
  echo -e " ${INFO} Snapshot-Name: ${BOLD}${snap_name}${CL}"
  echo ""
  echo -ne " Backup jetzt starten? [J/n]: "
  read -r confirm
  confirm="${confirm:-J}"
  [[ "${confirm,,}" == "n" ]] && msg_error "Abgebrochen."

  msg_info "Erstelle Proxmox VM-Snapshot"
  if qm snapshot "$TARGET_VMID" "$snap_name" \
      --description "Tactical RMM Backup ${ts}" 2>/dev/null; then
    msg_ok "Snapshot erstellt: ${snap_name}"
  else
    msg_warn "Snapshot fehlgeschlagen (Storage unterstützt keine Snapshots?). Weiter mit App-Backup."
  fi

  msg_info "Ermittle VM-IP"
  local VM_IP=""
  VM_IP=$(qm guest exec "$TARGET_VMID" -- \
    bash -c "ip -4 addr show | grep 'inet ' | grep -v 127 | awk '{print \$2}' | cut -d/ -f1 | head -1" \
    2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data','').strip())" \
    2>/dev/null || true)

  if [[ -n "$VM_IP" ]]; then
    msg_ok "VM-IP: ${VM_IP}"
    prompt "SSH-User" SSH_USER "tactical"
    echo -e " ${INFO} Starte App-Backup auf der VM..."
    ssh -o StrictHostKeyChecking=accept-new -t "${SSH_USER}@${VM_IP}" \
      "sudo trmm-backup --auto" 2>/dev/null \
      || msg_warn "App-Backup fehlgeschlagen (trmm-backup installiert?)"
  else
    msg_warn "IP nicht ermittelbar – App-Backup übersprungen."
  fi

  echo ""
  echo -e " ${GN}Vorhandene Snapshots für VM ${TARGET_VMID}:${CL}"
  qm listsnapshot "$TARGET_VMID" 2>/dev/null | grep -v "^->" || echo "  (keine)"
  echo ""
  divider
  echo -e " ${CM} Backup abgeschlossen!"
  echo ""
}

# ─── Hauptprogramm ────────────────────────────────────────────────────────────
header_info
check_proxmox
select_mode#!/usr/bin/env bash
# =============================================================================
#  Proxmox VM Installer für Tactical RMM  (Community Script)
#  https://github.com/DEIN-GITHUB-USER/tacticalrmm-proxmox
#
#  Aufruf auf dem Proxmox-Host als root:
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/DEIN-GITHUB-USER/tacticalrmm-proxmox/main/tacticalrmm.sh)"
#
#  DISCLAIMER: Dieses Script ist ein unabhängiges Community-Projekt und steht
#  in keiner Verbindung zu AmidaWare LLC. "Tactical RMM" ist eine eingetragene
#  Marke von AmidaWare LLC. Das Script lädt die offizielle Tactical RMM Software
#  herunter und installiert sie gemäß der öffentlichen Installationsdokumentation
#  unter https://docs.tacticalrmm.com – ohne diese zu verändern.
#
#  WICHTIG: Tactical RMM läuft NUR auf VMs (kein LXC)
#  Quelle: https://docs.tacticalrmm.com/unsupported_guidelines/
# =============================================================================

set -eo pipefail

# ─── Farben mit $'...' – funktioniert in read -p zuverlässig ─────────────────
YW=$'\033[33m'
BL=$'\033[36m'
RD=$'\033[01;31m'
GN=$'\033[1;92m'
CL=$'\033[m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
BFR=$'\r\033[K'
HOLD=" "
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${BL}ℹ${CL}"
WARN="${YW}⚠${CL}"

# ─── GitHub-Basis-URL (DEIN-GITHUB-USER ersetzen!) ────────────────────────────
GITHUB_RAW="https://raw.githubusercontent.com/DEIN-GITHUB-USER/tacticalrmm-proxmox/main"

# ─── Globale Variablen ────────────────────────────────────────────────────────
VMID=""
VM_HOSTNAME="tacticalrmm"
CORES="2"
RAM="4096"
DISK="50"
BRIDGE="vmbr0"
VLAN=""
START_VM="yes"
STORAGE=""
TACTICAL_PASS=""
TARGET_VMID=""
SSH_USER="tactical"

# OS (wird durch select_os_version gesetzt)
DEBIAN_URL=""
DEBIAN_IMAGE=""
DEBIAN_VERSION=""
DEBIAN_CODENAME=""

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# ─── Hilfsfunktionen ──────────────────────────────────────────────────────────
msg_info()  { local msg="$1"; echo -ne " ${HOLD} ${YW}${msg}...${CL}"; }
msg_ok()    { local msg="$1"; echo -e "${BFR} ${CM} ${GN}${msg}${CL}"; }
msg_error() { local msg="$1"; echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"; exit 1; }
msg_warn()  { local msg="$1"; echo -e " ${WARN} ${YW}${msg}${CL}"; }
divider()   { echo -e "${DIM}$(printf '━%.0s' {1..62})${CL}"; }

# read-Wrapper: gibt farbigen Prompt aus, dann liest ohne Farb-Probleme
prompt() {
  # $1 = Anzeigetext (mit Farbe), $2 = Variablenname, $3 = Default
  local display="$1" varname="$2" default="${3:-}"
  if [[ -n "$default" ]]; then
    echo -ne " ${YW}${display}${CL} [${default}]: "
  else
    echo -ne " ${YW}${display}${CL}: "
  fi
  local input
  read -r input
  # Ergebnis in die gewünschte globale Variable schreiben
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
  echo -e "  ${BOLD}Proxmox VM Installer für Tactical RMM${CL}"
  echo -e "  ${DIM}Community Script – kein offizielles AmidaWare-Projekt${CL}"
  echo ""
}

# ─── Proxmox-Voraussetzungen prüfen ───────────────────────────────────────────
check_proxmox() {
  msg_info "Prüfe Proxmox-Umgebung"
  if ! command -v pvesh &>/dev/null; then
    msg_error "Muss auf einem Proxmox VE Host ausgeführt werden!"
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "Bitte als root ausführen!"
  fi

  local pve_raw
  pve_raw=$(pveversion 2>/dev/null | head -1 || true)
  local PVE_VERSION=""
  local PVE_MAJOR=0

  if [[ "$pve_raw" =~ pve-manager/([0-9]+)\.([0-9]+) ]]; then
    PVE_MAJOR="${BASH_REMATCH[1]}"
    PVE_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  else
    PVE_VERSION=$(echo "$pve_raw" | grep -oP '\d+\.\d+' | head -1 || true)
    PVE_MAJOR=$(echo "$PVE_VERSION" | cut -d'.' -f1 || echo "0")
  fi

  if [[ -z "$PVE_VERSION" ]]; then
    msg_warn "Proxmox-Version konnte nicht ermittelt werden – fahre fort."
  elif [[ "$PVE_MAJOR" -lt 7 ]]; then
    msg_error "Proxmox VE 7.0+ erforderlich (erkannt: $PVE_VERSION)"
  else
    msg_ok "Proxmox VE $PVE_VERSION"
  fi
}

# ─── Modus-Auswahl ────────────────────────────────────────────────────────────
select_mode() {
  echo ""
  divider
  echo -e " ${BOLD}Was möchtest du tun?${CL}"
  divider
  echo ""
  echo -e "  ${BOLD}1)${CL} ${GN}Neue VM installieren${CL}       – Debian 12 VM + TRMM-Vorbereitung"
  echo -e "  ${BOLD}2)${CL} ${BL}Tactical RMM aktualisieren${CL} – Update auf bestehender TRMM-VM"
  echo -e "  ${BOLD}3)${CL} ${YW}Backup erstellen${CL}            – Snapshot + App-Backup einer TRMM-VM"
  echo -e "  ${BOLD}4)${CL} ${DIM}Beenden${CL}"
  echo ""
  echo -ne " Auswahl [1-4]: "
  read -r MODE
  MODE="${MODE:-}"

  case "$MODE" in
    1) mode_install ;;
    2) mode_update ;;
    3) mode_backup ;;
    4) echo -e "\n Auf Wiedersehen!\n"; exit 0 ;;
    *) msg_warn "Ungültige Auswahl – bitte 1, 2, 3 oder 4 eingeben."; select_mode ;;
  esac
}

# ─── OS-Version auswählen ─────────────────────────────────────────────────────
select_os_version() {
  echo ""
  echo -e " ${BOLD}Betriebssystem wählen:${CL}"
  echo ""
  echo -e "  ${BOLD}1)${CL} ${GN}Debian 12 (Bookworm)${CL}  ${GN}← Empfohlen${CL}"
  echo -e "     ${DIM}Offiziell unterstützt von Tactical RMM${CL}"
  echo ""
  echo -e "  ${BOLD}2)${CL} ${YW}Debian 13 (Trixie)${CL}   ${WARN} Experimentell${CL}"
  echo -e "     ${DIM}Noch NICHT offiziell von Tactical RMM unterstützt.${CL}"
  echo -e "     ${DIM}Python 3.13 / PostgreSQL 17 können Probleme verursachen.${CL}"
  echo -e "     ${DIM}Nur für Tests – nicht für Produktion empfohlen!${CL}"
  echo ""
  echo -ne " Auswahl [1/2, Enter = 1]: "
  read -r os_choice
  os_choice="${os_choice:-1}"

  case "$os_choice" in
    2)
      DEBIAN_VERSION="13"
      DEBIAN_CODENAME="trixie"
      DEBIAN_IMAGE="debian-13-genericcloud-amd64.qcow2"
      DEBIAN_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
      echo ""
      echo -e " ${RD}${BOLD}ACHTUNG:${CL} ${YW}Debian 13 ist von Tactical RMM offiziell NICHT unterstützt.${CL}"
      echo -e " ${YW}Das TRMM-Installationsscript kann fehlschlagen.${CL}"
      echo -e " ${YW}Nur auf eigene Gefahr verwenden!${CL}"
      echo ""
      echo -ne " Wirklich Debian 13 verwenden? [j/N]: "
      read -r confirm13
      confirm13="${confirm13:-N}"
      if [[ "${confirm13,,}" != "j" ]]; then
        msg_warn "Zurück zur OS-Auswahl."
        select_os_version
        return
      fi
      msg_ok "OS: Debian 13 Trixie (experimentell)"
      ;;
    *)
      DEBIAN_VERSION="12"
      DEBIAN_CODENAME="bookworm"
      DEBIAN_IMAGE="debian-12-genericcloud-amd64.qcow2"
      DEBIAN_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
      msg_ok "OS: Debian 12 Bookworm (empfohlen)"
      ;;
  esac
}

# ─── Storage-Auswahl ──────────────────────────────────────────────────────────
select_storage() {
  local -a STORAGES=()

  # pvesm status gibt je nach PVE-Version unterschiedliche Spalten aus.
  # Wir suchen Storages die "images" im content-Feld haben und "active" sind.
  # Robust: alle Zeilen holen, dann filtern
  while IFS= read -r line; do
    [[ -n "$line" ]] && STORAGES+=("$line")
  done < <(
    pvesm status 2>/dev/null | awk 'NR>1 {
      name=$1; status=$2; content=""
      # Status-Spalte suchen (active/inactive)
      for(i=1;i<=NF;i++) {
        if($i=="active") { found=1 }
      }
      if(found) print name
    }' | while read -r stor; do
      # Prüfen ob Storage images unterstützt
      if pvesm status --storage "$stor" 2>/dev/null | grep -q "images\|vztmpl\|iso"; then
        echo "$stor"
      fi
    done || true
  )

  # Fallback: direkt alle aktiven Storages ohne Content-Filter
  if [[ ${#STORAGES[@]} -eq 0 ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && STORAGES+=("$line")
    done < <(pvesm status 2>/dev/null | awk 'NR>1 {print $1}' || true)
  fi

  if [[ ${#STORAGES[@]} -eq 0 ]]; then
    msg_error "Kein Storage gefunden! Bitte Proxmox-Storage-Konfiguration prüfen."
  elif [[ ${#STORAGES[@]} -eq 1 ]]; then
    STORAGE="${STORAGES[0]}"
    msg_ok "Storage: ${STORAGE}"
  else
    echo ""
    echo -e " ${YW}Verfügbarer Storage:${CL}"
    local i=1
    for s in "${STORAGES[@]}"; do
      echo -e "  ${BOLD}${i})${CL} ${s}"
      ((i++))
    done
    echo ""
    echo -ne " Auswahl [1-${#STORAGES[@]}]: "
    local choice
    read -r choice
    choice="${choice:-1}"
    if [[ "$choice" -ge 1 && "$choice" -le ${#STORAGES[@]} ]] 2>/dev/null; then
      STORAGE="${STORAGES[$((choice-1))]}"
    else
      STORAGE="${STORAGES[0]}"
    fi
    msg_ok "Storage: ${STORAGE}"
  fi
}

# =============================================================================
#  MODUS 1: INSTALLATION
# =============================================================================

mode_install() {
  echo ""
  divider
  echo -e " ${BOLD}${GN}NEUE VM INSTALLIEREN${CL}"
  divider
  echo -e " ${DIM}Erstellt eine Debian VM und bereitet die Installation von Tactical RMM vor.${CL}"
  echo -e " ${WARN} Tactical RMM benötigt 3 DNS A-Records (rmm/api/mesh) auf deine Domain!"

  # OS-Version
  select_os_version

  # VM-ID
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
  prompt "VM-ID" VMID "$next_id"

  # Hostname
  prompt "Hostname" VM_HOSTNAME "tacticalrmm"

  # CPU
  prompt "CPU-Kerne" CORES "2"

  # RAM
  prompt "RAM in MB" RAM "4096"
  if [[ "$RAM" -lt 4096 ]] 2>/dev/null; then
    msg_warn "Mindestens 4096 MB empfohlen! TRMM kann instabil werden."
    echo -ne " Trotzdem fortfahren? [j/N]: "
    read -r c; c="${c:-N}"
    [[ "${c,,}" != "j" ]] && msg_error "Abgebrochen."
  fi

  # Disk
  prompt "Disk in GB" DISK "50"

  # Bridge
  prompt "Netzwerk-Bridge" BRIDGE "vmbr0"

  # VLAN
  echo -ne " ${YW}VLAN-Tag${CL} (leer = keiner): "
  read -r VLAN
  VLAN="${VLAN:-}"

  # Storage
  select_storage

  # Autostart
  echo -ne " ${YW}VM nach Erstellung starten?${CL} [J/n]: "
  read -r _start
  _start="${_start:-J}"
  [[ "${_start,,}" == "n" ]] && START_VM="no" || START_VM="yes"

  # Zusammenfassung
  echo ""
  divider
  echo -e " ${BOLD}Zusammenfassung${CL}"
  divider
  printf "  %-16s ${BOLD}%s${CL}\n"    "VM-ID:"     "$VMID"
  printf "  %-16s ${BOLD}%s${CL}\n"    "OS:"        "Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
  printf "  %-16s ${BOLD}%s${CL}\n"    "Hostname:"  "$VM_HOSTNAME"
  printf "  %-16s ${BOLD}%s${CL}\n"    "CPU-Kerne:" "$CORES"
  printf "  %-16s ${BOLD}%s MB${CL}\n" "RAM:"       "$RAM"
  printf "  %-16s ${BOLD}%s GB${CL}\n" "Disk:"      "$DISK"
  printf "  %-16s ${BOLD}%s${CL}\n"    "Bridge:"    "$BRIDGE"
  [[ -n "$VLAN" ]] && printf "  %-16s ${BOLD}%s${CL}\n" "VLAN:" "$VLAN"
  printf "  %-16s ${BOLD}%s${CL}\n"    "Storage:"   "$STORAGE"
  printf "  %-16s ${BOLD}%s${CL}\n"    "Autostart:" "$START_VM"
  if [[ "$DEBIAN_VERSION" == "13" ]]; then
    echo ""
    echo -e "  ${YW}⚠ Debian 13 ist von Tactical RMM nicht offiziell unterstützt!${CL}"
  fi
  echo ""
  echo -ne " Jetzt erstellen? [J/n]: "
  read -r confirm
  confirm="${confirm:-J}"
  [[ "${confirm,,}" == "n" ]] && msg_error "Abgebrochen."

  _do_install
}

_do_install() {
  TACTICAL_PASS=$(tr -dc 'A-Za-z0-9@#%^' </dev/urandom | head -c 20)
  local hashed_pw
  hashed_pw=$(echo "$TACTICAL_PASS" | openssl passwd -6 -stdin)

  local net0_arg="virtio,bridge=${BRIDGE}"
  [[ -n "$VLAN" ]] && net0_arg="virtio,bridge=${BRIDGE},tag=${VLAN}"

  cat > "$TEMP_DIR/user-data.yml" <<CLOUDINIT
#cloud-config
hostname: ${VM_HOSTNAME}
fqdn: ${VM_HOSTNAME}
manage_etc_hosts: true

users:
  - name: tactical
    gecos: Tactical RMM
    groups: sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: ${hashed_pw}

ssh_pwauth: true
disable_root: false

package_update: true
package_upgrade: true
packages:
  - curl
  - wget
  - sudo
  - ufw
  - git
  - htop
  - ncdu

runcmd:
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow https
  - ufw allow ssh
  - ufw --force enable
  - echo "tactical ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/tactical
  - chmod 0440 /etc/sudoers.d/tactical
  - curl -fsSL https://raw.githubusercontent.com/amidaware/tacticalrmm/master/install.sh -o /home/tactical/install.sh
  - chown tactical:tactical /home/tactical/install.sh
  - chmod +x /home/tactical/install.sh
  - curl -fsSL ${GITHUB_RAW}/scripts/trmm-update.sh -o /usr/local/bin/trmm-update
  - curl -fsSL ${GITHUB_RAW}/scripts/trmm-backup.sh -o /usr/local/bin/trmm-backup
  - chmod +x /usr/local/bin/trmm-update /usr/local/bin/trmm-backup
  - mkdir -p /opt/trmm-backups
  - echo "0 2 * * * tactical /usr/local/bin/trmm-backup --auto >> /var/log/trmm-backup.log 2>&1" >> /etc/crontab
  - |
    cat > /etc/motd << 'MOTD'

    ╔══════════════════════════════════════════════════════════════╗
    ║        TACTICAL RMM – Bereit zur Installation                ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Schritt 1: DNS A-Records erstellen (alle -> VM-IP)         ║
    ║    rmm.deine-domain.de                                       ║
    ║    api.deine-domain.de                                       ║
    ║    mesh.deine-domain.de                                      ║
    ║                                                              ║
    ║  Schritt 2: Als tactical-User einloggen:                     ║
    ║    su - tactical                                             ║
    ║    ./install.sh                                              ║
    ║                                                              ║
    ║  Nach der Installation:                                      ║
    ║    trmm-update   Tactical RMM aktualisieren                  ║
    ║    trmm-backup   Manuelles Backup erstellen                  ║
    ║                                                              ║
    ║  Doku: https://docs.tacticalrmm.com/install_server/          ║
    ╚══════════════════════════════════════════════════════════════╝

MOTD

power_state:
  mode: reboot
  delay: "+1"
  message: "Initialisierung abgeschlossen - Neustart..."
CLOUDINIT

  msg_info "Lade Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME}) Cloud-Image"
  wget -q --show-progress -O "$TEMP_DIR/$DEBIAN_IMAGE" "$DEBIAN_URL" \
    || msg_error "Download fehlgeschlagen: $DEBIAN_URL"
  msg_ok "Debian ${DEBIAN_VERSION} Cloud-Image geladen"

  msg_info "Erstelle VM ${VMID}"
  qm create "$VMID" \
    --name "$VM_HOSTNAME" \
    --ostype l26 \
    --memory "$RAM" \
    --balloon 0 \
    --cores "$CORES" \
    --cpu host \
    --net0 "$net0_arg" \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${STORAGE}:0,pre-enrolled-keys=0" \
    --scsihw virtio-scsi-single \
    --agent enabled=1 \
    --vga serial0 \
    --serial0 socket \
    --onboot 1 \
    --tablet 0 \
    --localtime 1 \
    --tags tacticalrmm
  msg_ok "VM ${VMID} angelegt"

  msg_info "Importiere Disk nach ${STORAGE}"
  qm importdisk "$VMID" "$TEMP_DIR/$DEBIAN_IMAGE" "$STORAGE" --format qcow2 >/dev/null 2>&1
  local disk_ref
  disk_ref=$(qm config "$VMID" | grep "^unused0:" | awk '{print $2}')
  qm set "$VMID" --scsi0 "${disk_ref},discard=on,ssd=1,cache=writethrough"
  qm disk resize "$VMID" scsi0 "${DISK}G" >/dev/null 2>&1
  qm set "$VMID" --boot order=scsi0
  msg_ok "Disk: ${DISK}GB auf ${STORAGE}"

  msg_info "Konfiguriere Cloud-Init"
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
  qm set "$VMID" --ipconfig0 ip=dhcp
  qm set "$VMID" --ciuser tactical
  qm set "$VMID" --cipassword "$TACTICAL_PASS"

  local snippets_path=""
  snippets_path=$(pvesm path "$STORAGE" 2>/dev/null || true)
  if [[ -n "$snippets_path" ]] && pvesm status --storage "$STORAGE" 2>/dev/null | grep -q "snippets"; then
    mkdir -p "${snippets_path}/snippets"
    cp "$TEMP_DIR/user-data.yml" "${snippets_path}/snippets/trmm-${VMID}-userdata.yml"
    qm set "$VMID" --cicustom "user=${STORAGE}:snippets/trmm-${VMID}-userdata.yml" 2>/dev/null || true
    msg_ok "Cloud-Init user-data installiert (Snippets)"
  else
    msg_ok "Cloud-Init konfiguriert (Basis)"
  fi

  if [[ "$START_VM" == "yes" ]]; then
    msg_info "Starte VM ${VMID}"
    qm start "$VMID"
    msg_ok "VM ${VMID} läuft"
  fi

  echo ""
  divider
  echo -e " ${GN}${BOLD}✓ VM erfolgreich erstellt!${CL}"
  divider
  echo ""
  printf "  %-16s ${BOLD}%s${CL}\n" "VM-ID:"    "$VMID"
  printf "  %-16s ${BOLD}%s${CL}\n" "OS:"       "Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
  printf "  %-16s ${BOLD}%s${CL}\n" "SSH-User:" "tactical"
  printf "  %-16s ${BOLD}${RD}%s${CL}  ${YW}← JETZT NOTIEREN!${CL}\n" "SSH-Passwort:" "$TACTICAL_PASS"
  echo ""
  echo -e " ${YW}Nächste Schritte:${CL}"
  echo -e "  1. DNS A-Records erstellen: ${BL}rmm / api / mesh${CL} → VM-IP"
  echo -e "  2. SSH: ${BL}ssh tactical@<VM-IP>${CL}"
  echo -e "  3. Installation: ${BL}./install.sh${CL}"
  echo ""
  echo -e " ${DIM}In der VM installierte Hilfstools:${CL}"
  echo -e "  ${BL}trmm-update${CL}  – TRMM aktualisieren"
  echo -e "  ${BL}trmm-backup${CL}  – Manuelles Backup (Cron täglich 02:00)"
  echo ""
  divider
  echo ""
}

# =============================================================================
#  MODUS 2: UPDATE
# =============================================================================

mode_update() {
  echo ""
  divider
  echo -e " ${BOLD}${BL}TACTICAL RMM AKTUALISIEREN${CL}"
  divider
  echo -e " ${DIM}Führt das offizielle Update-Script auf der TRMM-VM aus.${CL}"
  echo ""

  local -a TRMM_VMS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && TRMM_VMS+=("$line")
  done < <(qm list 2>/dev/null | awk 'NR>1 {print $1, $2}' | grep -i "tactical\|trmm" || true)

  if [[ ${#TRMM_VMS[@]} -eq 0 ]]; then
    msg_warn "Keine VM mit 'tactical' oder 'trmm' im Namen gefunden."
    echo -e " Alle VMs:"
    qm list 2>/dev/null | awk 'NR>1 {printf "  %-6s %-20s %s\n", $1, $2, $3}'
  else
    echo -e " ${GN}Gefundene TRMM-VMs:${CL}"
    for vm in "${TRMM_VMS[@]}"; do echo "  $vm"; done
  fi
  echo ""

  prompt "VM-ID der TRMM-VM" TARGET_VMID ""
  [[ -z "$TARGET_VMID" ]] && msg_error "Keine VM-ID eingegeben."

  local vm_status
  vm_status=$(qm status "$TARGET_VMID" 2>/dev/null | awk '{print $2}' || echo "unknown")
  if [[ "$vm_status" != "running" ]]; then
    msg_warn "VM ${TARGET_VMID} läuft nicht (Status: ${vm_status})"
    echo -ne " VM jetzt starten? [J/n]: "
    read -r s; s="${s:-J}"
    if [[ "${s,,}" != "n" ]]; then
      msg_info "Starte VM ${TARGET_VMID}"
      qm start "$TARGET_VMID"
      sleep 15
      msg_ok "VM gestartet"
    else
      msg_error "Abgebrochen."
    fi
  fi

  msg_info "Ermittle VM-IP (warte auf Guest Agent)"
  local VM_IP=""
  local i
  for i in {1..12}; do
    VM_IP=$(qm guest exec "$TARGET_VMID" -- \
      bash -c "ip -4 addr show | grep 'inet ' | grep -v 127 | awk '{print \$2}' | cut -d/ -f1 | head -1" \
      2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data','').strip())" \
      2>/dev/null || true)
    [[ -n "$VM_IP" ]] && break
    sleep 5
  done

  if [[ -z "$VM_IP" ]]; then
    msg_warn "IP nicht automatisch ermittelbar."
    prompt "VM-IP manuell eingeben" VM_IP ""
    [[ -z "$VM_IP" ]] && msg_error "Keine IP eingegeben."
  fi
  msg_ok "VM-IP: ${VM_IP}"

  prompt "SSH-User" SSH_USER "tactical"

  echo ""
  echo -e " ${INFO} Verbinde mit ${VM_IP} und führe Update aus..."
  echo -e " ${DIM}(SSH-Passwort wird abgefragt)${CL}"
  echo ""

  ssh -o StrictHostKeyChecking=accept-new -t "${SSH_USER}@${VM_IP}" \
    "sudo bash -c 'curl -fsSL ${GITHUB_RAW}/scripts/trmm-update.sh | bash'" \
    || msg_error "SSH-Verbindung oder Update fehlgeschlagen!"

  echo ""
  msg_ok "Update abgeschlossen!"
  divider
  echo ""
}

# =============================================================================
#  MODUS 3: BACKUP
# =============================================================================

mode_backup() {
  echo ""
  divider
  echo -e " ${BOLD}${YW}BACKUP ERSTELLEN${CL}"
  divider
  echo -e " ${DIM}Erstellt einen Proxmox-VM-Snapshot und ein TRMM-App-Backup.${CL}"
  echo ""

  echo -e " Alle VMs:"
  qm list 2>/dev/null | awk 'NR>1 {printf "  %-6s %-20s %s\n", $1, $2, $3}'
  echo ""

  prompt "VM-ID der TRMM-VM" TARGET_VMID ""
  [[ -z "$TARGET_VMID" ]] && msg_error "Keine VM-ID eingegeben."

  local ts
  ts=$(date +%Y%m%d_%H%M%S)
  local snap_name="trmm-bkp-${ts}"

  echo ""
  echo -e " ${INFO} Snapshot-Name: ${BOLD}${snap_name}${CL}"
  echo ""
  echo -ne " Backup jetzt starten? [J/n]: "
  read -r confirm
  confirm="${confirm:-J}"
  [[ "${confirm,,}" == "n" ]] && msg_error "Abgebrochen."

  msg_info "Erstelle Proxmox VM-Snapshot"
  if qm snapshot "$TARGET_VMID" "$snap_name" \
      --description "Tactical RMM Backup ${ts}" 2>/dev/null; then
    msg_ok "Snapshot erstellt: ${snap_name}"
  else
    msg_warn "Snapshot fehlgeschlagen (Storage unterstützt keine Snapshots?). Weiter mit App-Backup."
  fi

  msg_info "Ermittle VM-IP"
  local VM_IP=""
  VM_IP=$(qm guest exec "$TARGET_VMID" -- \
    bash -c "ip -4 addr show | grep 'inet ' | grep -v 127 | awk '{print \$2}' | cut -d/ -f1 | head -1" \
    2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data','').strip())" \
    2>/dev/null || true)

  if [[ -n "$VM_IP" ]]; then
    msg_ok "VM-IP: ${VM_IP}"
    prompt "SSH-User" SSH_USER "tactical"
    echo -e " ${INFO} Starte App-Backup auf der VM..."
    ssh -o StrictHostKeyChecking=accept-new -t "${SSH_USER}@${VM_IP}" \
      "sudo trmm-backup --auto" 2>/dev/null \
      || msg_warn "App-Backup fehlgeschlagen (trmm-backup installiert?)"
  else
    msg_warn "IP nicht ermittelbar – App-Backup übersprungen."
  fi

  echo ""
  echo -e " ${GN}Vorhandene Snapshots für VM ${TARGET_VMID}:${CL}"
  qm listsnapshot "$TARGET_VMID" 2>/dev/null | grep -v "^->" || echo "  (keine)"
  echo ""
  divider
  echo -e " ${CM} Backup abgeschlossen!"
  echo ""
}

# ─── Hauptprogramm ────────────────────────────────────────────────────────────
header_info
check_proxmox
select_mode
