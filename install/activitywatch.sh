#!/usr/bin/env bash
# =============================================================================
#  ⏱️  ActivityWatch – One-Click-Installer (Proxmox VE)
#  https://github.com/HatchetMan111/ActivityWatch-Proxmox
#
#  Erstellt einen unprivilegierten LXC-Container und installiert darin
#  ActivityWatch (https://github.com/ActivityWatch/activitywatch): den lokalen,
#  datenschutzfreundlichen Time-Tracker (aktive Fenster/Apps, AFK-Status,
#  Browser-Erweiterungen, REST-API) als immer-laufenden Zeit-Server.
#
#  Architektur im Container:
#    - aw-server-rust (offizielles Release-Binary, Web-UI eingebettet)
#      → REST-API + Web-UI unter http://[CT-IP]:5600
#    - aw-watcher-afk (offizielles Frozen-Binary, headless unter Xvfb)
#    - SQLite-Datastore in /var/lib/activitywatch (bleibt bei Updates erhalten)
#    - systemd-Services activitywatch.service + aw-watcher-afk.service
#
#  Kein Rust-/Node-Build im Container: der Installer lädt das offizielle
#  Release-Bundle (aw-server-rust + aw-watcher-afk) von GitHub Releases.
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ActivityWatch-Proxmox/main/install/activitywatch.sh)"
#
#  Mit Optionen (direkt hinter dem schließenden Anführungszeichen):
#    ... " --id 210 --memory 1024 --port 5600 --no-watcher
#
#  Update / Deinstall / Status / Debug:
#    ... " --update        |  ... " --uninstall  |  ... " --status  |  ... " --debug
# =============================================================================

# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) sind Absicht
set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALLER_VERSION="1.0.0"
APP_NAME="activitywatch"
# Die App kommt NICHT aus diesem Repo, sondern als offizielles Release-Bundle
# aus github.com/ActivityWatch/activitywatch (siehe AW_VERSION unten).
CT_ID=""                    # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="activitywatch"
CT_STORAGE="local-lvm"
CT_ROOTFS=4                 # GB – Debian + Release-Bundle (~400 MB entpackt)
CT_CORES=2
CT_MEMORY=1024              # MB – aw-server-rust ist ein schlankes Rust-Binary
CT_SWAP=512                 # MB Puffer
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_GATEWAY=""               # nur bei statischer IP nötig, z. B. 192.168.1.1
CT_PASSWORD=""              # leer = automatisch generieren
CT_SSHKEY=""                # Pfad ODER URL zu einer Public-Key-Datei (optional)
SSH_KEY_FILE=""             # aufgelöste Key-Datei für pct create
PORT=5600                   # ActivityWatch-Standardport (API + Web-UI)
WITH_WATCHER=true           # aw-watcher-afk im CT (headless unter Xvfb)
AW_VERSION=""               # leer = neuestes Release via GitHub-API ermitteln
AW_FALLBACK_VERSION="0.14.3"  # Fallback, wenn die GitHub-API nicht erreichbar ist
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
FORCE_RECREATE=false
ASSUME_YES=false
TMP_DIR=""
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
# Der fertige Einzeiler für Hinweise/Fehlerausgaben – exakt kopierbar (Optionen
# hinter dem schließenden Anführungszeichen; der Installer erkennt sie via $0-Fallback)
# shellcheck disable=SC2016  # Absicht: Literal, das zum Ausgeben gedacht ist
ONE_LINER='bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ActivityWatch-Proxmox/main/install/activitywatch.sh)"'

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + Services), falls schon ein
# Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + ActivityWatch-Services):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 40 /var/log/activitywatch-setup.log 2>/dev/null
            echo "--- journalctl -u activitywatch ---"
            journalctl -u activitywatch --no-pager 2>/dev/null | tail -n 25
            echo "--- journalctl -u aw-watcher-afk ---"
            journalctl -u aw-watcher-afk --no-pager 2>/dev/null | tail -n 10
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Debug-Modus (voller bash -x-Trace) ─────────────────────────────────────
# (Vor parse_args, damit --debug selbst noch mitgetraced wird.)
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
ct_exists() {
    # Echtes `pct list`: Spalte 1 = VMID, 2 = Status, 3 = Lock, 4 = Name –
    # die Spaltenzahl/-lage VARIIERT aber (Lock oft leer, v. a. bei LXCs).
    # Deshalb NICHT eine feste Spalte, sondern der Hostname als eigenes
    # (durch Leerraum begrenztes) Wort in der Zeile.
    pct list 2>/dev/null \
        | awk -v h="${1:-}" 'NR>1 && $1 ~ /^[0-9]+$/ && $0 ~ ("(^|[[:space:]])" h "([[:space:]]|$)") {found=1} END {exit !found}'
}

find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

find_ct_id_by_hostname() {
    # Hostname als eigenes Wort in der pct list-Zeile suchen (Spaltenlage
    # variiert: VMID/Status/Lock/Name, Lock bei LXCs oft leer). NR>1
    # überspringt die Kopfzeile; $1 muss eine Zahl sein (echte CT-Zeile).
    pct list 2>/dev/null \
        | awk -v h="$CT_HOSTNAME" 'NR>1 && $1 ~ /^[0-9]+$/ && $0 ~ ("(^|[[:space:]])" h "([[:space:]]|$)") {print $1; exit}'
}

get_ct_ip() {
    # Grube (pipefail): bei pct-exec-Fehlschlag stirbt die Substitution –
    # deshalb || true INNERHALB von $(). Bei statischer IP direkt nutzen.
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true
    return 0
}

wait_for_ct_network() {
    # Nach pct create --start nicht blind sleep 3 (DHCP/DNS-Race) – aktiv pollen.
    local id="$1" tries=0 ip=""
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP am Bridge-Interface ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

verify_ct_dns() {
    # IP allein reicht nicht – das Release-Bundle kommt von GitHub (Objekt-
    # Storage). Live-Fall (2026-11-10, CT 200): DNS ist FLAKY – ein einzelner
    # getent-Erfolg reichte, Stunden später war wieder alles tot. Deshalb:
    # 3 Erfolge in Folge verlangen; eine einzige Störung → Fallback + Freeze.
    local id="$1" ok_count=0 tries=0
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts github.com >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert (3x bestätigt)"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    # Fallback: DNS des Hosts (falls nicht loopback) + öffentliche Resolver eintragen
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8 9.9.9.9"
    if [[ -n "$host_ns" ]]; then
        ns_list="$host_ns $ns_list"
    fi
    warn "DNS im Container defekt – schreibe Fallback-Nameserver ($ns_list) nach /etc/resolv.conf"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    # Dauerhaft: dhclient-Hook (verhindert das Überschreiben durch Lease-Renewals —
    # chattr +i funktioniert in unprivilegierten LXCs nicht) + nochmal prüfen.
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns'
    if pct exec "$id" -- getent hosts github.com >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt – Auflösung funktioniert"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion (auch mit Fallback).
  Prüfe: pct exec $id -- cat /etc/resolv.conf && pct exec $id -- ping -c2 1.1.1.1
  Firewall/Router: ausgehende DNS-Anfragen (Port 53) am Bridge-Netz erlauben."
}

ensure_ct_running() {
    # Update-/Verwaltungs-Pfade müssen einen GESTOPPTEN CT selbst starten –
    # pct exec auf gestopptem CT scheitert kryptisch (Exit 255).
    local ct_id="$1"
    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    if [[ "$state" == *"running"* ]]; then
        return 0
    fi
    warn "Container $ct_id läuft nicht (Status: ${state}) – starte ihn ..."
    if ! pct start "$ct_id" 2>&1 | tail -2; then
        die "Container $ct_id konnte nicht gestartet werden.\n  Manuell prüfen: pct start $ct_id && pct status $ct_id"
    fi
    info "Warte auf Netzwerk des Containers ..."
    local i ip=""
    for i in $(seq 1 60); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | tr -d ' \n' || true)
        if [[ -n "$ip" ]]; then
            ok "Container läuft (IP: ${ip%% *})"
            return 0
        fi
        sleep 1
    done
    die "Container $ct_id hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $ct_id -- ip a)"
}

resolve_aw_version() {
    # Neueste ActivityWatch-Version via GitHub-API ermitteln. || true INNERHALB
    # der Substitution (pipefail-Grube): leere Ausgabe → Caller nutzt Fallback.
    local v=""
    v=$(curl -fsSL --max-time 15 \
        "https://api.github.com/repos/ActivityWatch/activitywatch/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
    echo "$v"
}

# ── Unit-Templates (in Repo systemd/ gespiegelt; @PORT@ wird beim Push ersetzt) ──
print_unit() {
    # Vom Harness genutzt (Diff gegen systemd/*.service) – interne/debug-Flag.
    case "${1:-}" in
        activitywatch)
            cat <<'UNIT_AW'
[Unit]
Description=ActivityWatch Server (aw-server-rust) – lokale Zeit-Tracking-Web-App
Documentation=https://github.com/ActivityWatch/activitywatch
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=activitywatch
Group=activitywatch
Environment=HOME=/var/lib/activitywatch
ExecStart=/opt/activitywatch/aw-server-rust/aw-server-rust --host 0.0.0.0 --port @PORT@
Restart=always
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT_AW
            ;;
        aw-watcher-afk)
            cat <<'UNIT_AFK'
[Unit]
Description=ActivityWatch AFK-Watcher (headless unter Xvfb)
Documentation=https://github.com/ActivityWatch/activitywatch
Wants=activitywatch.service
After=activitywatch.service

[Service]
Type=simple
User=activitywatch
Group=activitywatch
Environment=HOME=/var/lib/activitywatch
ExecStart=/usr/bin/xvfb-run -a /opt/activitywatch/aw-watcher-afk/aw-watcher-afk --host 127.0.0.1 --port @PORT@ --timeout 180
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT_AFK
            ;;
        *) die "print_unit: unbekannte Unit '${1:-}' (erwartet: activitywatch | aw-watcher-afk)" ;;
    esac
}

push_units() {
    # @PORT@ im Host-Kontext ersetzen (kein Expansion-Heredoc → keine
    # Doppel-Escaping-Gruben), dann per pct push in den Container.
    local ct_id="$1"
    print_unit activitywatch | sed "s/@PORT@/${PORT}/g" > "$TMP_DIR/activitywatch.service"
    print_unit aw-watcher-afk | sed "s/@PORT@/${PORT}/g" > "$TMP_DIR/aw-watcher-afk.service"
    pct push "$ct_id" "$TMP_DIR/activitywatch.service" /root/aw-activitywatch.service
    pct push "$ct_id" "$TMP_DIR/aw-watcher-afk.service" /root/aw-watcher-afk.service
}

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument nach dem Script-String mit $0, nicht $1 – die Option würde
    # still geschluckt. Fallback: startet $0 mit "-", ist es eine Option.
    local args=("$@")
    if [[ "$0" == -* ]]; then
        args=("$0" "$@")
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)            CT_ID="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --hostname)      CT_HOSTNAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --storage)       CT_STORAGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rootfs)        CT_ROOTFS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --cores)         CT_CORES="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --memory)        CT_MEMORY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --swap)          CT_SWAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --bridge)        CT_BRIDGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ip)            CT_IP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --gateway)       CT_GATEWAY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --password)      CT_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --sshkey)        CT_SSHKEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --port)          PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --aw-version)    AW_VERSION="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --no-watcher)    WITH_WATCHER=false; i=$((i+1)) ;;
            --force)         FORCE_RECREATE=true; i=$((i+1)) ;;
            --yes|-y)        ASSUME_YES=true; i=$((i+1)) ;;
            --update)        UPDATE=true; i=$((i+1)) ;;
            --uninstall)     UNINSTALL=true; i=$((i+1)) ;;
            --status)        STATUS_CHECK=true; i=$((i+1)) ;;
            --debug)         set -x; i=$((i+1)) ;;
            --help|-h)       print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (--help zeigt alle Optionen)" ;;
        esac
    done
    # Port hart validieren – er landet direkt im systemd-Service.
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
        die "Ungültiger Port: '$PORT' (1–65535 erwartet, z. B. --port 5600)"
    fi
    if [[ -n "$AW_VERSION" && ! "$AW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Ungültige --aw-version: '$AW_VERSION' (Format 0.14.3 erwartet)"
    fi
}

print_help() {
    cat <<'EOF'
⏱️  ActivityWatch – Proxmox-Installer (lokaler Time-Tracking-Server)

Installation:   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/ActivityWatch-Proxmox/main/install/activitywatch.sh)"

Optionen (hinter dem schließenden Anführungszeichen anhängen, z. B. ... " --id 210):
  --id ID          Container-ID (Default: nächste freie ab 200)
  --hostname NAME  Container-Hostname (Default: activitywatch)
  --storage NAME   Storage für rootfs (Default: local-lvm)
  --rootfs GB      Disk-Größe (Default: 4)
  --cores N        vCPUs (Default: 2)
  --memory MB      RAM (Default: 1024)
  --swap MB        Swap (Default: 512)
  --bridge BR      Netzwerk-Bridge (Default: vmbr0)
  --ip CIDR        Statt DHCP, z. B. 192.168.1.50/24 (+ --gateway 192.168.1.1)
  --gateway GW     Gateway für statische IP
  --password PW    Root-Passwort (Default: automatisch generiert)
  --sshkey PFAD    Public-Key-Datei oder URL – ssh-key-Login als root im CT
  --port PORT      API/Web-UI-Port im Container (Default: 5600)
  --aw-version V   ActivityWatch-Version pinnen (z. B. 0.14.3; Default: neuestes Release)
  --no-watcher     AFK-Watcher NICHT installieren (reiner Server, ohne Xvfb)
  --force          Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y       Rückfragen überspringen
  --update         App im bestehenden Container aktualisieren (neuestes Release)
  --uninstall      Container stoppen und löschen
  --status         Status anzeigen
  --debug          Vollständiges bash -x-Trace

  Modus:  Install (Default) / --update / --uninstall / --status / --debug
EOF
}

# ── In-Container-Setup-Script (idempotent) ─────────────────────────────────
# ACHTUNG: QUOTETER Heredoc ('INNEREOF') – nichts wird vom HOST-Script expandiert.
# Alle Werte (PORT, AW_VERSION, WITH_WATCHER, HOST_DNS) kommen als
# Umgebungsvariablen via `pct exec -- env …` in den Container.
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# ActivityWatch In-Container-Setup (idempotent – safe für Update & Re-Run)
# Variablen via env: PORT, HOST_DNS, AW_VERSION, WITH_WATCHER
# Lädt das offizielle Release-Bundle (aw-server-rust + aw-watcher-afk),
# KEIN Rust-/Node-Build im Container.
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C   # verhindert perl/locale-Warnungen im frischen Debian-CT

err(){ echo "✘ $1" >&2; }
die(){ err "$1"; exit 1; }

: "${PORT:?PORT fehlt (env)}"
: "${HOST_DNS:?HOST_DNS fehlt (env)}"
: "${AW_VERSION:?AW_VERSION fehlt (env)}"
: "${WITH_WATCHER:?WITH_WATCHER fehlt (env)}"

AW_BASE=/opt/activitywatch
AW_HOME=/var/lib/activitywatch
BUNDLE_BASE="https://github.com/ActivityWatch/activitywatch/releases/download/v${AW_VERSION}"

echo ">>> Pakete installieren (curl, unzip, ca-certificates$([ "$WITH_WATCHER" = "1" ] && echo ", xauth, xvfb" || echo "")) ..."
apt-get update -qq
if [ "$WITH_WATCHER" = "1" ]; then
    apt-get install -y -qq curl ca-certificates unzip xauth xvfb >/dev/null
else
    apt-get install -y -qq curl ca-certificates unzip >/dev/null
fi

echo ">>> DNS festschreiben (DHCP-DNS des Netzes ist unzuverlässig) ..."
# dhclient-Hook: verhindert, dass Lease-Renewals /etc/resolv.conf überschreiben.
mkdir -p /etc/dhcp/dhclient-enter-hooks.d
printf '# ActivityWatch: resolv.conf nicht von DHCP überschreiben lassen\nmake_resolv_conf() { :; }\n' > /etc/dhcp/dhclient-enter-hooks.d/no-dns
printf 'domain home.arpa\nsearch home.arpa\nnameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\n' "${HOST_DNS}" > /etc/resolv.conf

echo ">>> System-User für ActivityWatch anlegen (Home: ${AW_HOME}) ..."
if ! id -u activitywatch >/dev/null 2>&1; then
    useradd --system --home-dir "${AW_HOME}" --create-home --shell /usr/sbin/nologin activitywatch
fi

echo ">>> ActivityWatch v${AW_VERSION} Release-Bundle herunterladen ..."
mkdir -p "${AW_BASE}"
# Bevorzugt manylinux-Build (glibc ≥ 2.28 – Debian 12: 2.36 ✓), Fallback aufs
# klassische Zip. curl -f: HTTP-Fehler bricht ab; die Fehlerkette steht im Log.
if ! curl -fSL --retry 3 "${BUNDLE_BASE}/activitywatch-v${AW_VERSION}-linux-x86_64-manylinux_2_28.zip" \
        -o /tmp/aw-bundle.zip 2>/tmp/aw-download.err; then
    echo "    manylinux-Zip nicht verfügbar – Fallback auf klassisches Zip ..."
    curl -fSL --retry 3 "${BUNDLE_BASE}/activitywatch-v${AW_VERSION}-linux-x86_64.zip" \
        -o /tmp/aw-bundle.zip 2>/tmp/aw-download.err || {
        err "Download-Fehler (letzte Meldung):"; cat /tmp/aw-download.err >&2 || true
        die "Release-Bundle v${AW_VERSION} konnte nicht geladen werden (beide URL-Varianten).
  Prüfe: curl -fsI ${BUNDLE_BASE}  und: pct exec $(hostname) -- cat /tmp/aw-download.err"
    }
fi
echo "    Download OK ($(du -h /tmp/aw-bundle.zip | cut -f1))"

echo ">>> Bundle auspacken (nur aw-server-rust + aw-watcher-afk) ..."
rm -rf /tmp/aw-extract "${AW_BASE}/aw-server-rust" "${AW_BASE}/aw-watcher-afk"
mkdir -p /tmp/aw-extract
unzip -o -q /tmp/aw-bundle.zip \
    'activitywatch/aw-server-rust/*' 'activitywatch/aw-watcher-afk/*' -d /tmp/aw-extract
mv /tmp/aw-extract/activitywatch/aw-server-rust "${AW_BASE}/"
mv /tmp/aw-extract/activitywatch/aw-watcher-afk "${AW_BASE}/"
chmod +x "${AW_BASE}/aw-server-rust/aw-server-rust" "${AW_BASE}/aw-watcher-afk/aw-watcher-afk"
if [ ! -x "${AW_BASE}/aw-server-rust/aw-server-rust" ]; then
    die "Unerwartete Bundle-Struktur: ${AW_BASE}/aw-server-rust/aw-server-rust fehlt.
  Bundle-Inhalt: $(find /tmp/aw-extract -maxdepth 2 | head -10 | tr '\n' ' ')"
fi

echo ">>> Binary-Selbsttest (${AW_BASE}/aw-server-rust/aw-server-rust --version) ..."
SERVER_VER=$("${AW_BASE}/aw-server-rust/aw-server-rust" --version 2>/dev/null || echo "unbekannt")
echo "    $SERVER_VER"

echo ">>> systemd-Units installieren (User activitywatch, Restart=always) ..."
install -m 644 /root/aw-activitywatch.service /etc/systemd/system/activitywatch.service
if [ "$WITH_WATCHER" = "1" ]; then
    install -m 644 /root/aw-watcher-afk.service /etc/systemd/system/aw-watcher-afk.service
fi

echo ">>> Rechte setzen (Daten liegen in ${AW_HOME}, bleiben bei Updates erhalten) ..."
chown -R activitywatch:activitywatch "${AW_HOME}" "${AW_BASE}"

echo ">>> INSTALL_INFO schreiben (für --status / Summary) ..."
cat > "${AW_BASE}/INSTALL_INFO" <<INFOEOF
AW_VERSION=${AW_VERSION}
PORT=${PORT}
INSTALLER_DATE=$(date +%Y-%m-%d_%H:%M)
WITH_WATCHER=${WITH_WATCHER}
BINARY_VER=${SERVER_VER}
INFOEOF

echo ">>> Services aktivieren + starten (Server zuerst, danach Watcher) ..."
systemctl daemon-reload
systemctl enable activitywatch >/dev/null 2>&1
systemctl restart activitywatch

echo ">>> Warte auf API auf Port ${PORT} ..."
API_OK=""
for _ in $(seq 1 30); do
    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${PORT}/api/0/info"; then
        API_OK=1
        break
    fi
    sleep 1
done
if [ -z "$API_OK" ]; then
    die "aw-server-rust lauscht nach Start nicht auf Port ${PORT}.
  Debug: journalctl -u activitywatch -e && ss -tlnp | grep ${PORT}"
fi
echo "    API antwortet (http://127.0.0.1:${PORT}/api/0/info)"

if [ "$WITH_WATCHER" = "1" ]; then
    echo ">>> AFK-Watcher starten (headless unter Xvfb) ..."
    systemctl enable aw-watcher-afk >/dev/null 2>&1
    systemctl restart aw-watcher-afk
    WATCHER_OK=""
    for _ in $(seq 1 20); do
        if systemctl is-active --quiet aw-watcher-afk; then
            WATCHER_OK=1
            break
        fi
        sleep 1
    done
    if [ -z "$WATCHER_OK" ]; then
        die "aw-watcher-afk läuft nicht (Xvfb/Pynput-Problem).
  Debug: journalctl -u aw-watcher-afk -e"
    fi
    echo "    Watcher aktiv (AFK-Bucket füllt sich ab jetzt; im CT ohne echte Eingaben = dauerhaft AFK)"
fi

echo ">>> Aufräumen ..."
rm -rf /tmp/aw-bundle.zip /tmp/aw-extract /tmp/aw-download.err /root/aw-activitywatch.service /root/aw-watcher-afk.service

echo ">>> Setup abgeschlossen."
INNEREOF
}

run_inner_setup() {
    local ct_id="$1"
    header "⚙️  Installiere ActivityWatch im Container $ct_id"
    # DNS des Hosts in den Container bringen (dort resolvert das Setup garantiert –
    # der DHCP-DNS des Zielnetzes war live unzuverlässig, siehe verify_ct_dns)
    HOST_DNS=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null \
               | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    write_inner_script
    push_units "$ct_id"
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    # Variablen via env in den Container (kein Expansion-Heredoc → keine
    # Escaping-Gruben). set -o pipefail: ein Crash im Inner-Script darf nicht
    # durch `tee` maskiert werden.
    pct exec "$ct_id" -- env PORT="$PORT" HOST_DNS="${HOST_DNS:-1.1.1.1}" \
        AW_VERSION="$AW_VERSION" WITH_WATCHER="$($WITH_WATCHER && echo 1 || echo 0)" \
        bash -c 'set -o pipefail; bash /root/setup-inner.sh 2>&1 | tee /var/log/activitywatch-setup.log'
}

get_installed_version() {
    # Version aus der INSTALL_INFO im CT – || true INNERHALB von $() (Grube:
    # pipefail + pct-exec-Fehlschlag würde die Substitution töten).
    local v=""
    v=$(pct exec "$1" -- sh -c 'grep -m1 "^AW_VERSION=" /opt/activitywatch/INSTALL_INFO 2>/dev/null | cut -d= -f2' 2>/dev/null || true)
    echo "$v"
}

# ── Verifikation ───────────────────────────────────────────────────────────
verify_installation() {
    local ct_id="$1" tries=0 code=""

    header "✅ Verifikation"

    # activitywatch-Service aktiv?
    while true; do
        if pct exec "$ct_id" -- systemctl is-active --quiet activitywatch 2>/dev/null; then
            ok "Service activitywatch läuft (API/Web-UI auf Port $PORT)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Service activitywatch läuft nicht.
  Debug: pct exec $ct_id -- journalctl -u activitywatch -e"
        fi
        sleep 1
    done

    # AFK-Watcher aktiv (falls installiert)?
    if $WITH_WATCHER; then
        if pct exec "$ct_id" -- systemctl is-active --quiet aw-watcher-afk 2>/dev/null; then
            ok "Service aw-watcher-afk läuft (headless unter Xvfb)"
        else
            warn "aw-watcher-afk läuft noch nicht (startet ggf. nach dem Server neu) – prüfe:"
            info "pct exec $ct_id -- journalctl -u aw-watcher-afk -e"
        fi
    fi

    # API antwortet? (Grube: curl -w gibt bei Verbindungsfehler bereits 000 aus –
    # NIE zusätzlich || echo 000 anhängen, sonst wird der Check falsch-positiv.)
    tries=0
    while true; do
        code=$(pct exec "$ct_id" -- curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
               "http://127.0.0.1:${PORT}/api/0/info" || true)
        if [[ "$code" == "200" ]]; then
            ok "API antwortet (HTTP 200 auf http://127.0.0.1:${PORT}/api/0/info)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            # Selbst-Diagnose: der häufigste Fall ist ein abgestürzter Server.
            local diag
            diag=$(pct exec "$ct_id" -- sh -c '
                echo "--- Listener auf Port '"$PORT"' (ss -tlnp) ---"
                ss -tlnp 2>/dev/null | grep -E "[:.]'"$PORT"'" || echo "  (KEIN Listener auf Port '"$PORT"')"
                echo "--- journalctl -u activitywatch (letzte Zeilen) ---"
                journalctl -u activitywatch --no-pager 2>/dev/null | tail -n 12 || true
            ' 2>/dev/null || true)
            die "API antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).

${diag}
  Debug: pct exec $ct_id -- journalctl -u activitywatch -e"
        fi
        sleep 1
    done

    # Web-UI eingebettet und erreichbar (GET / liefert index.html)?
    code=$(pct exec "$ct_id" -- curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
           "http://127.0.0.1:${PORT}/" || true)
    if [[ "$code" == "200" ]]; then
        ok "Web-UI antwortet (HTTP 200 auf http://127.0.0.1:${PORT}/)"
    else
        warn "Web-UI nicht erreichbar (HTTP ${code:-unbekannt}) – API läuft aber; Bundle ohne Web-UI?"
    fi

    # Erreichbarkeit vom PROXMOX-HOST aus (die Nutzer-URL läuft über die CT-IP;
    # im CT-Loopback kann alles OK sein, während eine Firewall draußen blockt).
    local ct_ip="" host_code=""
    ct_ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ct_ip" ]]; then
        host_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                    "http://${ct_ip}:${PORT}/api/0/info" || true)
        if [[ "$host_code" == "200" ]]; then
            ok "Vom Host erreichbar: http://${ct_ip}:${PORT} (HTTP 200)"
        else
            warn "Im CT OK, aber vom Proxmox-Host nicht erreichbar (HTTP ${host_code:-000} über http://${ct_ip}:${PORT})."
            info "Prüfe CT-Firewall (pct config $ct_id | grep -E 'net0|firewall') und Bridge-Setup."
        fi
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "⏱️  ActivityWatch ist bereit!"

    local ct_ip installed_version=""
    ct_ip=$(get_ct_ip "$CT_ID")
    if [[ -z "$ct_ip" ]]; then
        ct_ip="<IP-ADRESSE>"
    fi
    installed_version=$(get_installed_version "$CT_ID")

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  🌐 Web-UI:      http://${ct_ip}:${PORT}${NC}"
    echo -e "  ${GREEN}  🔌 REST-API:    http://${ct_ip}:${PORT}/api/0/info${NC}"
    echo -e "  ${GREEN}  🐚 Terminal:    pct enter ${CT_ID}${NC}"
    if [[ -n "$CT_PASSWORD" ]]; then
        echo -e "  ${GREEN}  🔑 Root-PW:     ${CT_PASSWORD}${NC}"
    fi
    if [[ -n "$installed_version" ]]; then
        echo -e "  ${GREEN}  📦 Version:     v${installed_version} (ActivityWatch v${AW_VERSION})${NC}"
    fi
    if $WITH_WATCHER; then
        echo -e "  ${GREEN}  👀 AFK-Watcher: aktiv (headless unter Xvfb)${NC}"
    else
        echo -e "  ${GREEN}  👀 AFK-Watcher: deaktiviert (--no-watcher)${NC}"
    fi
    echo -e "  ${GREEN}  💾 Daten:       /var/lib/activitywatch (im CT, überlebt Updates)${NC}"
    echo -e "  ${GREEN}  🔧 Installer:   v${INSTALLER_VERSION}${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Sobald der Server läuft:${NC}"
    echo "  1. http://${ct_ip}:${PORT} öffnen → Timeline/Statistiken der ActivityWatch-UI"
    echo "  2. Echte Tracking-Daten kommen von deinen Geräten: dort ActivityWatch"
    echo "     installieren und per aw-sync (ist im Bundle enthalten) mit dem"
    echo "     Server ${ct_ip}:${PORT} synchronisieren – siehe README (Abschnitt „Clients anbinden“)."
    echo "  3. Automatische Auswertungen: aw-notify / eigene Skripte via REST-API."
    echo ""
    echo -e "  ${CYAN}Nützliche Befehle (exakt kopierbar):${NC}"
    echo "  Status:    ${ONE_LINER} --status"
    echo "  Update:    ${ONE_LINER} --update"
    echo "  Deinstall: ${ONE_LINER} --uninstall"
    echo "  Logs:      pct exec ${CT_ID} -- journalctl -u activitywatch -f"
    echo ""
    if $WITH_WATCHER; then
        warn "Der AFK-Watcher im CT läuft headless (Xvfb, keine echte Eingabe) –"
        warn "sein Bucket zeigt daher dauerhaft AFK. Er ist ein Funktionstest der"
        warn "Watcher-Pipeline; echtes Input-Tracking passiert auf deinen Client-Geräten."
    fi
    warn "Der Server lauscht auf 0.0.0.0:${PORT} – für das LAN gedacht, nicht fürs Internet."
}

# ── Install ────────────────────────────────────────────────────────────────
do_install() {
    header "⏱️  Installiere ActivityWatch (LXC)"
    info "Installer-Version: v${INSTALLER_VERSION}"

    if [[ $EUID -ne 0 ]]; then
        die "Bitte als root ausführen (auf dem Proxmox-Host)."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        die "pct nicht gefunden – das Script muss auf einem Proxmox-VE-Host laufen."
    fi

    # Bereits vorhanden?
    local existing
    existing=$(find_ct_id_by_hostname || true)
    if [[ -n "$existing" ]]; then
        if $FORCE_RECREATE; then
            warn "Container $existing ($CT_HOSTNAME) existiert – --force: lösche und lege neu an."
            pct stop "$existing" || true
            pct destroy "$existing" --purge
        else
            die "Container $existing mit Hostname '$CT_HOSTNAME' existiert bereits.
  Update:  ${ONE_LINER} --update
  Neu aufsetzen:  ${ONE_LINER} --force"
        fi
    fi

    # ActivityWatch-Version ermitteln (GitHub-API, Fallback auf Pin)
    if [[ -z "$AW_VERSION" ]]; then
        AW_VERSION=$(resolve_aw_version)
        if [[ -z "$AW_VERSION" ]]; then
            AW_VERSION="$AW_FALLBACK_VERSION"
            warn "GitHub-API nicht erreichbar – nutze Fallback-Version ${AW_VERSION}"
        else
            ok "Neueste ActivityWatch-Version: ${AW_VERSION}"
        fi
    else
        info "Gepinnte Version (--aw-version): ${AW_VERSION}"
    fi

    # Debian-Template sicherstellen
    header "🧱 Container-Template"
    local template=""
    # Robust gegen Versions-Suffixe: Templates heißen "debian-12-standard" ODER
    # "debian-12.12-standard_..." – wir matchen auf beides (grep -E) und
    # sortieren nach Version, die höchste gewinnt.
    if ! pveam list local 2>/dev/null | grep -qE "debian-12[^ ]*standard"; then
        info "Kein Debian-12-Template vorhanden – lade es herunter ..."
        pveam update
        local tpl
        tpl=$(pveam available 2>/dev/null | grep -E "debian-12[^ ]*standard" | tail -1 | awk '{print $2}')
        if [[ -z "$tpl" ]]; then
            die "Kein Debian-12-Template in pveam available gefunden.
  Prüfe: pveam available | grep debian-12"
        fi
        pveam download local "$tpl"
    fi
    template=$(pveam list local 2>/dev/null | grep -E "debian-12[^ ]*standard" | sort -V | tail -1 | awk '{print $1}')
    if [[ -z "$template" ]]; then
        die "Kein Debian-12-Template gefunden – bitte prüfen: pveam list local"
    fi
    ok "Template: $template"

    # ID & Passwort
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_free_id)
        info "Nächste freie CT-ID: $CT_ID"
    fi
    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -base64 12 2>/dev/null || true)
        if [[ -z "$CT_PASSWORD" ]]; then
            CT_PASSWORD="aw-$(date +%s)"
        fi
    fi

    # Container anlegen
    header "🚀 Erzeuge Container $CT_ID ($CT_HOSTNAME)"
    local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},firewall=0"
    if [[ -n "$CT_GATEWAY" ]]; then
        net0+=",gateway=${CT_GATEWAY}"
    fi
    local ssh_keys_args=()
    if [[ -n "$CT_SSHKEY" ]]; then
        if [[ "$CT_SSHKEY" == http://* || "$CT_SSHKEY" == https://* ]]; then
            info "Lade SSH-Public-Key herunter ..."
            wget -q --tries=3 -O "$TMP_DIR/sshkey.pub" "$CT_SSHKEY" || die "SSH-Key-URL nicht ladbar: $CT_SSHKEY"
        elif [[ -f "$CT_SSHKEY" ]]; then
            cp "$CT_SSHKEY" "$TMP_DIR/sshkey.pub"
        else
            die "SSH-Key-Datei nicht gefunden: $CT_SSHKEY"
        fi
        if [[ ! -s "$TMP_DIR/sshkey.pub" ]]; then
            die "SSH-Key-Datei ist leer: $CT_SSHKEY"
        fi
        SSH_KEY_FILE="$TMP_DIR/sshkey.pub"
        ok "SSH-Public-Key wird in den Container installiert (ssh-key-Login als root)"
        ssh_keys_args=(--ssh-public-keys "$SSH_KEY_FILE")
    fi
    pct create "$CT_ID" "$template" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net0" \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --start 1 \
        --password "$CT_PASSWORD" \
        "${ssh_keys_args[@]}"
    ok "Container $CT_ID erstellt und gestartet"

    wait_for_ct_network "$CT_ID"
    verify_ct_dns "$CT_ID"

    run_inner_setup "$CT_ID"
    verify_installation "$CT_ID"
    print_summary
}

# ── Update ─────────────────────────────────────────────────────────────────
do_update() {
    header "🔄 Update ActivityWatch (neues Release)"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden.
  Erst installieren:  ${ONE_LINER}"
    fi
    CT_ID="$ct_id"

    ensure_ct_running "$ct_id"
    verify_ct_dns "$ct_id"

    # Daten bleiben erhalten (liegen in /var/lib/activitywatch) – nur die
    # Binaries unter /opt/activitywatch werden ersetzt.
    local old_v=""
    old_v=$(get_installed_version "$ct_id")

    # Version auflösen (wie Install; --aw-version pinnt auch beim Update)
    if [[ -z "$AW_VERSION" ]]; then
        AW_VERSION=$(resolve_aw_version)
        if [[ -z "$AW_VERSION" ]]; then
            AW_VERSION="$AW_FALLBACK_VERSION"
            warn "GitHub-API nicht erreichbar – nutze Fallback-Version ${AW_VERSION}"
        else
            ok "Ziel-Version: ${AW_VERSION}"
        fi
    fi

    run_inner_setup "$ct_id"
    verify_installation "$ct_id"

    if [[ -n "$old_v" && "$old_v" != "$AW_VERSION" ]]; then
        ok "Update abgeschlossen: v${old_v} → v${AW_VERSION} (Datenbank blieb erhalten)"
    else
        ok "Update abgeschlossen (v${AW_VERSION}) – Datenbank blieb erhalten."
    fi
    print_summary
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    header "🗑️  Deinstalliere ActivityWatch"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden – nichts zu tun."
        return 0
    fi
    CT_ID="$ct_id"

    warn "Container $ct_id ($CT_HOSTNAME) wird GESTOPPT und GELÖSCHT."
    warn "Alle getrackten Daten (SQLite in /var/lib/activitywatch) gehen damit verloren!"
    if ! $ASSUME_YES; then
        local answer=""
        if ! read -r -t 60 -p "Wirklich löschen? (ja/NEIN): " answer; then
            die "Keine Bestätigung erhalten (nicht-interaktiv?) – nichts gelöscht.
  Erzwingen:  ${ONE_LINER} --uninstall --yes"
        fi
        if [[ "$answer" != "ja" ]]; then
            info "Abgebrochen – nichts gelöscht."
            return 0
        fi
    fi
    pct stop "$ct_id" || true
    pct destroy "$ct_id" --purge
    ok "Container $ct_id gelöscht."
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    header "📊 Status ActivityWatch"
    info "Installer-Version: v${INSTALLER_VERSION}"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden."
        info "Installieren:  ${ONE_LINER}"
        return 0
    fi
    CT_ID="$ct_id"

    # Gestoppten CT nicht als "ActivityWatch läuft nicht" fehldeklarieren
    local state
    state=$(pct status "$ct_id" 2>/dev/null | awk '{print $2}' || true)

    pct list 2>/dev/null | awk -v id="$ct_id" -v st="$state" -v hn="$CT_HOSTNAME" \
        '$1==id {print "Container:  " $1 " (" hn ") – " st}'

    if [[ "$state" != "running" ]]; then
        warn "Container $ct_id ist nicht gestartet (${state:-unbekannt}) – Service/Version/Web-UI ohne Start nicht prüfbar."
        info "Starten:    pct start $ct_id"
        return 0
    fi

    if pct exec "$ct_id" -- systemctl is-active --quiet activitywatch 2>/dev/null; then
        ok "Service:   activitywatch läuft (API/Web-UI auf Port $PORT)"
    else
        err "Service:   activitywatch läuft NICHT"
        info "Logs:      pct exec $ct_id -- journalctl -u activitywatch -e"
    fi

    if pct exec "$ct_id" -- systemctl is-active --quiet aw-watcher-afk 2>/dev/null; then
        ok "Watcher:   aw-watcher-afk läuft (Xvfb)"
    else
        info "Watcher:   aw-watcher-afk nicht aktiv (mit --no-watcher installiert?)"
    fi

    local installed_version=""
    installed_version=$(get_installed_version "$ct_id")
    if [[ -n "$installed_version" ]]; then
        info "Version:   v${installed_version} (ActivityWatch, upstream ActivityWatch/activitywatch)"
    else
        warn "Version:   nicht ermittelbar (App installiert?)"
    fi

    local ip code=""
    ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ip" ]]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${PORT}/api/0/info" || true)
        if [[ "$code" == "200" ]]; then
            ok "Web-UI:    http://${ip}:${PORT}  (HTTP 200)"
        else
            warn "Web-UI:    HTTP-Code ${code:-unbekannt} von http://${ip}:${PORT}"
        fi
    else
        warn "Container hat keine IP (läuft er?)."
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
case "${1:-}" in
    --print-unit) print_unit "${2:-}" 2>/dev/null; exit 0 ;;
esac

parse_args "$@"

TMP_DIR=$(mktemp -d)

if $UNINSTALL; then
    do_uninstall
elif $UPDATE; then
    do_update
elif $STATUS_CHECK; then
    do_status
else
    do_install
fi
