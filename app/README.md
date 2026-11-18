# ActivityWatch – Komponenten im Container

Dieses Repo baut die App NICHT selbst – der Installer lädt das **offizielle
Release-Bundle** von `ActivityWatch/activitywatch` (GitHub Releases) und
installiert daraus die zwei headless-tauglichen Komponenten:

| Komponente | Quelle im Bundle | Zweck |
|---|---|---|
| `aw-server-rust` | `activitywatch/aw-server-rust/aw-server-rust` | REST-API + SQLite-Datastore + **eingebettete aw-webui** (rust-embed → `GET /` liefert die Web-UI direkt aus dem Binary) |
| `aw-watcher-afk` | `activitywatch/aw-watcher-afk/` (PyInstaller-onedir, self-contained) | AFK-Erkennung; läuft im headless LXC unter Xvfb |

Bewusst NICHT installiert (Desktop-Komponenten des Bundles): `aw-qt`
(Tray-Icon), `aw-watcher-window` / `aw-watcher-input` (brauchen einen echten
Desktop), `aw-notify`, `aw-server` (legacy Python-Server – rust ist der
offizielle Standard).

## Container-Layout

```
/opt/activitywatch/
  aw-server-rust/aw-server-rust     # Binary (--version → "aw-server X.Y.Z")
  aw-watcher-afk/aw-watcher-afk     # Frozen-Watcher + mitgebündelte libs
  INSTALL_INFO                      # Version/Port/Datum (für --status)
/var/lib/activitywatch/             # $HOME des System-Users
  .local/share/activitywatch/       # SQLite-Datastore (bleibt bei Updates!)
/etc/systemd/system/
  activitywatch.service
  aw-watcher-afk.service            # nur ohne --no-watcher
```

## Versionen / Pinnung

- Default: neuestes Release via GitHub-API (`.../releases/latest`).
- Fixpin: `--aw-version 0.14.3` (oder Variable `AW_VERSION` im Installer).
- Fallback (API nicht erreichbar): `AW_FALLBACK_VERSION` im Installer.
- Getestet mit **v0.14.3** (Bundle `activitywatch-v0.14.3-linux-x86_64-manylinux_2_28.zip`,
  ~158 MB; aw-server-rust Binary 38 MB inkl. Web-UI, watcher onedir ~35 MB).

## Kompatibilität

- Bundle: `manylinux_2_28` (glibc ≥ 2.28) – Debian 12 hat glibc 2.36 ✓.
- `aw-server-rust`Flags: `--host 0.0.0.0 --port 5600` (verifiziert lokal:
  `/api/0/info` → `{"version":"v0.14.3 (rust)", ...}`, `GET /` → Web-UI-HTML).
- `aw-watcher-afk` (pynput) braucht einen X-Server → Xvfb im CT; ohne X crasht
  das Binary hart (`ImportError: failed to acquire X connection`).
