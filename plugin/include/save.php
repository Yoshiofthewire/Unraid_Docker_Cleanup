<?php
// Saves settings, then applies the schedule. The candidate config is validated
// by cron-apply.sh before it replaces the live one, so a rejected value never
// lands on flash and never reaches the crontab.
declare(strict_types=1);
require_once __DIR__ . '/config.php';
dc_require_csrf();

header('Content-Type: text/plain; charset=utf-8');

$cfg = dc_read_cfg();
foreach (array_keys(dc_defaults()) as $key) {
    if (isset($_POST[$key])) {
        $cfg[$key] = (string)$_POST[$key];
    }
}

$tmp = "$cfgFile.tmp";
if (!dc_write_cfg($cfg, $tmp)) {
    http_response_code(500);
    exit("Could not write the configuration file.\n");
}

$script = escapeshellarg("$pluginRoot/scripts/cron-apply.sh");
$out = [];
$rc = 0;
exec("$script --validate-only --cfg " . escapeshellarg($tmp) . " 2>&1", $out, $rc);
if ($rc !== 0) {
    @unlink($tmp);
    http_response_code(400);
    exit(implode("\n", $out) . "\n");
}

if (!rename($tmp, $cfgFile)) {
    @unlink($tmp);
    http_response_code(500);
    exit("Could not save the configuration file.\n");
}

$out = [];
exec("$script 2>&1", $out, $rc);
if ($rc !== 0) {
    http_response_code(500);
    exit("Settings saved, but the schedule could not be applied:\n" . implode("\n", $out) . "\n");
}

echo "Settings saved.\n";
