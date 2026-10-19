#!/usr/bin/env bash
# API-Tests von AuslagenFlow (Bash, ohne Framework und ohne Abhängigkeiten).
# Laufen in der Testumgebung (~/projects/testumgebung):
#   pt test                 mit Syntax- und Linkprüfung
#   pt bash tests/run.sh    nur diese Tests
#   pt offen                danach bleibt der Server unter http://localhost:8002 offen
#   pt abdeckung            mit Zeilen-Coverage der PHP-Dateien
# Brauchen php (mit pdo_mysql), MariaDB, curl und jq. Arbeiten auf einer Kopie des Arbeitsstands (ohne ignorierte
# Dateien wie api/config/config.php) mit einer Wegwerf-MariaDB in einem temporären Ordner; im Repo entsteht nichts.
# PHP läuft mit eingeschalteter Fehleranzeige (ungünstigster Fall auf Webspaces): Warnungen oder Pfade in
# Antworten fallen so in der Leck-Prüfung am Ende auf.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${TEST_PORT:-8002}"
DBPORT="${TEST_DB_PORT:-3398}"
U="http://127.0.0.1:$PORT"
PHP_SERVER="${PHP_SERVER:-php}"   # pt abdeckung setzt hier PHP mit Xdebug
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
abschnitt() { printf '\n-- %s\n' "$1"; }
sql() { mariadb --socket="$TMP/db/sock" -N af -e "$1"; }

# Akteure: je eigener Cookie-Speicher und eigene Absenderadresse, weil die Login-Sperre auch je IP zählt
declare -A IP=([test]=127.0.0.1 [gast]=127.0.0.2 [admin]=127.0.0.3 [anna]=127.0.0.4 [ben]=127.0.0.5
  [kai]=127.0.0.6 [vera]=127.0.0.7 [anna2]=127.0.0.8 [fix]=127.0.0.9 [sperre]=127.0.0.10 [sperre2]=127.0.0.11
  [ipsperre]=127.0.0.12 [tom]=127.0.0.13 [tom2]=127.0.0.14 [tom3]=127.0.0.15 [tom4]=127.0.0.16 [tom5]=127.0.0.17
  [pia]=127.0.0.18 [pk]=127.0.0.19 [pk2]=127.0.0.20 [pk3]=127.0.0.21 [pk4]=127.0.0.22 [weg]=127.0.0.23 [eva]=127.0.0.24 [uwe]=127.0.0.25 [sigi]=127.0.0.26
  [ida]=127.0.0.27 [jan]=127.0.0.28)
LOG="$TMP/antworten.log"

# als <akteur> <curl-argumente …>  → Antwort (mit Pflicht-Header und passendem Origin); jede Antwort ins Protokoll
als() {
  local wer=$1; shift
  local r; r="$(curl -s --interface "${IP[$wer]}" -b "$TMP/k_$wer" -c "$TMP/k_$wer" \
    -H 'X-VA-Anfrage: 1' -H "Origin: $U" -H 'Content-Type: application/json' "$@" | tr -d '\0')"
  printf '%s\n' "$r" >> "$LOG"; printf '%s' "$r"
}
# status <akteur> <curl-argumente …>  → nur der HTTP-Status (Antwort trotzdem ins Protokoll)
status() {
  local wer=$1; shift
  local r; r="$(curl -s --interface "${IP[$wer]}" -b "$TMP/k_$wer" -c "$TMP/k_$wer" \
    -H 'X-VA-Anfrage: 1' -H "Origin: $U" -H 'Content-Type: application/json' -w '\n%{http_code}' "$@" | tr -d '\0')"
  printf '%s\n' "$r" >> "$LOG"; printf '%s' "${r##*$'\n'}"
}
api() { als test "$@"; }

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
# shellcheck disable=SC2086
$PHP_SERVER -d display_errors=1 -d display_startup_errors=1 -d error_reporting=-1 \
  -S "0.0.0.0:$PORT" -t "$TMP/app" >"$TMP/server.log" 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "$U/" && break; sleep 0.2; done

abschnitt "Grundfunktionen"
pruefe "Startseite" "$(curl -s "$U/" | grep -c '<html')" '. > 0'
pruefe "Status vor der Einrichtung" "$(api "$U/api/?r=status")" '.ok == true and .eingerichtet == false and .benutzer == null'
pruefe "Einrichtung" "$(api -X POST "$U/api/?r=einrichtung" \
  -d "{\"db\":{\"host\":\"127.0.0.1\",\"port\":$DBPORT,\"name\":\"af\",\"benutzer\":\"af\",\"passwort\":\"af\"},\"admin\":{\"benutzername\":\"admin\",\"passwort\":\"Test-Passwort-123!\"}}")" '.fehler == null'
pruefe "Anmeldung" "$(api -X POST "$U/api/?r=anmeldung/passwort" -d '{"benutzername":"admin","passwort":"Test-Passwort-123!"}')" '.benutzer != null'
pruefe "Status angemeldet" "$(api "$U/api/?r=status")" '.ok == true and .eingerichtet == true and .benutzer.benutzername == "admin"'

# shellcheck source=tests/sicherheit.sh
. "$ROOT/tests/sicherheit.sh"
# shellcheck source=tests/routen.sh
. "$ROOT/tests/routen.sh"

echo
echo "$ANZAHL Prüfungen, $FEHLER fehlgeschlagen"
if [ "$FEHLER" -gt 0 ]; then echo "Serverprotokoll:"; tail -20 "$TMP/server.log"; fi

if [ -n "${OFFEN:-}" ]; then
  echo "Läuft: http://localhost:$PORT/ (Anmeldung admin / Test-Passwort-123!) – Strg+C beendet"
  wait "$SRV"
fi
[ "$FEHLER" -eq 0 ]
