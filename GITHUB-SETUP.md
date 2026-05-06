# GitHub Veröffentlichung – Schritt-für-Schritt

## Übersicht: Repository-Struktur

```
tacticalrmm-proxmox/          ← Repository-Name
├── tacticalrmm.sh            ← Haupt-Script (Proxmox-Host)
├── scripts/
│   ├── trmm-update.sh        ← In VM installiert via Cloud-Init
│   └── trmm-backup.sh        ← In VM installiert via Cloud-Init
├── README.md
├── GITHUB-SETUP.md           ← Diese Datei
└── LICENSE
```

---

## Schritt 1: GitHub Repository erstellen

1. Öffne https://github.com → oben rechts **+** → **New repository**
2. Einstellungen:
   - **Repository name:** `tacticalrmm-proxmox`
   - **Description:** `Community Script: Proxmox VM Installer für Tactical RMM – Install, Update & Backup`
   - **Public** ✅ ← Pflicht! Sonst funktionieren die raw.githubusercontent.com URLs nicht
   - **Add a README file:** NEIN (wir haben schon eine)
   - **Add .gitignore:** NEIN
   - **License:** NEIN (ist bereits enthalten)
3. **Create repository** klicken

---

## Schritt 2: Deinen GitHub-Username eintragen

**Das ist der wichtigste Schritt!** In zwei Dateien muss `DEIN-GITHUB-USER` ersetzt werden:

### In `tacticalrmm.sh` (ca. Zeile 18):
```bash
# Vorher:
GITHUB_RAW="https://raw.githubusercontent.com/DEIN-GITHUB-USER/tacticalrmm-proxmox/main"

# Nachher (Beispiel):
GITHUB_RAW="https://raw.githubusercontent.com/meinname/tacticalrmm-proxmox/main"
```

### In `README.md` (Schnellstart-Befehl):
```bash
# Vorher:
bash -c "$(wget -qLO - https://raw.githubusercontent.com/DEIN-GITHUB-USER/tacticalrmm-proxmox/main/tacticalrmm.sh)"

# Nachher (Beispiel):
bash -c "$(wget -qLO - https://raw.githubusercontent.com/meinname/tacticalrmm-proxmox/main/tacticalrmm.sh)"
```

---

## Schritt 3: Dateien hochladen

### Option A: Per Browser (einfachste Methode)

**Haupt-Script und README:**
1. Im Repository: **Add file** → **Upload files**
2. `tacticalrmm.sh`, `README.md`, `LICENSE`, `GITHUB-SETUP.md` hochladen
3. Commit message: `feat: initial release`
4. **Commit changes**

**scripts/-Ordner anlegen:**

GitHub kann keinen leeren Ordner erstellen. Trick: Dateiname mit Slash eingeben.

1. **Add file** → **Create new file**
2. Im Dateinamen-Feld eintippen: `scripts/trmm-update.sh`
   → GitHub erstellt den Ordner `scripts/` automatisch!
3. Inhalt von `trmm-update.sh` einfügen
4. Commit: `feat: add trmm-update script`
5. Wieder **Add file** → **Create new file**
6. Dateiname: `scripts/trmm-backup.sh` (GitHub ist jetzt schon im scripts/-Ordner)
7. Inhalt von `trmm-backup.sh` einfügen
8. Commit: `feat: add trmm-backup script`

### Option B: Per Git (Kommandozeile)

```bash
# Repository klonen
git clone https://github.com/DEIN-USER/tacticalrmm-proxmox.git
cd tacticalrmm-proxmox

# Dateien reinkopieren (Pfad anpassen!)
cp /pfad/zu/den/dateien/tacticalrmm.sh .
cp /pfad/zu/den/dateien/README.md .
cp /pfad/zu/den/dateien/LICENSE .
cp /pfad/zu/den/dateien/GITHUB-SETUP.md .
mkdir -p scripts
cp /pfad/zu/den/dateien/scripts/trmm-update.sh scripts/
cp /pfad/zu/den/dateien/scripts/trmm-backup.sh scripts/

# GitHub-Username ersetzen (DEIN-USER anpassen!)
sed -i 's/DEIN-GITHUB-USER/DEIN-USER/g' tacticalrmm.sh README.md

# Alles hochladen
git add .
git commit -m "feat: initial release – Proxmox VM installer for Tactical RMM"
git push origin main
```

---

## Schritt 4: URLs testen

Nach dem Upload diese URLs im Browser aufrufen – du musst den Script-Inhalt sehen:

```
https://raw.githubusercontent.com/DEIN-USER/tacticalrmm-proxmox/main/tacticalrmm.sh
https://raw.githubusercontent.com/DEIN-USER/tacticalrmm-proxmox/main/scripts/trmm-update.sh
https://raw.githubusercontent.com/DEIN-USER/tacticalrmm-proxmox/main/scripts/trmm-backup.sh
```

Wenn du den Script-Inhalt siehst → ✅ fertig!

---

## Schritt 5: Repository-Einstellungen (optional aber empfohlen)

In deinem Repository → rechts oben bei **About** auf das ⚙️ klicken:

- **Description:** `Community Script: Proxmox VM Installer für Tactical RMM`
- **Website:** `https://tacticalrmm.com`
- **Topics:** `proxmox` `tactical-rmm` `rmm` `bash` `homelab` `self-hosted` `debian`

Das macht das Repo über die GitHub-Suche auffindbar.

---

## Der fertige Aufruf-Befehl

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/DEIN-USER/tacticalrmm-proxmox/main/tacticalrmm.sh)"
```

---

## Häufige Fehler

| Problem | Lösung |
|---|---|
| `404` bei der Raw-URL | Repository ist noch **Private** → Settings → Danger Zone → Make public |
| Script lädt falsches Script | `DEIN-GITHUB-USER` wurde nicht ersetzt |
| `Permission denied` auf Proxmox | Script muss als `root` ausgeführt werden |
| `scripts/` Ordner fehlt | Beim Erstellen der Datei `scripts/trmm-update.sh` als Namen eingeben (mit Slash) |
| wget: unable to resolve | Kein DNS auf dem Proxmox-Host – Internetverbindung prüfen |
