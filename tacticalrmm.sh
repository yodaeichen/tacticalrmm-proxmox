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

set -euo pipefail

# ─── Farben & Symbole ─────────────────────────────────────────────────────────
YW="\033[33m"; BL="\033[36m"; RD="\033[01;31m"
GN="\033[1;92m"; CL="\033[m"; BOLD="\033[1m"; DIM="\033[2m"
BFR="\\r\\033[K"; HOLD=" "
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"; INFO="${BL}ℹ${CL}"; WARN="${YW}⚠${CL}"

# ─── GitHub-Basis-URL (wird beim Veröffentlichen angepasst) ───────────────────
GITHUB_RAW="https://raw.githubusercontent.com/DEIN-GITHUB-USER/tacticalrmm-proxmox/main"

# ─── Hilfsfunktionen ──────────────────────────────────────────────────────────
msg_info()  { local msg="$1"; echo -ne " ${HOLD} ${YW}${msg}...${CL}"; }
msg_ok()    { local msg="$1"; echo -e "${BFR} ${CM} ${GN}${msg}${CL}"; }
msg_error() { local msg="$1"; echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"; exit 1; }
msg_warn()  { local msg="$1"; echo -e " ${WARN} ${YW}${msg}${CL}"; }
msg_info2() { local msg="$1"; echo -e " ${INFO} ${BL}${msg}${CL}"; }
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
  PVE_VERSION=$(pveversion | grep "pve-manager" | awk '{print $2}' | cut -d'/' -f2 | cut -d'-' -f1)
  PVE_MAJOR=$(echo "$PVE_VERSION" | cut -d'.' -f1)
  if [[ $PVE_MAJOR -lt 7 ]]; then
    msg_error "Proxmox VE 7.0+ erforderlich (aktuell: $PVE_VERSION)"
  fi
  msg_ok "Proxmox VE $PVE_VERSION"
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
  echo -e "  ${BOLD}3)${CL} ${YW}Backup erstellen${CL}            – Manuelles Backup einer TRMM-VM"
  echo -e "  ${BOLD}4)${CL} ${DIM}Beenden${CL}"
  echo ""
  read -rp " Auswahl [1-4]: " MODE

  case "$MODE" in
    1) mode_install ;;
    2) mode_update ;;
    3) mode_backup ;;
    4) echo -e "\n Auf Wiedersehen!\n"; exit 0 ;;
    *) msg_warn "Ungültige Auswahl."; select_mode ;;
  esac
}

# =============================================================================
#  MODUS 1: INSTALLATION
# =============================================================================

VMID=""; HOSTNAME="tacticalrmm"; CORES="2"; RAM="4096"
DISK="50"; BRIDGE="vmbr0"; VLAN=""; START_VM="yes"; STORAGE=""
DEBIAN_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
DEBIAN_IMAGE="debian-12-genericcloud-amd64.qcow2"
TEMP_DIR=$(mktemp -d)
trap "rm -rf '$TEMP_DIR'" EXIT

select_storage() {
  local content_type="${1:-images}"
  local -a STORAGES=()
  while IFS= read -r line; do
    STORAGES+=("$line")
  done < <(pvesm status --content "$content_type" 2>/dev/null | awk 'NR>1 && $2=="active" {print $1}')

  if [[ ${#STORAGES[@]} -eq 0 ]]; then
    msg_error "Kein aktiver Storage für '$content_type' gefunden!"
  elif [[ ${#STORAGES[@]} -eq 1 ]]; then
    STORAGE="${STORAGES[0]}"
    msg_ok "Storage: ${STORAGE}"
  else
    echo -e "\n ${YW}Verfügbare Storages:${CL}"
    PS3=" Auswahl: "
    select s in "${STORAGES[@]}"; do
      [[ -n "$s" ]] && { STORAGE="$s"; break; }
    done
    msg_ok "Storage gewählt: ${STORAGE}"
  fi
}

mode_install() {
  echo ""
  divider
  echo -e " ${BOLD}${GN}NEUE VM INSTALLIEREN${CL}"
  divider
  echo -e " ${DIM}Erstellt eine Debian 12 VM und bereitet die Installation von Tactical RMM vor.${CL}"
  echo -e " ${WARN} Tactical RMM benötigt 3 DNS A-Records (rmm/api/mesh) auf deine Domain!"
  echo ""

  # VM-ID
  local next_id; next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
  read -rp " ${YW}VM-ID${CL} [${next_id}]: " input; VMID="${input:-$next_id}"

  # Hostname
  read -rp " ${YW}Hostname${CL} [${HOSTNAME}]: " input; HOSTNAME="${input:-$HOSTNAME}"

  # CPU
  read -rp " ${YW}CPU-Kerne${CL} [${CORES}]: " input; CORES="${input:-$CORES}"

  # RAM
  read -rp " ${YW}RAM in MB${CL} [${RAM}]: " input; RAM="${input:-$RAM}"
  if [[ "$RAM" -lt 4096 ]]; then
    msg_warn "Mindestens 4096 MB empfohlen! TRMM kann mit weniger instabil werden."
    read -rp " Trotzdem fortfahren? [j/N]: " c; [[ "${c,,}" != "j" ]] && msg_error "Abgebrochen."
  fi

  # Disk
  read -rp " ${YW}Disk in GB${CL} [${DISK}]: " input; DISK="${input:-$DISK}"

  # Bridge
  read -rp " ${YW}Netzwerk-Bridge${CL} [${BRIDGE}]: " input; BRIDGE="${input:-$BRIDGE}"

  # VLAN
  read -rp " ${YW}VLAN-Tag${CL} (leer = keiner): " input; VLAN="${input:-}"

  # Storage
  select_storage "images"

  # Autostart
  read -rp " ${YW}VM nach Erstellung starten?${CL} [J/n]: " input
  [[ "${input,,}" == "n" ]] && START_VM="no"

  # Zusammenfassung
  echo ""
  divider
  echo -e " ${BOLD}Zusammenfassung${CL}"
  divider
  printf "  %-16s ${BOLD}%s${CL}\n" "VM-ID:"     "$VMID"
  printf "  %-16s ${BOLD}%s${CL}\n" "Hostname:"  "$HOSTNAME"
  printf "  %-16s ${BOLD}%s${CL}\n" "CPU-Kerne:" "$CORES"
  printf "  %-16s ${BOLD}%s MB${CL}\n" "RAM:"     "$RAM"
  printf "  %-16s ${BOLD}%s GB${CL}\n" "Disk:"    "$DISK"
  printf "  %-16s ${BOLD}%s${CL}\n" "Bridge:"    "$BRIDGE"
  [[ -n "$VLAN" ]] && printf "  %-16s ${BOLD}%s${CL}\n" "VLAN:" "$VLAN"
  printf "  %-16s ${BOLD}%s${CL}\n" "Storage:"   "$STORAGE"
  printf "  %-16s ${BOLD}%s${CL}\n" "Autostart:" "$START_VM"
  echo ""
  read -rp " Jetzt erstellen? [J/n]: " confirm
  [[ "${confirm,,}" == "n" ]] && msg_error "Abgebrochen."

  _do_install
}

_do_install() {
  # Cloud-Init vorbereiten
  TACTICAL_PASS=$(tr -dc 'A-Za-z0-9@#%^' </dev/urandom | head -c 20)
  local hashed_pw; hashed_pw=$(echo "$TACTICAL_PASS" | openssl passwd -6 -stdin)

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
  - printf '\n# Tactical RMM Backup (täglich 02:00)\n0 2 * * * tactical /usr/local/bin/trmm-backup --auto >> /var/log/trmm-backup.log 2>&1\n' >> /etc/crontab
  - |
    cat > /etc/motd << 'MOTD'

    ╔══════════════════════════════════════════════════════════════╗
    ║           TACTICAL RMM – Bereit zur Installation             ║
    ╠══════════════════════════════════════════════════════════════╣
    ║                                                              ║
    ║  Schritt 1: DNS A-Records erstellen (alle → diese VM-IP)    ║
    ║    rmm.deine-domain.de                                       ║
    ║    api.deine-domain.de                                       ║
    ║    mesh.deine-domain.de                                      ║
    ║                                                              ║
    ║  Schritt 2: Als tactical-User einloggen und starten:         ║
    ║    su - tactical                                             ║
    ║    ./install.sh                                              ║
    ║                                                              ║
    ║  Nützliche Befehle nach der Installation:                    ║
    ║    trmm-update   – Tactical RMM aktualisieren                ║
    ║    trmm-backup   – Manuelles Backup erstellen                ║
    ║                                                              ║
    ║  Doku: https://docs.tacticalrmm.com/install_server/          ║
    ╚══════════════════════════════════════════════════════════════╝

MOTD

power_state:
  mode: reboot
  delay: "+1"
  message: "Initialisierung abgeschlossen – Neustart..."
CLOUDINIT

  # Debian Cloud-Image laden
  msg_info "Lade Debian 12 Cloud-Image"
  wget -q --show-progress -O "$TEMP_DIR/$DEBIAN_IMAGE" "$DEBIAN_URL" \
    || msg_error "Download fehlgeschlagen!"
  msg_ok "Debian 12 Cloud-Image geladen"

  # VM erstellen
  msg_info "Erstelle VM ${VMID}"
  qm create "$VMID" \
    --name "$HOSTNAME" \
    --ostype l26 \
    --memory "$RAM" \
    --balloon 0 \
    --cores "$CORES" \
    --cpu host \
    --net0 "virtio,bridge=${BRIDGE}${VLAN:+,tag=$VLAN}" \
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

  # Disk importieren
  msg_info "Importiere Disk nach ${STORAGE}"
  qm importdisk "$VMID" "$TEMP_DIR/$DEBIAN_IMAGE" "$STORAGE" --format qcow2 >/dev/null 2>&1
  local disk_ref; disk_ref=$(qm config "$VMID" | grep "^unused0:" | awk '{print $2}')
  qm set "$VMID" --scsi0 "${disk_ref},discard=on,ssd=1,cache=writethrough"
  qm disk resize "$VMID" scsi0 "${DISK}G" >/dev/null 2>&1
  qm set "$VMID" --boot order=scsi0
  msg_ok "Disk: ${DISK}GB auf ${STORAGE}"

  # Cloud-Init
  msg_info "Konfiguriere Cloud-Init"
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
  qm set "$VMID" --ipconfig0 ip=dhcp
  qm set "$VMID" --ciuser tactical
  qm set "$VMID" --cipassword "$TACTICAL_PASS"

  # Snippets für custom user-data versuchen
  local snippets_path; snippets_path=$(pvesm path "$STORAGE" 2>/dev/null || true)
  if [[ -n "$snippets_path" ]] && pvesm status "$STORAGE" 2>/dev/null | grep -q "snippets"; then
    mkdir -p "${snippets_path}/snippets"
    cp "$TEMP_DIR/user-data.yml" "${snippets_path}/snippets/trmm-${VMID}-userdata.yml"
    qm set "$VMID" --cicustom "user=${STORAGE}:snippets/trmm-${VMID}-userdata.yml" 2>/dev/null || true
    msg_ok "Cloud-Init user-data installiert"
  else
    msg_ok "Cloud-Init konfiguriert (ohne Snippets)"
  fi

  # Starten
  if [[ "$START_VM" == "yes" ]]; then
    msg_info "Starte VM ${VMID}"
    qm start "$VMID"
    msg_ok "VM ${VMID} läuft"
  fi

  # Abschluss
  echo ""
  divider
  echo -e " ${GN}${BOLD}✓ VM erfolgreich erstellt!${CL}"
  divider
  echo ""
  printf "  %-16s ${BOLD}%s${CL}\n" "VM-ID:"       "$VMID"
  printf "  %-16s ${BOLD}%s${CL}\n" "SSH-User:"    "tactical"
  printf "  %-16s ${BOLD}${RD}%s${CL}  ${YW}← JETZT NOTIEREN!${CL}\n" "SSH-Passwort:" "$TACTICAL_PASS"
  echo ""
  echo -e " ${YW}Nächste Schritte:${CL}"
  echo -e "  1. DNS A-Records erstellen: ${BL}rmm / api / mesh${CL} → VM-IP"
  echo -e "  2. SSH: ${BL}ssh tactical@<VM-IP>${CL}"
  echo -e "  3. Installation: ${BL}./install.sh${CL}"
  echo ""
  echo -e " ${DIM}Automatisch installierte Hilfstools in der VM:${CL}"
  echo -e "  ${BL}trmm-update${CL}  – TRMM aktualisieren"
  echo -e "  ${BL}trmm-backup${CL}  – Manuelles Backup"
  echo -e "  ${DIM}Automatisches Backup täglich 02:00 → /opt/trmm-backups/${CL}"
  echo ""
  divider
  echo ""
}

# =============================================================================
#  MODUS 2: UPDATE (läuft auf dem Proxmox-Host, SSH zur VM)
# =============================================================================

mode_update() {
  echo ""
  divider
  echo -e " ${BOLD}${BL}TACTICAL RMM AKTUALISIEREN${CL}"
  divider
  echo -e " ${DIM}Führt das offizielle Update-Script auf der TRMM-VM aus.${CL}"
  echo ""

  # Welche VM soll aktualisiert werden?
  local -a TRMM_VMS=()
  while IFS= read -r line; do
    TRMM_VMS+=("$line")
  done < <(qm list 2>/dev/null | awk 'NR>1 {print $1, $2}' | grep -i "tactical\|trmm" || true)

  if [[ ${#TRMM_VMS[@]} -eq 0 ]]; then
    msg_warn "Keine VM mit 'tactical' oder 'trmm' im Namen gefunden."
    echo -e " Alle laufenden VMs:"
    qm list 2>/dev/null | awk 'NR>1 && $3=="running" {printf "  %-6s %s\n", $1, $2}'
    echo ""
  else
    echo -e " ${GN}Gefundene TRMM-VMs:${CL}"
    for vm in "${TRMM_VMS[@]}"; do echo "  $vm"; done
    echo ""
  fi

  read -rp " ${YW}VM-ID der TRMM-VM${CL}: " TARGET_VMID
  [[ -z "$TARGET_VMID" ]] && msg_error "Keine VM-ID eingegeben."

  # Status prüfen
  local vm_status; vm_status=$(qm status "$TARGET_VMID" 2>/dev/null | awk '{print $2}')
  if [[ "$vm_status" != "running" ]]; then
    msg_warn "VM ${TARGET_VMID} ist nicht gestartet (Status: ${vm_status})"
    read -rp " VM jetzt starten? [J/n]: " s
    if [[ "${s,,}" != "n" ]]; then
      msg_info "Starte VM ${TARGET_VMID}"
      qm start "$TARGET_VMID"
      sleep 15
      msg_ok "VM gestartet"
    else
      msg_error "Abgebrochen."
    fi
  fi

  # IP der VM ermitteln
  msg_info "Ermittle VM-IP (warte auf Guest Agent)"
  local VM_IP=""
  for i in {1..12}; do
    VM_IP=$(qm guest exec "$TARGET_VMID" -- bash -c \
      "ip -4 addr show | grep 'inet ' | grep -v 127 | awk '{print \$2}' | cut -d/ -f1 | head -1" \
      2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data','').strip())" 2>/dev/null || true)
    [[ -n "$VM_IP" ]] && break
    sleep 5
  done

  if [[ -z "$VM_IP" ]]; then
    msg_warn "IP nicht automatisch ermittelbar."
    read -rp " Bitte VM-IP manuell eingeben: " VM_IP
    [[ -z "$VM_IP" ]] && msg_error "Keine IP eingegeben."
  fi
  msg_ok "VM-IP: ${VM_IP}"

  # SSH-Verbindung testen und Update ausführen
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
#  MODUS 3: BACKUP (läuft auf dem Proxmox-Host)
# =============================================================================

mode_backup() {
  echo ""
  divider
  echo -e " ${BOLD}${YW}BACKUP ERSTELLEN${CL}"
  divider
  echo -e " ${DIM}Erstellt ein Proxmox-VM-Snapshot UND ein TRMM-Applikations-Backup.${CL}"
  echo ""

  # VM auswählen
  echo -e " Laufende VMs:"
  qm list 2>/dev/null | awk 'NR>1 && $3=="running" {printf "  %-6s %s\n", $1, $2}'
  echo ""
  read -rp " ${YW}VM-ID der TRMM-VM${CL}: " TARGET_VMID
  [[ -z "$TARGET_VMID" ]] && msg_error "Keine VM-ID eingegeben."

  local vm_name; vm_name=$(qm config "$TARGET_VMID" 2>/dev/null | grep "^name:" | awk '{print $2}' || echo "vm-${TARGET_VMID}")
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  local snap_name="trmm-backup-${ts}"

  echo ""
  echo -e " ${INFO} Ziel: ${BL}Proxmox-Snapshot${CL} + ${BL}Applikations-Backup in der VM${CL}"
  echo -e " ${INFO} Snapshot-Name: ${BOLD}${snap_name}${CL}"
  echo ""
  read -rp " Backup jetzt starten? [J/n]: " confirm
  [[ "${confirm,,}" == "n" ]] && msg_error "Abgebrochen."

  # 1. Proxmox VM-Snapshot
  msg_info "Erstelle Proxmox VM-Snapshot '${snap_name}'"
  if qm snapshot "$TARGET_VMID" "$snap_name" --description "Tactical RMM Backup ${ts}" 2>/dev/null; then
    msg_ok "Proxmox Snapshot erstellt: ${snap_name}"
  else
    msg_warn "Snapshot fehlgeschlagen (kein ZFS/LVM-Thin?). Weiter mit App-Backup."
  fi

  # 2. Applikations-Backup via SSH
  msg_info "Ermittle VM-IP"
  local VM_IP=""
  VM_IP=$(qm guest exec "$TARGET_VMID" -- bash -c \
    "ip -4 addr show | grep 'inet ' | grep -v 127 | awk '{print \$2}' | cut -d/ -f1 | head -1" \
    2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data','').strip())" 2>/dev/null || true)

  if [[ -n "$VM_IP" ]]; then
    msg_ok "VM-IP: ${VM_IP}"
    read -rp " ${YW}SSH-User${CL} [tactical]: " SSH_USER
    SSH_USER="${SSH_USER:-tactical}"

    echo -e " ${INFO} Starte Applikations-Backup auf der VM..."
    ssh -o StrictHostKeyChecking=accept-new -t "${SSH_USER}@${VM_IP}" \
      "sudo trmm-backup --auto" 2>/dev/null \
      || msg_warn "App-Backup per SSH fehlgeschlagen (trmm-backup nicht installiert?)"
  else
    msg_warn "IP nicht ermittelbar – überspringe App-Backup."
  fi

  # Vorhandene Snapshots anzeigen
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
