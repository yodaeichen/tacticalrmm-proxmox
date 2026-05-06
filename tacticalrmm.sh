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
# Hinweis: -u (unbound variable) absichtlich weggelassen, da Proxmox-interne
# Umgebungsvariablen wie 'running' gesetzt sein können und sonst Fehler erzeugen.

# ─── Farben & Symbole ─────────────────────────────────────────────────────────
YW="\033[33m"; BL="\033[36m"; RD="\033[01;31m"
GN="\033[1;92m"; CL="\033[m"; BOLD="\033[1m"; DIM="\033[2m"
BFR="\\r\\033[K"; HOLD=" "
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"; INFO="${BL}ℹ${CL}"; WARN="${YW}⚠${CL}"

# ─── GitHub-Basis-URL (DEIN-GITHUB-USER ersetzen!) ────────────────────────────
GITHUB_RAW="https://raw.githubusercontent.com/DEIN-GITHUB-USER/tacticalrmm-proxmox/main"

# ─── Globale Variablen mit sicheren Defaults ──────────────────────────────────
VMID=""
HOSTNAME="tacticalrmm"
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

# OS-Images (werden durch select_os_version gesetzt)
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

  # pveversion gibt z.B. aus: "pve-manager/8.2.4/..."
  # Robuste Extraktion mit Fallback
  local pve_raw
  pve_raw=$(pveversion 2>/dev/null | head -1 || true)
  local PVE_VERSION=""
  local PVE_MAJOR=0

  if [[ "$pve_raw" =~ pve-manager/([0-9]+)\.([0-9]+) ]]; then
    PVE_MAJOR="${BASH_REMATCH[1]}"
    PVE_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  else
    # Fallback: versuche anders zu parsen
    PVE_VERSION=$(echo "$pve_raw" | grep -oP '\d+\.\d+' | head -1 || true)
    PVE_MAJOR=$(echo "$PVE_VERSION" | cut -d'.' -f1 || echo "0")
  fi

  if [[ -z "$PVE_VERSION" ]]; then
    msg_warn "Proxmox-Version konnte nicht ermittelt werden – fahre trotzdem fort."
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
  read -rp " Auswahl [1-4]: " MODE
  MODE="${MODE:-}"

  case "$MODE" in
    1) mode_install ;;
    2) mode_update ;;
    3) mode_backup ;;
    4) echo -e "\n Auf Wiedersehen!\n"; exit 0 ;;
    *) msg_warn "Ungültige Auswahl – bitte 1, 2, 3 oder 4 eingeben."; select_mode ;;
  esac
}

# ─── Storage-Auswahl ──────────────────────────────────────────────────────────
select_storage() {
  local content_type="${1:-images}"
  local -a STORAGES=()

  while IFS= read -r line; do
    [[ -n "$line" ]] && STORAGES+=("$line")
  done < <(pvesm status --content "$content_type" 2>/dev/null | awk 'NR>1 && $2=="active" {print $1}' || true)

  if [[ ${#STORAGES[@]} -eq 0 ]]; then
    msg_error "Kein aktiver Storage für '$content_type' gefunden!"
  elif [[ ${#STORAGES[@]} -eq 1 ]]; then
    STORAGE="${STORAGES[0]}"
    msg_ok "Storage: ${STORAGE}"
  else
    echo -e "\n ${YW}Verfügbare Storages:${CL}"
    local i=1
    for s in "${STORAGES[@]}"; do
      echo -e "  ${BOLD}${i})${CL} ${s}"
      ((i++))
    done
    echo ""
    local choice
    read -rp " Auswahl [1-${#STORAGES[@]}]: " choice
    choice="${choice:-1}"
    # Validierung
    if [[ "$choice" -ge 1 && "$choice" -le ${#STORAGES[@]} ]] 2>/dev/null; then
      STORAGE="${STORAGES[$((choice-1))]}"
    else
      STORAGE="${STORAGES[0]}"
    fi
    msg_ok "Storage gewählt: ${STORAGE}"
  fi
}

# ─── OS-Version auswählen ─────────────────────────────────────────────────────
select_os_version() {
  echo ""
  echo -e " ${BOLD}Betriebssystem wählen:${CL}"
  echo ""
  echo -e "  ${BOLD}1)${CL} ${GN}Debian 12 (Bookworm)${CL}  ${GN}← Empfohlen${CL}"
  echo -e "     ${DIM}Offiziell unterstützt von Tactical RMM${CL}"
  echo ""
  echo -e "  ${BOLD}2)${CL} ${YW}Debian 13 (Trixie)${CL}   ${YW}⚠ Experimentell${CL}"
  echo -e "     ${DIM}Noch NICHT offiziell von Tactical RMM unterstützt.${CL}"
  echo -e "     ${DIM}Python 3.13 / PostgreSQL 17 können Probleme verursachen.${CL}"
  echo -e "     ${DIM}Nur für Tests – nicht für Produktion empfohlen!${CL}"
  echo ""
  read -rp " Auswahl [1/2, Enter = 1]: " os_choice
  os_choice="${os_choice:-1}"

  case "$os_choice" in
    2)
      DEBIAN_VERSION="13"
      DEBIAN_CODENAME="trixie"
      DEBIAN_IMAGE="debian-13-genericcloud-amd64.qcow2"
      DEBIAN_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
      echo ""
      echo -e " ${RD}${BOLD}ACHTUNG:${CL} ${YW}Debian 13 (Trixie) ist von Tactical RMM${CL}"
      echo -e " ${YW}offiziell NICHT unterstützt. Das TRMM-Installationsscript${CL}"
      echo -e " ${YW}kann fehlschlagen. Nur auf eigene Gefahr verwenden!${CL}"
      echo ""
      read -rp " Wirklich Debian 13 verwenden? [j/N]: " confirm13
      confirm13="${confirm13:-N}"
      if [[ "${confirm13,,}" != "j" ]]; then
        msg_warn "Zurück zu Debian 12."
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
  echo ""

  # OS-Version
  select_os_version

  # VM-ID
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
  read -rp " ${YW}VM-ID${CL} [${next_id}]: " input
  VMID="${input:-$next_id}"

  # Hostname
  read -rp " ${YW}Hostname${CL} [${HOSTNAME}]: " input
  HOSTNAME="${input:-$HOSTNAME}"

  # CPU
  read -rp " ${YW}CPU-Kerne${CL} [${CORES}]: " input
  CORES="${input:-$CORES}"

  # RAM
  read -rp " ${YW}RAM in MB${CL} [${RAM}]: " input
  RAM="${input:-$RAM}"
  if [[ "$RAM" -lt 4096 ]] 2>/dev/null; then
    msg_warn "Mindestens 4096 MB empfohlen! TRMM kann mit weniger instabil werden."
    read -rp " Trotzdem fortfahren? [j/N]: " c
    c="${c:-N}"
    [[ "${c,,}" != "j" ]] && msg_error "Abgebrochen."
  fi

  # Disk
  read -rp " ${YW}Disk in GB${CL} [${DISK}]: " input
  DISK="${input:-$DISK}"

  # Bridge
  read -rp " ${YW}Netzwerk-Bridge${CL} [${BRIDGE}]: " input
  BRIDGE="${input:-$BRIDGE}"

  # VLAN (optional – darf leer bleiben)
  read -rp " ${YW}VLAN-Tag${CL} (leer = keiner): " input
  VLAN="${input:-}"

  # Storage
  select_storage "images"

  # Autostart
  read -rp " ${YW}VM nach Erstellung starten?${CL} [J/n]: " input
  input="${input:-J}"
  [[ "${input,,}" == "n" ]] && START_VM="no" || START_VM="yes"

  # Zusammenfassung
  echo ""
  divider
  echo -e " ${BOLD}Zusammenfassung${CL}"
  divider
  printf "  %-16s ${BOLD}%s${CL}\n"    "VM-ID:"     "$VMID"
  printf "  %-16s ${BOLD}%s${CL}\n"    "OS:"        "Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
  printf "  %-16s ${BOLD}%s${CL}\n"    "Hostname:"  "$HOSTNAME"
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
  read -rp " Jetzt erstellen? [J/n]: " confirm
  confirm="${confirm:-J}"
  [[ "${confirm,,}" == "n" ]] && msg_error "Abgebrochen."

  _do_install
}

_do_install() {
  # Passwort generieren
  TACTICAL_PASS=$(tr -dc 'A-Za-z0-9@#%^' </dev/urandom | head -c 20)
  local hashed_pw
  hashed_pw=$(echo "$TACTICAL_PASS" | openssl passwd -6 -stdin)

  # Cloud-Init User-Data schreiben
  # VLAN-Zeile im net0-Argument nur setzen wenn VLAN nicht leer
  local net0_arg="virtio,bridge=${BRIDGE}"
  [[ -n "$VLAN" ]] && net0_arg="virtio,bridge=${BRIDGE},tag=${VLAN}"

  cat > "$TEMP_DIR/user-data.yml" <<CLOUDINIT
#cloud-config
hostname: ${HOSTNAME}
fqdn: ${HOSTNAME}
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

  # Debian Cloud-Image laden
  msg_info "Lade Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME}) Cloud-Image"
  wget -q --show-progress -O "$TEMP_DIR/$DEBIAN_IMAGE" "$DEBIAN_URL" \
    || msg_error "Download fehlgeschlagen!"
  msg_ok "Debian ${DEBIAN_VERSION} Cloud-Image geladen"

  # VM erstellen
  msg_info "Erstelle VM ${VMID}"
  qm create "$VMID" \
    --name "$HOSTNAME" \
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

  # Disk importieren und konfigurieren
  msg_info "Importiere Disk nach ${STORAGE}"
  qm importdisk "$VMID" "$TEMP_DIR/$DEBIAN_IMAGE" "$STORAGE" --format qcow2 >/dev/null 2>&1
  local disk_ref
  disk_ref=$(qm config "$VMID" | grep "^unused0:" | awk '{print $2}')
  qm set "$VMID" --scsi0 "${disk_ref},discard=on,ssd=1,cache=writethrough"
  qm disk resize "$VMID" scsi0 "${DISK}G" >/dev/null 2>&1
  qm set "$VMID" --boot order=scsi0
  msg_ok "Disk: ${DISK}GB auf ${STORAGE}"

  # Cloud-Init konfigurieren
  msg_info "Konfiguriere Cloud-Init"
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
  qm set "$VMID" --ipconfig0 ip=dhcp
  qm set "$VMID" --ciuser tactical
  qm set "$VMID" --cipassword "$TACTICAL_PASS"

  # Custom user-data via Snippets (optional, kein Fehler wenn nicht verfügbar)
  local snippets_path=""
  snippets_path=$(pvesm path "$STORAGE" 2>/dev/null || true)
  if [[ -n "$snippets_path" ]] && pvesm status "$STORAGE" 2>/dev/null | grep -q "snippets"; then
    mkdir -p "${snippets_path}/snippets"
    cp "$TEMP_DIR/user-data.yml" "${snippets_path}/snippets/trmm-${VMID}-userdata.yml"
    qm set "$VMID" --cicustom "user=${STORAGE}:snippets/trmm-${VMID}-userdata.yml" 2>/dev/null || true
    msg_ok "Cloud-Init user-data installiert (Snippets)"
  else
    msg_ok "Cloud-Init konfiguriert (Basis)"
  fi

  # VM starten
  if [[ "$START_VM" == "yes" ]]; then
    msg_info "Starte VM ${VMID}"
    qm start "$VMID"
    msg_ok "VM ${VMID} läuft"
  fi

  # Abschluss-Ausgabe
  echo ""
  divider
  echo -e " ${GN}${BOLD}✓ VM erfolgreich erstellt!${CL}"
  divider
  echo ""
  printf "  %-16s ${BOLD}%s${CL}\n" "VM-ID:"    "$VMID"
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

  # TRMM-VMs suchen
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

  read -rp " ${YW}VM-ID der TRMM-VM${CL}: " TARGET_VMID
  TARGET_VMID="${TARGET_VMID:-}"
  [[ -z "$TARGET_VMID" ]] && msg_error "Keine VM-ID eingegeben."

  # VM-Status prüfen
  local vm_status
  vm_status=$(qm status "$TARGET_VMID" 2>/dev/null | awk '{print $2}' || echo "unknown")
  if [[ "$vm_status" != "running" ]]; then
    msg_warn "VM ${TARGET_VMID} läuft nicht (Status: ${vm_status})"
    read -rp " VM jetzt starten? [J/n]: " s
    s="${s:-J}"
    if [[ "${s,,}" != "n" ]]; then
      msg_info "Starte VM ${TARGET_VMID}"
      qm start "$TARGET_VMID"
      sleep 15
      msg_ok "VM gestartet"
    else
      msg_error "Abgebrochen."
    fi
  fi

  # IP ermitteln via Guest Agent
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
    read -rp " VM-IP manuell eingeben: " VM_IP
    VM_IP="${VM_IP:-}"
    [[ -z "$VM_IP" ]] && msg_error "Keine IP eingegeben."
  fi
  msg_ok "VM-IP: ${VM_IP}"

  read -rp " ${YW}SSH-User${CL} [tactical]: " SSH_USER
  SSH_USER="${SSH_USER:-tactical}"

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

  read -rp " ${YW}VM-ID der TRMM-VM${CL}: " TARGET_VMID
  TARGET_VMID="${TARGET_VMID:-}"
  [[ -z "$TARGET_VMID" ]] && msg_error "Keine VM-ID eingegeben."

  local ts
  ts=$(date +%Y%m%d_%H%M%S)
  local snap_name="trmm-bkp-${ts}"

  echo ""
  echo -e " ${INFO} Snapshot-Name: ${BOLD}${snap_name}${CL}"
  echo ""
  read -rp " Backup jetzt starten? [J/n]: " confirm
  confirm="${confirm:-J}"
  [[ "${confirm,,}" == "n" ]] && msg_error "Abgebrochen."

  # Proxmox VM-Snapshot
  msg_info "Erstelle Proxmox VM-Snapshot"
  if qm snapshot "$TARGET_VMID" "$snap_name" \
      --description "Tactical RMM Backup ${ts}" 2>/dev/null; then
    msg_ok "Snapshot erstellt: ${snap_name}"
  else
    msg_warn "Snapshot fehlgeschlagen (Storage unterstützt kein Snapshots?). Weiter mit App-Backup."
  fi

  # IP ermitteln
  msg_info "Ermittle VM-IP"
  local VM_IP=""
  VM_IP=$(qm guest exec "$TARGET_VMID" -- \
    bash -c "ip -4 addr show | grep 'inet ' | grep -v 127 | awk '{print \$2}' | cut -d/ -f1 | head -1" \
    2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data','').strip())" \
    2>/dev/null || true)

  if [[ -n "$VM_IP" ]]; then
    msg_ok "VM-IP: ${VM_IP}"
    read -rp " ${YW}SSH-User${CL} [tactical]: " SSH_USER
    SSH_USER="${SSH_USER:-tactical}"

    echo -e " ${INFO} Starte App-Backup auf der VM..."
    ssh -o StrictHostKeyChecking=accept-new -t "${SSH_USER}@${VM_IP}" \
      "sudo trmm-backup --auto" 2>/dev/null \
      || msg_warn "App-Backup fehlgeschlagen (trmm-backup installiert?)"
  else
    msg_warn "IP nicht ermittelbar – App-Backup übersprungen."
  fi

  # Snapshots anzeigen
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
