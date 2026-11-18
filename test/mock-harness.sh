#!/usr/bin/env bash
# =============================================================================
# Mock-Harness für install/activitywatch.sh
# =============================================================================
# Testet die Host-Seite des Installers (Argumente, pct create, Unit-Push,
# In-Container-Setup, Verifikation, Update, Status, Uninstall, $0-Fallback)
# mit gemocktem pct/pveam/curl – ohne echten Proxmox-Host, ohne sudo.
#
# Nutzung:
#   bash test/mock-harness.sh            # alle Tests
#   bash test/mock-harness.sh --verbose  # mehr Ausgabe (derzeit: gleiche Ausgabe)
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO_ROOT/install/activitywatch.sh"
export REPO_ROOT
WORK_DIR="$(mktemp -d)"
MOCK_BIN="$WORK_DIR/mock-bin"
PASS=0
FAIL=0

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

green() { printf '\033[0;32m%s\033[0m' "$1"; }
red()   { printf '\033[0;31m%s\033[0m' "$1"; }
pass()  { PASS=$((PASS+1)); echo "  $(green PASS)  $1"; }
fail()  { FAIL=$((FAIL+1)); echo "  $(red FAIL)  $1"; }

# ── Mock-Umgebung aufbauen ──────────────────────────────────────────────────
setup_mocks() {
    mkdir -p "$MOCK_BIN"
    # pct: list, create, start, status, exec, push, stop, destroy, config
    cat > "$MOCK_BIN/pct" <<'MOCKPCT'
#!/usr/bin/env bash
# state file: $MOCK_STATE_DIR/<id>.status, .ip, .<service>.active
STATE="${MOCK_STATE_DIR:-/tmp/mock-pct}"
mkdir -p "$STATE"
case "$1" in
    list)
        # Echtes pct list-Format: Kopfzeile + "VMID Status Lock Name".
        # Spalten variieren (Lock bei LXCs oft leer) – der Installer darf
        # sich deshalb NICHT auf eine feste Spalte verlassen.
        echo "VMID       Status     Lock         Name"
        echo "------------------------------------------------------------------"
        if [ -f "$STATE/list.txt" ]; then cat "$STATE/list.txt"; fi
        ;;
    create)
        id="$2"
        echo "$id" > "$STATE/next_id"
        echo "running" > "$STATE/$id.status"
        echo "10.0.0.$id" > "$STATE/$id.ip"
        # In die CT-Liste eintragen, damit Status/Update/Idempotenz ihn sehen.
        # Echtes Format: VMID Status Lock Name (Lock absichtlich "-" wie bei
        # echten LXCs – der Name steht damit in Spalte 4, nicht 2!).
        echo "$id    running    -            activitywatch" >> "$STATE/list.txt"
        # Netzwerkgabe simulieren
        echo "eth0: 10.0.0.$id/24"
        ;;
    start)
        echo "running" > "$STATE/$2.status"
        ;;
    stop)
        echo "stopped" > "$STATE/$2.status"
        # In list.txt auf stopped setzen (Spalte 2 = Status)
        if [ -f "$STATE/list.txt" ]; then
            sed -i "s/^\([[:space:]]*$2[[:space:]]*\)running/\1stopped/" "$STATE/list.txt"
        fi
        ;;
    destroy)
        if [ -f "$STATE/list.txt" ]; then
            sed -i "/^$2 /d" "$STATE/list.txt"
        fi
        rm -f "$STATE/$2.status" "$STATE/$2.ip" "$STATE/$2.activitywatch.active" \
              "$STATE/$2.aw-watcher-afk.active"
        ;;
    status)
        # Echtes pct status: "status: running" – Status primär aus list.txt
        # (Spalte 2), Fallback auf die .status-Datei.
        st=$(awk -v id="$2" '$1==id {print $2; exit}' "$STATE/list.txt" 2>/dev/null)
        if [ -z "$st" ]; then st=$(cat "$STATE/$2.status" 2>/dev/null || echo unknown); fi
        echo "status: $st"
        ;;
    exec)
        id="$2"; shift 2
        # pct exec <id> [--] [env VAR=.. ..] CMD args...
        if [ "${1:-}" = "--" ]; then shift; fi
        # env-Praxis: pct exec <id> -- env VAR=x ... CMD -> Variablen übernehmen
        if [ "${1:-}" = "env" ]; then
            shift
            # "*.=*" statt "*=*": der Loop muss bei "PORT=5600" weiterlaufen
            # (endet NICHT mit '='), sonst wird der erste Env-Eintrag als cmd gelesen.
            while [[ $# -gt 0 && "$1" == *=* ]]; do export "$1"; shift; done
        fi
        cmd="${1:-}"
        shift || true
        case "$cmd" in
            hostname)
                cat "$STATE/$id.ip" 2>/dev/null || echo "10.0.0.$id"
                ;;
            systemctl)
                sub="${1:-}"; shift || true
                # Service-Name = erstes Argument, das kein Flag ist
                svc=""
                for a in "$@"; do
                    if [[ "$a" != -* ]]; then svc="$a"; break; fi
                done
                case "$sub" in
                    is-active)
                        # echtes `systemctl is-active --quiet`: aktiv -> Exit 0 (stumm);
                        # inaktiv -> "inactive" + Exit 3
                        if [ -f "$STATE/$id.$svc.active" ]; then
                            exit 0
                        else
                            echo "inactive"
                            exit 3
                        fi
                        ;;
                    restart|enable|daemon-reload|start)
                        # restart/enable Aktivieren des benannten Services
                        if [ -n "$svc" ]; then touch "$STATE/$id.$svc.active"; fi
                        [ -z "$svc" ] && touch "$STATE/$id.activitywatch.active"
                        ;;
                esac
                ;;
            getent)
                if [ -f "$STATE/$id.dns-broken" ]; then exit 2; fi
                exit 0
                ;;
            bash)
                # Nur der echte Inner-Setup-Aufruf simuliert die Installation:
                # bash -c 'set -o pipefail; bash /root/setup-inner.sh ...'
                # (der andere bash -c-Aufruf ist der dhclient-Hook in verify_ct_dns –
                #  der darf KEINE Install-Simulierung triggern).
                if [[ "${1:-}" == "-c" && "${2:-}" == *"setup-inner.sh"* ]]; then
                    mkdir -p "$STATE/$id.opt/activitywatch"
                    {
                        echo "AW_VERSION=${AW_VERSION:-0.14.3}"
                        echo "PORT=${PORT:-5600}"
                        echo "WITH_WATCHER=${WITH_WATCHER:-1}"
                    } > "$STATE/$id.opt/activitywatch/INSTALL_INFO"
                    touch "$STATE/$id.activitywatch.active"
                    if [ "${WITH_WATCHER:-1}" = "1" ]; then
                        touch "$STATE/$id.aw-watcher-afk.active"
                    fi
                    echo "mock: setup-inner.sh ausgeführt (Bundle + Units + Services)"
                fi
                ;;
            sh)
                # get_installed_version: sh -c 'grep ... INSTALL_INFO ...'
                if [ -f "$STATE/$id.opt/activitywatch/INSTALL_INFO" ]; then
                    grep -m1 '^AW_VERSION=' "$STATE/$id.opt/activitywatch/INSTALL_INFO" | cut -d= -f2
                fi
                ;;
            curl)
                printf '200'
                ;;
            journalctl)
                echo "mock: keine logs"
                ;;
            *)
                echo "mock pct-exec($id): $cmd $*"
                ;;
        esac
        ;;
    push)
        # pct push <id> <local> <remote> – lokal nach "$STATE/pushed/" kopieren
        id="$2"; local_f="$3"; remote_f="$4"
        mkdir -p "$STATE/pushed"
        cp -r "$local_f" "$STATE/pushed/" 2>/dev/null || true
        echo "mock: pct push $id $local_f -> $remote_f"
        ;;
    config)
        echo "mock: config $2"
        ;;
    *)
        echo "mock pct: $*" >&2
        exit 0
        ;;
esac
MOCKPCT
    chmod +x "$MOCK_BIN/pct"

    # pveam: Template-Liste (list local / available / download simulieren)
    cat > "$MOCK_BIN/pveam" <<'MOCKPVEAM'
#!/usr/bin/env bash
case "$1" in
    list)
        # list local: Template + CTs (Name in Spalte 1)
        echo "local:vztmpl/debian-12.12-standard_amd64.tar.zst"
        ;;
    available)
        echo "debian-12.12-standard_amd64.tar.zst"
        ;;
    update|download)
        ;;
    *)
        echo "mock pveam: $*"
        ;;
esac
MOCKPVEAM
    chmod +x "$MOCK_BIN/pveam"

    # curl: GitHub-API liefert Release-JSON, alles andere HTTP-200 (printf OHNE
    # Zeilenumbruch – der Installer prüft exakt auf "200").
    cat > "$MOCK_BIN/curl" <<'MOCKCURL'
#!/usr/bin/env bash
url=""
for a in "$@"; do
    if [[ "$a" == http* ]]; then url="$a"; break; fi
done
case "$url" in
    *api.github.com*)
        printf '{"tag_name": "v0.14.3", "name": "v0.14.3"}'
        ;;
    *)
        printf '200'
        ;;
esac
MOCKCURL
    chmod +x "$MOCK_BIN/curl"

    # State-Dir anlegen (pct-Mock liest/schreibt hier CT-Listen)
    mkdir -p "$WORK_DIR/mock-state"
    # Absolute Pfade exportieren: unshare -rm (root-Simulation) startet eine
    # NEUE Session – relative Pfade würden dort ins Nichts zeigen.
    export PATH="$MOCK_BIN:$PATH"
    local state_dir
    state_dir="$(cd "$WORK_DIR/mock-state" && pwd)"
    export MOCK_STATE_DIR="$state_dir"
}

# ── Main ────────────────────────────────────────────────────────────────────
setup_mocks

# Root simulieren: Der Installer verlangt EUID 0 (pct create etc.). In der
# Sandbox gibt es kein sudo – wir mappen den User per user-namespace auf root
# (unshare -rm), damit der getestete Pfad exakt der Production-Pfad ist.
RUN_PREFIX=(bash "$INSTALLER")
if [[ "$(id -u)" -ne 0 ]] && command -v unshare >/dev/null 2>&1 && unshare -rm true 2>/dev/null; then
    RUN_PREFIX=(unshare -rm bash "$INSTALLER")
fi

echo "🧪 Mock-Harness activitywatch.sh"
echo "   Installationsverzeichnis: $INSTALLER"
echo

# Startzustand: KEIN CT vorhanden (pct list-Mock liest list.txt, das hier
# leer bleibt) – der Happy-Path legt CT 200 selbst an.
mkdir -p "$MOCK_STATE_DIR"
: > "$MOCK_STATE_DIR/list.txt"

test_help() {
    echo "→ --help"
    local out
    out=$("${RUN_PREFIX[@]}" --help 2>&1)
    if [[ "$out" == *"ActivityWatch"* && "$out" == *"--update"* ]]; then
        pass "--help zeigt Titel + Optionen"
    else
        fail "--help Ausgabe unerwartet"
    fi
}

test_unit_templates_match_repo() {
    echo "→ Unit-Templates: Installer vs systemd/ (Drift-Schutz)"
    local rc=0
    bash "$INSTALLER" --print-unit activitywatch | diff -q - "$REPO_ROOT/systemd/activitywatch.service" >/dev/null || rc=1
    bash "$INSTALLER" --print-unit aw-watcher-afk | diff -q - "$REPO_ROOT/systemd/aw-watcher-afk.service" >/dev/null || rc=2
    if [[ $rc -eq 0 ]]; then
        pass "Installer-Templates identisch mit systemd/*.service"
    else
        fail "Unit-Drift (diff $rc): bash install/activitywatch.sh --print-unit <unit> | diff - systemd/<unit>.service"
    fi
}

test_zero_fallback() {
    # Grube 8 (bash -c): Optionen hinter dem Script-String landen in $0, nicht $1.
    echo "→ \$0-Fallback (bash -c \"\$(cat …)\" --status)"
    local out rc
    set +e
    out=$(bash -c "$(cat "$INSTALLER")" --status 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 && "$out" == *"Kein Container"* ]]; then
        pass "--status über \$0-Fallback erkannt (Grube bash -c)"
    else
        fail "\$0-Fallback: rc=$rc, Ausgabe: $(echo "$out" | tail -2)"
    fi
}

test_status_not_found() {
    echo "→ --status (kein CT)"
    local out
    out=$("${RUN_PREFIX[@]}" --status 2>&1) || true
    if [[ "$out" == *"Kein Container"* ]]; then
        pass "--status ohne CT: saubere Meldung"
    else
        fail "--status ohne CT: '$out'"
    fi
}

test_install_happy() {
    echo "→ Install (happy path, In-Container-Setup-Mock)"
    local out rc
    set +e
    out=$("${RUN_PREFIX[@]}" --yes --hostname activitywatch 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        pass "Install exit 0"
    else
        fail "Install exit $rc – Ausgabe: $out"
        return
    fi
    if [[ "$out" == *"Container 200 erstellt"* ]]; then
        pass "pct create 200 aufgerufen (nächste freie ID ab 200)"
    elif [[ "$out" == *"Container 201 erstellt"* ]]; then
        pass "pct create 201 aufgerufen (IDScan: 200 belegt)"
    else
        fail "CT nicht gemeldet: $(echo "$out" | grep -o 'Container [0-9]* erstellt' | head -1)"
    fi
    if [[ "$out" == *"Neueste ActivityWatch-Version: 0.14.3"* ]]; then
        pass "GitHub-API-Version aufgelöst (0.14.3)"
    else
        fail "Versionsauflösung fehlt: $(echo "$out" | grep -i version | head -2)"
    fi
    if [[ "$out" == *"setup-inner.sh ausgeführt"* ]]; then
        pass "In-Container-Setup (Bundle + Units + Services) lief durch"
    else
        fail "In-Container-Setup nicht gemeldet"
    fi
    if [[ "$out" == *"API antwortet (HTTP 200"* ]]; then
        pass "Verifikation API HTTP 200"
    else
        fail "API-Verifikation nicht gemeldet: $(echo "$out" | grep -i http | head -3)"
    fi
    if [[ "$out" == *"ActivityWatch ist bereit"* ]]; then
        pass "Summary-Box ausgegeben"
    else
        fail "Summary fehlt"
    fi
    if [[ "$out" == *"Web-UI:      http://"* ]]; then
        pass "Web-UI-URL in Summary"
    else
        fail "Web-UI-URL fehlt in Summary"
    fi
    if [[ "$out" == *"👀 AFK-Watcher: aktiv"* ]]; then
        pass "Watcher-Status in Summary (aktiv)"
    else
        fail "Watcher-Status fehlt in Summary"
    fi
    # Unit-Push-Inhalt: Port-Ersetzung @PORT@ -> 5600 (lokaler Name = activitywatch.service)
    if grep -q -- "--port 5600" "$MOCK_STATE_DIR/pushed/activitywatch.service" 2>/dev/null \
        && ! grep -q "@PORT@" "$MOCK_STATE_DIR/pushed/activitywatch.service" 2>/dev/null; then
        pass "activitywatch.service gepusht mit ersetztem Port (5600)"
    else
        fail "Unit-Push: Port nicht ersetzt oder Unit nicht gepusht"
    fi
}

test_install_no_watcher() {
    echo "→ Install --no-watcher (eigener State, CT 201)"
    local out rc
    set +e
    out=$("${RUN_PREFIX[@]}" --yes --no-watcher --id 201 --force 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        pass "Install --no-watcher exit 0"
    else
        fail "--no-watcher exit $rc – $(echo "$out" | tail -3)"
        return
    fi
    if [[ "$out" == *"deaktiviert (--no-watcher)"* ]]; then
        pass "Summary meldet Watcher deaktiviert"
    else
        fail "--no-watcher nicht in Summary: $(echo "$out" | grep -i watcher | head -3)"
    fi
    if [[ -f "$MOCK_STATE_DIR/201.aw-watcher-afk.active" ]]; then
        fail "Watcher-Service wurde trotz --no-watcher simuliert"
    else
        pass "Watcher-Service bei --no-watcher nicht installiert"
    fi
    # State für Folge-Tests zurücksetzen (nur Watcher-Flag), CT 200 bleibt Referenz
}

test_install_idempotent() {
    echo "→ Install erneut (gleicher Hostname → Abbruch ohne --force)"
    local out rc
    set +e
    out=$("${RUN_PREFIX[@]}" --yes --hostname activitywatch 2>&1)
    rc=$?
    set -e
    if [[ $rc -ne 0 && "$out" == *"existiert bereits"* ]]; then
        pass "zweiter Install ohne --force bricht sauber ab"
    else
        fail "Idempotenz-Bruch (rc=$rc): $(echo "$out" | tail -2)"
    fi
}

test_update() {
    echo "→ --update"
    local out rc
    set +e
    out=$("${RUN_PREFIX[@]}" --update --yes 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        pass "--update exit 0"
    else
        fail "--update exit $rc – $(echo "$out" | tail -3)"
        return
    fi
    if [[ "$out" == *"setup-inner.sh ausgeführt"* ]]; then
        pass "--update aktualisiert App (In-Container-Setup)"
    else
        fail "--update: Update-Meldung fehlt"
    fi
    if [[ "$out" == *"blieb erhalten"* ]]; then
        pass "--update meldet erhaltene Datenbank"
    else
        fail "--update: Datenbank-Hinweis fehlt"
    fi
}

test_status_running() {
    echo "→ --status (CT läuft)"
    local out
    out=$("${RUN_PREFIX[@]}" --status 2>&1)
    if [[ "$out" == *"running"* && "$out" == *"Web-UI"* && "$out" == *"0.14.3"* ]]; then
        pass "--status zeigt laufenden CT + Web-UI + Version"
    else
        fail "--status: '$out'"
    fi
}

test_uninstall() {
    echo "→ --uninstall --yes"
    local out rc
    set +e
    out=$("${RUN_PREFIX[@]}" --uninstall --yes 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 && "$out" == *"gelöscht"* ]]; then
        pass "--uninstall löscht CT"
    else
        fail "--uninstall (rc=$rc): $(echo "$out" | tail -2)"
    fi
    out=$("${RUN_PREFIX[@]}" --status 2>&1) || true
    if [[ "$out" == *"Kein Container"* ]]; then
        pass "--status nach uninstall: kein CT"
    else
        fail "--status nach uninstall: '$out'"
    fi
}

test_invalid_port() {
    echo "→ --port abc (Validierung)"
    local out rc
    set +e
    out=$("${RUN_PREFIX[@]}" --port abc --yes 2>&1)
    rc=$?
    set -e
    if [[ $rc -ne 0 && "$out" == *"Ungültiger Port"* ]]; then
        pass "ungültiger Port → sauberer Abbruch"
    else
        fail "Port-Validierung: '$out'"
    fi
}

test_invalid_aw_version() {
    echo "→ --aw-version 14.3 (Format-Validierung)"
    local out rc
    set +e
    out=$("${RUN_PREFIX[@]}" --aw-version 14.3 --yes 2>&1)
    rc=$?
    set -e
    if [[ $rc -ne 0 && "$out" == *"Ungültige --aw-version"* ]]; then
        pass "ungültige --aw-version → sauberer Abbruch"
    else
        fail "aw-version-Validierung: '$out'"
    fi
}

test_help
test_unit_templates_match_repo
test_zero_fallback
test_status_not_found
test_install_happy
test_install_no_watcher
test_install_idempotent
test_update
test_status_running
test_uninstall
test_invalid_port
test_invalid_aw_version

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Ergebnis: $(green "$PASS passed") / $(red "$FAIL failed")"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ "$FAIL" -eq 0 ]]
