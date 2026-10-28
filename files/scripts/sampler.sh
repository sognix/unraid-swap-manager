#!/bin/bash
# sampler.sh — records swap usage for the history graph (settings page + dashboard tile).
# Started by swapctl.sh history (plg on install/update/boot, history Save on the settings page).
# Line format: "epoch used_kb total_kb". Lives in RAM like all runtime data: the history
# starts over after a reboot.
DATA=/var/lib/swap-manager
HIST=$DATA/history
CFGS=(/boot/config/plugins/swap-manager/swap-manager.cfg /usr/local/emhttp/plugins/swap-manager/default.cfg)
mkdir -p "$DATA"

# one sampler only; -w: on Save/update the old one is killed right before, give it time to exit
exec 8>"$DATA/sampler.lock"
flock -w 10 8 || exit 0
echo $$ >"$DATA/sampler.pid"

# cfg value (user cfg first, then default.cfg), bash builtins only
cfgval() {
  local f l
  for f in "${CFGS[@]}"; do
    [ -r "$f" ] || continue
    while IFS= read -r l; do
      [[ $l == "$1="* ]] && { l=${l#*=}; echo "${l//\"/}"; return; }
    done <"$f"
  done
}

# sampling interval: whole seconds, minimum 5 (no upper limit - the user decides)
INTERVAL=$(cfgval history_interval)
[[ $INTERVAL =~ ^[0-9]{1,6}$ ]] || INTERVAL=30
INTERVAL=$((10#$INTERVAL)); ((INTERVAL < 5)) && INTERVAL=5
KEEP=$((86400 / INTERVAL + 1))          # 24h, the longest selectable range
TRIM=$((3600 / INTERVAL)); ((TRIM < 1)) && TRIM=1   # trim about once an hour

n=0
while :; do
  # safety net (cfg changed by hand, Save failed half-way): stop when history gets disabled
  if [ "$(cfgval history)" = no ]; then
    rm -f "$HIST" "$HIST.tmp" "$DATA/sampler.pid"
    exit 0
  fi
  total=0 free=0
  while read -r k v _; do
    case $k in SwapTotal:) total=$v ;; SwapFree:) free=$v ;; esac
  done </proc/meminfo
  printf '%s %s %s\n' "$EPOCHSECONDS" "$((total - free))" "$total" >>"$HIST"
  if ((n % TRIM == 0)); then   # also right at start
    tail -n "$KEEP" "$HIST" >"$HIST.tmp" && mv "$HIST.tmp" "$HIST"
  fi
  ((n++))
  sleep "$INTERVAL" 8>&-   # sleep must not inherit the lock fd
done
