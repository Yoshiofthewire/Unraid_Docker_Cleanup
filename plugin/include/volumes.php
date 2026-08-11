<?php
// Lists unused volumes, and removes an explicitly named set.
// Volume names are validated here AND re-validated in volume-prune.sh.
declare(strict_types=1);
require_once __DIR__ . '/config.php';
dc_require_csrf();

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

$rawAction = $_POST['action'] ?? '';
$action = is_string($rawAction) ? $rawAction : '';

if ($action === 'list') {
    $out = [];
    $rc = 0;
    exec(escapeshellarg("$pluginRoot/scripts/volume-list.sh") . ' 2>&1', $out, $rc);
    if ($rc !== 0) {
        echo json_encode(['error' => trim(implode(' ', $out))], JSON_INVALID_UTF8_SUBSTITUTE);
        exit;
    }
    $volumes = [];
    foreach ($out as $line) {
        $parts = explode("\t", $line);
        if (count($parts) < 3) {
            continue;
        }
        $volumes[] = [
            'name'      => $parts[0],
            'bytes'     => (int)$parts[1],
            'size'      => dc_human_bytes((int)$parts[1]),
            'anonymous' => $parts[2] === 'yes',
        ];
    }
    echo json_encode(['volumes' => $volumes], JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

if ($action === 'remove') {
    $names = $_POST['names'] ?? [];
    if (!is_array($names) || count($names) === 0) {
        echo json_encode(['error' => 'No volumes were selected.'], JSON_INVALID_UTF8_SUBSTITUTE);
        exit;
    }
    $args = '';
    foreach ($names as $name) {
        // The D modifier stops $ from matching just before a trailing
        // newline, so "foo\n" is rejected here rather than only downstream.
        if (!is_string($name) || !preg_match('/^[A-Za-z0-9][A-Za-z0-9_.-]*$/D', $name)) {
            echo json_encode(['error' => 'Refused: invalid volume name.'], JSON_INVALID_UTF8_SUBSTITUTE);
            exit;
        }
        $args .= ' ' . escapeshellarg($name);
    }
    $out = [];
    $rc = 0;
    exec(escapeshellarg("$pluginRoot/scripts/volume-prune.sh") . $args . ' 2>&1', $out, $rc);
    echo json_encode(['exit' => $rc, 'output' => $out], JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

http_response_code(400);
echo json_encode(['error' => 'Unknown action.'], JSON_INVALID_UTF8_SUBSTITUTE);
