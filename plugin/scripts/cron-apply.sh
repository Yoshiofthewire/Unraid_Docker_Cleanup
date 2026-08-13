#!/usr/bin/env bash
# Validates the plugin config and applies it to cron the Unraid way: write a
# fragment to flash, then let update_cron rebuild the system crontab.
set -uo pipefail

# Force the C locale for the whole process. [0-9] in a bracket expression is
# collation-dependent: under some UTF-8 locales it matches non-ASCII digits
# (e.g. Arabic-Indic ٣), which would otherwise sail through the regex below
# and then blow up the `10#` arithmetic that follows it. C locale makes
# [0-9] mean exactly the ten ASCII digits, so that class of input fails the
# regex cleanly instead of reaching arithmetic at all.
export LC_ALL=C

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

valid_number() { # value min max
  local value="$1" min="$2" max="$3" n
  # Every cron field and every preset value fits in two digits (max is 59).
  # Bounding the digit count keeps a huge numeral from wrapping the 10#
  # arithmetic below into an in-range result (10#18446744073709551616 -> 0
  # in 64-bit bash arithmetic).
  [[ "$value" =~ ^[0-9]{1,2}$ ]] || return 1
  n=$(( 10#$value ))   # 10# so a leading zero is not read as octal
  (( n >= min && n <= max ))
}

# One cron field: *, integer, range, step, or a comma-list of those.
valid_cron_field() { # field min max
  local field="$1" min="$2" max="$3"
  [[ -n "$field" ]] || return 1
  # Reject a leading, trailing, or doubled comma up front. `read -ra` with
  # IFS=',' silently drops a lone trailing delimiter (interior empties are
  # kept but the final empty field is not), which would otherwise let
  # "1,2," through as if it were "1,2".
  [[ "$field" != ,* && "$field" != *, && "$field" != *,,* ]] || return 1
  local -a parts hparts
  IFS=',' read -ra parts <<< "$field"
  local part range step lo hi lonum hinum
  for part in "${parts[@]}"; do
    range="${part%%/*}"
    if [[ "$part" == */* ]]; then
      step="${part#*/}"
      valid_number "$step" 1 "$max" || return 1
    fi
    case "$range" in
      '*') continue ;;
      *-*)
        # Split on every '-' and require exactly two components: %%/##
        # trimming only ever look at the first/last '-', so "1-5-9" would
        # otherwise validate as "1..9" with the middle silently discarded.
        IFS='-' read -ra hparts <<< "$range"
        (( ${#hparts[@]} == 2 )) || return 1
        lo="${hparts[0]}"
        hi="${hparts[1]}"
        valid_number "$lo" "$min" "$max" || return 1
        valid_number "$hi" "$min" "$max" || return 1
        lonum=$(( 10#$lo ))
        hinum=$(( 10#$hi ))
        (( lonum <= hinum )) || return 1
        ;;
      *)
        valid_number "$range" "$min" "$max" || return 1
        ;;
    esac
  done
  return 0
}

valid_cron_expression() {
  local expr="$1"
  # A cron daemon reads crontab lines into a small fixed buffer; an
  # over-long line can corrupt the whole rebuilt crontab, not just this job.
  (( ${#expr} <= 200 )) || return 1
  [[ "$expr" != *$'\n'* ]] || return 1
  [[ "$expr" != *%* ]] || return 1
  local -a f
  read -ra f <<< "$expr"
  (( ${#f[@]} == 5 )) || return 1
  valid_cron_field "${f[0]}" 0 59 || return 1
  valid_cron_field "${f[1]}" 0 23 || return 1
  valid_cron_field "${f[2]}" 1 31 || return 1
  valid_cron_field "${f[3]}" 1 12 || return 1
  valid_cron_field "${f[4]}" 0 7  || return 1
  return 0
}

cron_expression() {
  case "$SCHEDULE" in
    hourly)  printf '%s * * * *'    "$MINUTE" ;;
    daily)   printf '%s %s * * *'   "$MINUTE" "$HOUR" ;;
    weekly)  printf '%s %s * * %s'  "$MINUTE" "$HOUR" "$DAY_OF_WEEK" ;;
    monthly) printf '%s %s %s * *'  "$MINUTE" "$HOUR" "$DAY_OF_MONTH" ;;
    custom)  printf '%s'            "$CUSTOM_CRON" ;;
    *) return 1 ;;
  esac
}

validate_cfg() {
  case "$ENABLED" in yes|no) ;; *) echo "ENABLED must be yes or no" >&2; return 1 ;; esac
  case "$NOTIFY"  in yes|no) ;; *) echo "NOTIFY must be yes or no" >&2; return 1 ;; esac
  case "$SCHEDULE" in
    hourly|daily|weekly|monthly|custom) ;;
    *) echo "Unknown schedule: $SCHEDULE" >&2; return 1 ;;
  esac
  valid_number "$MINUTE"       0 59 || { echo "Minute must be 0-59" >&2; return 1; }
  valid_number "$HOUR"         0 23 || { echo "Hour must be 0-23" >&2; return 1; }
  valid_number "$DAY_OF_WEEK"  0 6  || { echo "Day of week must be 0-6" >&2; return 1; }
  valid_number "$DAY_OF_MONTH" 1 28 || { echo "Day of month must be 1-28" >&2; return 1; }
  local expr
  expr="$(cron_expression)" || { echo "Unknown schedule: $SCHEDULE" >&2; return 1; }
  valid_cron_expression "$expr" \
    || { echo "Invalid cron expression: $expr" >&2; return 1; }
  # CUSTOM_CRON is validated here even when it isn't the active schedule. The
  # field stays in the form (just visually hidden) whichever preset is
  # selected, so a stale or malformed value typed while Custom was selected
  # earlier must never round-trip onto flash unnoticed — it would sit inert
  # until the day someone switches back to Custom, or worse, never round-trip
  # through parse_ini_file at all. Empty is fine; it's the shipped default
  # for every preset schedule.
  if [[ -n "$CUSTOM_CRON" ]]; then
    valid_cron_expression "$CUSTOM_CRON" \
      || { echo "Invalid custom cron expression: $CUSTOM_CRON" >&2; return 1; }
  fi
  return 0
}

apply_cron() {
  if [[ -z "$UPDATE_CRON" || ! -x "$UPDATE_CRON" ]]; then
    echo "Cannot apply the schedule: no executable update_cron found (tried: ${UPDATE_CRON_PATHS[*]})" >&2
    return 1
  fi
  "$UPDATE_CRON" >/dev/null 2>&1
}

write_fragment() {
  mkdir -p "$(dirname "$CRON_FILE")" || return 1
  {
    echo "# Generated by the Docker Cleanup plugin — edits are overwritten"
    printf '%s %s/scripts/image-prune.sh >/dev/null 2>&1\n' \
      "$(cron_expression)" "$PLUGIN_ROOT"
  } > "$CRON_FILE"
}

main() {
  local validate_only=0 cfg="$CFG_FILE" cfg_explicit=0
  while (( $# )); do
    case "$1" in
      --validate-only) validate_only=1 ;;
      --disable)
        rm -f "$CRON_FILE"
        apply_cron
        return $?
        ;;
      --cfg)
        shift
        cfg="${1:-}"
        [[ -n "$cfg" ]] || { echo "--cfg needs a path" >&2; return 2; }
        cfg_explicit=1
        ;;
      *) echo "Unknown option: $1" >&2; return 2 ;;
    esac
    shift
  done

  if (( cfg_explicit )) && [[ ! -f "$cfg" ]]; then
    echo "Config file not found: $cfg" >&2
    return 1
  fi

  load_cfg "$cfg"
  validate_cfg || return 1
  (( validate_only )) && return 0

  if [[ "$ENABLED" == "yes" ]]; then
    if ! write_fragment; then
      echo "Failed to write cron fragment to $CRON_FILE" >&2
      return 1
    fi
  else
    rm -f "$CRON_FILE"
  fi
  apply_cron
}

main "$@"
