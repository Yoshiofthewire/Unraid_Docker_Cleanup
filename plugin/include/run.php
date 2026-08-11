<?php
// Streams a manual image prune. The page targets an iframe at this endpoint,
// so the browser renders the text/plain response as it arrives — no JS needed
// and nothing is interpreted as markup.
declare(strict_types=1);
require_once __DIR__ . '/config.php';
dc_require_csrf();

header('Content-Type: text/plain; charset=utf-8');
header('X-Accel-Buffering: no');
header('Cache-Control: no-store');

while (ob_get_level() > 0) {
    ob_end_flush();
}
ob_implicit_flush(true);

$handle = popen(escapeshellarg("$pluginRoot/scripts/image-prune.sh") . ' 2>&1', 'r');
if ($handle === false) {
    http_response_code(500);
    exit("Could not start the prune script.\n");
}

while (($line = fgets($handle)) !== false) {
    echo $line;
    flush();
}

$rc = pclose($handle);
echo $rc === 0 ? "\nDone.\n" : "\nFailed with exit code $rc.\n";
