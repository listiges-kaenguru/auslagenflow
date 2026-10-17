# Sicherheits- und Negativtests von AuslagenFlow. Wird von tests/run.sh eingebunden (Server, Datenbank, Helfer
# und Einrichtung als admin stehen dort bereit), nicht allein ausführen.
# Abschnitte: ohne Anmeldung, Benutzer, fremde Daten, Kasse, Admin-Rechte, Sitzungen, CSRF, Login-Sperre,
# Zwei-Faktor, Passkeys, Injection, Eingabevalidierung, Fehlermeldungen.

A="$U/api/?r="
HEUTE="$(date +%F)"
PNG_B64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
printf '%s' "$PNG_B64" | base64 -d > "$TMP/beleg.png"
json() { jq -cn "$@"; }
lang() { printf "%${2}s" '' | sed "s/ /$1/g"; }
# beleg <akteur> <auslage-id> <datei> <typ> → Antwort (Binärdaten mit eigenem Content-Type)
beleg() {
  local r; r="$(curl -s --interface "${IP[$1]}" -b "$TMP/k_$1" -c "$TMP/k_$1" -H 'X-VA-Anfrage: 1' -H "Origin: $U" \
    -H "Content-Type: $4" -X PUT --data-binary @"$3" "${A}beleg&id=$2")"
  printf '%s\n' "$r" >> "$LOG"; printf '%s' "$r"
}
# roh <akteur> <curl-argumente …> → HTTP-Status ohne die Standard-Header (für CSRF-Prüfungen)
roh() {
  local wer=$1; shift
  local r; r="$(curl -s --interface "${IP[$wer]}" -b "$TMP/k_$wer" -c "$TMP/k_$wer" -w '\n%{http_code}' "$@")"
  printf '%s\n' "$r" >> "$LOG"; printf '%s' "${r##*$'\n'}"
}
auslage() { als "$1" -X POST "${A}auslagen" -d "$(json --arg d "$HEUTE" --arg h "$2" '{datum: $d, haendler: $h, betrag: 12.5, notiz: ""}')"; }
# anlegen <name> [kassenrolle] → Startpasswort; einrichten <akteur> <name> <start> <neu> → anmelden und Passwort setzen
anlegen() { als admin -X POST "${A}admin/benutzer" -d "$(json --arg n "$1" --arg k "${2:-keine}" '{benutzername: $n, kassenrolle: $k}')" | jq -r '.startpasswort'; }
anmelden() { als "$1" -X POST "${A}anmeldung/passwort" -d "$(json --arg n "$2" --arg p "$3" '{benutzername: $n, passwort: $p}')"; }
einrichten() { anmelden "$1" "$2" "$3" >/dev/null; als "$1" -X POST "${A}profil/passwort" -d "$(json --arg a "$3" --arg n "$4" '{alt: $a, neu: $n}')" >/dev/null; }

# ---------------------------------------------------------------------------------------------------------
abschnitt "Ohne Anmeldung: geschützte Routen → 401"
for r in 'GET auslagen' 'POST auslagen' 'PUT auslagen&id=x' 'DELETE auslagen&id=x' 'GET beleg&id=x' 'DELETE beleg&id=x' \
  'GET einreichungen' 'POST einreichungen' 'GET einreichungen/pdf&id=x' 'POST einreichungen/zurueckziehen' \
  'GET kommentare&einreichung=x' 'POST kommentare' 'GET kommentare/ungelesen' 'GET kasse/auslagen' 'GET kasse/beleg&id=x' \
  'POST kasse/einreichung/status' 'GET admin/benutzer' 'POST admin/benutzer' 'GET admin/db' 'POST admin/db/test' \
  'GET profil' 'PUT profil/stammdaten' 'POST profil/passwort' 'POST profil/totp/start' 'POST profil/passkey-optionen' \
  'GET profil/version'; do
  set -- $r
  pruefe "ohne Login: $1 $2 → 401" "$(status gast -X "$1" "$A$2" $([ "$1" != GET ] && echo -d '{}'))" '. == 401'
done
pruefe "ohne Login: Status liefert keinen Benutzer" "$(als gast "${A}status")" '.ok == true and .benutzer == null'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Benutzer anlegen, Pflicht zum Passwortwechsel"
anmelden admin admin 'Test-Passwort-123!' >/dev/null
START="$(anlegen anna)"
pruefe "Admin legt Benutzer an, Startpasswort 14 Zeichen" "$(json --arg s "$START" '$s')" 'length == 14'
anmelden anna anna "$START" >/dev/null
pruefe "neuer Benutzer: vor dem Passwortwechsel gesperrt → 403" "$(status anna "${A}auslagen")" '. == 403'
pruefe "Passwortwechsel: zu kurz → 400" "$(status anna -X POST "${A}profil/passwort" -d "$(json --arg a "$START" '{alt: $a, neu: "kurz-123"}')")" '. == 400'
pruefe "Passwortwechsel: falsches altes Passwort → 403" "$(status anna -X POST "${A}profil/passwort" -d '{"alt":"falsch","neu":"Anna-Passwort-1"}')" '. == 403'
pruefe "Passwortwechsel" "$(als anna -X POST "${A}profil/passwort" -d "$(json --arg a "$START" '{alt: $a, neu: "Anna-Passwort-1"}')")" '.ok == true'
pruefe "neuer Benutzer: danach Zugriff" "$(status anna "${A}auslagen")" '. == 200'
ANNA_PW='Anna-Passwort-1'
einrichten ben ben "$(anlegen ben)" 'Ben-Passwort-1'
einrichten kai kai "$(anlegen kai kassenwart)" 'Kai-Passwort-1'
einrichten vera vera "$(anlegen vera vorstand)" 'Vera-Passwort-1'
ID_BEN="$(sql "SELECT id FROM va_benutzer WHERE benutzername = 'ben'")"
ID_ANNA="$(sql "SELECT id FROM va_benutzer WHERE benutzername = 'anna'")"
ID_ADMIN="$(sql "SELECT id FROM va_benutzer WHERE benutzername = 'admin'")"

# ---------------------------------------------------------------------------------------------------------
abschnitt "Fremde Daten: Ben kommt nicht an Annas Auslagen, Belege und Einreichungen"
X="$(auslage anna 'Annas Einkauf' | jq -r '.auslage.id')"
Y="$(auslage anna 'Annas offene Auslage' | jq -r '.auslage.id')"
beleg anna "$X" "$TMP/beleg.png" image/png >/dev/null
beleg anna "$Y" "$TMP/beleg.png" image/png >/dev/null
pruefe "Anna: Auslagen mit Beleg angelegt" "$(als anna "${A}auslagen")" '[.auslagen[] | select(.hatFoto)] | length == 2'
pruefe "Ben: sieht Annas Auslagen nicht" "$(als ben "${A}auslagen")" '.auslagen | length == 0'
pruefe "Ben: fremden Beleg abrufen → 404" "$(status ben "${A}beleg&id=$X")" '. == 404'
pruefe "Ben: fremde Auslage ändern → 404" "$(status ben -X PUT "${A}auslagen&id=$X" -d '{"haendler":"übernommen"}')" '. == 404'
pruefe "Ben: fremden Beleg ersetzen → 404" "$(beleg ben "$X" "$TMP/beleg.png" image/png)" '.fehler | test("nicht gefunden")'
pruefe "Ben: fremden Beleg löschen → 404" "$(status ben -X DELETE "${A}beleg&id=$X")" '. == 404'
als ben -X DELETE "${A}auslagen&id=$X" >/dev/null
pruefe "Ben: Löschversuch lässt Annas Auslage bestehen" "$(sql "SELECT COUNT(*) FROM va_auslagen WHERE id = '$X'")" '. == 1'
pruefe "Ben: Auslage mit Annas ID anlegen → neue ID" \
  "$(als ben -X POST "${A}auslagen" -d "$(json --arg d "$HEUTE" --arg i "$X" '{id: $i, datum: $d, haendler: "Kopie", betrag: 1}')" | jq --arg x "$X" '.auslage.id != $x')" '. == true'
pruefe "Annas Auslage unverändert" "$(json --arg v "$(sql "SELECT CONCAT(haendler, '|', benutzer_id) FROM va_auslagen WHERE id = '$X'")" '$v')" ". == \"Annas Einkauf|$ID_ANNA\""
pruefe "Ben: fremde Auslage einreichen → 409" "$(status ben -X POST "${A}einreichungen" -d "$(json --arg x "$X" '{ids: [$x]}')")" '. == 409'
E="$(als anna -X POST "${A}einreichungen" -d "$(json --arg x "$X" '{ids: [$x]}')" | jq -r '.einreichung.id')"
pruefe "Anna: Einreichung angelegt" "$(json --arg e "$E" '$e')" 'length == 36'
pruefe "Ben: fremdes Einreichungs-PDF → 404" "$(status ben "${A}einreichungen/pdf&id=$E")" '. == 404'
pruefe "Ben: fremde Kommentare lesen → 404" "$(status ben "${A}kommentare&einreichung=$E")" '. == 404'
pruefe "Ben: fremde Einreichung kommentieren → 404" "$(status ben -X POST "${A}kommentare" -d "$(json --arg e "$E" '{einreichungId: $e, text: "hallo"}')")" '. == 404'
pruefe "Ben: fremde Einreichung zurückziehen → 404" "$(status ben -X POST "${A}einreichungen/zurueckziehen" -d "$(json --arg e "$E" '{id: $e}')")" '. == 404'
pruefe "Ben: Einreichungsliste ohne Annas" "$(als ben "${A}einreichungen")" '.einreichungen | length == 0'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Kasse: nur Kassenwart und Vorstand, nur eingereichte Auslagen"
pruefe "Mitglied: Kasse → 403" "$(status ben "${A}kasse/auslagen")" '. == 403'
pruefe "Mitglied: fremder Beleg über die Kasse → 403" "$(status ben "${A}kasse/beleg&id=$X")" '. == 403'
pruefe "Kassenwart: sieht die eingereichte Auslage" "$(als kai "${A}kasse/auslagen" | jq --arg x "$X" '[.. | objects | select(.id? == $x)] | length > 0')" '. == true'
pruefe "Kassenwart: sieht die offene Auslage nicht" "$(als kai "${A}kasse/auslagen" | jq --arg y "$Y" '[.. | objects | select(.id? == $y)] | length == 0')" '. == true'
pruefe "Kassenwart: Beleg der eingereichten Auslage" "$(status kai "${A}kasse/beleg&id=$X")" '. == 200'
pruefe "Kassenwart: Beleg der offenen Auslage → 404" "$(status kai "${A}kasse/beleg&id=$Y")" '. == 404'
pruefe "Kassenwart: eigene Auslagenliste ohne Annas" "$(als kai "${A}auslagen")" '.auslagen | length == 0'
pruefe "Vorstand: sieht die Kasse" "$(status vera "${A}kasse/auslagen")" '. == 200'
pruefe "Vorstand: Erstattung veranlassen → 403" "$(als vera -X POST "${A}kasse/einreichung/status" -d "$(json --arg e "$E" '{id: $e, status: "veranlasst"}')")" '.fehler == "Nur für den Kassenwart."'
pruefe "Status unverändert eingereicht" "$(json --arg s "$(sql "SELECT status FROM va_auslagen WHERE id = '$X'")" '$s')" '. == "eingereicht"'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Admin-Rechte"
for r in 'GET admin/benutzer' 'POST admin/benutzer' "PUT admin/benutzer&id=$ID_BEN" "POST admin/benutzer/passwort&id=$ID_BEN" \
  "POST admin/benutzer/mfa-zuruecksetzen&id=$ID_BEN" "POST admin/benutzer/loeschen&id=$ID_BEN" 'GET admin/db' 'POST admin/db/test' 'POST admin/db'; do
  set -- $r
  pruefe "Mitglied: $1 ${2%%&*} → 403" "$(status anna -X "$1" "$A$2" $([ "$1" != GET ] && echo -d '{"benutzername":"xyz","aktiv":false,"passwort":"x"}'))" '. == 403'
done
pruefe "Ben nach den Versuchen weiter aktiv" "$(sql "SELECT aktiv FROM va_benutzer WHERE id = $ID_BEN")" '. == 1'
pruefe "Admin: sieht keine fremden Auslagen" "$(als admin "${A}auslagen")" '.auslagen | length == 0'
pruefe "Admin: fremder Beleg → 404" "$(status admin "${A}beleg&id=$X")" '. == 404'
pruefe "Admin: sich selbst sperren → 400" "$(status admin -X PUT "${A}admin/benutzer&id=$ID_ADMIN" -d '{"aktiv":false}')" '. == 400'
pruefe "Admin: letzter Admin nicht herabstufbar" "$(status admin -X PUT "${A}admin/benutzer&id=$ID_ADMIN" -d '{"rolle":"user"}')" '. == 400'
pruefe "Admin: ungültige Kassenrolle → 400" "$(status admin -X PUT "${A}admin/benutzer&id=$ID_BEN" -d '{"kassenrolle":"chef"}')" '. == 400'
pruefe "Admin: Löschen nur mit eigenem Passwort → 403" "$(status admin -X POST "${A}admin/benutzer/loeschen&id=$ID_BEN" -d '{"passwort":"falsch"}')" '. == 403'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Sitzungen"
pruefe "manipuliertes Sitzungscookie → 401" "$(curl -s -o /dev/null -w '%{http_code}' -b 'VA_SITZUNG=manipuliert123' "${A}auslagen")" '. == 401'
KOPF="$(curl -s -D - -o /dev/null --interface "${IP[fix]}" -H 'X-VA-Anfrage: 1' -H "Origin: $U" -H 'Content-Type: application/json' \
  -b 'VA_SITZUNG=fixiert1234567890' -X POST "${A}anmeldung/passwort" -d "$(json --arg p "$ANNA_PW" '{benutzername: "anna", passwort: $p}')")"
pruefe "Session-Fixation: Anmeldung vergibt neue Sitzungs-ID" "$(printf '%s' "$KOPF" | grep -i '^set-cookie: VA_SITZUNG=' | grep -vc 'fixiert1234567890')" '. >= 1'
pruefe "Cookie mit HttpOnly und SameSite=Strict" "$(printf '%s' "$KOPF" | grep -i '^set-cookie: VA_SITZUNG=' | tail -1 | grep -ic 'httponly' )" '. >= 1'
pruefe "Cookie mit SameSite=Strict" "$(printf '%s' "$KOPF" | grep -i '^set-cookie: VA_SITZUNG=' | tail -1 | grep -ic 'samesite=strict')" '. >= 1'
KOPF="$(curl -s -D - -o /dev/null -b "$TMP/k_anna" "${A}auslagen" | tr -d '\r')"
for h in 'x-content-type-options: nosniff' 'cache-control: no-store' 'referrer-policy: no-referrer' "content-security-policy: default-src 'none'"; do
  pruefe "Sicherheits-Header: $h" "$(printf '%s' "$KOPF" | grep -ic "^$h")" '. >= 1'
done
anmelden anna2 anna "$ANNA_PW" >/dev/null
cp "$TMP/k_anna2" "$TMP/k_alt"
als anna2 -X POST "${A}abmeldung" -d '{}' >/dev/null
pruefe "nach dem Abmelden: altes Cookie → 401" "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/k_alt" "${A}auslagen")" '. == 401'
anmelden anna2 anna "$ANNA_PW" >/dev/null
pruefe "zweite Sitzung von Anna aktiv" "$(status anna2 "${A}auslagen")" '. == 200'
als anna -X POST "${A}profil/passwort" -d "$(json --arg a "$ANNA_PW" '{alt: $a, neu: "Anna-Passwort-2"}')" >/dev/null
ANNA_PW='Anna-Passwort-2'
pruefe "Passwortwechsel: eigene Sitzung bleibt" "$(status anna "${A}auslagen")" '. == 200'
pruefe "Passwortwechsel: andere Sitzung endet → 401" "$(status anna2 "${A}auslagen")" '. == 401'
als admin -X POST "${A}admin/benutzer/passwort&id=$ID_ANNA" -d '{}' >/dev/null
pruefe "Admin setzt Passwort zurück: Sitzung endet → 401" "$(status anna "${A}auslagen")" '. == 401'
als admin -X PUT "${A}admin/benutzer&id=$ID_BEN" -d '{"aktiv":false}' >/dev/null
pruefe "gesperrt: laufende Sitzung endet → 401" "$(status ben "${A}auslagen")" '. == 401'
pruefe "gesperrt: Anmeldung abgewiesen → 401" "$(status ben -X POST "${A}anmeldung/passwort" -d '{"benutzername":"ben","passwort":"Ben-Passwort-1"}')" '. == 401'

# ---------------------------------------------------------------------------------------------------------
abschnitt "CSRF: Schreibanfragen ohne Pflicht-Header oder von fremder Herkunft → 403"
H=(-H 'Content-Type: application/json')
pruefe "POST ohne X-VA-Anfrage → 403" "$(roh kai "${H[@]}" -H "Origin: $U" -X POST "${A}auslagen" -d '{}')" '. == 403'
pruefe "POST mit fremdem Origin → 403" "$(roh kai "${H[@]}" -H 'X-VA-Anfrage: 1' -H 'Origin: https://boese.example' -X POST "${A}auslagen" -d '{}')" '. == 403'
pruefe "POST mit Origin null → 403" "$(roh kai "${H[@]}" -H 'X-VA-Anfrage: 1' -H 'Origin: null' -X POST "${A}auslagen" -d '{}')" '. == 403'
pruefe "POST mit Origin anderer Port → 403" "$(roh kai "${H[@]}" -H 'X-VA-Anfrage: 1' -H 'Origin: http://127.0.0.1:1' -X POST "${A}auslagen" -d '{}')" '. == 403'
pruefe "Formular-POST (einfache Cross-Site-Anfrage) → 403" "$(roh kai -X POST "${A}auslagen" -d 'haendler=csrf')" '. == 403'
pruefe "DELETE ohne Header → 403" "$(roh kai -X DELETE "${A}auslagen&id=x")" '. == 403'
pruefe "Abmelden ohne Header → 403" "$(roh kai -X POST "${A}abmeldung")" '. == 403'
pruefe "Kai danach weiter angemeldet" "$(status kai "${A}auslagen")" '. == 200'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Login-Sperre und Benutzer-Aufzählung"
for i in 1 2 3 4 5; do
  pruefe "Fehlversuch $i für kai → 401" "$(status sperre -X POST "${A}anmeldung/passwort" -d '{"benutzername":"kai","passwort":"falsch-falsch"}')" '. == 401'
done
pruefe "6. Versuch für kai, auch mit richtigem Passwort → 429" \
  "$(status sperre -X POST "${A}anmeldung/passwort" -d '{"benutzername":"kai","passwort":"Kai-Passwort-1"}')" '. == 429'
pruefe "Sperre gilt für den Namen, auch von anderer Adresse → 429" \
  "$(status sperre2 -X POST "${A}anmeldung/passwort" -d '{"benutzername":"kai","passwort":"Kai-Passwort-1"}')" '. == 429'
pruefe "Kais laufende Sitzung bleibt" "$(status kai "${A}auslagen")" '. == 200'
for i in $(seq 1 20); do status ipsperre -X POST "${A}anmeldung/passwort" -d "{\"benutzername\":\"unbekannt$i\",\"passwort\":\"x\"}" >/dev/null; done
pruefe "nach 20 Fehlversuchen von einer Adresse → 429 auch für andere Namen" \
  "$(status ipsperre -X POST "${A}anmeldung/passwort" -d '{"benutzername":"vera","passwort":"Vera-Passwort-1"}')" '. == 429'
pruefe "andere Adresse für vera nicht gesperrt" "$(status sperre2 -X POST "${A}anmeldung/passwort" -d '{"benutzername":"vera","passwort":"Vera-Passwort-1"}')" '. == 200'
UNBEKANNT="$(als sperre2 -X POST "${A}anmeldung/passwort" -d '{"benutzername":"niemand","passwort":"falsch-falsch"}')"
FALSCH="$(als sperre2 -X POST "${A}anmeldung/passwort" -d '{"benutzername":"vera","passwort":"falsch-falsch"}')"
pruefe "gleiche Antwort für unbekannten Namen und falsches Passwort" "$(json --argjson a "$UNBEKANNT" --argjson b "$FALSCH" '[$a, $b]')" '.[0] == .[1] and .[0].ok == false'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Zwei-Faktor-Anmeldung (TOTP)"
totp() { php "$ROOT/tests/totp-code.php" "$@"; }
mit_code() { json --arg c "$1" '{code: $c}'; }
einrichten tom tom "$(anlegen tom)" 'Tom-Passwort-1'
TOM='{"benutzername":"tom","passwort":"Tom-Passwort-1"}'
GEHEIM="$(als tom -X POST "${A}profil/totp/start" -d '{}' | jq -r '.geheimnis')"
pruefe "Einrichtung liefert ein Base32-Geheimnis" "$(json --arg g "$GEHEIM" '$g')" 'test("^[A-Z2-7]{32}$")'
pruefe "Bestätigung mit falschem Code → 400" "$(status tom -X POST "${A}profil/totp/bestaetigen" -d "$(mit_code 000000)")" '. == 400'
CODES="$(als tom -X POST "${A}profil/totp/bestaetigen" -d "$(mit_code "$(totp "$GEHEIM" -1)")")"
pruefe "Bestätigung mit richtigem Code: 10 Wiederherstellungscodes" "$CODES" '.codes | length == 10'
WC1="$(echo "$CODES" | jq -r '.codes[0]')"; WC2="$(echo "$CODES" | jq -r '.codes[1]')"
pruefe "Geheimnis nicht im Klartext in der Datenbank" "$(sql "SELECT LOCATE('$GEHEIM', totp_geheimnis) FROM va_benutzer WHERE benutzername = 'tom'")" '. == 0'
pruefe "Wiederherstellungscodes nur als Hash gespeichert" "$(sql "SELECT COUNT(*) FROM va_wiederherstellung w JOIN va_benutzer b ON b.id = w.benutzer_id WHERE b.benutzername = 'tom' AND w.code_hash LIKE '\$2y\$%'")" '. == 10'
pruefe "zweite Einrichtung → 400" "$(status tom -X POST "${A}profil/totp/start" -d '{}')" '. == 400'
pruefe "Passwort allein meldet nicht an" "$(als tom2 -X POST "${A}anmeldung/passwort" -d "$TOM")" '.mfa == true and .benutzer == null'
pruefe "vor dem Code kein Zugriff → 401" "$(status tom2 "${A}auslagen")" '. == 401'
pruefe "falscher Code → 401" "$(status tom2 -X POST "${A}anmeldung/mfa" -d "$(mit_code 000000)")" '. == 401'
C0="$(totp "$GEHEIM" 0)"
pruefe "richtiger Code meldet an" "$(als tom2 -X POST "${A}anmeldung/mfa" -d "$(mit_code "$C0")")" '.benutzer.benutzername == "tom"'
pruefe "danach Zugriff" "$(status tom2 "${A}auslagen")" '. == 200'
als tom3 -X POST "${A}anmeldung/passwort" -d "$TOM" >/dev/null
pruefe "derselbe Code ein zweites Mal → 401 (Replay)" "$(status tom3 -X POST "${A}anmeldung/mfa" -d "$(mit_code "$C0")")" '. == 401'
pruefe "Wiederherstellungscode meldet an" "$(als tom3 -X POST "${A}anmeldung/mfa" -d "$(mit_code "$WC1")")" '.benutzer.benutzername == "tom"'
als tom4 -X POST "${A}anmeldung/passwort" -d "$TOM" >/dev/null
pruefe "Wiederherstellungscode nur einmal gültig → 401" "$(status tom4 -X POST "${A}anmeldung/mfa" -d "$(mit_code "$WC1")")" '. == 401'
pruefe "Code ohne vorherige Passwortprüfung → 401" "$(status gast -X POST "${A}anmeldung/mfa" -d "$(mit_code "$C0")")" '. == 401'
als tom5 -X POST "${A}anmeldung/passwort" -d "$TOM" >/dev/null
for i in 1 2 3 4; do
  pruefe "Durchprobieren: falscher Code $i → 401" "$(status tom5 -X POST "${A}anmeldung/mfa" -d "$(mit_code "00000$i")")" '. == 401'
done
pruefe "5. falscher Code beendet den Anmeldevorgang" "$(als tom5 -X POST "${A}anmeldung/mfa" -d "$(mit_code 000005)")" '.fehler | test("Zu viele")'
pruefe "danach auch der richtige Code → 401" "$(status tom5 -X POST "${A}anmeldung/mfa" -d "$(mit_code "$(totp "$GEHEIM" 1)")")" '. == 401'
pruefe "Fehlversuche zählen für die Namenssperre → 429" "$(status tom5 -X POST "${A}anmeldung/passwort" -d "$TOM")" '. == 429'
pruefe "Abschalten mit falschem Passwort → 403" "$(status tom -X POST "${A}profil/totp/deaktivieren" -d '{"passwort":"falsch"}')" '. == 403'
pruefe "neue Codes mit falschem Passwort → 403" "$(status tom -X POST "${A}profil/totp/neue-codes" -d '{"passwort":"falsch"}')" '. == 403'
pruefe "neue Codes mit Passwort" "$(als tom -X POST "${A}profil/totp/neue-codes" -d '{"passwort":"Tom-Passwort-1"}')" '.codes | length == 10'
pruefe "alte Codes danach ungültig" "$(sql "SELECT code_hash FROM va_wiederherstellung w JOIN va_benutzer b ON b.id = w.benutzer_id WHERE b.benutzername = 'tom'" \
  | php -r '$c = strtoupper(preg_replace("/[^A-Za-z2-7]/", "", $argv[1])); $n = 0; while (($h = fgets(STDIN)) !== false) $n += password_verify($c, trim($h)); echo $n;' "$WC2")" '. == 0'
pruefe "Abschalten mit Passwort" "$(als tom -X POST "${A}profil/totp/deaktivieren" -d '{"passwort":"Tom-Passwort-1"}')" '.benutzer.totpAktiv == false'
pruefe "Codes und Geheimnis gelöscht" "$(sql "SELECT COUNT(w.id) + SUM(b.totp_geheimnis IS NOT NULL) FROM va_wiederherstellung w RIGHT JOIN va_benutzer b ON b.id = w.benutzer_id WHERE b.benutzername = 'tom'")" '. == 0'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Passkeys (WebAuthn)"
pk() { php "$ROOT/tests/passkey-client.php" "$@"; }
RP=127.0.0.1
reg_challenge() { als "$1" -X POST "${A}profil/passkey-optionen" -d '{}' | jq -r '.optionen.challenge'; }
login_challenge() { als "$1" -X POST "${A}anmeldung/passkey-optionen" -d '{}' | jq -r '.optionen.challenge'; }
pk_anmelden() { als "$1" -X POST "${A}anmeldung/passkey" -d "$2"; }
einrichten pia pia "$(anlegen pia)" 'Pia-Passwort-1'
ID_PIA="$(sql "SELECT id FROM va_benutzer WHERE benutzername = 'pia'")"
HANDLE_PIA="$(sql "SELECT webauthn_handle FROM va_benutzer WHERE benutzername = 'pia'")"
HANDLE_KAI="$(sql "SELECT webauthn_handle FROM va_benutzer WHERE benutzername = 'kai'")"
pk neu "$TMP/pia.key"; pk neu "$TMP/fremd.key"; pk neu "$TMP/rsa.key" rsa
CH="$(reg_challenge pia)"
pruefe "Registrierung eines Passkeys" "$(als pia -X POST "${A}profil/passkey" -d "$(pk registrieren "$TMP/pia.key" "$CH" "$U" "$RP")")" '.benutzer.passkeys | length == 1'
CH="$(reg_challenge pia)"
pruefe "Registrierung eines RSA-Passkeys (RS256)" "$(als pia -X POST "${A}profil/passkey" -d "$(pk registrieren "$TMP/rsa.key" "$CH" "$U" "$RP")")" '.benutzer.passkeys | length == 2'
pruefe "verbrauchte Challenge → 400" "$(status pia -X POST "${A}profil/passkey" -d "$(pk registrieren "$TMP/fremd.key" "$CH" "$U" "$RP")")" '. == 400'
CH="$(reg_challenge pia)"
pruefe "derselbe Passkey zweimal → 400" "$(status pia -X POST "${A}profil/passkey" -d "$(pk registrieren "$TMP/pia.key" "$CH" "$U" "$RP")")" '. == 400'
for m in ohne-uv fremde-rp falscher-typ; do
  CH="$(reg_challenge pia)"
  pruefe "Registrierung $m → 400" "$(status pia -X POST "${A}profil/passkey" -d "$(pk registrieren "$TMP/fremd.key" "$CH" "$U" "$RP" "$m")")" '. == 400'
done
CH="$(reg_challenge pia)"
pruefe "Registrierung von fremder Adresse → 400" "$(status pia -X POST "${A}profil/passkey" -d "$(pk registrieren "$TMP/fremd.key" "$CH" "http://boese.example" "$RP")")" '. == 400'
CH="$(reg_challenge pia)"
CD="$(json --arg c "$CH" --arg o "$U" '{type: "webauthn.create", challenge: $c, origin: $o}' | base64 -w0 | tr '+/' '-_' | tr -d '=')"
pruefe "kaputtes CBOR → 400" "$(status pia -X POST "${A}profil/passkey" -d "$(json --arg c "$CD" '{credential: {response: {clientDataJSON: $c, attestationObject: "q83vASNFZ4mrze8BI0Vn"}}}')")" '. == 400'
CH="$(reg_challenge pia)"
CD="$(json --arg c "$CH" --arg o "$U" '{type: "webauthn.create", challenge: $c, origin: $o}' | base64 -w0 | tr '+/' '-_' | tr -d '=')"
# 1 000 000 verschachtelte Arrays (0x81) – Bytes direkt kodieren, Nullbytes überleben keine Variable
{ printf '{"credential":{"response":{"clientDataJSON":"%s","attestationObject":"' "$CD"
  { head -c 1000000 /dev/zero | tr '\0' '\201'; printf '\x00'; } | base64 -w0 | tr '+/' '-_' | tr -d '='; printf '"}}}'; } > "$TMP/tief.json"
TIEF="$(als pia -X POST "${A}profil/passkey" -d @"$TMP/tief.json")"
pruefe "1 000 000 Ebenen CBOR: sauber abgewiesen (JSON-Fehler, kein Absturz)" "$TIEF" '.ok == false'
pruefe "kein Base64url → 400" "$(status pia -X POST "${A}profil/passkey" -d '{"credential":{"response":{"clientDataJSON":"!!!","attestationObject":"!!!"}}}')" '. == 400'

CH="$(login_challenge pk)"
KOERPER="$(pk anmelden "$TMP/pia.key" "$CH" "$U" "$RP" 1 '' "$HANDLE_PIA")"
pruefe "Anmeldung mit Passkey (ohne zweiten Faktor)" "$(pk_anmelden pk "$KOERPER")" '.benutzer.benutzername == "pia"'
pruefe "danach Zugriff" "$(status pk "${A}auslagen")" '. == 200'
pruefe "dieselbe Anmeldung noch einmal (Replay) → 400" "$(status pk -X POST "${A}anmeldung/passkey" -d "$KOERPER")" '. == 400'
CH="$(login_challenge pk)"
pruefe "Zähler nicht gestiegen (kopierter Schlüssel) → 401" "$(status pk -X POST "${A}anmeldung/passkey" -d "$(pk anmelden "$TMP/pia.key" "$CH" "$U" "$RP" 1)")" '. == 401'
CH="$(login_challenge pk)"
pruefe "Zähler gestiegen → angemeldet" "$(pk_anmelden pk "$(pk anmelden "$TMP/pia.key" "$CH" "$U" "$RP" 5)")" '.benutzer.benutzername == "pia"'
CH="$(login_challenge pk)"
pruefe "Anmeldung mit RSA-Passkey" "$(pk_anmelden pk "$(pk anmelden "$TMP/rsa.key" "$CH" "$U" "$RP" 1)")" '.benutzer.benutzername == "pia"'
CH="$(login_challenge pk2)"
pruefe "falsche Signatur → 401" "$(status pk2 -X POST "${A}anmeldung/passkey" -d "$(pk anmelden "$TMP/pia.key" "$CH" "$U" "$RP" 9 falsche-signatur)")" '. == 401'
pruefe "nach falscher Signatur kein Zugriff" "$(status pk2 "${A}auslagen")" '. == 401'
for m in ohne-uv fremde-rp falscher-typ; do
  CH="$(login_challenge pk2)"
  pruefe "Anmeldung $m → 400" "$(status pk2 -X POST "${A}anmeldung/passkey" -d "$(pk anmelden "$TMP/pia.key" "$CH" "$U" "$RP" 9 "$m")")" '. == 400'
done
CH="$(login_challenge pk2)"
pruefe "Anmeldung von fremder Adresse → 400" "$(status pk2 -X POST "${A}anmeldung/passkey" -d "$(pk anmelden "$TMP/pia.key" "$CH" "http://boese.example" "$RP" 9)")" '. == 400'
CH="$(reg_challenge pia)"
pruefe "Challenge der Registrierung taugt nicht zur Anmeldung → 400" "$(status pia -X POST "${A}anmeldung/passkey" -d "$(pk anmelden "$TMP/pia.key" "$CH" "$U" "$RP" 9)")" '. == 400'
CH="$(login_challenge pk3)"
pruefe "unbekannter Passkey → 401" "$(status pk3 -X POST "${A}anmeldung/passkey" -d "$(pk anmelden "$TMP/fremd.key" "$CH" "$U" "$RP" 1)")" '. == 401'
CH="$(login_challenge pk3)"
pruefe "Benutzerkennung eines anderen → 401" "$(status pk3 -X POST "${A}anmeldung/passkey" -d "$(pk anmelden "$TMP/pia.key" "$CH" "$U" "$RP" 10 '' "$HANDLE_KAI")")" '. == 401'
PK_ID="$(sql "SELECT MIN(id) FROM va_passkeys WHERE benutzer_id = $ID_PIA")"
als kai -X DELETE "${A}profil/passkey&id=$PK_ID" >/dev/null
pruefe "Kai: Löschversuch lässt Pias Passkey bestehen" "$(sql "SELECT COUNT(*) FROM va_passkeys WHERE benutzer_id = $ID_PIA")" '. == 2'
als admin -X PUT "${A}admin/benutzer&id=$ID_PIA" -d '{"aktiv":false}' >/dev/null
CH="$(login_challenge pk3)"
pruefe "gesperrter Benutzer: Passkey-Anmeldung → 401" "$(status pk3 -X POST "${A}anmeldung/passkey" -d "$(pk anmelden "$TMP/pia.key" "$CH" "$U" "$RP" 20)")" '. == 401'
als admin -X PUT "${A}admin/benutzer&id=$ID_PIA" -d '{"aktiv":true}' >/dev/null
als admin -X POST "${A}admin/benutzer/mfa-zuruecksetzen&id=$ID_PIA" -d '{}' >/dev/null
pruefe "Admin setzt Anmeldung zurück: Passkeys entfernt" "$(sql "SELECT COUNT(*) FROM va_passkeys WHERE benutzer_id = $ID_PIA")" '. == 0'
pruefe "… und Pias Sitzung endet → 401" "$(status pia "${A}auslagen")" '. == 401'
for i in $(seq 1 20); do
  CH="$(login_challenge pk4)"; status pk4 -X POST "${A}anmeldung/passkey" -d "$(pk anmelden "$TMP/fremd.key" "$CH" "$U" "$RP" 1)" >/dev/null
done
CH="$(login_challenge pk4)"
pruefe "Passkey-Anmeldung: nach 20 Fehlversuchen je Adresse → 429" "$(status pk4 -X POST "${A}anmeldung/passkey" -d "$(pk anmelden "$TMP/fremd.key" "$CH" "$U" "$RP" 1)")" '. == 429'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Injection"
SQL="x'); DROP TABLE va_auslagen; --"
pruefe "SQL im Händler wird wörtlich gespeichert" "$(auslage kai "$SQL" | jq --arg s "$SQL" '.auslage.haendler == $s')" '. == true'
pruefe "Tabelle danach intakt" "$(sql "SELECT COUNT(*) FROM va_auslagen")" '. >= 3'
pruefe "ID mit SQL-Fragment → 404" "$(status kai "${A}beleg&id=%27%20OR%20%271%27%3D%271")" '. == 404'
pruefe "Änderung mit SQL-Fragment in der ID → 404" "$(status kai -X PUT "${A}auslagen&id=%27%20OR%201%3D1%20--" -d '{"haendler":"x"}')" '. == 404'
pruefe "Import-ID mit Pfad → 400" "$(status kai -X POST "${A}auslagen" -d "$(json --arg d "$HEUTE" '{id: "../../etc/passwd", datum: $d, haendler: "x", betrag: 1}')")" '. == 400'
pruefe "Einreichung mit SQL-Fragment in den IDs → 409" "$(status kai -X POST "${A}einreichungen" -d '{"ids":["x'"'"' OR 1=1 --"]}')" '. == 409'
pruefe "Kommentar-ID mit SQL-Fragment → 404" "$(status kai "${A}kommentare&einreichung=%27%20OR%201%3D1%20--")" '. == 404'
pruefe "Benutzername mit SQL-Zeichen → 400" "$(status admin -X POST "${A}admin/benutzer" -d '{"benutzername":"x'"'"'; DROP TABLE va_benutzer; --"}')" '. == 400'
HTML='<script>alert(1)</script><img src=x onerror=alert(2)>'
pruefe "HTML/Skript kommt unverändert als Daten zurück" "$(auslage kai "$HTML" | jq --arg h "$HTML" '.auslage.haendler == $h')" '. == true'
pruefe "Route mit Pfad-Trick → 404" "$(status kai "${A}../config/config")" '. == 404'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Eingabevalidierung"
neu() { status kai -X POST "${A}auslagen" -d "$1"; }
mit() { json --arg d "$HEUTE" "$@"; }
pruefe "gültige Auslage → 200" "$(neu "$(mit '{datum: $d, haendler: "H", betrag: 1}')")" '. == 200'
pruefe "Datum 30. Februar → 400" "$(neu "$(mit '{datum: "2024-02-30", haendler: "H", betrag: 1}')")" '. == 400'
pruefe "Datum in der Zukunft → 400" "$(neu "$(mit '{datum: "2999-01-01", haendler: "H", betrag: 1}')")" '. == 400'
pruefe "Datum falsches Format → 400" "$(neu "$(mit '{datum: "17.10.2026", haendler: "H", betrag: 1}')")" '. == 400'
pruefe "Datum fehlt → 400" "$(neu "$(mit '{haendler: "H", betrag: 1}')")" '. == 400'
for b in 0 -5 0.004 1000000 '"12"' 'null' '[1]'; do pruefe "Betrag $b → 400" "$(neu "$(mit "{datum: \$d, haendler: \"H\", betrag: $b}")")" '. == 400'; done
for b in 0.01 999999.99; do pruefe "Betrag $b → 200" "$(neu "$(mit "{datum: \$d, haendler: \"H\", betrag: $b}")")" '. == 200'; done
pruefe "Händler leer → 400" "$(neu "$(mit '{datum: $d, haendler: "  ", betrag: 1}')")" '. == 400'
pruefe "Händler als Liste → 400" "$(neu "$(mit '{datum: $d, haendler: ["a"], betrag: 1}')")" '. == 400'
pruefe "Händler 100 Zeichen (Umlaute) → 200" "$(neu "$(mit --arg h "$(lang ä 100)" '{datum: $d, haendler: $h, betrag: 1}')")" '. == 200'
pruefe "Händler 101 Zeichen → 400" "$(neu "$(mit --arg h "$(lang ä 101)" '{datum: $d, haendler: $h, betrag: 1}')")" '. == 400'
pruefe "Notiz 500 Zeichen → 200" "$(neu "$(mit --arg n "$(lang x 500)" '{datum: $d, haendler: "H", betrag: 1, notiz: $n}')")" '. == 200'
pruefe "Notiz 501 Zeichen → 400" "$(neu "$(mit --arg n "$(lang x 501)" '{datum: $d, haendler: "H", betrag: 1, notiz: $n}')")" '. == 400'
printf '{"datum":"%s","haendler":"H","betrag":1,"notiz":"%s"}' "$HEUTE" "$(lang x 1048576)" > "$TMP/gross.json"
pruefe "Notiz 1 MB → 400 (kein Serverfehler)" "$(neu @"$TMP/gross.json")" '. == 400'
pruefe "Status veranlasst beim Anlegen → 400" "$(neu "$(mit '{datum: $d, haendler: "H", betrag: 1, status: "veranlasst"}')")" '. == 400'
pruefe "kaputtes JSON → 400" "$(neu '{"datum":')" '. == 400'
pruefe "JSON-Text statt Objekt → 400" "$(neu '"x"')" '. == 400'
UNI='Café 😀 שלום مرحبا ‮abc 你好'
pruefe "Unicode wird unverändert gespeichert" "$(auslage kai "$UNI" | jq --arg u "$UNI" '.auslage.haendler == $u')" '. == true'
NUL="$(als kai -X POST "${A}auslagen" -d "$(mit '{datum: $d, haendler: "a\u0000b", betrag: 1}')")"
pruefe "Nullbyte: korrekt gespeichert oder sauber abgewiesen" "$NUL" '(.ok == true and .auslage.haendler == "a\u0000b") or .ok == false'
Z="$(auslage kai 'Belegtest' | jq -r '.auslage.id')"
printf '<html><script>alert(1)</script></html>' > "$TMP/boese.html"
printf 'kein pdf' > "$TMP/boese.pdf"
: > "$TMP/leer.png"
pruefe "Beleg als HTML → 400" "$(beleg kai "$Z" "$TMP/boese.html" text/html)" '.ok == false'
pruefe "PDF ohne PDF-Signatur → 400" "$(beleg kai "$Z" "$TMP/boese.pdf" application/pdf)" '.ok == false'
pruefe "leerer Beleg → 413" "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/k_kai" -H 'X-VA-Anfrage: 1' -H "Origin: $U" -H 'Content-Type: image/png' -X PUT --data-binary @"$TMP/leer.png" "${A}beleg&id=$Z")" '. == 413'
MAX="$(als kai "${A}status" | jq -r '.maxBelegBytes')"
head -c "$((MAX + 1))" /dev/zero > "$TMP/zu-gross.png"
pruefe "Beleg größer als erlaubt → 413" "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/k_kai" -H 'X-VA-Anfrage: 1' -H "Origin: $U" -H 'Content-Type: image/png' -X PUT --data-binary @"$TMP/zu-gross.png" "${A}beleg&id=$Z")" '. == 413'
beleg kai "$Z" "$TMP/beleg.png" image/png >/dev/null
KOPF="$(curl -s -D - -o /dev/null -b "$TMP/k_kai" "${A}beleg&id=$Z" | tr -d '\r')"
pruefe "Beleg wird als Anhang ausgeliefert" "$(printf '%s' "$KOPF" | grep -ic '^content-disposition: attachment')" '. >= 1'
pruefe "Beleg mit festem Typ und nosniff" "$(printf '%s' "$KOPF" | grep -ic '^content-type: image/png\|^x-content-type-options: nosniff')" '. == 2'
for iban in 'DE00123456781234567890' 'XX' 'DE8937040044053201300'; do
  pruefe "IBAN $iban → 400" "$(status kai -X PUT "${A}profil/stammdaten" -d "$(json --arg i "$iban" '{iban: $i}')")" '. == 400'
done
pruefe "gültige IBAN → 200" "$(status kai -X PUT "${A}profil/stammdaten" -d '{"vorname":"Kai","nachname":"K","iban":"DE89 3704 0044 0532 0130 00","ort":"Ort"}')" '. == 200'
for n in ab "$(lang u 51)" 'mit leer' 'ümlaut'; do
  pruefe "Benutzername »${n:0:12}« → 400" "$(status admin -X POST "${A}admin/benutzer" -d "$(json --arg n "$n" '{benutzername: $n}')")" '. == 400'
done
pruefe "Benutzername 50 Zeichen → 200" "$(status admin -X POST "${A}admin/benutzer" -d "$(json --arg n "$(lang u 50)" '{benutzername: $n}')")" '. == 200'
pruefe "Benutzername doppelt → 400" "$(status admin -X POST "${A}admin/benutzer" -d '{"benutzername":"kai"}')" '. == 400'
pruefe "Kommentar zu langer Text oder leer → 400" "$(status kai -X POST "${A}kommentare" -d "$(json --arg e "$E" '{einreichungId: $e, text: ""}')")" '. == 400'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Statuswechsel und Kommentare: wer darf was"
einrichten eva eva "$(anlegen eva)" 'Eva-Passwort-1'
einrichten uwe uwe "$(anlegen uwe)" 'Uwe-Passwort-1'
mit_id() { json --arg i "$1" "${@:2}"; }
EA="$(auslage eva 'Evas Einkauf' | jq -r '.auslage.id')"
EE="$(als eva -X POST "${A}einreichungen" -d "$(json --arg a "$EA" '{ids: [$a]}')" | jq -r '.einreichung.id')"
pruefe "Uwe: fremde Einreichung als erstattet markieren → 404" "$(status uwe -X POST "${A}einreichungen/status" -d "$(mit_id "$EE" '{id: $i, status: "erstattet"}')")" '. == 404'
pruefe "Uwe: fremde Einreichung zurückziehen → 404" "$(status uwe -X POST "${A}einreichungen/zurueckziehen" -d "$(mit_id "$EE" '{id: $i}')")" '. == 404'
pruefe "Uwe: fremde Einreichung verwerfen → 404" "$(status uwe -X DELETE "${A}einreichungen&id=$EE")" '. == 404'
pruefe "Eva: »veranlasst« selbst setzen → 403" "$(status eva -X POST "${A}einreichungen/status" -d "$(mit_id "$EE" '{id: $i, status: "veranlasst"}')")" '. == 403'
pruefe "Eva: unbekannter Status → 400" "$(status eva -X POST "${A}einreichungen/status" -d "$(mit_id "$EE" '{id: $i, status: "bezahlt"}')")" '. == 400'
KE="$(als eva -X POST "${A}kommentare" -d "$(mit_id "$EE" '{einreichungId: $i, text: "Frage von Eva <b>fett</b>"}')" | jq -r '.. | objects | .id? // empty' | head -1)"
pruefe "Eva: kommentiert eigene Einreichung" "$(json --arg k "$KE" '$k')" 'length > 0'
pruefe "Kassenwart: kommentiert" "$(status kai -X POST "${A}kommentare" -d "$(mit_id "$EE" '{einreichungId: $i, text: "Antwort vom Kassenwart"}')")" '. == 200'
KK="$(sql "SELECT MAX(k.id) FROM va_kommentare k JOIN va_benutzer b ON b.id = k.benutzer_id WHERE b.benutzername = 'kai' AND k.art = 'kommentar'")"
pruefe "Eva liest beide Kommentare, Text unverändert" "$(als eva "${A}kommentare&einreichung=$EE")" '[.. | strings | select(. == "Frage von Eva <b>fett</b>" or . == "Antwort vom Kassenwart")] | length >= 2'
pruefe "Eva: fremden Kommentar löschen → 404" "$(status eva -X DELETE "${A}kommentare&id=$KK")" '. == 404'
pruefe "Kommentar des Kassenwarts noch da" "$(sql "SELECT COUNT(*) FROM va_kommentare WHERE id = $KK")" '. == 1'
pruefe "Kommentar über 2000 Zeichen → 400" "$(status eva -X POST "${A}kommentare" -d "$(mit_id "$EE" --arg t "$(lang x 2001)" '{einreichungId: $i, text: $t}')")" '. == 400'
pruefe "Kassenwart: veranlasst" "$(status kai -X POST "${A}kasse/einreichung/status" -d "$(mit_id "$EE" '{id: $i, status: "veranlasst"}')")" '. == 200'
pruefe "Vorstand: veranlassen → 403" "$(status vera -X POST "${A}kasse/einreichung/status" -d "$(mit_id "$EE" '{id: $i, status: "eingereicht"}')")" '. == 403'
pruefe "Kassenwart: »erstattet« über die Kasse → 400" "$(status kai -X POST "${A}kasse/einreichung/status" -d "$(mit_id "$EE" '{id: $i, status: "erstattet"}')")" '. == 400'
pruefe "Eva: nach Veranlassung nicht mehr zurückziehbar → 409" "$(status eva -X POST "${A}einreichungen/zurueckziehen" -d "$(mit_id "$EE" '{id: $i}')")" '. == 409'
pruefe "Vorstand: nach Veranlassung nicht mehr ablehnbar → 409" "$(status vera -X POST "${A}kasse/einreichung/ablehnen" -d "$(mit_id "$EE" '{id: $i, begruendung: "nein"}')")" '. == 409'
pruefe "Eva: als erstattet markieren" "$(status eva -X POST "${A}einreichungen/status" -d "$(mit_id "$EE" '{id: $i, status: "erstattet"}')")" '. == 200'
pruefe "Status der Auslage: erstattet" "$(json --arg s "$(sql "SELECT status FROM va_auslagen WHERE id = '$EA'")" '$s')" '. == "erstattet"'
pruefe "Eva: innerhalb der Frist zurück auf veranlasst" "$(status eva -X POST "${A}einreichungen/status" -d "$(mit_id "$EE" '{id: $i, status: "veranlasst"}')")" '. == 200'
pruefe "Eva: nach Veranlassung nicht zurück auf eingereicht → 409" "$(status eva -X POST "${A}einreichungen/status" -d "$(mit_id "$EE" '{id: $i, status: "eingereicht"}')")" '. == 409'
EB="$(auslage eva 'Evas zweiter Einkauf' | jq -r '.auslage.id')"
EE2="$(als eva -X POST "${A}einreichungen" -d "$(json --arg a "$EB" '{ids: [$a]}')" | jq -r '.einreichung.id')"
pruefe "Vorstand: Ablehnen ohne Begründung → 400" "$(status vera -X POST "${A}kasse/einreichung/ablehnen" -d "$(mit_id "$EE2" '{id: $i, begruendung: "  "}')")" '. == 400'
pruefe "Mitglied: Ablehnen → 403" "$(status uwe -X POST "${A}kasse/einreichung/ablehnen" -d "$(mit_id "$EE2" '{id: $i, begruendung: "nein"}')")" '. == 403'
pruefe "Vorstand: lehnt mit Begründung ab" "$(status vera -X POST "${A}kasse/einreichung/ablehnen" -d "$(mit_id "$EE2" '{id: $i, begruendung: "Beleg fehlt"}')")" '. == 200'
pruefe "abgelehnte Auslage ist wieder offen bei Eva" "$(json --arg s "$(sql "SELECT CONCAT(status, '|', IFNULL(einreichung_id, '-')) FROM va_auslagen WHERE id = '$EB'")" '$s')" '. == "offen|-"'
pruefe "abgelehnte Einreichung nicht mehr kommentierbar → 409" "$(status eva -X POST "${A}kommentare" -d "$(mit_id "$EE2" '{einreichungId: $i, text: "Hallo?"}')")" '. == 409'
pruefe "abgelehnte Einreichung nicht mehr veranlassbar → 404" "$(status kai -X POST "${A}kasse/einreichung/status" -d "$(mit_id "$EE2" '{id: $i, status: "veranlasst"}')")" '. == 404'
EC="$(auslage eva 'Evas dritter Einkauf' | jq -r '.auslage.id')"
EE3="$(als eva -X POST "${A}einreichungen" -d "$(json --arg a "$EC" '{ids: [$a]}')" | jq -r '.einreichung.id')"
pruefe "eingereichte Auslage einzeln nicht änderbar → 409" "$(status eva -X PUT "${A}auslagen&id=$EC" -d '{"haendler":"geändert"}')" '. == 409'
pruefe "eingereichte Auslage einzeln nicht löschbar → 409" "$(status eva -X DELETE "${A}auslagen&id=$EC")" '. == 409'
pruefe "Eva: zieht eigene Einreichung zurück" "$(status eva -X POST "${A}einreichungen/zurueckziehen" -d "$(mit_id "$EE3" '{id: $i}')")" '. == 200'
pruefe "zurückgezogene Auslage wieder offen und änderbar" "$(status eva -X PUT "${A}auslagen&id=$EC" -d '{"haendler":"geändert"}')" '. == 200'
einrichten sigi sigi "$(anlegen sigi)" 'Sigi-Passwort-1'
sql "UPDATE va_benutzer SET aktiv = 0 WHERE benutzername = 'sigi'"
pruefe "nur »aktiv« abgeschaltet (ohne neue Sitzungs-Generation): Sitzung endet → 401" "$(status sigi "${A}auslagen")" '. == 401'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Benutzer löschen"
einrichten weg weg "$(anlegen weg)" 'Weg-Passwort-1'
ID_WEG="$(sql "SELECT id FROM va_benutzer WHERE benutzername = 'weg'")"
W="$(auslage weg 'Wegs Auslage' | jq -r '.auslage.id')"
beleg weg "$W" "$TMP/beleg.png" image/png >/dev/null
pruefe "Admin löscht Benutzer (mit eigenem Passwort)" "$(status admin -X POST "${A}admin/benutzer/loeschen&id=$ID_WEG" -d '{"passwort":"Test-Passwort-123!"}')" '. == 200'
pruefe "seine Auslagen und Belege sind gelöscht" "$(sql "SELECT (SELECT COUNT(*) FROM va_auslagen WHERE id = '$W') + (SELECT COUNT(*) FROM va_belege WHERE auslage_id = '$W')")" '. == 0'
pruefe "seine Sitzung endet → 401" "$(status weg "${A}auslagen")" '. == 401'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Fehlermeldungen ohne interne Details"
pruefe "unbekannte Route → 404 als JSON" "$(als kai "${A}gibt-es-nicht")" '.ok == false'
pruefe "falsche Methode → 404 als JSON" "$(als kai -X PATCH "${A}auslagen")" '.ok == false'
pruefe "überlange ID → 404" "$(status kai "${A}beleg&id=$(lang x 10000)")" '. == 404'
pruefe "Konfiguration nicht über das Web lesbar" "$(curl -s "$U/api/config/config.php" | grep -c 'passwort')" '. == 0'
# JSON maskiert / als \/ – vor der Suche zurückwandeln, sonst bleiben Pfade in JSON-Antworten unentdeckt
LECK_MUSTER='Stack trace|#[0-9]+ /|/tmp/|\.php on line|\.php:[0-9]|\.php\([0-9]|Fatal error|Warning:|Notice:|Deprecated:|Uncaught|PDOException|SQLSTATE|passwort_hash|totp_geheimnis|code_hash|/home/|/projects/'
sed 's#\\/#/#g' "$LOG" > "$TMP/antworten-klar.log"
LECKS="$(grep -E -c "$LECK_MUSTER" "$TMP/antworten-klar.log")"
pruefe "keine Stacktraces, Pfade, SQL oder Geheimnisse in $(wc -l < "$LOG") Antworten" "$LECKS" '. == 0'
[ "$LECKS" = 0 ] || grep -E -m 5 "$LECK_MUSTER" "$TMP/antworten-klar.log" | cut -c1-200
pruefe "keine PHP-Warnungen im Serverprotokoll" "$(grep -E -c 'PHP (Warning|Notice|Deprecated|Fatal)' "$TMP/server.log")" '. == 0'
