<?PHP
// Current swap usage in kB: [used, total]
function swap_manager_usage(): array {
  $meminfo = @file_get_contents('/proc/meminfo') ?: '';
  $total = preg_match('/SwapTotal:\s+(\d+)/', $meminfo, $m) ? (int)$m[1] : 0;
  $free  = preg_match('/SwapFree:\s+(\d+)/',  $meminfo, $m) ? (int)$m[1] : 0;
  return [max($total - $free, 0), $total];
}

// Current swap usage as a ring (like the dashboard system tiles). Inline SVG with
// theme CSS variables, so it adapts to light and dark themes automatically.
function swap_manager_ring(int $size = 120): string {
  [$used, $total] = swap_manager_usage();
  $human = function(int $kb): string {
    if ($kb >= 1048576) return round($kb / 1048576, 1).' GB';
    if ($kb >= 1024)    return round($kb / 1024).' MB';
    return $kb.' kB';
  };
  $base = '<svg viewBox="0 0 120 120" width="'.$size.'" height="'.$size.'">'
        . '<circle cx="60" cy="60" r="50" fill="none" stroke="var(--usage-bar-background-color)" stroke-width="10"/>';
  if ($total <= 0)
    return $base.'<text x="60" y="65" text-anchor="middle" font-size="16" fill="var(--text-color)">no swap</text></svg>';
  $pct = (int)round($used / $total * 100);
  $c = 2 * M_PI * 50;
  $arc = $c * $used / $total;
  $label = htmlspecialchars($human($used).' / '.$human($total), ENT_QUOTES);
  return $base
    . '<circle cx="60" cy="60" r="50" fill="none" stroke="#e6821e" stroke-width="10" stroke-linecap="round"'
    . ' stroke-dasharray="'.round($arc, 1).' '.round($c, 1).'" transform="rotate(-90 60 60)"/>'
    . '<text x="60" y="57" text-anchor="middle" font-size="24" fill="var(--text-color)">'.$pct.'%</text>'
    . '<text x="60" y="76" text-anchor="middle" font-size="10" fill="var(--text-color)">'.$label.'</text>'
    . '</svg>';
}

// Plugin cfg: default.cfg overlaid with the user cfg (like parse_plugin_cfg, which is not
// available in exec.php)
function swap_manager_cfg(): array {
  return array_merge(@parse_ini_file('/usr/local/emhttp/plugins/swap-manager/default.cfg') ?: [],
                     @parse_ini_file('/boot/config/plugins/swap-manager/swap-manager.cfg') ?: []);
}

// Usage thresholds in percent from Settings > Display Settings: [warning, critical]
function swap_manager_thresholds(): array {
  $default = @parse_ini_file('/usr/local/emhttp/plugins/dynamix/default.cfg', true) ?: [];
  $user = @parse_ini_file('/boot/config/plugins/dynamix/dynamix.cfg', true) ?: [];
  $display = array_merge($default['display'] ?? [], $user['display'] ?? []);
  return [(int)($display['warning'] ?? 70), (int)($display['critical'] ?? 90)];
}

// Sampling interval in seconds, same rules as sampler.sh: whole number, minimum 5
function swap_manager_interval(): int {
  $v = (string)(swap_manager_cfg()['history_interval'] ?? '');
  return preg_match('/^[0-9]{1,6}$/', $v) ? max(5, (int)$v) : 30;
}

// Swap usage history for the graph (settings page + dashboard), read from the samples of
// sampler.sh ("epoch used_kb total_kb"). Long ranges are reduced to at most ~300 points;
// each point keeps the MAX of its bucket so short peaks stay visible. The browser draws it.
function swap_manager_history(int $range): array {
  if (!in_array($range, [300, 3600, 86400], true)) $range = 300;
  $now = time();
  $from = $now - $range;
  $step = max(1, intdiv($range, 300));
  $b = [];
  foreach (@file('/var/lib/swap-manager/history', FILE_IGNORE_NEW_LINES) ?: [] as $line) {
    $f = explode(' ', $line);
    if (count($f) !== 3 || (int)$f[0] < $from) continue;
    [$t, $used, $total] = array_map('intval', $f);
    $k = intdiv($t - $from, $step);
    $b[$k] = isset($b[$k]) ? [$t, max($b[$k][1], $used), max($b[$k][2], $total)] : [$t, $used, $total];
  }
  // gap = more than 3 sample intervals without data (sampler not running, reboot)
  $interval = swap_manager_interval();
  [$used, $total] = swap_manager_usage();
  [$warning, $critical] = swap_manager_thresholds();
  return ['now' => $now, 'range' => $range, 'interval' => $interval,
          'gap' => 3 * max($step, $interval), 'points' => array_values($b),
          'used' => $used, 'total' => $total, 'warning' => $warning, 'critical' => $critical];
}
