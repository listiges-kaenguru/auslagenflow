<?php
// =============================================
// PROFIL: Stammdaten, Passwort, TOTP, Passkeys
// App-Version: installierte Version (sw.js) und neuestes GitHub-Release, zwischengespeichert in va_meta.
// Kritische Änderungen (TOTP abschalten, neue Codes) verlangen das aktuelle Passwort.
// =============================================
declare(strict_types=1);

function pruefeAktuellesPasswort(array $benutzer, mixed $passwort): void
{
    if (!is_string($passwort) || !password_verify($passwort, $benutzer['passwort_hash'])) {
        throw new ApiFehler('Aktuelles Passwort ist falsch.', 403);
    }
}

/** Formal gültige IBAN? (Aufbau + Prüfsumme Modulo 97) */
function istGueltigeIban(string $iban): bool
{
    if (!preg_match('/^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$/', $iban)) return false;
    if (str_starts_with($iban, 'DE') && strlen($iban) !== 22) return false;
    $umgestellt = substr($iban, 4) . substr($iban, 0, 4);
    $rest = 0;
    foreach (str_split($umgestellt) as $z) {
        $wert = ctype_digit($z) ? $z : (string)(ord($z) - 55);
        foreach (str_split($wert) as $ziffer) $rest = ($rest * 10 + (int)$ziffer) % 97;
    }
    return $rest === 1;
}

function speichereNeueCodes(int $benutzerId): array
{
    $codes = erzeugeWiederherstellungscodes();
    abfrage('DELETE FROM va_wiederherstellung WHERE benutzer_id = ?', [$benutzerId]);
    $stmt = db()->prepare('INSERT INTO va_wiederherstellung (benutzer_id, code_hash) VALUES (?, ?)');
    foreach ($codes as $code) {
        $stmt->execute([$benutzerId, password_hash(normalisiereWiederherstellungscode($code), PASSWORD_DEFAULT)]);
    }
    return $codes;
}

route('GET', 'profil', function (): void {
    $benutzer = aktuellerBenutzer();
    if (!$benutzer) throw new ApiFehler('Bitte anmelden.', 401);
    antworte(['benutzer' => benutzerFuerClient($benutzer)]);
});

route('PUT', 'profil/stammdaten', function (): void {
    $b = erfordereLogin();
    $e = eingabe();
    $iban = strtoupper(preg_replace('/\s+/', '', textFeld($e, 'iban', 50)) ?? '');
    if ($iban !== '' && !istGueltigeIban($iban)) throw new ApiFehler('IBAN ist ungültig – bitte prüfen.');
    abfrage('UPDATE va_benutzer SET vorname = ?, nachname = ?, iban = ?, ort = ? WHERE id = ?', [
        textFeld($e, 'vorname'), textFeld($e, 'nachname'), $iban, textFeld($e, 'ort'), $b['id'],
    ]);
    antworte(['benutzer' => ladeBenutzerFuerClient((int)$b['id'])]);
});

// Auch bei ausstehendem Pflichtwechsel erlaubt → nur Login prüfen
route('POST', 'profil/passwort', function (): void {
    $b = aktuellerBenutzer();
    if (!$b) throw new ApiFehler('Bitte anmelden.', 401);
    $e = eingabe();
    pruefeAktuellesPasswort($b, $e['alt'] ?? null);
    $neu = (string)($e['neu'] ?? '');
    pruefePasswortRegeln($neu);
    if (password_verify($neu, $b['passwort_hash'])) throw new ApiFehler('Das neue Passwort muss sich vom alten unterscheiden.');

    abfrage('UPDATE va_benutzer SET passwort_hash = ?, muss_passwort_aendern = 0 WHERE id = ?',
        [password_hash($neu, PASSWORD_DEFAULT), $b['id']]);
    erneuereSitzungsGeneration((int)$b['id']); // andere Geräte werden abgemeldet
    antworte(['benutzer' => ladeBenutzerFuerClient((int)$b['id'])]);
});

// ---------------------------------------------
// TOTP
// ---------------------------------------------
route('POST', 'profil/totp/start', function (): void {
    $b = erfordereLogin();
    if ($b['totp_aktiv']) throw new ApiFehler('TOTP ist bereits eingerichtet.');
    $geheimnis = base32Encode(random_bytes(20));
    $_SESSION['totp_einrichtung'] = ['geheimnis' => $geheimnis, 'zeit' => time()];
    antworte([
        'geheimnis' => $geheimnis,
        'uri'       => totpUri($geheimnis, $b['benutzername'], 'AuslagenFlow'),
    ]);
});

route('POST', 'profil/totp/bestaetigen', function (): void {
    $b = erfordereLogin();
    $vorgang = $_SESSION['totp_einrichtung'] ?? null;
    if (!$vorgang || time() - $vorgang['zeit'] > 900) throw new ApiFehler('Einrichtung abgelaufen – bitte neu starten.');
    $schritt = pruefeTotp(base32Decode($vorgang['geheimnis']), textFeld(eingabe(), 'code', 10, true), 0);
    if ($schritt === null) throw new ApiFehler('Code stimmt nicht. Uhrzeit des Smartphones prüfen und neuen Code eingeben.');

    unset($_SESSION['totp_einrichtung']);
    abfrage('UPDATE va_benutzer SET totp_geheimnis = ?, totp_aktiv = 1, totp_letzter_schritt = ? WHERE id = ?',
        [verschluessele($vorgang['geheimnis']), $schritt, $b['id']]);
    $codes = speichereNeueCodes((int)$b['id']);
    antworte([
        'codes'    => $codes,
        'benutzer' => ladeBenutzerFuerClient((int)$b['id']),
    ]);
});

route('POST', 'profil/totp/deaktivieren', function (): void {
    $b = erfordereLogin();
    pruefeAktuellesPasswort($b, eingabe()['passwort'] ?? null);
    abfrage('UPDATE va_benutzer SET totp_geheimnis = NULL, totp_aktiv = 0, totp_letzter_schritt = 0 WHERE id = ?', [$b['id']]);
    abfrage('DELETE FROM va_wiederherstellung WHERE benutzer_id = ?', [$b['id']]);
    antworte(['benutzer' => ladeBenutzerFuerClient((int)$b['id'])]);
});

route('POST', 'profil/totp/neue-codes', function (): void {
    $b = erfordereLogin();
    if (!$b['totp_aktiv']) throw new ApiFehler('TOTP ist nicht eingerichtet.');
    pruefeAktuellesPasswort($b, eingabe()['passwort'] ?? null);
    antworte(['codes' => speichereNeueCodes((int)$b['id'])]);
});

// ---------------------------------------------
// Passkeys
// ---------------------------------------------
route('POST', 'profil/passkey-optionen', function (): void {
    $b = erfordereLogin();
    $ids = abfrage('SELECT credential_id FROM va_passkeys WHERE benutzer_id = ?', [$b['id']])->fetchAll(PDO::FETCH_COLUMN);
    antworte(['optionen' => passkeyRegistrierungsOptionen($b, $ids)]);
});

route('POST', 'profil/passkey', function (): void {
    $b = erfordereLogin();
    $e = eingabe();
    $daten = pruefePasskeyRegistrierung($e['credential'] ?? []);
    $name = textFeld($e, 'name', 100) ?: 'Passkey';
    try {
        abfrage('INSERT INTO va_passkeys (benutzer_id, credential_id, public_key, sign_count, name) VALUES (?, ?, ?, ?, ?)',
            [$b['id'], $daten['credential_id'], $daten['public_key'], $daten['sign_count'], $name]);
    } catch (PDOException $ex) {
        if (istDoppelterEintrag($ex)) throw new ApiFehler('Dieser Passkey ist bereits registriert.');
        throw $ex;
    }
    antworte(['benutzer' => benutzerFuerClient($b)]);
});

route('DELETE', 'profil/passkey', function (): void {
    $b = erfordereLogin();
    abfrage('DELETE FROM va_passkeys WHERE id = ? AND benutzer_id = ?', [(int)($_GET['id'] ?? 0), $b['id']]);
    antworte(['benutzer' => benutzerFuerClient($b)]);
});

// ---------------------------------------------
// App-Version
// ---------------------------------------------
// Der Server fragt GitHub (nicht der Browser): keine Verbindung der Mitglieder zu Dritten, CSP bleibt
// unverändert, und dank Zwischenspeicher reicht eine Anfrage je Installation und Halbtag.
const RELEASE_API = 'https://api.github.com/repos/listiges-kaenguru/auslagenflow/releases/latest';
const RELEASE_GUELTIG_S = 12 * 3600;
const RELEASE_FEHLER_PAUSE_S = 3600;  // nach einem Fehlschlag erst nach einer Stunde erneut fragen

/** Auf dem Server installierte Version – steht nur in sw.js (VERSION) */
function installierteVersion(): ?string
{
    $skript = @file_get_contents(dirname(__DIR__, 2) . '/sw.js') ?: '';
    return preg_match("/const VERSION\s*=\s*'([^']+)'/", $skript, $m) ? $m[1] : null;
}

/** Versionsnummer des neuesten Releases von GitHub oder null (kein Netz, Limit, gesperrt …) */
function frageGithubRelease(): ?string
{
    $kopf = ['Accept: application/vnd.github+json', 'User-Agent: AuslagenFlow'];
    $roh = false;
    $status = 0;
    if (function_exists('curl_init')) {
        $ch = curl_init(RELEASE_API);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true, CURLOPT_HTTPHEADER => $kopf,
            CURLOPT_CONNECTTIMEOUT => 3, CURLOPT_TIMEOUT => 5,
        ]);
        $roh = curl_exec($ch);
        $status = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
    } elseif (ini_get('allow_url_fopen')) {
        $kontext = stream_context_create(['http' => ['header' => $kopf, 'timeout' => 5, 'ignore_errors' => true]]);
        $roh = @file_get_contents(RELEASE_API, false, $kontext);
        $status = preg_match('#^HTTP/\S+ (\d+)#', $http_response_header[0] ?? '', $m) ? (int)$m[1] : 0;
    }
    if (!is_string($roh) || $status !== 200) return null;
    $tag = json_decode($roh, true)['tag_name'] ?? null;
    return is_string($tag) && preg_match('/^v?(\d+\.\d+\.\d+)$/', $tag, $m) ? $m[1] : null;
}

/** Neuestes Release aus dem Zwischenspeicher bzw. frisch von GitHub: ['version' => ?string, 'geprueft' => ?int] */
function neuestesRelease(): array
{
    $roh = abfrage("SELECT wert FROM va_meta WHERE schluessel = 'github_release'")->fetchColumn();
    $gemerkt = is_string($roh) ? (json_decode($roh, true) ?: []) : [];
    $version = is_string($gemerkt['version'] ?? null) ? $gemerkt['version'] : null;
    $geprueft = is_int($gemerkt['geprueft'] ?? null) ? $gemerkt['geprueft'] : null;
    $versucht = is_int($gemerkt['versucht'] ?? null) ? $gemerkt['versucht'] : 0;

    $jetzt = time();
    $frisch = $geprueft !== null && $jetzt - $geprueft < RELEASE_GUELTIG_S;
    if ($frisch || $jetzt - $versucht < RELEASE_FEHLER_PAUSE_S) {
        return ['version' => $version, 'geprueft' => $geprueft];
    }

    $neu = frageGithubRelease();
    if ($neu !== null) {
        $version = $neu;
        $geprueft = $jetzt;
    }
    $wert = json_encode(['version' => $version, 'geprueft' => $geprueft, 'versucht' => $jetzt]);
    abfrage("INSERT INTO va_meta (schluessel, wert) VALUES ('github_release', ?)
        ON DUPLICATE KEY UPDATE wert = VALUES(wert)", [$wert]);
    return ['version' => $version, 'geprueft' => $geprueft];
}

route('GET', 'profil/version', function (): void {
    erfordereLogin();
    $release = neuestesRelease();
    antworte([
        'installiert' => installierteVersion(),
        'neueste'     => $release['version'],
        'geprueftAm'  => $release['geprueft'] !== null ? gmdate('Y-m-d\TH:i:s\Z', $release['geprueft']) : null,
    ]);
});
