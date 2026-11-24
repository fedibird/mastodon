#!/usr/bin/env bash
# Read-only, single-host observation for PR #710. NEVER changes service settings.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: script/feed_delivery_reason_observe.sh --phase off|shadow|enforce \
  --seconds 600 --out-dir PATH [--unit UNIT ...] [--pg]

Checks listed units' MainPID environment, snapshots Redis counters, samples for
N seconds, and compares. Without --unit, the user MUST verify all workers.
--pg reads pg_stat through the Rails connection for RAILS_ENV and refuses a
different database. It does not print the connection URL or credentials.
A listed process with no initial FEED_DELIVERY_REASON_MODE is unknown, not
off, and this command exits non-zero. Dotenv can set the mode after exec.
Requires RAILS_ENV (defaults to production) and an existing application setup.
Does not restart services, change modes, or delete any Redis/DB data.
EOF
}

phase=''
seconds=600
out_dir=''
pg=false
units=()
while (($#)); do
  case "$1" in
    --phase) phase="${2:?missing phase}"; shift 2 ;;
    --seconds) seconds="${2:?missing seconds}"; shift 2 ;;
    --out-dir) out_dir="${2:?missing output directory}"; shift 2 ;;
    --unit) units+=("${2:?missing unit name}"); shift 2 ;;
    --pg) pg=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$phase" in off|shadow|enforce) ;; *) usage >&2; exit 2 ;; esac
[[ "$seconds" =~ ^[0-9]+$ ]] && ((10#$seconds >= 30 && 10#$seconds <= 86400)) || {
  echo '--seconds must be 30..86400' >&2
  exit 2
}
[[ -n "$out_dir" && ! -e "$out_dir" ]] || {
  echo 'Specify a NEW --out-dir (no overwriting)' >&2
  exit 2
}

[[ "$out_dir" = /* ]] || out_dir="$PWD/$out_dir"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
umask 077
mkdir -m 700 -- "$out_dir"
# The current working directory is now the repo; retain an absolute path.
out_dir="$(cd -- "$out_dir" && pwd)"

runner=(ruby script/feed_delivery_reason_rollout.rb)
check_modes() {
  if ((${#units[@]} == 0)); then
    echo 'WARNING: No --unit; verify EVERY live Sidekiq/Web process manually.' >&2
    return
  fi
  args=()
  for unit in "${units[@]}"; do args+=(--unit "$unit"); done
  "${runner[@]}" process-modes --expect "$phase" "${args[@]}"
}

snapshot() {
  local name="$1"
  RAILS_ENV="${RAILS_ENV:-production}" bundle exec ruby \
    script/feed_delivery_reason_rollout.rb snapshot \
    --phase "$phase" --out "$out_dir/$phase-$name.json"
}

pg_snapshot() {
  local name="$1"
  if [[ "$pg" == true ]]; then
    RAILS_ENV="${RAILS_ENV:-production}" bundle exec ruby \
      script/feed_delivery_reason_rollout.rb pg-baseline \
      --out "$out_dir/$phase-pg-$name.txt"
  fi
}

check_modes | tee "$out_dir/$phase-modes-start.txt"
snapshot start
pg_snapshot start
printf 'Monitoring phase=%s for %s seconds (no mode changes)\n' "$phase" "$seconds"
sleep "$seconds"
snapshot end
pg_snapshot end
check_modes | tee "$out_dir/$phase-modes-end.txt"

incomplete=0
if ! "${runner[@]}" check-pids \
  --start "$out_dir/$phase-modes-start.txt" \
  --end "$out_dir/$phase-modes-end.txt"
then
  incomplete=1
fi

compare_args=(--before "$out_dir/$phase-start.json" \
              --after "$out_dir/$phase-end.json" \
              --out "$out_dir/$phase-report.json" --strict --min-jobs 100)
if [[ "$phase" == shadow ]]; then
  compare_args+=(--min-compared 10 \
    --min-coverage ignore_block_compared=1 \
    --min-coverage list_compared=1)
elif [[ "$phase" == enforce ]]; then
  compare_args+=(--min-coverage reply_evidence=1 \
    --min-coverage ignore_block_evidence=1 \
    --min-coverage list_reuse=1)
fi
set +e
"${runner[@]}" compare "${compare_args[@]}" | tee "$out_dir/$phase-summary.txt"
statuses=("${PIPESTATUS[@]}")
set -e
[[ "${statuses[1]}" -eq 0 ]]
compare_status="${statuses[0]}"
echo "NOTE: Redis metric flush is about 5 seconds, so counts at the window edges can move by one flush."
echo "NOTE: Only listed unit MainPIDs are compared. Another process can restart during the window unnoticed; check service logs."
if ((incomplete)); then
  echo "INCOMPLETE: a listed unit MainPID changed. Do not treat this run as a clean gate." >&2
  exit 3
fi
echo "Observation saved under $out_dir. REVIEW_REQUIRED does not authorize promotion."
exit "$compare_status"
