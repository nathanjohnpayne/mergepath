# Shared pure check-run reduction for required-head verification and routing.
# Sourcing has no side effects. Inputs are JSON arrays: normalized check runs
# (name/status/conclusion/suite/started_at) and suite-to-workflow mappings.
# Every workflow must be green; any in-flight run retains pending precedence.
head_check_runs_reduce() {  # <check name> <runs.json> <workflows.json>
  [ "$#" -eq 3 ] && [ -r "$2" ] && [ -r "$3" ] || return 2
  jq -n --arg n "$1" --slurpfile r "$2" --slurpfile m "$3" '
    ($m[0] | map({key: (.suite|tostring), value: (.wf|tostring)}) | from_entries) as $bysuite
    | [ $r[0][] | select(.name == $n)
        | . + {wf: ($bysuite[(.suite|tostring)] // ("suite:" + (.suite|tostring)))} ]
    | if length == 0 then {state:"absent", conclusion:"absent"}
      else
        group_by(.wf)
        | map(if any(.status != "completed") then {state:"pending", conclusion:"pending"}
              else (sort_by(.started_at // "") | last
                    | {state: (if (.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped")
                               then "green" else "failed" end),
                       conclusion: (.conclusion // "pending")})
              end)
        | {state: (if any(.state == "pending") then "pending"
                   elif all(.state == "green") then "green" else "failed" end),
           # Merge-clearance routing requires an actual success, even when
           # neutral/skipped are acceptable for a required build check.
           conclusion: (if any(.state == "pending") then "pending"
                        elif all(.conclusion == "success") then "success"
                        elif length == 1 then .[0].conclusion else "failure" end)}
      end'
}
