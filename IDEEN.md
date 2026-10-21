# Ideen & ToDo

Offene Punkte und Ideen für spätere Versionen. Erledigtes wird hier gestrichen und ins
[CHANGELOG](CHANGELOG.md) übernommen.

## ToDo

- [ ] PHPStan (Stufe 5) meldet zwei Hinweise: `api/lib/db.php:306` – Vergleich `<` zwischen `int<min, 5>` und 6 ist
  immer wahr (Migrationsblock prüfen); `api/lib/webauthn.php:23` – `Cbor::dekodiere()` setzt `&$gelesen` nie auf
  `null`, der Typ kann enger werden.
- [ ] Ende-zu-Ende-Test auf echtem Webhosting (Apache mit `.htaccess`, nginx-Regeln aus der README)

## Ideen

- **E-Mail-Benachrichtigungen:** Versand über SMTP (Zugangsdaten im Admin-Bereich, ohne Fremdbibliothek), z. B. um
  den Kassenwart auf neue Einreichungen und Mitglieder auf Rückfragen hinzuweisen.
