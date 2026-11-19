# Sourced from /etc/bash.bashrc. Active only inside a recorded shell (see zz-ws-record.sh).
# Appends one tab-separated line per command to $WS_EVENTS:
#   <epoch-ms> S <cmd>        command started
#   <epoch-ms> E <rc>         command finished
# Nothing is printed to the participant's terminal.
if [ -n "$WS_EVENTS" ] && [ -z "$__WS_HOOKED" ]; then
  __WS_HOOKED=1
  __ws_now() { date +%s%3N; }
  __ws_start() {
    local c
    c=$(HISTTIMEFORMAT='' builtin history 1 2>/dev/null | sed -e 's/^ *[0-9]*[* ] *//' | tr '\t\n' '  ' | sed -e 's/ *$//')
    printf '%s\tS\t%s\n' "$(__ws_now)" "$c" >> "$WS_EVENTS" 2>/dev/null
    : > "$WS_EVENTS.pending" 2>/dev/null
  }
  __ws_end() {
    local rc=$?
    if [ -e "$WS_EVENTS.pending" ]; then
      rm -f "$WS_EVENTS.pending"
      printf '%s\tE\t%s\n' "$(__ws_now)" "$rc" >> "$WS_EVENTS" 2>/dev/null
    fi
    return $rc
  }
  # PS0 is expanded by bash after a command is read: the single quotes keep it unexpanded until then.
  # shellcheck disable=SC2016
  PS0='$(__ws_start)'"${PS0}"
  PROMPT_COMMAND="__ws_end${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi
