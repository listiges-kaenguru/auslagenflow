<?php
// TOTP-Code nach RFC 6238 (SHA-1, 6 Stellen, 30 Sekunden) für die Tests.
// Bewusst eine eigene Berechnung und nicht api/lib/totp.php, damit ein Fehler dort auffällt.
//   php tests/totp-code.php <base32-geheimnis> [schritt-versatz]
declare(strict_types=1);

[$geheim, $versatz] = [strtoupper(rtrim($argv[1] ?? '', '=')), (int)($argv[2] ?? 0)];
$bits = '';
foreach (str_split($geheim) as $zeichen) {
    $wert = strpos('ABCDEFGHIJKLMNOPQRSTUVWXYZ234567', $zeichen);
    if ($wert === false) exit(2);
    $bits .= str_pad(decbin($wert), 5, '0', STR_PAD_LEFT);
}
$schluessel = '';
foreach (str_split(substr($bits, 0, intdiv(strlen($bits), 8) * 8), 8) as $byte) $schluessel .= chr(bindec($byte));

$hmac = hash_hmac('sha1', pack('J', intdiv(time(), 30) + $versatz), $schluessel, true);
$o = ord($hmac[19]) & 0x0f;
$zahl = ((ord($hmac[$o]) & 0x7f) << 24) | (ord($hmac[$o + 1]) << 16) | (ord($hmac[$o + 2]) << 8) | ord($hmac[$o + 3]);
printf('%06d', $zahl % 1000000);
