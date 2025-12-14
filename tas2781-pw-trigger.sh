#!/usr/bin/env bash
set -euo pipefail

last_state=""
seen_suspended=0
last_run=0

extract_states() {
  pw-mon 2>/dev/null \
    | stdbuf -oL sed -nE 's/^[[:space:]]*\*?[[:space:]]*state:[[:space:]]*"([^"]+)".*/\1/p'
}

while true; do
  set +e
  while IFS= read -r state; do
    #echo "[STATE] $state"
  
    # Ignore duplicate consecutive states
    if [[ "$state" == "$last_state" ]]; then
      continue
    fi

    # Remember that we were suspended
    if [[ "$state" == "suspended" ]]; then
      seen_suspended=1
    fi

    last_state="$state"

    case "$state" in
      running)
        if [[ "$seen_suspended" -eq 1 ]]; then
	  now=$(date +%s)
	  if (( now - last_run >= 1 )); then
            sudo -n /usr/local/bin/tas2781-fix
	    last_run=$now
            seen_suspended=0
	  fi
        fi
        ;;

      *)
        ;;
    esac
  done < <(extract_states)
  rc=$?
  set -e  
  last_state=""
  sleep 1
done

