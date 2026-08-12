<?php
// Plain-assert PHP tests. Run under php:8-cli in Docker; no framework.
declare(strict_types=1);

$failures = 0;
function check(string $label, bool $ok): void {
    global $failures;
    if ($ok) {
        echo "  ok   $label\n";
    } else {
        echo "  FAIL $label\n";
        $failures++;
    }
}

$tmp = sys_get_temp_dir() . '/dc-php-' . getmypid();
@mkdir($tmp, 0777, true);

require_once __DIR__ . '/../../plugin/include/config.php';

// Point the globals at the temp directory.
$cfgFile     = "$tmp/docker.cleanup.cfg";
$lastrunFile = "$tmp/lastrun";

check('defaults contain every key', count(dc_defaults()) === 8);
check('default schedule is daily', dc_defaults()['SCHEDULE'] === 'daily');

$written = dc_write_cfg(
    ['ENABLED' => 'yes', 'SCHEDULE' => 'weekly', 'HOUR' => '5', 'MINUTE' => '30',
     'DAY_OF_WEEK' => '2', 'DAY_OF_MONTH' => '1', 'CUSTOM_CRON' => '', 'NOTIFY' => 'no'],
    $cfgFile
);
check('write_cfg succeeds', $written === true);

$raw = (string)file_get_contents($cfgFile);
check('write_cfg quotes values', str_contains($raw, 'SCHEDULE="weekly"'));
check('write_cfg writes every key', substr_count($raw, "\n") === 8);

$roundTripped = dc_read_cfg();
check('read_cfg round-trips schedule', $roundTripped['SCHEDULE'] === 'weekly');
check('read_cfg round-trips notify', $roundTripped['NOTIFY'] === 'no');

// A value containing a quote must not be able to break out of the assignment.
dc_write_cfg(['ENABLED' => 'yes', 'SCHEDULE' => 'daily', 'HOUR' => '3', 'MINUTE' => '0',
              'DAY_OF_WEEK' => '0', 'DAY_OF_MONTH' => '1',
              'CUSTOM_CRON' => 'a"b$(id)', 'NOTIFY' => 'yes'], $cfgFile);
$raw = (string)file_get_contents($cfgFile);
check('quotes are stripped from values', !str_contains($raw, 'a"b'));
check('one line per key after sanitising', substr_count($raw, "\n") === 8);

// A trailing backslash must not leave the value's quotes unterminated for
// parse_ini_file — that would make the whole file unparsable and silently
// fall every key back to its default, including ENABLED.
dc_write_cfg(['ENABLED' => 'yes', 'SCHEDULE' => 'custom', 'HOUR' => '3', 'MINUTE' => '0',
              'DAY_OF_WEEK' => '0', 'DAY_OF_MONTH' => '1',
              'CUSTOM_CRON' => 'a\\', 'NOTIFY' => 'yes'], $cfgFile);
$raw = (string)file_get_contents($cfgFile);
check('backslashes are stripped from values', !str_contains($raw, '\\'));
$roundTripped = dc_read_cfg();
check('config round-trips after a backslash value (not falling back to defaults)',
    $roundTripped['ENABLED'] === 'yes' && $roundTripped['SCHEDULE'] === 'custom');

check('lastrun is null when absent', dc_lastrun() === null);
file_put_contents($lastrunFile, "2026-08-11T03:00:04-05:00|ok|Reclaimed 4.509GB\n");
$lr = dc_lastrun();
check('lastrun parses status', is_array($lr) && $lr['status'] === 'ok');
check('lastrun parses message', is_array($lr) && $lr['message'] === 'Reclaimed 4.509GB');
// A message containing a pipe must survive, because explode is limited to 3.
file_put_contents($lastrunFile, "2026-08-11T03:00:04-05:00|error|failed | badly\n");
$lr = dc_lastrun();
check('lastrun keeps pipes in the message', is_array($lr) && $lr['message'] === 'failed | badly');

check('human bytes formats MB', dc_human_bytes(2097152) === '2MB');
check('human bytes handles zero', dc_human_bytes(0) === '0B');
check('human bytes handles unknown', dc_human_bytes(-1) === 'unknown');

// CSRF must fail closed when no token is configured at all (no var.ini in
// this container, and $var left untouched).
$_POST = [];
check('csrf fails with no token configured', dc_csrf_ok() === false);

// Once a token is configured, the comparison itself must actually run.
$var = ['csrf_token' => 'right'];
$_POST = [];
check('csrf fails when POST carries no token', dc_csrf_ok() === false);
$_POST['csrf_token'] = 'wrong';
check('csrf fails with a wrong token', dc_csrf_ok() === false);
$_POST['csrf_token'] = 'right';
check('csrf succeeds with a matching token', dc_csrf_ok() === true);

array_map('unlink', glob("$tmp/*") ?: []);
@rmdir($tmp);

echo $failures === 0 ? "\nPHP tests passed\n" : "\n$failures PHP test(s) failed\n";
exit($failures === 0 ? 0 : 1);
