<?php
// Simulierter Passkey (Authenticator) für die Tests: echter Schlüssel (P-256 oder RSA-2048), Attestierung „none“.
// Bewusst unabhängig von api/lib/webauthn.php geschrieben (eigener CBOR-Encoder, eigene authData).
//   php tests/passkey-client.php neu <schluesseldatei> [rsa]
//   php tests/passkey-client.php registrieren <schluesseldatei> <challenge> <origin> <rp-id> [manipulation]
//   php tests/passkey-client.php anmelden <schluesseldatei> <challenge> <origin> <rp-id> <zaehler> [manipulation] [user-handle]
// Manipulationen: ohne-uv (Benutzer nicht verifiziert), fremde-rp (RP-ID-Hash einer anderen Adresse),
// falscher-typ (webauthn.create statt .get bzw. umgekehrt), falsche-signatur (mit anderem Schlüssel signiert).
// Ausgabe: JSON-Body für die API (Registrierung: {credential, name}, Anmeldung: {id, response}).
// Der user-handle wird unverändert übernommen (bei AuslagenFlow schon Base64url, wie im Browser-Frontend).
declare(strict_types=1);

function b64u(string $d): string { return rtrim(strtr(base64_encode($d), '+/', '-_'), '='); }

/** Minimaler CBOR-Encoder: int, Text, Bytes (als ['b' => …]), Map (assoziatives Array) */
function cbor(mixed $v): string
{
    $kopf = function (int $typ, int $n): string {
        if ($n < 24) return chr(($typ << 5) | $n);
        if ($n < 256) return chr(($typ << 5) | 24) . chr($n);
        if ($n < 65536) return chr(($typ << 5) | 25) . pack('n', $n);
        return chr(($typ << 5) | 26) . pack('N', $n);
    };
    if (is_int($v)) return $v >= 0 ? $kopf(0, $v) : $kopf(1, -1 - $v);
    if (is_string($v)) return $kopf(3, strlen($v)) . $v;
    if (is_array($v) && array_keys($v) === ['b']) return $kopf(2, strlen($v['b'])) . $v['b'];
    $out = $kopf(5, count($v));
    foreach ($v as $k => $w) $out .= cbor($k) . cbor($w);
    return $out;
}

$befehl = $argv[1] ?? '';
$datei = $argv[2] ?? '';
if ($befehl === 'neu') {
    $key = ($argv[3] ?? '') === 'rsa'
        ? openssl_pkey_new(['private_key_type' => OPENSSL_KEYTYPE_RSA, 'private_key_bits' => 2048])
        : openssl_pkey_new(['private_key_type' => OPENSSL_KEYTYPE_EC, 'curve_name' => 'prime256v1']);
    openssl_pkey_export($key, $pem);
    file_put_contents($datei, $pem);
    exit(0);
}

$key = openssl_pkey_get_private((string)file_get_contents($datei));
[$challenge, $origin, $rpId] = [$argv[3] ?? '', $argv[4] ?? '', $argv[5] ?? ''];
$credentialId = substr(hash('sha256', (string)file_get_contents($datei), true), 0, 16);
$rpHash = hash('sha256', $rpId, true);

if ($befehl === 'registrieren') {
    $manipulation = $argv[6] ?? '';
    $details = openssl_pkey_get_details($key);
    $cose = isset($details['rsa'])
        ? cbor([1 => 3, 3 => -257, -1 => ['b' => $details['rsa']['n']], -2 => ['b' => $details['rsa']['e']]])
        : cbor([1 => 2, 3 => -7, -1 => 1, -2 => ['b' => str_pad($details['ec']['x'], 32, "\0", STR_PAD_LEFT)],
            -3 => ['b' => str_pad($details['ec']['y'], 32, "\0", STR_PAD_LEFT)]]);
    $flags = $manipulation === 'ohne-uv' ? 0x41 : 0x45;   // UP | (UV) | AT
    if ($manipulation === 'fremde-rp') $rpHash = hash('sha256', 'boese.example', true);
    $authData = $rpHash . chr($flags) . pack('N', 0) . str_repeat("\0", 16) . pack('n', strlen($credentialId)) . $credentialId . $cose;
    $clientData = json_encode(['type' => $manipulation === 'falscher-typ' ? 'webauthn.get' : 'webauthn.create',
        'challenge' => $challenge, 'origin' => $origin, 'crossOrigin' => false], JSON_UNESCAPED_SLASHES);
    echo json_encode(['credential' => [
        'id' => b64u($credentialId),
        'response' => [
            'clientDataJSON' => b64u($clientData),
            'attestationObject' => b64u(cbor(['fmt' => 'none', 'attStmt' => [], 'authData' => ['b' => $authData]])),
        ],
    ], 'name' => 'Testschlüssel']);
    exit(0);
}

if ($befehl === 'anmelden') {
    [$zaehler, $manipulation, $userHandle] = [(int)($argv[6] ?? 0), $argv[7] ?? '', $argv[8] ?? ''];
    $flags = $manipulation === 'ohne-uv' ? 0x01 : 0x05;   // UP | (UV)
    if ($manipulation === 'fremde-rp') $rpHash = hash('sha256', 'boese.example', true);
    $authData = $rpHash . chr($flags) . pack('N', $zaehler);
    $clientData = json_encode(['type' => $manipulation === 'falscher-typ' ? 'webauthn.create' : 'webauthn.get',
        'challenge' => $challenge, 'origin' => $origin, 'crossOrigin' => false], JSON_UNESCAPED_SLASHES);
    $signierer = $manipulation === 'falsche-signatur'
        ? openssl_pkey_new(['private_key_type' => OPENSSL_KEYTYPE_EC, 'curve_name' => 'prime256v1']) : $key;
    openssl_sign($authData . hash('sha256', $clientData, true), $signatur, $signierer, OPENSSL_ALGO_SHA256);
    echo json_encode(['id' => b64u($credentialId), 'response' => array_filter([
        'clientDataJSON' => b64u($clientData),
        'authenticatorData' => b64u($authData),
        'signature' => b64u($signatur),
        'userHandle' => $userHandle !== '' ? $userHandle : null,
    ], fn($v) => $v !== null)]);
    exit(0);
}
fwrite(STDERR, "Unbekannter Befehl\n");
exit(2);
