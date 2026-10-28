# swapoff.sh — disabling swap (sourced, not executed)

# Uses the device remembered at enable time ($DATA/active) instead of the cfg, so that
# changing the cfg (Apply/Create) can never orphan active swap.
do_swapoff() {
  local dev
  if ! recorded_active; then
    echo "already inactive"
    return
  fi
  dev=$(cat "$DATA/active")
  echo "swapoff running - with used swap this can take minutes ..."
  swapoff "$dev" || die "swapoff failed (not enough free RAM for the swapped-out data?)"
  # loop mode detaches its loop device on top
  case "$dev" in /dev/loop*) losetup -d "$dev" ;; esac
  rm -f "$DATA/active"
  echo "off"
}

off() {
  touch "$DATA/manual_off"      # keep autostart off until 'Enable' or reboot
  do_swapoff
}

# A running 'create' (dd of up to 128 GB) would hold the lock - and the pool - for many
# minutes. A half-written swapfile is worthless, so the array stop aborts it instead of
# waiting. A running 'off' is not aborted: autostop waits for it (lock wait).
abort_create() {
  local pid
  pid=$(cat "$DATA/create.pid" 2>/dev/null)
  [ -n "$pid" ] && grep -qsF swapctl.sh "/proc/$pid/cmdline" || return 0
  echo "== $(date '+%F %T') array stop: aborting the running swapfile creation" >>"$LOG"
  kill -TERM "$pid"            # first the shell: its trap must be armed before dd ends
  pkill -TERM -P "$pid"        # then dd / btrfs mkswapfile
  notify warning "Swap Manager: swapfile creation aborted" "the array is stopping - the partly written swapfile was removed, create it again after the array start"
}

# Called by two emhttpd events at array stop (blocking: emhttpd waits for event hooks):
#   stopping_svcs     Docker and VMs are already stopped (RAM is free again), and it comes
#                     before Unassigned Devices unmounts its disks in this same event
#                     ("unassigned.devices" sorts after "swap-manager")
#   unmounting_disks  safety net right before the array unmounts the pools
# So swapoff is done before any umount of a disk holding the swapfile. No manual_off flag:
# the next array start brings swap back automatically.
# No load() here on purpose: a broken cfg must never break the array stop.
# Waits for a running action (e.g. a manual 'off') instead of skipping: skipping would let
# emhttpd unmount while swapoff still runs.
autostop() {
  abort_create
  lock wait
  local dev
  recorded_active || return 0   # nothing active (or already done by the first hook)
  dev=$(cat "$DATA/active")
  ( do_swapoff ) >>"$LOG" 2>&1
  if ! swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$dev"; then
    [ "$(cfg notify_info)" = yes ] && notify normal "Swap Manager: swap disabled" "swap was disabled automatically at array stop"
    return 0
  fi
  notify alert "Swap Manager: disabling swap failed" "swapoff failed - the array stop may hang at unmounting (not enough free RAM?)"
}