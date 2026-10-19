# Routentests von AuslagenFlow für Routen, die tests/sicherheit.sh nicht abdeckt: Übernahme importierter
# Auslagen, „gelesen“-Stand der Kommentare, Einreichungs-PDF über die Kasse. Wird von tests/run.sh nach
# sicherheit.sh eingebunden (nutzt deren Helfer und die Benutzer kai/vera), nicht allein ausführen.

LOG_START="$(wc -l < "$LOG")"
# pdf_hochladen <akteur> <einreichung-id> <datei> <typ> → Antwort
pdf_hochladen() {
  local r; r="$(curl -s --interface "${IP[$1]}" -b "$TMP/k_$1" -c "$TMP/k_$1" -H 'X-VA-Anfrage: 1' -H "Origin: $U" \
    -H "Content-Type: $4" -X PUT --data-binary @"$3" "${A}einreichungen/pdf&id=$2")"
  printf '%s\n' "$r" >> "$LOG"; printf '%s' "$r"
}
# import <akteur> <händler> <status> → ID einer importierten Auslage
import() { als "$1" -X POST "${A}auslagen" -d "$(json --arg d "$HEUTE" --arg h "$2" --arg s "$3" '{datum: $d, haendler: $h, betrag: 3, status: $s}')" | jq -r '.auslage.id'; }
uebernahme() { als "$1" -X POST "${A}einreichungen/uebernahme" -d "$2"; }
gruppe() { sql "SELECT IFNULL(einreichung_id, '-') FROM va_auslagen WHERE id = '$1'"; }
ungelesen() { als "$1" "${A}kommentare/ungelesen"; }
gelesen() { status "$1" -X POST "${A}kommentare/gelesen" -d "$2"; }

einrichten ida ida "$(anlegen ida)" 'Ida-Passwort-1'
einrichten jan jan "$(anlegen jan)" 'Jan-Passwort-1'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Übernahme importierter Auslagen (einreichungen/uebernahme)"
# Kein GET auslagen für ida vor den Prüfungen: das bündelt verwaiste Auslagen selbst (Rückfallebene)
I1="$(import ida 'Import 1' eingereicht)"
I2="$(import ida 'Import 2' eingereicht)"
I3="$(import ida 'Import 3' erstattet)"
I4="$(import ida 'Import offen' offen)"
I5="$(import ida 'Import 5' eingereicht)"
J1="$(import jan 'Jans Import' eingereicht)"
pruefe "ohne Login → 401" "$(status gast -X POST "${A}einreichungen/uebernahme" -d "$(json --arg a "$I1" '{ids: [$a]}')")" '. == 401'
R="$(uebernahme ida "$(json --arg a "$I1" --arg b "$I2" '{ids: [$a, $b, $a]}')")"
UE="$(echo "$R" | jq -r '.einreichung.id')"
pruefe "zwei eingereichte bündeln (doppelte ID zählt einmal)" "$R" '.ok == true and (.einreichung.id | length == 36)'
pruefe "beide gehören zur neuen Gruppe" "$(json --arg a "$(gruppe "$I1")" --arg b "$(gruppe "$I2")" --arg e "$UE" '[$a, $b, $e]')" '.[0] == .[2] and .[1] == .[2]'
pruefe "Gruppe ist eine Übernahme von ida" "$(json --arg v "$(sql "SELECT CONCAT(e.art, '|', b.benutzername) FROM va_einreichungen e JOIN va_benutzer b ON b.id = e.benutzer_id WHERE e.id = '$UE'")" '$v')" '. == "uebernahme|ida"'
pruefe "Status bleibt eingereicht" "$(sql "SELECT COUNT(*) FROM va_auslagen WHERE einreichung_id = '$UE' AND status = 'eingereicht'")" '. == 2'
pruefe "schon gebündelt → 409" "$(status ida -X POST "${A}einreichungen/uebernahme" -d "$(json --arg a "$I1" '{ids: [$a]}')")" '. == 409'
pruefe "teilweise schon gebündelt → 409, nichts geändert" "$(status ida -X POST "${A}einreichungen/uebernahme" -d "$(json --arg a "$I1" --arg b "$I5" '{ids: [$b, $a]}')")" '. == 409'
pruefe "… I5 bleibt ungebündelt" "$(json --arg v "$(gruppe "$I5")" '$v')" '. == "-"'
pruefe "gemischter Status → 400" "$(uebernahme ida "$(json --arg a "$I3" --arg b "$I5" '{ids: [$a, $b]}')")" '.fehler | test("gleichem Status")'
pruefe "offene Auslage → 400" "$(uebernahme ida "$(json --arg a "$I4" '{ids: [$a]}')")" '.fehler | test("gleichem Status")'
pruefe "nichts gebündelt nach den Fehlversuchen" "$(json --arg a "$(gruppe "$I3")" --arg b "$(gruppe "$I4")" --arg c "$(gruppe "$I5")" '[$a, $b, $c]')" '. == ["-", "-", "-"]'
pruefe "fremde Auslage → 409" "$(status ida -X POST "${A}einreichungen/uebernahme" -d "$(json --arg a "$J1" '{ids: [$a]}')")" '. == 409'
pruefe "fremde und eigene gemischt → 409" "$(status ida -X POST "${A}einreichungen/uebernahme" -d "$(json --arg a "$J1" --arg b "$I5" '{ids: [$a, $b]}')")" '. == 409'
pruefe "Jans Auslage nicht gebündelt" "$(json --arg v "$(gruppe "$J1")" '$v')" '. == "-"'
for d in '{}' '{"ids":[]}' '{"ids":"x"}' '{"ids":[1,2]}' '{"ids":null}'; do
  pruefe "ungültige ids $d → 400" "$(status ida -X POST "${A}einreichungen/uebernahme" -d "$d")" '. == 400'
done
# Ein JSON-Objekt kommt in PHP als Array an: seine Werte gelten als IDs (hier unbekannt → 409)
pruefe "ids als Objekt → 409" "$(status ida -X POST "${A}einreichungen/uebernahme" -d '{"ids":{"a":"b"}}')" '. == 409'
pruefe "über 1000 ids → 400" "$(status ida -X POST "${A}einreichungen/uebernahme" -d "$(jq -cn '{ids: [range(1001) | tostring]}')")" '. == 400'
pruefe "unbekannte ID → 409" "$(status ida -X POST "${A}einreichungen/uebernahme" -d '{"ids":["gibt-es-nicht"]}')" '. == 409'
pruefe "Injection in ids bleibt wirkungslos → 409" "$(status ida -X POST "${A}einreichungen/uebernahme" -d "$(json --arg a "$I5' OR '1'='1" '{ids: [$a]}')")" '. == 409'
pruefe "erstattete einzeln bündeln" "$(uebernahme ida "$(json --arg a "$I3" '{ids: [$a]}')")" '.ok == true'
printf '%%PDF-1.4 Test\n' > "$TMP/test.pdf"
pruefe "Übernahme hat kein Einreichungs-PDF → 400" "$(pdf_hochladen ida "$UE" "$TMP/test.pdf" application/pdf)" '.fehler | test("übernommenen")'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Kommentare gelesen (kommentare/gelesen, kommentare/ungelesen)"
K="$(auslage ida 'Idas Einkauf' | jq -r '.auslage.id')"
EK="$(als ida -X POST "${A}einreichungen" -d "$(json --arg a "$K" '{ids: [$a]}')" | jq -r '.einreichung.id')"
letzter() { sql "SELECT MAX(id) FROM va_kommentare WHERE einreichung_id = '$EK'"; }
pruefe "ohne Login: gelesen → 401" "$(gelesen gast "$(mit_id "$EK" '{einreichungId: $i, bisId: 1}')")" '. == 401'
pruefe "Ida: zu Beginn nichts ungelesen" "$(ungelesen ida)" '.eigene == 0 and .kasse == 0'
KASSE_VORHER="$(ungelesen kai | jq '.kasse')"
# Davon schon in EK: der Statuseintrag „Eingereicht“ von ida
EK_VORHER="$(sql "SELECT COUNT(*) FROM va_kommentare WHERE einreichung_id = '$EK'")"
pruefe "Einreichen schreibt einen Statuseintrag" "$EK_VORHER" '. == 1'
als kai -X POST "${A}kommentare" -d "$(mit_id "$EK" '{einreichungId: $i, text: "Erste Frage"}')" >/dev/null
K1="$(letzter)"
pruefe "Kommentar vom Kassenwart: Ida hat 1 ungelesen" "$(ungelesen ida)" '.eigene == 1'
pruefe "eigener Kommentar zählt beim Kassenwart nicht" "$(ungelesen kai | jq --argjson v "$KASSE_VORHER" '.kasse == $v')" '. == true'
pruefe "Ida: als gelesen markieren" "$(gelesen ida "$(mit_id "$EK" --argjson k "$K1" '{einreichungId: $i, bisId: $k}')")" '. == 200'
pruefe "danach 0 ungelesen" "$(ungelesen ida)" '.eigene == 0'
als kai -X POST "${A}kommentare" -d "$(mit_id "$EK" '{einreichungId: $i, text: "Zweite Frage"}')" >/dev/null
K2="$(letzter)"
pruefe "neuer Kommentar: wieder 1 ungelesen" "$(ungelesen ida)" '.eigene == 1'
gelesen ida "$(mit_id "$EK" --argjson k "$K2" '{einreichungId: $i, bisId: $k}')" >/dev/null
pruefe "älterer Stand setzt nicht zurück" "$(gelesen ida "$(mit_id "$EK" --argjson k "$K1" '{einreichungId: $i, bisId: $k}')")$(ungelesen ida | jq '.eigene')" '. == 2000'
pruefe "nur ein gelesen-Eintrag je Benutzer und Einreichung" "$(sql "SELECT COUNT(*) FROM va_kommentar_gelesen g JOIN va_benutzer b ON b.id = g.benutzer_id WHERE b.benutzername = 'ida' AND g.einreichung_id = '$EK'")" '. == 1'
als ida -X POST "${A}kommentare" -d "$(mit_id "$EK" '{einreichungId: $i, text: "Antwort von Ida"}')" >/dev/null
K3="$(letzter)"
pruefe "Kommentar der Einreicherin: Kasse hat 1 mehr ungelesen" "$(ungelesen kai | jq --argjson v "$KASSE_VORHER" '.kasse == $v + 1')" '. == true'
pruefe "Kassenwart: fremde Einreichung als gelesen markieren" "$(gelesen kai "$(mit_id "$EK" --argjson k "$K3" '{einreichungId: $i, bisId: $k}')")" '. == 200'
pruefe "Kasse: EK komplett gelesen" "$(ungelesen kai | jq --argjson v "$KASSE_VORHER" --argjson e "$EK_VORHER" '.kasse == $v - $e')" '. == true'
pruefe "Vorstand: darf ebenfalls markieren" "$(gelesen vera "$(mit_id "$EK" --argjson k "$K3" '{einreichungId: $i, bisId: $k}')")" '. == 200'
pruefe "Mitglied: Kasse-Zähler immer 0" "$(ungelesen jan)" '.kasse == 0 and .eigene == 0'
pruefe "Jan: fremde Einreichung → 404" "$(gelesen jan "$(mit_id "$EK" --argjson k "$K3" '{einreichungId: $i, bisId: $k}')")" '. == 404'
pruefe "Jan: kein gelesen-Eintrag angelegt" "$(sql "SELECT COUNT(*) FROM va_kommentar_gelesen g JOIN va_benutzer b ON b.id = g.benutzer_id WHERE b.benutzername = 'jan'")" '. == 0'
pruefe "unbekannte Einreichung → 404" "$(gelesen ida '{"einreichungId":"gibt-es-nicht","bisId":1}')" '. == 404'
als kai -X POST "${A}kommentare" -d "$(mit_id "$EK" '{einreichungId: $i, text: "Dritte Frage"}')" >/dev/null
pruefe "eigener Kommentar zählt nicht, neue Frage schon: 1 ungelesen" "$(ungelesen ida)" '.eigene == 1'
pruefe "ohne einreichungId → 404" "$(gelesen ida '{"bisId":1}')" '. == 404'
for b in 0 -5 '"abc"' null '[]'; do
  pruefe "bisId $b → 400" "$(gelesen ida "$(mit_id "$EK" --argjson k "$b" '{einreichungId: $i, bisId: $k}')")" '. == 400'
done
pruefe "ohne bisId → 400" "$(gelesen ida "$(mit_id "$EK" '{einreichungId: $i}')")" '. == 400'
pruefe "Fehlversuche ändern den Stand nicht" "$(ungelesen ida)" '.eigene == 1'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Einreichungs-PDF über die Kasse (kasse/einreichung/pdf)"
pruefe "ohne PDF: Kassenwart → 404" "$(als kai "${A}kasse/einreichung/pdf&id=$EK")" '.ok == false and (.fehler | test("kein PDF"))'
pruefe "kein PDF-Typ → 400" "$(pdf_hochladen ida "$EK" "$TMP/beleg.png" application/pdf)" '.fehler | test("kein gültiges PDF")'
pruefe "Ida: PDF speichern" "$(pdf_hochladen ida "$EK" "$TMP/test.pdf" application/pdf)" '.ok == true'
pruefe "zweites PDF → 409" "$(pdf_hochladen ida "$EK" "$TMP/test.pdf" application/pdf)" '.fehler | test("bereits")'
kasse_pdf() { curl -s --interface "${IP[$1]}" -b "$TMP/k_$1" -H 'X-VA-Anfrage: 1' -H "Origin: $U" -D "$TMP/kopf_$1" "${A}kasse/einreichung/pdf&id=$2"; }
pruefe "Kassenwart: bekommt das PDF" "$(json --arg v "$(kasse_pdf kai "$EK")" '$v')" '. == "%PDF-1.4 Test"'
pruefe "… als application/pdf" "$(grep -ci '^content-type: application/pdf' "$TMP/kopf_kai")" '. == 1'
pruefe "Vorstand: bekommt das PDF" "$(json --arg v "$(kasse_pdf vera "$EK")" '$v')" '. == "%PDF-1.4 Test"'
pruefe "Mitglied: → 403" "$(status jan "${A}kasse/einreichung/pdf&id=$EK")" '. == 403'
pruefe "Einreicherin ohne Kassenrolle: über die Kasse → 403" "$(status ida "${A}kasse/einreichung/pdf&id=$EK")" '. == 403'
pruefe "ohne Login → 401" "$(status gast "${A}kasse/einreichung/pdf&id=$EK")" '. == 401'
pruefe "unbekannte ID → 404" "$(status kai "${A}kasse/einreichung/pdf&id=gibt-es-nicht")" '. == 404'
pruefe "ohne ID → 404" "$(status kai "${A}kasse/einreichung/pdf")" '. == 404'
pruefe "Injection in der ID → 404" "$(status kai "${A}kasse/einreichung/pdf&id=x%27%20OR%20%271%27%3D%271")" '. == 404'
pruefe "Übernahme ohne PDF → 404" "$(status kai "${A}kasse/einreichung/pdf&id=$UE")" '. == 404'
als ida -X POST "${A}einreichungen/zurueckziehen" -d "$(mit_id "$EK" '{id: $i}')" >/dev/null
pruefe "nach dem Zurückziehen bleibt das PDF für die Kasse abrufbar" "$(json --arg v "$(kasse_pdf kai "$EK")" '$v')" '. == "%PDF-1.4 Test"'

# ---------------------------------------------------------------------------------------------------------
abschnitt "Routentests: Fehlermeldungen ohne interne Details"
tail -n +"$((LOG_START + 1))" "$LOG" | sed 's#\\/#/#g' > "$TMP/routen-klar.log"
pruefe "keine Stacktraces, Pfade, SQL oder Geheimnisse in $(wc -l < "$TMP/routen-klar.log") Antworten" "$(grep -E -c "$LECK_MUSTER" "$TMP/routen-klar.log")" '. == 0'
pruefe "keine PHP-Warnungen im Serverprotokoll" "$(grep -E -c 'PHP (Warning|Notice|Deprecated|Fatal)' "$TMP/server.log")" '. == 0'
