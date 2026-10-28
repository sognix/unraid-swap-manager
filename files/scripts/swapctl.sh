#!/bin/bash
# swapctl.sh — Swap Manager entry point: sources lib/, dispatches commands
# lib/ is resolved relative to this script, so it works from the plugin dir as well as from a checkout
SRCDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SRCDIR/lib/utils.sh"
source "$SRCDIR/lib/swapon.sh"
source "$SRCDIR/lib/swapoff.sh"

status_tail() {
  if recorded_active; then
    echo "Status: active ($(cat "$DATA/active"))"
  else
    echo "Status: inactive"
  fi
  [ -e "$DATA/manual_off" ] && echo "Note: manually disabled - autostart paused until 'Enable' or reboot"
  free -h | grep -E '^(Mem|Swap)'
  [ -s "$LOG" ] && { echo "" && echo "--- Log ---"; tail -n 5 "$LOG"; }
}

# The array state never blocks anything (manual use and tests without an array must work).
# It is only shown as a hint when the cfg cannot be loaded - typically because the location
# lives on a pool that is not mounted while the array is stopped.
status() {
  local err
  if ! err=$( (load) 2>&1 ); then
    echo "$err"
    array_started || echo "Note: the array is not started - pools are not mounted"
    status_tail
    return
  fi
  load
  if is_created; then
    echo "Path: $SWAPPATH (${SIZE_GB} GB, fs=$FS, bind=$BIND_MODE)"
  else
    echo "File: not created"
  fi
  tmp_warn
  [ -n "$PART" ] && [ -e "$PART" ] &&
    echo "Partial file: $(du -m "$PART" | cut -f1) of $((SIZE_GB * 1024)) MB (creation running or aborted)"
  status_tail
}

# Start or stop the usage sampler according to cfg 'history'. Called by the plg (boot/install/
# update) and by the history Save button (exec.php). When on, it is always restarted so a changed history_interval takes
# effect; the sampler's own flock keeps it to one instance (the new one waits up to 10s for
# the killed one to release the lock).
history_apply() {
  kill_pidfile "$DATA/sampler.pid" sampler.sh
  if [ "$(cfg history)" = no ]; then
    rm -f "$DATA/history" "$DATA/history.tmp" "$DATA/sampler.pid"
    echo "history off"
  else
    # /dev/null for all fds: a caller reading our stdout (exec.php, the plg)
    # must never wait on the forever-running sampler
    setsid nohup "$SRCDIR/sampler.sh" >/dev/null 2>&1 </dev/null &
    echo "history on"
  fi
}

selftest() {
  local p
  for p in /mnt/cache/system/swap /mnt/disks/ssd1/swap /tmp/swap /boot/config/plugins/swap-manager /mnt/user/swap; do
    valid_location "$p" || { echo "FAIL (should be valid): $p"; return 1; }
  done
  for p in /mnt/cache/../etc "mnt/cache" "/mnt/cache/a b" $'/mnt/cache/x\ny' '/mnt/cache/$(x)' '/mnt/cache/x;reboot'; do
    valid_location "$p" && { echo "FAIL (should be invalid): $p"; return 1; }
  done
  echo "selftest ok"
}

case "$1" in
  selftest) selftest ;;
  history)  history_apply ;;
  state)    is_busy && echo "busy=yes" || echo "busy=no"
            if ( load ) 2>/dev/null; then
              load; is_active && echo "swap=active" || echo "swap=inactive"; is_created && echo "file=present" || echo "file=missing"
            else   # cfg not loadable (e.g. location not mounted): only what is known without it
              recorded_active && echo "swap=active" || echo "swap=inactive"; echo "file=missing"
            fi ;;
  autostart) rotate_log; ( autostart "$2" ) || notify alert "Swap Manager: autostart failed" "swap could not be enabled - check the Swap Manager status page" ;;
  autostop)  rotate_log; ( autostop ) || notify alert "Swap Manager: array-stop hook failed" "swap could not be disabled - the array stop may hang" ;;
  status)   status ;;
  # $DATA/pending is set by exec.php before the detached start; it bridges the gap until lock().
  # exec.php rotates the log before it starts these (it holds the log open for the redirect).
  create|on|delete) echo "== $(date '+%F %T') $1"; trap 'rm -f "$DATA/pending" "$DATA/create.pid"' EXIT; load; lock; "$1" ;;
  # off needs no load(): it uses $DATA/active, so it works with a broken cfg or a stopped array
  off)      echo "== $(date '+%F %T') off"; trap 'rm -f "$DATA/pending"' EXIT; lock; off ;;
  *) echo "usage: swapctl.sh status|create|on|off|delete|autostart|autostop|history|selftest"; exit 1 ;;
esac
