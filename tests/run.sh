#!/usr/bin/env bash
# API-Tests von AuslagenFlow (Bash, ohne Framework und ohne Abhängigkeiten).
# Laufen in der Testumgebung (~/projects/testumgebung):
#   pt test                 mit Syntax- und Linkprüfung
#   pt bash tests/run.sh    nur diese Tests
#   pt offen                danach bleibt der Server unter http://localhost:8002 offen
# Brauchen php (mit pdo_mysql), MariaDB, curl und jq. Arbeiten auf einer Kopie des Arbeitsstands (ohne ignorierte
# Dateien wie api/config/config.php) mit einer Wegwerf-MariaDB in einem temporären Ordner; im Repo entsteht nichts.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${TEST_PORT:-8002}"
DBPORT="${TEST_DB_PORT:-3398}"
U="http://localhost:$PORT"
for t in php curl jq git mariadbd mariadb mariadb-install-db; do
  command -v "$t" >/dev/null || { echo "$t fehlt – in der Testumgebung ausführen: ~/projects/testumgebung/pt test" >&2; exit 2; }
done

TMP="$(mktemp -d)"
SRV=
aufraeumen() {
  [ -n "$SRV" ] && kill "$SRV" 2>/dev/null
  [ -f "$TMP/db/pid" ] && kill "$(cat "$TMP/db/pid")" 2>/dev/null && while [ -S "$TMP/db/sock" ]; do sleep 0.2; done
  rm -rf "$TMP"
}
trap aufraeumen EXIT

ANZAHL=0
FEHLER=0
# pruefe <name> <antwort> <jq-ausdruck>
pruefe() {
  ANZAHL=$((ANZAHL + 1))
  if echo "$2" | jq -e "$3" >/dev/null 2>&1; then echo "ok   $1"
  else echo "FAIL $1: ${2:0:300}"; FEHLER=$((FEHLER + 1)); fi
}
api() { curl -s -b "$TMP/cookies" -c "$TMP/cookies" -H 'X-VA-Anfrage: 1' -H "Origin: $U" -H 'Content-Type: application/json' "$@"; }

# Wegwerf-MariaDB mit leerer Datenbank af
mkdir -p "$TMP/db"
mariadb-install-db --no-defaults --datadir="$TMP/db/daten" --auth-root-authentication-method=socket --skip-test-db >/dev/null \
  || { echo "mariadb-install-db fehlgeschlagen" >&2; exit 1; }
mariadbd --no-defaults --datadir="$TMP/db/daten" --socket="$TMP/db/sock" --port="$DBPORT" --bind-address=127.0.0.1 \
  --skip-name-resolve --pid-file="$TMP/db/pid" --log-error="$TMP/db/fehler.log" &
for _ in $(seq 1 60); do [ -S "$TMP/db/sock" ] && break; sleep 0.5; done
mariadb --socket="$TMP/db/sock" -e "CREATE DATABASE af; CREATE USER 'af'@'127.0.0.1' IDENTIFIED BY 'af';
  GRANT ALL ON af.* TO 'af'@'127.0.0.1';" || { echo "MariaDB startet nicht:"; tail -5 "$TMP/db/fehler.log"; exit 1; }

# Kopie des Arbeitsstands, Server starten
mkdir -p "$TMP/app"
(cd "$ROOT" && git ls-files -co --exclude-standard -z | tar --null -T - -c) | tar -x -C "$TMP/app"
php -S "0.0.0.0:$PORT" -t "$TMP/app" >"$TMP/server.log" 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "$U/" && break; sleep 0.2; done

pruefe "Startseite" "$(curl -s "$U/" | grep -c '<html')" '. > 0'
pruefe "Status vor der Einrichtung" "$(api "$U/api/?r=status")" '.ok == true and .eingerichtet == false and .benutzer == null'
pruefe "Einrichtung" "$(api -X POST "$U/api/?r=einrichtung" \
  -d "{\"db\":{\"host\":\"127.0.0.1\",\"port\":$DBPORT,\"name\":\"af\",\"benutzer\":\"af\",\"passwort\":\"af\"},\"admin\":{\"benutzername\":\"admin\",\"passwort\":\"Test-Passwort-123!\"}}")" '.fehler == null'
pruefe "Anmeldung" "$(api -X POST "$U/api/?r=anmeldung/passwort" -d '{"benutzername":"admin","passwort":"Test-Passwort-123!"}')" '.benutzer != null'
pruefe "Status angemeldet" "$(api "$U/api/?r=status")" '.ok == true and .eingerichtet == true and .benutzer.benutzername == "admin"'

echo "$ANZAHL Prüfungen, $FEHLER fehlgeschlagen"
if [ "$FEHLER" -gt 0 ]; then echo "Serverprotokoll:"; tail -20 "$TMP/server.log"; fi

if [ -n "${OFFEN:-}" ]; then
  echo "Läuft: $U/ (Anmeldung admin / Test-Passwort-123!) – Strg+C beendet"
  wait "$SRV"
fi
[ "$FEHLER" -eq 0 ]
