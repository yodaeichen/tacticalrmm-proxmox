# Proxmox VM Installer für Tactical RMM

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Proxmox VE](https://img.shields.io/badge/Proxmox_VE-7%2B-orange)](https://www.proxmox.com)
[![Tactical RMM](https://img.shields.io/badge/Tactical_RMM-latest-blue)](https://tacticalrmm.com)

> **Disclaimer:** Dieses Script ist ein unabhängiges Community-Projekt und steht in keiner
> Verbindung zu AmidaWare LLC. „Tactical RMM" ist eine eingetragene Marke von AmidaWare LLC.
> Das Script lädt die offizielle Tactical RMM Software herunter und installiert sie gemäß der
> öffentlichen Installationsdokumentation unter [docs.tacticalrmm.com](https://docs.tacticalrmm.com)
> – ohne sie zu verändern.

Automatisiertes Community-Hilfscript zur Installation von [Tactical RMM](https://tacticalrmm.com)
auf Proxmox VE – im Stil der [Proxmox Community Helper Scripts](https://community-scripts.github.io/ProxmoxVE/).

**Funktionen:**
- 🖥️ **VM installieren** – Debian 12 VM mit Cloud-Init, UEFI/Q35, fertig für Tactical RMM
- 🔄 **Aktualisieren** – Offizielles Update-Script mit automatischem Pre-Update-Backup
- 💾 **Backup** – Vollständiges App-Backup + täglicher Cron-Job (02:00 Uhr)

---

## ⚠️ Wichtig: VM, kein LXC!

Tactical RMM wird offiziell **ausschließlich auf VMs** unterstützt.  
LXC Container sind laut [offizieller Dokumentation](https://docs.tacticalrmm.com/unsupported_guidelines/) **nicht unterstützt**.  
Dieses Script erstellt daher immer eine vollwertige Debian 12 VM.

---

## Schnellstart

Auf dem **Proxmox-Host** als `root` ausführen:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/DEIN-GITHUB-USER/tacticalrmm-proxmox/main/tacticalrmm.sh)"
```

Das Script öffnet ein interaktives Menü mit allen Funktionen.

---

## Voraussetzungen

| Anforderung | Detail |
|---|---|
| Proxmox VE | 7.0 oder höher |
| RAM | Mindestens 4 GB für die VM |
| Disk | Mindestens 50 GB |
| DNS | 3 A-Records: `rmm`, `api`, `mesh` → VM-IP |
| Internet | Zugang vom Proxmox-Host (Image-Download) |

---

## Dateistruktur

```
tacticalrmm-proxmox/
├── tacticalrmm.sh          ← Haupt-Script (läuft auf dem Proxmox-Host)
├── scripts/
│   ├── trmm-update.sh      ← Update-Hilfscript (wird in der VM installiert)
│   └── trmm-backup.sh      ← Backup-Hilfscript (wird in der VM installiert)
├── README.md
├── GITHUB-SETUP.md         ← Anleitung zur Veröffentlichung
└── LICENSE
```

---

## Funktionen im Detail

### 1. VM installieren

Erstellt eine vollständige Debian 12 VM mit:
- UEFI/OVMF + Q35-Chipsatz
- VirtIO-SCSI mit Discard/SSD-Optimierung
- QEMU Guest Agent
- Cloud-Init (User `tactical`, UFW-Firewall, Hilfsscripts)
- Automatisches Backup via Cron täglich um 02:00 Uhr

**Nach der VM-Erstellung:**
```bash
# 1. DNS A-Records erstellen (alle → VM-IP)
#    rmm.deine-domain.de
#    api.deine-domain.de
#    mesh.deine-domain.de

# 2. SSH-Login
ssh tactical@<VM-IP>

# 3. Offizielles TRMM-Installationsscript starten
./install.sh
```

### 2. Tactical RMM aktualisieren

Im Menü „Aktualisieren" wählen – oder direkt in der VM:

```bash
sudo trmm-update
```

Das Script:
1. Erstellt automatisch ein Pre-Update-Backup (DB + Konfiguration)
2. Führt das offizielle TRMM-Update-Script von amidaware aus
3. Zeigt den Service-Status nach dem Update

### 3. Backup erstellen

```bash
sudo trmm-backup           # Interaktiv
sudo trmm-backup --auto    # Automatisch (Cron)
sudo trmm-backup --list    # Vorhandene Backups anzeigen
sudo trmm-backup --restore # Backup wiederherstellen
```

**Was gesichert wird:**
- PostgreSQL-Datenbank (komprimiert)
- Nginx-Konfiguration
- TRMM `local_settings.py`
- Let's Encrypt Zertifikate
- MeshCentral-Daten
- TRMM-API-Codebase (ohne virtualenv)

**Speicherort:** `/opt/trmm-backups/` in der VM  
**Retention:** 7 Backups (älteste werden automatisch gelöscht)

---

## Ressourcen

- [Offizielle Tactical RMM Dokumentation](https://docs.tacticalrmm.com)
- [Installationsanleitung](https://docs.tacticalrmm.com/install_server/)
- [GitHub amidaware/tacticalrmm](https://github.com/amidaware/tacticalrmm)
- [Tactical RMM Discord](https://discord.gg/upGTkWp)
- [Tactical RMM Lizenz](https://docs.tacticalrmm.com/license/)

---

## Lizenz dieses Scripts

MIT – siehe [LICENSE](LICENSE)

Dieses Script selbst steht unter der MIT-Lizenz. Die durch das Script installierte
Software (Tactical RMM) unterliegt der separaten
[Tactical RMM License Version 1.0](https://docs.tacticalrmm.com/license/) von AmidaWare LLC.
