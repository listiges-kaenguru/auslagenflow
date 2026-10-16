# Entwicklung – Referenz

Technischer Überblick über AuslagenFlow: Stand, Funktionen, API-Routen und Datenbank. Konventionen und
Checkliste für Änderungen stehen in [`CLAUDE.md`](../CLAUDE.md) und [`CONTRIBUTING.md`](../CONTRIBUTING.md).

## Aktueller Stand

| | |
|---|---|
| App-Version (`sw.js` → `VERSION`) | **v3.4.0** |
| Schema-Version (`api/lib/db.php` → `SCHEMA_VERSION`) | **6** |
| Tests | keine automatisierten Tests |

Offene Punkte stehen in [`IDEEN.md`](../IDEEN.md), Änderungen je Version im [`CHANGELOG.md`](../CHANGELOG.md).

## Funktionen

**Auslagen**
- Erfassen mit Datum, Händler, Betrag, Notiz, Beleg (Foto wird verkleinert, oder PDF, max. 15 MB)
- Übersicht mit Status offen / eingereicht / Erstattung veranlasst / erstattet; offene Auslagen
  einzeln, eingereichte gebündelt nach Einreichung. Detail-Bottom-Sheet zum Bearbeiten offener Auslagen
- Einreichen: offene Auslagen einzeln auswählen → PDF (Übersicht + Stammdaten + Belege), das mit der
  Einreichung gespeichert wird und für Mitglied, Kassenwart und Vorstand abrufbar bleibt;
  jede Einreichung ist eine feste Gruppe, deren Status sich nur gemeinsam ändert (zurückziehen,
  erstattet, veranlasst, ablehnen). Zurückgezogene/abgelehnte bleiben unter „Abgebrochen“ erhalten,
  erstattete wandern nach 5 Minuten nach „Abgeschlossen“
- Rückfragen: Kommentarverlauf je Einreichung (Mitglied, Kassenwart, Vorstand), Ungelesen-Hinweise;
  Einreichungen und Verläufe sind einklappbar
- Export (CSV/PDF/ZIP), Datensicherung als ZIP, Import von Backups der früheren Einzelplatz-Version
- PWA: installierbar, App-Shell offline, Update-Hinweis, Versionsanzeige im Profil;
  Hell/Dunkel/System-Farbschema

**Mehrbenutzer / Server**
- Ersteinrichtung im Browser (DB-Zugang + erster Admin → `api/config/config.php`)
- Login/Logout, Pflicht-Passwortwechsel beim ersten Login, Passwort ändern
- TOTP-2FA mit 10 Wiederherstellungscodes; Passkeys (WebAuthn) als Alternative
- Stammdaten (Name, IBAN, Ort) im Profil, gehen ins Einreichungs-PDF
- Kassenrollen: **Kassenwart** sieht eingereichte Auslagen aller Mitglieder (Ansicht „Kasse“, mit
  Belegen und IBAN) und setzt „Erstattung veranlasst“; **Vorstand** sieht dasselbe lesend;
  beide können eine Einreichung ablehnen (→ wieder offen beim Mitglied)
- Admin: Benutzer anlegen/sperren/löschen, Rolle und Kassenrolle ändern, Passwort und MFA zurücksetzen,
  Datenbank-Verbindung wechseln (mit optionaler Datenübernahme)
- Sicherheit: CSRF (Header + Origin), Brute-Force-Sperre, Sitzungs-Generationen, strikte CSP

## API-Routen (`api/?r=…`)

| Datei | Routen |
|---|---|
| `einrichtung.php` | `GET status`, `POST einrichtung` |
| `anmeldung.php` | `POST anmeldung/passwort`, `anmeldung/mfa`, `anmeldung/passkey-optionen`, `anmeldung/passkey`, `abmeldung` |
| `profil.php` | `GET profil`, `GET profil/version` (installierte Version + neuestes GitHub-Release), `PUT profil/stammdaten`, `POST profil/passwort`, `profil/totp/{start,bestaetigen,deaktivieren,neue-codes}`, `POST/DELETE profil/passkey`, `POST profil/passkey-optionen` |
| `auslagen.php` | `GET/POST/PUT/DELETE auslagen`, `GET/PUT/DELETE beleg` |
| `einreichungen.php` | `GET/POST/DELETE einreichungen`, `POST einreichungen/{status,zurueckziehen,uebernahme}`, `GET/PUT einreichungen/pdf` |
| `kommentare.php` | `GET/POST/DELETE kommentare`, `POST kommentare/gelesen`, `GET kommentare/ungelesen` |
| `kasse.php` | `GET kasse/auslagen`, `GET kasse/beleg`, `GET kasse/einreichung/pdf`, `POST kasse/einreichung/status`, `POST kasse/einreichung/ablehnen` (Kassenwart/Vorstand) |
| `admin.php` | `GET/POST/PUT admin/benutzer`, `POST admin/benutzer/{passwort,mfa-zuruecksetzen,loeschen}`, `GET/POST admin/db`, `POST admin/db/test` |

## Datenbank (Schema 6)

`va_meta`, `va_benutzer` (mit `kassenrolle`), `va_wiederherstellung`, `va_passkeys`,
`va_einreichungen` (mit `art`: einreichung/uebernahme, `zustand`: aktiv/abgelehnt/zurueckgezogen, `erstattet_am`, Eckdaten), `va_auslagen` (mit `einreichung_id`, `veranlasst_am`, `veranlasst_von`),
`va_belege` (LONGBLOB), `va_einreichung_pdfs` (LONGBLOB), `va_kommentare`, `va_kommentar_gelesen`, `va_anmeldeversuche`.
