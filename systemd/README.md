# systemd-Units

Die Units hier sind **Referenzkopien** – die Single Source of Truth liegt im
Installer (`install/activitywatch.sh`, Funktion `print_unit`), weil das
Install-Script als Einzeiler standalone von GitHub geladen wird und keine
Repo-Dateien mitbringen kann.

- `@PORT@` wird beim `pct push` durch den gewählten Port ersetzt (Default `5600`).
- Der Mock-Harness (`test/mock-harness.sh`) prüft per `--print-unit`, dass
  Installer-Templates und die Dateien hier identisch sind (Drift-Schutz).

## activitywatch.service
`aw-server-rust` als System-User `activitywatch` (Home `/var/lib/activitywatch`,
dort liegt auch die SQLite-Datenbank), `Restart=always`, Start nach
`network-online.target`.

## aw-watcher-afk.service
`aw-watcher-afk` (frozen Binary aus dem offiziellen Release-Bundle) unter
Xvfb (`xvfb-run -a`): pynput braucht zwingend einen X-Server, im headless LXC
springt Xvfb ein. Im Container gibt es keine echte Eingabe → der AFK-Bucket
zeigt dauerhaft AFK (Funktionstest der Pipeline; echtes Tracking passiert auf
Client-Geräten). Wird bei `--no-watcher` nicht installiert.
