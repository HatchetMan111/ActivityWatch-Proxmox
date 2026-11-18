# ⏱️ ActivityWatch – Proxmox-Installer

Ein-Klick-Installer für **[ActivityWatch](https://github.com/ActivityWatch/activitywatch)** –
den lokalen, datenschutzfreundlichen Time-Tracker – als **LXC-Container** auf
Proxmox VE, im Stil der Proxmox VE Community Scripts.

ActivityWatch zeichnet automatisch, welche Apps/Fenster/Browser-Tabs du nutzt
und wie lange (plus AFK-Erkennung). Alles läuft **vollständig lokal** – keine
Cloud, keine externen Dienste. Dieser Installer macht daraus einen
immer-laufenden **Zeit-Server auf dem Proxmox-Host**: REST-API + Web-UI im
LXC, tracked-Daten in SQLite im Container, Reboot-sicher per systemd.

## Installieren (Einzeiler auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ActivityWatch-Proxmox/main/install/activitywatch.sh)"
```

Am Ende steht da z. B.:

```
━━━ ⏱️  ActivityWatch ist bereit! ━━━

  ════════════════════════════════════════════════════════════
  🌐 Web-UI:      http://10.120.1.107:5600
  🔌 REST-API:    http://10.120.1.107:5600/api/0/info
  🐚 Terminal:    pct enter 205
  🔑 Root-PW:     **********
  📦 Version:     v0.14.3 (ActivityWatch v0.14.3)
  👀 AFK-Watcher: aktiv (headless unter Xvfb)
  💾 Daten:       /var/lib/activitywatch (im CT, überlebt Updates)
  🔧 Installer:   v1.0.0
  ════════════════════════════════════════════════════════════
```

## Optionen (hinter dem schließenden Anführungszeichen anhängen)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ActivityWatch-Proxmox/main/install/activitywatch.sh)" --id 205 --port 5600 --no-watcher
```

| Option | Default | Bedeutung |
|---|---|---|
| `--id ID` | nächste freie ab 200 | Container-ID |
| `--hostname NAME` | `activitywatch` | CT-Hostname |
| `--rootfs GB` | 4 | Disk |
| `--cores N` | 2 | vCPUs |
| `--memory MB` | 1024 | RAM |
| `--port PORT` | 5600 | API + Web-UI-Port |
| `--aw-version V` | neuestes Release | ActivityWatch-Version pinnen (z. B. `0.14.3`) |
| `--no-watcher` | – | AFK-Watcher nicht installieren (kein Xvfb) |
| `--ip / --gateway` | DHCP | statische IP, z. B. `--ip 192.168.1.50/24 --gateway 192.168.1.1` |
| `--sshkey PFAD` | – | Public-Key für ssh-Login als root |
| `--force` | – | vorhandenen CT gleichen Hostnames löschen + neu |
| `--update` | – | neuestes Release installieren (Daten bleiben!) |
| `--uninstall` | – | CT stoppen + löschen (**Daten gehen verloren**) |
| `--status` | – | Status von CT, Services, Version, Web-UI |
| `--debug` | – | vollständiges `bash -x`-Trace |

## Was im Container läuft

- **aw-server-rust** (offizielles Release-Binary v0.14.3, 38 MB): REST-API +
  SQLite + **eingebettete Web-UI** unter `http://[CT-IP]:5600` – kein extra
  Frontend, kein Rust-/Node-Build im Container. Der Installer lädt das
  offizielle
  [`activitywatch-vX-linux-x86_64-manylinux_2_28.zip`](https://github.com/ActivityWatch/activitywatch/releases)
  (~158 MB) und installiert daraus nur die headless-tauglichen Teile
  (siehe [app/README.md](app/README.md)).
- **aw-watcher-afk** (frozen Binary, optional via `--no-watcher`): AFK-Erkennung
  unter **Xvfb** – pynput braucht einen X-Server, im headless LXC springt Xvfb ein.
- systemd-Services `activitywatch.service` + `aw-watcher-afk.service`
  (`Restart=always`, `enable`), CT mit `onboot: 1` → **Reboot-sicher**.
- Daten: `/var/lib/activitywatch` (System-User-Home) – Updates ersetzen nur
  `/opt/activitywatch`, die Datenbank bleibt.

## Clients anbinden (echtes Tracking)

Im Server-CT gibt es keine Fenster/Eingaben – deshalb liefert der CT selbst
keine Fenster-/App-Events. So kommt echtes Tracking herein:

1. **Auf deinem Desktop** (PC/Laptop) ActivityWatch installieren
   (aw-qt + aw-watcher-window + aw-watcher-input) – dort wird trackt, was du
   wirklich machst.
2. **Synchronisieren in den LXC:** das Bundle enthält `aw-sync`. Auf dem Client
   in der Sync-Config den Server als Peer eintragen
   (`http://[CT-IP]:5600`), Datastores werden per REST-API abgeglichen –
   Details: [aw-sync-Doku](https://github.com/ActivityWatch/aw-server-rust#aw-sync).
   Alternativ direkt per REST-API Events posten (`POST /api/0/buckets/...`).
3. **Browser-Erweiterungen** (Chrome/Firefox „ActivityWatch Web UI extension“)
   tracken Tabs und senden an den konfigurierten Host – ebenfalls `[CT-IP]:5600`.

> ⚠️ Der AFK-Watcher im CT ist ein **Funktionstest der Pipeline**: unter Xvfb
> gibt es nie echte Eingaben → sein Bucket zeigt dauerhaft AFK. Für echten
> AFK-Status auf deinen Geräten läuft dort ein eigener Watcher.

## Update / Deinstall

```bash
# Update (neuestes Release; Daten in /var/lib/activitywatch bleiben erhalten):
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ActivityWatch-Proxmox/main/install/activitywatch.sh)" --update

# Deinstall (fragt nach; --yes überspringt):
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ActivityWatch-Proxmox/main/install/activitywatch.sh)" --uninstall
```

## Testen

```bash
bash test/mock-harness.sh   # 25 Mock-Tests (pct/pveam/curl gemockt, ohne sudo)
```

Getestete Pfade: Install (happy path + `--no-watcher` + Idempotenz-Abbruch),
`--update`, `--status`, `--uninstall`, `--help`, `$0`-Fallback (Grube
`bash -c`), Port-/Versions-Validierung, Unit-Template-Drift gegen `systemd/`.

## Fehlerdiagnose

Das Script schneidet alles mit (`/tmp/activitywatch-installer-*.log`) und gibt
bei Fehlern die **komplette Kette** aus: Exit-Code, Zeile, fehlgeschlagener
Befehl, letzte Logzeilen, Container-Logs (Setup + journalctl beider Services).
Volles Trace:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ActivityWatch-Proxmox/main/install/activitywatch.sh)" --debug
```

Manuell im Container:

```bash
pct exec <ID> -- journalctl -u activitywatch -e
pct exec <ID> -- journalctl -u aw-watcher-afk -e
pct exec <ID> -- tail -n 50 /var/log/activitywatch-setup.log
pct enter <ID>
```

## Repo-Struktur

```
install/activitywatch.sh   # Der Einzeiler-Installer (single source of truth)
systemd/                   # Referenzkopien der systemd-Units (@PORT@-Templates)
app/README.md              # Welche Bundle-Komponenten wohin installiert werden
test/mock-harness.sh       # Mock-Harness (unshare -rm root-Simulation)
```

Getestet mit ActivityWatch **v0.14.3**, Debian 12 LXC (unprivilegiert,
nesting=1), Proxmox VE 8.x.
