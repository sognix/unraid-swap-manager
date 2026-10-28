# swapon.sh — creating and enabling swap (sourced, not executed)

fail() { rm -f "$PART"; die "$*"; }

create() {
  # There is always at most ONE swapfile. Creating while one exists is blocked:
  # the user must deactivate, delete, create, activate - in that order (see message).
  if recorded_active; then
    die "swap active: deactivate swap, delete old swapfile, create new swapfile, activate swap"
  fi
  if is_created; then
    if is_swapfile; then
      # only possible while swap is disabled (guarded above)
      echo "existing swapfile found - replacing it"
      if [ "$FS" = zfs ]; then
        zfs destroy "$ZPOOL/swap-manager" || die "zfs destroy failed"
      else
        rm -f "$SWAPPATH"
      fi
    else
      # something else lives at that path - never overwrite or delete foreign files
      die "$SWAPPATH exists and is not a swapfile - delete it by hand first"
    fi
  fi

  if [ "$FS" = zfs ]; then
    # Swap tuning per the OpenZFS FAQ; deadlock risk remains (see README, ZFS warning)
    zfs list -H "$ZPOOL/swap-manager" >/dev/null 2>&1 ||
      zfs create -V "${SIZE_GB}G" -b "$(getconf PAGESIZE)" -o logbias=throughput -o sync=always \
        -o primarycache=metadata -o com.sun:auto-snapshot=false "$ZPOOL/swap-manager" ||
      die "zfs create failed"
    udevadm settle
    [ -b "$SWAPPATH" ] || die "zvol device missing: $SWAPPATH"
    mkswap "$SWAPPATH" >/dev/null || die "mkswap failed"
    echo "ok (zvol): $SWAPPATH"; return
  fi

  tmp_warn
  mover_check
  # the filesystem check happens in load(): FS is the type really mounted under the
  # path (auto). tmp_warn and the fs-specific paths below rely on that.
  mkdir -p "$LOCATION" || die "cannot create path: $LOCATION"
  local avail
  avail=$(df -P -BG "$LOCATION" | awk 'NR==2 {sub("G", "", $4); print $4}')
  # 10 GB stay free for everything else on the pool
  ((${avail:-0} >= SIZE_GB + 10)) || die "not enough free space: ${avail:-?} GB free, ${SIZE_GB} GB + 10 GB reserve needed"

  # Build as .part and rename at the end: half-written files never count as "created"
  rm -f "$PART"
  # An array stop aborts the creation (abort_create in swapoff.sh): it sends TERM to this
  # shell, then to dd/mkswapfile. bash runs the trap once the child is gone - the btrfs
  # fallback never starts, the .part file is removed. create.pid is removed by the EXIT trap.
  echo $$ >"$DATA/create.pid"
  trap 'rm -f "$PART"; echo "aborted: array is stopping"; exit 143' TERM
  case "$FS" in
    xfs|ext4)
      install -m 600 /dev/null "$PART" &&
        dd if=/dev/zero of="$PART" bs=1M count=$((SIZE_GB * 1024)) conv=fsync status=none ||
        fail "dd failed" ;;
    btrfs)
      # btrfs-progs >= 6.1: mkswapfile sets nocow itself; fallback: nocow BEFORE the first write
      btrfs filesystem mkswapfile --size "${SIZE_GB}g" "$PART" >/dev/null 2>&1 || {
        rm -f "$PART"
        install -m 600 /dev/null "$PART" && chattr +C "$PART" &&
          dd if=/dev/zero of="$PART" bs=1M count=$((SIZE_GB * 1024)) conv=fsync status=none ||
          fail "btrfs fallback failed"
      } ;;
  esac
  mkswap "$PART" >/dev/null && mv "$PART" "$SWAPPATH" || fail "mkswap/mv failed"
  echo "ok: $SWAPPATH"
}

# Delete the swapfile. Only allowed while swap is disabled - an active swapfile cannot be removed.
# Only a real swap signature counts: foreign files at that path are never touched.
delete() {
  recorded_active && die "swap active: deactivate swap first"
  is_swapfile || { echo "no swapfile"; return; }
  if [ "$FS" = zfs ]; then
    zfs destroy "$ZPOOL/swap-manager" || die "zfs destroy failed"
  else
    rm -f "$SWAPPATH"
  fi
  rm -f "$PART"
  echo "deleted: $SWAPPATH"
}

on() {
  is_created || die "swapfile does not exist - create it first"
  if ! is_active; then
    tmp_warn
    [ "$FS" = zfs ] || mover_check
    local target=$SWAPPATH newloop= hint=
    if [ "$BIND_MODE" = loop ]; then
      echo "WARNING: loop mode (not recommended) - deadlock risk under memory pressure, see the warning on the settings page"
      # nocow is mandatory in loop mode as well
      lsattr -d "$SWAPPATH" 2>/dev/null | awk '{print $1}' | grep -q C || die "nocow flag (C) missing on $SWAPPATH"
      target=$(loopdev)
      if [ -z "$target" ]; then
        target=$(losetup -f --show --direct-io=on "$SWAPPATH" 2>/dev/null) ||
          target=$(losetup -f --show "$SWAPPATH") || die "losetup failed"
        newloop=1
      fi
    elif [ "$FS" = btrfs ]; then
      hint=" (kernel: $(dmesg 2>/dev/null | grep -i 'swapfile' | tail -n 1))"
    fi
    swapon "$target" || { [ -n "$newloop" ] && losetup -d "$target"; die "swapon failed: $target$hint"; }
  fi
  # remember the device that is really active, independent of the cfg:
  # do_swapoff/autostop use this, so changing the cfg can never orphan active swap
  active_swap_dev >"$DATA/active"
  rm -f "$DATA/manual_off"
  sysctl -w "vm.swappiness=$SWAPPINESS" >/dev/null
  echo "on"
}

# Called by two emhttpd events (both blocking, plugins run in alphabetical order):
#   disks_mounted  array and pools mounted - but Unassigned Devices ("unassigned.devices"
#                  sorts after "swap-manager") mounts its disks in this event AFTER us
#   started        end of the array start: every disks_mounted hook is done, UD disks too
# $1=final on 'started': a still missing swapfile is reported instead of silently skipped.
# One-shot: no polling, no self-healing - problems notify the user.
autostart() {
  [ -e "$DATA/manual_off" ] && return 0
  load
  [ "$AUTOSTART" = yes ] || return 0
  is_active && return 0
  # a zvol's /dev/zvol link is created by udev asynchronously after the pool import
  [ "$FS" = zfs ] && udevadm settle -t 30
  if ! is_created; then
    [ "$1" = final ] && notify warning "Swap Manager: swapfile not found" "autostart is on, but $SWAPPATH does not exist after the array start - swap stays off"
    return 0
  fi
  lock quiet
  if ( on ) >>"$LOG" 2>&1 && is_active; then
    [ "$NOTIFY_INFO" = yes ] && notify normal "Swap Manager: swap enabled" "swap was enabled automatically at array start ($SWAPPATH)"
    return 0
  fi
  notify alert "Swap Manager: enabling swap failed" "swapon on $SWAPPATH failed - check the Swap Manager status page"
}
