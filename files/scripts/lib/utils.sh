# utils.sh — shared helpers for all Swap Manager scripts (sourced, not executed)
PLUG=/usr/local/emhttp/plugins/swap-manager
CONF=/boot/config/plugins/swap-manager/swap-manager.cfg
DATA=/var/lib/swap-manager
LOG=/var/log/swap-manager.log
mkdir -p "$DATA"

# /var/log is a small tmpfs: keep the log at max. 1 MB plus one old copy (.1). Own rotation
# instead of logrotate, so it does not depend on cron. Called before every logging command.
rotate_log() {
  [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && mv -f "$LOG" "$LOG.1"
  return 0
}

# Array (and with it the pools) started? fsState in emhttpd's var.ini. The webGui's own shell
# scripts 'source' that file, so the value may come quoted or unquoted - accept both.
array_started() { grep -qsE '^fsState="?Started"?[[:space:]]*$' /var/local/emhttp/var.ini; }

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Unraid notification center (webGui/scripts/notify is the CLI; include/Notify.php is only the
# web POST handler); falls back to syslog when the helper is unavailable (early boot)
notify() { # $1=importance(normal|warning|alert) $2=subject $3=text
  /usr/local/emhttp/webGui/scripts/notify -e "Swap Manager" -s "$2" -d "$3" -i "$1" >/dev/null 2>&1 ||
    logger -t swap-manager "$2 - $3"
}

# User cfg first, then default.cfg. Strips the quotes that /update.php writes.
cfg() {
  local f v
  for f in "$CONF" "$PLUG/default.cfg"; do
    v=$(grep -m1 -E "^$1=" "$f" 2>/dev/null) || continue
    v=${v#*=}; v=${v#\"}; echo "${v%\"}"; return
  done
}

# Trust boundary: /update.php writes form values into the cfg unchecked -> validate strictly here.
# Any absolute path is allowed (the user decides); shell-unsafe characters and '..' are rejected.
valid_location() {
  [[ $1 =~ ^(/[A-Za-z0-9_.-]+)+$ ]] || return 1
  [[ $1 == *..* ]] && return 1
  return 0
}

# /tmp is tmpfs (RAM): the kernel refuses swapfiles there. Warn, but leave the decision to the user.
tmp_warn() {
  case $LOCATION in /tmp|/tmp/*)
    echo "WARNING: $LOCATION is on tmpfs (RAM) - a swapfile there will not work, the kernel refuses it" ;;
  esac
}

# Filesystem type of the deepest existing parent directory (pool not mounted -> tmpfs/rootfs)
fs_of() {
  local p=$1
  while [ ! -d "$p" ]; do p=$(dirname "$p"); done
  findmnt -T "$p" -no FSTYPE
}

load() {
  SIZE_GB=$(cfg size_gb);     LOCATION=$(cfg location);   NAME=$(cfg name)
  FS=$(cfg fs);               ZPOOL=$(cfg zpool);         AUTOSTART=$(cfg autostart)
  NOTIFY_INFO=$(cfg notify_info)
  SWAPPINESS=$(cfg swappiness); BIND_MODE=$(cfg bind_mode)

  # tolerate trailing whitespace and slashes from the form input
  LOCATION=$(printf '%s' "$LOCATION" | sed -e 's/[[:space:]]*$//' -e 's|/*$||')

  [[ $SIZE_GB =~ ^[0-9]{1,4}$ ]] && SIZE_GB=$((10#$SIZE_GB)) && ((SIZE_GB >= 1 && SIZE_GB <= 128)) || die "size_gb: 1-128 only"
  [[ $SWAPPINESS =~ ^[0-9]{1,3}$ ]] && SWAPPINESS=$((10#$SWAPPINESS)) && ((SWAPPINESS <= 200)) || die "swappiness: 0-200 only"
  [[ $NAME =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "name: only A-Z a-z 0-9 _ . -"
  [[ $ZPOOL =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "zpool: invalid name"
  [[ $FS =~ ^(auto|zfs)$ ]] || die "fs: auto|zfs only"
  [[ $AUTOSTART =~ ^(yes|no)$ ]] || die "autostart: yes|no only"
  [[ $NOTIFY_INFO =~ ^(yes|no)$ ]] || die "notify_info: yes|no only"
  [[ $BIND_MODE =~ ^(direct|loop)$ ]] || die "bind_mode: direct|loop only"

  if [ "$FS" = zfs ]; then
    SWAPPATH=/dev/zvol/$ZPOOL/swap-manager
  else
    valid_location "$LOCATION" || die "location: absolute path of A-Z a-z 0-9 _ . - segments only, no '..'"
    SWAPPATH=$LOCATION/$NAME
    PART=$SWAPPATH.part
    # auto: use the filesystem really mounted under the path (fs_of walks up to the
    # deepest existing parent directory). Only these support a swapfile; anything
    # else (FAT, tmpfs, ...) is refused with the real type in the message.
    FS=$(fs_of "$LOCATION")
    case $FS in
      xfs|ext4|btrfs) ;;
      zfs) die "location is on zfs - use a zvol instead: set fs=zfs and the pool name" ;;
      *) die "location is on '$FS' - that filesystem does not support a swapfile" ;;
    esac
  fi
  # checked after the detection: FS is the real filesystem here, not the cfg value 'auto'
  [ "$BIND_MODE" = loop ] && [ "$FS" != btrfs ] && die "bind_mode=loop only works on btrfs (path is on $FS)"
  return 0
}

# The mover moves files of shares with secondary storage, and it only skips files that a
# process holds open (fuser) or that are attached to a loop device. An active swapfile is
# neither, so the mover would move it away under the kernel. Refuse such locations:
#   use cache=yes:    moves /mnt/<primary pool>/<share>            -> secondary
#   use cache=prefer: moves /mnt/<secondary pool or diskN>/<share> -> primary pool
# Never moved: files directly at /mnt/<pool>/ and hidden top-level dirs (/mnt/cache/.swap).
mover_check() {
  local _ mnt root share cfg use p1 p2
  IFS=/ read -r _ mnt root share _ <<<"$LOCATION"
  [ "$mnt" = mnt ] && [ -n "$share" ] && [[ $share != .* ]] || return 0
  cfg=/boot/config/shares/$share.cfg
  [ -f "$cfg" ] || return 0
  use=$(grep -m1 '^shareUseCache=' "$cfg" | cut -d'"' -f2)
  p1=$(grep -m1 '^shareCachePool=' "$cfg" | cut -d'"' -f2)
  p2=$(grep -m1 '^shareCachePool2=' "$cfg" | cut -d'"' -f2)
  case $use in
    yes) [ "$root" = "$p1" ] || return 0 ;;
    prefer) if [ -n "$p2" ]; then [ "$root" = "$p2" ] || return 0; else [[ $root == disk[0-9]* ]] || return 0; fi ;;
    *) return 0 ;;
  esac
  die "share '$share' has a mover action that moves $LOCATION - the mover would move the swapfile away. Use a share without secondary storage or a hidden top-level directory such as /mnt/$root/.swap"
}

loopdev() { losetup -j "$SWAPPATH" 2>/dev/null | cut -d: -f1 | head -n1; }

is_created() {
  if [ "$FS" = zfs ]; then
    [ -b "$SWAPPATH" ]
  else
    [ -f "$SWAPPATH" ]
  fi
}

# Only a file with a real swap signature counts as OUR swapfile.
# Anything else at that path must never be deleted or overwritten by create/delete.
is_swapfile() {
  if [ "$FS" = zfs ]; then
    [ -b "$SWAPPATH" ] && [ "$(blkid -o value -s TYPE "$SWAPPATH" 2>/dev/null)" = swap ]
  else
    [ -f "$SWAPPATH" ] && [ "$(blkid -o value -s TYPE "$SWAPPATH" 2>/dev/null)" = swap ]
  fi
}

# The device that is really active (from /proc, independent of the cfg). Empty = inactive.
active_swap_dev() {
  local dev
  for dev in $(swapon --show=NAME --noheadings 2>/dev/null); do
    [ "$(readlink -f "$dev")" = "$(readlink -f "$SWAPPATH" 2>/dev/null)" ] && { echo "$dev"; return; }
    [ "$(readlink -f "$dev")" = "$(readlink -f "$(loopdev)" 2>/dev/null)" ] && { echo "$dev"; return; }
  done
}

# $DATA/active, but only while that device really is an active swap. A stale entry (swap
# turned off outside the plugin, e.g. 'swapoff -a' on the console) is removed - otherwise
# create/delete would refuse with "swap active" while the UI shows swap as off.
recorded_active() {
  local dev
  dev=$(cat "$DATA/active" 2>/dev/null)
  [ -n "$dev" ] && swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$dev" && return 0
  rm -f "$DATA/active"
  return 1
}

# swapon --show prints the resolved path (zvol symlink -> /dev/zdN, loop mode -> /dev/loopN)
is_active() {
  local dev=$SWAPPATH
  if [ "$BIND_MODE" = loop ]; then dev=$(loopdev); [ -n "$dev" ] || return 1; fi
  swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$(readlink -f "$dev")"
}

# lock          fail when another action runs
# lock quiet    exit silently when another action runs
# lock wait     block until the other action is done (array stop must not skip swapoff)
# Kill a process by its pid file, but only if it really is the expected script
# (a stale pid file may point to a reused pid).
kill_pidfile() { # $1=pid file $2=script name
  local pid
  pid=$(cat "$1" 2>/dev/null)
  [ -n "$pid" ] && grep -qsF "$2" "/proc/$pid/cmdline" && kill "$pid"
  return 0
}

lock() {
  exec 9>"$DATA/lock"
  if [ "$1" = wait ]; then
    flock -w 900 9 || die "timed out waiting for another Swap Manager action"
    return
  fi
  flock -n 9 || { [ "$1" = quiet ] && exit 0; die "another Swap Manager action is still running"; }
}

# Busy = lock held, or an action was just started by exec.php and has not reached lock() yet.
# A pending marker older than 30s is stale (process killed before its EXIT trap ran).
is_busy() {
  ! ( flock -n 9 ) 9>"$DATA/lock" 2>/dev/null && return 0
  [ -n "$(find "$DATA/pending" -newermt '-30 seconds' 2>/dev/null)" ]
}
