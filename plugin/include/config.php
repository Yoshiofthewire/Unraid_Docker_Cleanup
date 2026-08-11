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
        // Strip quotes and newlines so a value can never break the file format.
        $value = str_replace(['"', "\r", "\n"], '', (string)($cfg[$key] ?? ''));
        $out .= sprintf("%s=\"%s\"\n", $key, $value);
    }
    return file_put_contents($path, $out) !== false;
}

function dc_csrf_ok(): bool {
    global $var;
    if (!isset($var['csrf_token']) && is_file('/var/local/emhttp/var.ini')) {
        $var = @parse_ini_file('/var/local/emhttp/var.ini') ?: [];
    }
    if (empty($var['csrf_token'])) {
        return false;   // fail closed
    }
    $token = (string)($_POST['csrf_token'] ?? $_GET['csrf_token'] ?? '');
    return hash_equals((string)$var['csrf_token'], $token);
}

function dc_require_csrf(): void {
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
