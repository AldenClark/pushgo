#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "usage: scripts/quality_changed.sh [quality_impact.py options]"
  echo "Generates a fresh impact plan and executes its recommended minimum lane."
  exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
results_root="$repo_root/build/quality-results"
impact_file="$results_root/apple-impact-plan.json"
impact_args=("$@")
has_output=0
for ((index = 0; index < ${#impact_args[@]}; index += 1)); do
  argument="${impact_args[$index]}"
  case "$argument" in
    --output)
      if ((index + 1 >= ${#impact_args[@]})); then
        echo "error=missing_impact_output_path" >&2
        exit 2
      fi
      impact_file="${impact_args[$((index + 1))]}"
      has_output=1
      index=$((index + 1))
      ;;
    --output=*)
      impact_file="${argument#--output=}"
      has_output=1
      ;;
  esac
done
if [[ "$impact_file" != /* ]]; then
  impact_file="$PWD/$impact_file"
fi
mkdir -p "$results_root"

python3 -m unittest discover -s "$repo_root/scripts/tests" -p 'test_*.py'
if ((has_output == 0)); then
  impact_args+=(--output "$impact_file")
fi
python3 "$repo_root/scripts/quality_impact.py" "${impact_args[@]}" --check

lane="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["recommended_lane"])' "$impact_file")"
if [[ "${QUALITY_IMPACT_PLAN_ONLY:-0}" == "1" ]]; then
  echo "status=NOT_RUN"
  echo "reason=impact_plan_only"
  exit 0
fi

if [[ "$lane" == "not-run" ]]; then
  python3 "$repo_root/scripts/quality_result.py" \
    --output "$results_root/apple-changed-summary.json" \
    --platform apple \
    --lane changed \
    --product-status NOT_RUN \
    --test-system-status PASSED \
    --not-run "No mapped Apple product capability changed; product lane intentionally not run." \
    --reason "documentation or unrelated support-only change"
  echo "status=NOT_RUN"
  echo "reason=no_product_capability_change"
  exit 0
fi

echo "executing_recommended_lane=$lane"
export QUALITY_IMPACT_PLAN="$impact_file"
exec "$repo_root/scripts/quality_test.sh" "$lane"
