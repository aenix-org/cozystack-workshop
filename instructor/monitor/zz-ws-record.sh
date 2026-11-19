# Records interactive login shells of workshop participants for the instructor monitor.
# Output goes to /var/log/ws-sessions/<user>/<timestamp>.log, command events to <...>.log.events.
# Users listed in /etc/ws-monitor/exclude (one per line) and system accounts are skipped.
if [ -z "$WS_RECORDING" ] && [ -t 0 ] && [ -t 1 ] && case $- in *i*) true;; *) false;; esac; then
  __ws_user=$(id -un)
  if [ "$(id -u)" -ge 1000 ] && ! grep -qx "$__ws_user" /etc/ws-monitor/exclude 2>/dev/null \
     && command -v script >/dev/null 2>&1; then
    __ws_dir="/var/log/ws-sessions/$__ws_user"
    # The parent directory is created by install.sh (mode 1733), so only the user's own level is made here.
    if { [ -d "$__ws_dir" ] || mkdir -m 700 "$__ws_dir" 2>/dev/null; } && [ -w "$__ws_dir" ]; then
      __ws_file="$__ws_dir/$(date +%Y%m%d-%H%M%S)-$$.log"
      export WS_RECORDING=1 WS_EVENTS="$__ws_file.events"
      exec script -q -f "$__ws_file"
    fi
  fi
  unset __ws_user __ws_dir __ws_file
fi
