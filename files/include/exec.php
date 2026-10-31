<?PHP
// POST only: Unraid checks the CSRF token itself (local_prepend.php); jQuery posts get it automatically
header('Content-Type: text/plain; charset=utf-8');
$ctl = '/usr/local/emhttp/plugins/swap-manager/scripts/swapctl.sh';
$cfg = '/boot/config/plugins/swap-manager/swap-manager.cfg';
require_once '/usr/local/emhttp/plugins/swap-manager/include/sparkline.php';

// merge key="value" pairs into the cfg (update.php rewrites the whole file from POST,
// so keys must be preserved when writing from here - only the given keys are replaced)
function swap_cfg_write(array $new) {
  global $cfg;
  foreach ($new as $k => $v) $new[$k] = str_replace(["\r","\n",'"'], ' ', $v);
  $out = [];
  foreach (@file($cfg, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
    $key = strtok($line, '=');
    if ($key !== false && isset($new[$key])) { $out[] = $key.'="'.$new[$key].'"'; unset($new[$key]); }
    elseif ($line !== '') $out[] = $line;
  }
  foreach ($new as $k => $v) $out[] = $k.'="'.$v.'"';
  @mkdir(dirname($cfg), 0755, true);
  file_put_contents($cfg, implode("\n", $out)."\n");
}

$a = $_POST['action'] ?? '';
if ($a === 'status' || $a === 'state') {
  echo shell_exec(escapeshellarg($ctl) . ' ' . $a . ' 2>&1');
} elseif ($a === 'ring') {
  echo swap_manager_ring(110); // live-updated on the dashboard by the tile script
} elseif ($a === 'history') {
  header('Content-Type: application/json');
  echo json_encode(swap_manager_history((int)($_POST['range'] ?? 0)));
} elseif ($a === 'history_settings') {
  // the history fields have their own save button: store them and restart/stop the sampler
  $hist = $_POST['history'] ?? '';
  $iv = $_POST['history_interval'] ?? '';
  $rg = $_POST['history_range'] ?? '';
  if (!in_array($hist, ['yes', 'no'], true) || !preg_match('/^[0-9]{1,6}$/', $iv) || (int)$iv < 5
      || !in_array($rg, ['300', '3600', '86400'], true)) {
    http_response_code(400);
    echo 'invalid history settings (interval: whole seconds, min. 5)';
  } else {
    swap_cfg_write(['history' => $hist, 'history_interval' => (string)(int)$iv, 'history_range' => $rg]);
    // returns at once: swapctl detaches the sampler with all fds on /dev/null
    exec(escapeshellarg($ctl) . ' history >/dev/null 2>&1');
    echo $hist === 'yes' ? 'History settings saved - sampling every ' . (int)$iv . ' s' : 'History settings saved - history off';
  }
} elseif ($a === 'swappiness') {
  // the swappiness field has its own save button: store it and apply it immediately
  $v = $_POST['swappiness'] ?? '';
  if ($v === '' || !preg_match('/^[0-9]{1,3}$/', $v) || (int)$v > 200) {
    http_response_code(400);
    echo 'invalid swappiness value (0-200)';
  } else {
    swap_cfg_write(['swappiness' => $v]);
    exec('sysctl -w vm.swappiness=' . (int)$v . ' >/dev/null 2>&1');
    echo 'vm.swappiness saved and applied: ' . (int)$v;
  }
} elseif (in_array($a, ['create', 'on', 'off', 'delete'], true)) {
  if ($a === 'create') {
    // Create is coupled to the swap fields: always use the values shown on the page
    // (swappiness is excluded - it has its own save button). Not while swap is active: create
    // refuses then, and the cfg must keep describing the swapfile that really is active.
    exec(escapeshellarg($ctl) . ' recorded >/dev/null 2>&1', $o, $active);
    if ($active !== 0) swap_cfg_write(array_intersect_key($_POST, array_flip(['size_gb','location','name','fs','zpool','bind_mode'])));
  }
  // dd and swapoff take minutes: start detached; the output shows up in the status afterwards.
  // The pending marker makes 'state' report busy until the script holds its lock.
  @mkdir('/var/lib/swap-manager', 0755, true);
  touch('/var/lib/swap-manager/pending');
  // same rotation as rotate_log in utils.sh: max. 1 MB plus one old copy
  $log = '/var/log/swap-manager.log';
  if (@filesize($log) > 1048576) @rename($log, "$log.1");
  exec('setsid nohup ' . escapeshellarg($ctl) . ' ' . $a . ' >>' . $log . ' 2>&1 &');
  echo "$a started";
} else {
  http_response_code(400);
  echo 'unknown action';
}
