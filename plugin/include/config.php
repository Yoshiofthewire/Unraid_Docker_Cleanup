<?php
// Shared helpers for the Docker Cleanup settings page.
// All decision logic lives in scripts/; this layer marshals arguments.
declare(strict_types=1);

$plugin      = 'docker.cleanup';
$pluginRoot  = "/usr/local/emhttp/plugins/$plugin";
$bootConfig  = "/boot/config/plugins/$plugin";
$cfgFile     = "$bootConfig/$plugin.cfg";
$lastrunFile = "$bootConfig/lastrun";

function dc_defaults(): array {
    return [
        'ENABLED'      => 'no',
        'SCHEDULE'     => 'daily',
        'HOUR'         => '3',
        'MINUTE'       => '0',
        'DAY_OF_WEEK'  => '0',
        'DAY_OF_MONTH' => '1',
        'CUSTOM_CRON'  => '',
        'NOTIFY'       => 'yes',
    ];
}

function dc_read_cfg(): array {
    global $cfgFile;
    $cfg = dc_defaults();
    if (is_file($cfgFile)) {
        $parsed = @parse_ini_file($cfgFile) ?: [];
        foreach (array_keys($cfg) as $key) {
            if (isset($parsed[$key])) {
                $cfg[$key] = (string)$parsed[$key];
            }
        }
    }
    return $cfg;
}

function dc_write_cfg(array $cfg, string $path): bool {
    $out = '';
    foreach (array_keys(dc_defaults()) as $key) {
        // Strip quotes, backslashes, and newlines so a value can never break
        // the file format. A trailing backslash left in front of the closing
        // quote would leave the string unterminated for parse_ini_file, which
        // then returns false for the *whole file* — every key silently falls
        // back to its default, not just this one.
        $value = str_replace(['"', '\\', "\r", "\n"], '', (string)($cfg[$key] ?? ''));
        $out .= sprintf("%s=\"%s\"\n", $key, $value);
    }
    return file_put_contents($path, $out) !== false;
}

// The one place the token is read. The settings page used to read $var
// directly, which is empty unless the webGui happens to have populated that
// global — so the page rendered a blank token while this file's fallback
// found the real one, and every POST was rejected.
function dc_csrf_token(string $varIni = '/var/local/emhttp/var.ini'): string {
    global $var;
    if (!isset($var['csrf_token']) && is_file($varIni)) {
        $var = @parse_ini_file($varIni) ?: [];
    }
    return (string)($var['csrf_token'] ?? '');
}

function dc_csrf_ok(): bool {
    $expected = dc_csrf_token();
    if ($expected === '') {
        return false;   // fail closed
    }
    // The token must only ever be read from the POST body: accepting it from
    // the query string would let it leak into logs, history, and Referer.
    $posted = $_POST['csrf_token'] ?? '';
    $token = is_string($posted) ? $posted : '';
    return hash_equals($expected, $token);
}

function dc_parse_post_body(string $raw): array {
    parse_str($raw, $fields);
    return $fields;
}

// nginx can hand php-fpm a request body with no CONTENT_LENGTH — HTTP/2 with
// request buffering off does exactly that. PHP then leaves $_POST empty even
// though the body arrived intact and well-formed, so every handler sees no
// fields at all and the CSRF check rejects a request that carried its token.
function dc_recover_post(): void {
    if (!empty($_POST) || ($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        return;
    }
    $type = (string)($_SERVER['CONTENT_TYPE'] ?? '');
    if (stripos($type, 'application/x-www-form-urlencoded') !== 0) {
        return;
    }
    $raw = file_get_contents('php://input');
    if (!is_string($raw) || $raw === '') {
        return;
    }
    $_POST = dc_parse_post_body($raw);
}

function dc_require_csrf(): void {
    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        http_response_code(405);
        header('Content-Type: text/plain');
        header('Allow: POST');
        exit("Method Not Allowed: POST required\n");
    }
    dc_recover_post();
    if (!dc_csrf_ok()) {
        http_response_code(403);
        header('Content-Type: text/plain');
        exit("Forbidden: missing or invalid CSRF token\n");
    }
}

function dc_lastrun(): ?array {
    global $lastrunFile;
    if (!is_file($lastrunFile)) {
        return null;
    }
    $parts = explode('|', trim((string)file_get_contents($lastrunFile)), 3);
    if (count($parts) < 3) {
        return null;
    }
    return ['time' => $parts[0], 'status' => $parts[1], 'message' => $parts[2]];
}

function dc_human_bytes(int $b): string {
    if ($b < 0) {
        return 'unknown';
    }
    $units = ['B', 'KB', 'MB', 'GB', 'TB'];
    $i = 0;
    while ($b >= 1024 && $i < 4) {
        $b = intdiv($b, 1024);
        $i++;
    }
    return $b . $units[$i];
}
