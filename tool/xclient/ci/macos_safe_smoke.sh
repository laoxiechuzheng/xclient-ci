#!/usr/bin/env bash
set -euo pipefail
umask 077

reject() {
  printf '::error::macOS safe smoke: %s\n' "$1" >&2
  exit "${2:-64}"
}

[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_OS:-}" == macOS &&
   "${XCLIENT_SAFE_MODE_BUILD:-}" == 1 ]] || reject ci_safe_mode_gate_required
[[ "$(uname -s)" == Darwin ]] || reject macos_host_required
[[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ &&
   "${GITHUB_JOB:-}" =~ ^[a-zA-Z0-9_-]+$ && "${GITHUB_SHA:-}" =~ ^[a-fA-F0-9]{40}$ ]] ||
  reject missing_job_identity

script_dir="$(cd -P "$(dirname "$0")" && pwd)"
[[ -d "${GITHUB_WORKSPACE:-}" && -d "${RUNNER_TEMP:-}" ]] || reject missing_ci_directories
workspace="$(cd -P "${GITHUB_WORKSPACE:?}" && pwd)"
[[ "$workspace" == "$(cd -P "$script_dir/../../.." && pwd)" ]] || reject wrong_workspace
runner_temp="$(cd -P "${RUNNER_TEMP:?}" && pwd)"
job_identity="$GITHUB_RUN_ID:$GITHUB_RUN_ATTEMPT:$GITHUB_JOB:$GITHUB_SHA"

canonical_new_file() {
  local path="$1" parent
  [[ "$path" != *$'\n'* && "$path" != *$'\t'* && ! -e "$path" && ! -L "$path" ]] ||
    reject expected_new_path
  parent="$(cd -P "$(dirname "$path")" && pwd)"
  printf '%s/%s\n' "$parent" "$(basename "$path")"
}

if [[ "$#" == 2 && "$1" == --prepare ]]; then
  marker="$(canonical_new_file "$2")"
  [[ "$marker" == "$runner_temp/"* ]] || reject marker_must_use_runner_temp
  (set -o noclobber; printf '%s\n' "$job_identity" > "$marker")
  printf 'macOS safe smoke: build marker prepared\n'
  exit 0
fi
[[ "$#" == 3 ]] || reject 'usage: macos_safe_smoke.sh <new-debug.app> <new-output-dir> <build-marker>'
[[ -d "$1" ]] || reject missing_debug_app 65
app="$(cd -P "$1" && pwd)"
[[ "$app" == "$workspace/build/macos/Build/Products/Debug/"*.app &&
   "$(dirname "$app")" == "$workspace/build/macos/Build/Products/Debug" ]] || reject unsafe_app_path 65
marker="$3"
[[ -f "$marker" && ! -L "$marker" ]] || reject missing_build_marker 65
marker="$(cd -P "$(dirname "$marker")" && pwd)/$(basename "$marker")"
[[ "$marker" == "$runner_temp/"* && "$(cat "$marker")" == "$job_identity" ]] || reject wrong_build_job 65
now="$(date +%s)"
marker_time="$(stat -f %m "$marker")"
(( now >= marker_time && now - marker_time <= 7200 )) || reject stale_build_marker 65

info="$app/Contents/Info.plist"
config="$workspace/macos/Flutter/ephemeral/Flutter-Generated.xcconfig"
[[ -f "$info" && -f "$config" && "$info" -nt "$marker" && "$config" -nt "$marker" ]] ||
  reject missing_fresh_build_metadata 65
[[ ! -L "$info" && ! -L "$config" &&
   "$(cd -P "$app/Contents/MacOS" && pwd)" == "$app/Contents/MacOS" ]] || reject linked_build_metadata 65
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
[[ "$bundle_id" == com.xclient.example.debug ]] || reject example_debug_bundle_required 65
[[ "$(/usr/libexec/PlistBuddy -c 'Print :FLTEnableImpeller' "$info")" == false ]] ||
  reject shipping_macos_renderer_required 65
exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")"
[[ -n "$exe_name" && "$exe_name" != */* && "$exe_name" != . && "$exe_name" != .. ]] || reject invalid_executable 65
executable="$app/Contents/MacOS/$exe_name"
core_executable="$app/Contents/MacOS/XClientexampleCore"
[[ -f "$executable" && -x "$executable" && ! -L "$executable" && "$executable" -nt "$marker" ]] ||
  reject missing_fresh_executable 65
safe_count=0
example_count=0
version_count=0
build_count=0
defines="$(sed -n 's/^DART_DEFINES=//p' "$config")"
[[ -n "$defines" ]] || reject missing_dart_defines 65
while IFS= read -r encoded; do
  decoded="$(printf '%s' "$encoded" | /usr/bin/base64 -D)" || reject invalid_dart_defines 65
  case "$decoded" in
    SAFE_MODE=true) safe_count=$((safe_count + 1)) ;;
    SAFE_MODE=*) reject unsafe_dart_define 65 ;;
    XC_BRAND_ID=example) example_count=$((example_count + 1)) ;;
    XC_BRAND_ID=*) reject real_brand_not_allowed 65 ;;
    XC_VERSION_NAME=1.0.0-pre.1) version_count=$((version_count + 1)) ;;
    XC_VERSION_NAME=*) reject canonical_prerelease_required 65 ;;
    XC_BUILD_NUMBER=10000401) build_count=$((build_count + 1)) ;;
    XC_BUILD_NUMBER=*) reject canonical_build_required 65 ;;
  esac
done < <(printf '%s\n' "$defines" | tr ',' '\n')
[[ "$safe_count" == 1 && "$example_count" == 1 ]] || reject exact_safe_example_defines_required 65
[[ "$version_count" == 1 && "$build_count" == 1 ]] || reject exact_canonical_defines_required 65

output="$(canonical_new_file "$2")"
[[ "$output" == "$workspace/out/"* ]] || reject output_must_use_workspace_out
mkdir "$output"
mkdir "$output/diagnostics"
probe="$output/.macos-window-probe"
/usr/bin/xcrun swiftc "$script_dir/macos_window_probe.swift" -o "$probe" > "$output/probe-build.log" 2>&1 ||
  reject swift_probe_build_failed 66
python_command="$(command -v python3)" || reject python3_required 66
capture_executable="$("$python_command" -c 'import os,sys; print(os.path.realpath(sys.executable))')"

app_pid=''
app_identity=''
core_pids=()
core_identities=()
core_count=0
result=internal_error
cleanup_failed=0
capture_pid=''
capture_identity=''
launched_at="$(date +%s)"

process_identity() {
  local pid="$1" expected="$2" actual started
  actual="$(/bin/ps -ww -p "$pid" -o comm= 2>/dev/null)" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  started="$(/bin/ps -p "$pid" -o lstart= 2>/dev/null)" || return 1
  [[ -n "$started" ]] || return 1
  printf '%s|%s|%s\n' "$pid" "$started" "$actual"
}

is_running() {
  local state
  kill -0 "$1" 2>/dev/null || return 1
  state="$(/bin/ps -p "$1" -o stat= 2>/dev/null | tr -d ' ')" || return 1
  [[ -n "$state" && "$state" != Z* ]]
}

network_hashes() {
  /usr/sbin/scutil --proxy | /usr/bin/shasum -a 256 | awk '{print "proxy_sha256=" $1}' || return 1
  /sbin/ifconfig -l | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort |
    /usr/bin/shasum -a 256 | awk '{print "interface_names_sha256=" $1}' || return 1
}

build_hashes() {
  /usr/bin/shasum -a 256 "$executable" "$info" "$config" || return 1
  if [[ -f "$core_executable" ]]; then /usr/bin/shasum -a 256 "$core_executable"; fi
}

record_core_children() {
  local pid identity parent known index current_app
  [[ -n "$app_pid" && -n "$app_identity" ]] || return 0
  current_app="$(process_identity "$app_pid" "$executable")" || return 0
  [[ "$current_app" == "$app_identity" ]] || return 0
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    identity="$(process_identity "$pid" "$core_executable")" || continue
    parent="$(/bin/ps -p "$pid" -o ppid= | tr -d ' ')"
    [[ "$parent" == "$app_pid" ]] || continue
    known=0
    for ((index=0; index<core_count; index++)); do
      if [[ "${core_pids[$index]}" == "$pid" ]]; then known=1; fi
    done
    if [[ "$known" == 0 ]]; then
      core_pids[$core_count]="$pid"
      core_identities[$core_count]="$identity"
      core_count=$((core_count + 1))
      printf '%s\n' "$identity" >> "$output/owned-core-processes.txt"
    fi
  done < <(/bin/ps -ax -o pid= -o ppid= | awk -v parent="$app_pid" '$2 == parent {print $1}')
}

stop_owned() {
  local pid="$1" expected="$2" identity="$3" current index
  is_running "$pid" || return 0
  current="$(process_identity "$pid" "$expected")" || current=''
  is_running "$pid" || return 0
  if [[ -z "$identity" || "$current" != "$identity" ]]; then
    printf 'refused_identity_mismatch_pid=%s\n' "$pid" >> "$output/cleanup.txt"
    cleanup_failed=1
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  for ((index=0; index<3; index++)); do
    is_running "$pid" || return 0
    sleep 1
  done
  current="$(process_identity "$pid" "$expected")" || current=''
  if [[ "$current" == "$identity" ]]; then
    kill -KILL "$pid" 2>/dev/null || true
    printf 'forced_owned_pid=%s\n' "$pid" >> "$output/cleanup.txt"
    sleep 1
    if is_running "$pid"; then cleanup_failed=1; fi
  elif is_running "$pid"; then
    cleanup_failed=1
  fi
}

check_app_identity() {
  local app_exit=0
  if ! is_running "$app_pid"; then
    wait "$app_pid" || app_exit="$?"
    printf 'app_exit_code=%s\n' "$app_exit" >> "$output/receipt.txt"
    if [[ "$app_exit" == 0 ]]; then result=app_exited_before_capture; exit 71; fi
    result=app_crash_or_abnormal_exit
    exit 70
  fi
  [[ "$(process_identity "$app_pid" "$executable")" == "$app_identity" ]] || { result=app_identity_changed; exit 79; }
}

capture_frame() {
  local label="$1" png="$2" permission_status=0 frame_window_id
  check_app_identity
  record_core_children
  (( SECONDS < observation_deadline )) || { result=smoke_time_budget_exhausted; exit 75; }
  "$probe" window "$app_pid" > "$output/$label.window.before.json" 2> "$output/$label.window-id.txt" ||
    { result=window_lost_before_capture; exit 76; }
  frame_window_id="$(cat "$output/$label.window-id.txt")"
  [[ "$frame_window_id" =~ ^[0-9]+$ ]] || { result=invalid_window_id; exit 76; }
  "$probe" permission > "$output/$label.capture-permission.json" || permission_status="$?"
  printf 'frame_%s_os_capture_preflight_status=%s\n' "$label" "$permission_status" >> "$output/receipt.txt"
  build_hashes > "$output/$label.build.before.sha256"
  cmp -s "$output/build.before.sha256" "$output/$label.build.before.sha256" || { result=build_changed_before_capture; exit 76; }
  "$python_command" "$script_dir/macos_flutter_capture.py" --log "$output/app.stdout.log" \
    --pid "$app_pid" --out "$output/$png" > "$output/$label.engine-capture.json" 2> "$output/$label.engine-capture.stderr.log" &
  capture_pid="$!"
  capture_identity=''
  capture_deadline=$((SECONDS + 5))
  if (( capture_deadline > observation_deadline )); then capture_deadline="$observation_deadline"; fi
  while is_running "$capture_pid" && (( SECONDS < capture_deadline )); do
    capture_identity="$(process_identity "$capture_pid" "$capture_executable")" || capture_identity=''
    sleep 1
  done
  if is_running "$capture_pid"; then result=engine_screenshot_timed_out; exit 75; fi
  if ! wait "$capture_pid"; then result=engine_screenshot_failed; exit 75; fi
  capture_pid=''
  check_app_identity
  if ! "$probe" image "$output/$png" > "$output/$label.image.json"; then result=screenshot_invalid; exit 76; fi
  "$probe" window "$app_pid" > "$output/$label.window.after.json" 2> "$output/$label.window-id.after.txt" ||
    { result=window_lost_after_capture; exit 76; }
  [[ "$(cat "$output/$label.window-id.after.txt")" == "$frame_window_id" ]] || { result=window_identity_changed; exit 76; }
  check_app_identity
  build_hashes > "$output/$label.build.after.sha256"
  cmp -s "$output/build.before.sha256" "$output/$label.build.after.sha256" || { result=build_changed_during_capture; exit 76; }
  printf 'frame_%s_elapsed_seconds=%s\n' "$label" "$((SECONDS - app_started_seconds))" >> "$output/receipt.txt"
}

finish() {
  local status="$?" index
  trap - EXIT INT TERM
  set +e
  printf 'capture_result=%s\ncapture_exit_code=%s\n' "$result" "$status" >> "$output/receipt.txt"
  if [[ -n "$capture_pid" ]]; then stop_owned "$capture_pid" "$capture_executable" "$capture_identity"; fi
  record_core_children
  if [[ -n "$app_pid" ]]; then
    stop_owned "$app_pid" "$executable" "$app_identity"
    if ! is_running "$app_pid"; then
      wait "$app_pid" 2>/dev/null
    fi
  fi
  for ((index=0; index<core_count; index++)); do
    stop_owned "${core_pids[$index]}" "$core_executable" "${core_identities[$index]}"
  done
  for app_log in app.stdout.log app.stderr.log; do
    if [[ -f "$output/$app_log" ]]; then
      "$python_command" "$script_dir/macos_flutter_capture.py" --log "$output/$app_log" --redact-log > "$output/$app_log.redaction.json" ||
        { rm -f "$output/$app_log"; result=vm_service_log_redaction_failed; status=75; }
    fi
  done
  network_hashes > "$output/network.after.txt"
  if [[ "$?" != 0 ]] || ! cmp -s "$output/network.before.txt" "$output/network.after.txt"; then
    result=network_snapshot_changed_or_unavailable
    status=77
  fi
  if [[ -n "$app_pid" ]]; then
    "$probe" diagnostics "$app_pid" "$executable" "$launched_at" "$output/diagnostics" > "$output/diagnostics.jsonl" ||
      printf 'diagnostics_collection=unavailable\n' >> "$output/receipt.txt"
  fi
  for ((index=0; index<core_count; index++)); do
    "$probe" diagnostics "${core_pids[$index]}" "$core_executable" "$launched_at" "$output/diagnostics" >> "$output/diagnostics.jsonl" ||
      printf 'diagnostics_collection=unavailable\n' >> "$output/receipt.txt"
  done
  if [[ "$cleanup_failed" != 0 ]]; then
    rm -f "$output/app.stdout.log" "$output/app.stderr.log"
    result=owned_process_cleanup_unconfirmed
    status=79
  fi
  printf 'result=%s\nexit_code=%s\nowned_core_count=%s\nmanual_png_review=pending\n' \
    "$result" "$status" "$core_count" >> "$output/receipt.txt"
  rm -f "$probe"
  printf 'macOS safe smoke: %s (exit %s); manual PNG review pending\n' "$result" "$status"
  exit "$status"
}
trap finish EXIT
trap 'result=interrupted; exit 130' INT TERM
printf 'safe_mode=true\nbrand=example\nconfiguration=Debug\ncapture_source=flutter_engine\nos_capture=not_requested\naccept_disclaimer_environment=1\njob=%s\n' \
  "$job_identity" > "$output/receipt.txt"
result=network_baseline_unavailable
network_hashes > "$output/network.before.txt" || exit 77
result=internal_error
build_hashes > "$output/build.before.sha256"
printf 'started_at_epoch=%s\n' "$launched_at" >> "$output/receipt.txt"

(export FLCLASH_ACCEPT_DISCLAIMER=1; exec "$executable") > "$output/app.stdout.log" 2> "$output/app.stderr.log" &
app_pid="$!"
printf 'app_pid=%s\n' "$app_pid" >> "$output/receipt.txt"
app_started_seconds="$SECONDS"
observation_deadline=$((SECONDS + 45))
deadline=$((SECONDS + 25))
window_id=''
while (( SECONDS < deadline )); do
  if ! is_running "$app_pid"; then
    app_exit=0
    wait "$app_pid" || app_exit="$?"
    printf 'app_exit_code=%s\n' "$app_exit" >> "$output/receipt.txt"
    if [[ "$app_exit" == 0 ]]; then result=app_exited_before_capture; exit 71; fi
    result=app_crash_or_abnormal_exit
    exit 70
  fi
  current="$(process_identity "$app_pid" "$executable")" || current=''
  if [[ -n "$current" ]]; then
    if [[ -z "$app_identity" ]]; then
      [[ "$(/bin/ps -p "$app_pid" -o ppid= | tr -d ' ')" == "$$" ]] || { result=wrong_app_parent; exit 79; }
      app_identity="$current"
      printf '%s\n' "$app_identity" > "$output/owned-app-process.txt"
    elif [[ "$current" != "$app_identity" ]]; then result=app_identity_changed; exit 79
    fi
    record_core_children
    probe_status=0
    "$probe" window "$app_pid" > "$output/window.before.json" 2> "$output/window-id.txt" || probe_status="$?"
    if [[ "$probe_status" == 0 ]]; then window_id="$(cat "$output/window-id.txt")"; break; fi
    if [[ "$probe_status" == 24 ]]; then result=window_server_unavailable; exit 74; fi
    if [[ "$probe_status" != 22 ]]; then result=window_probe_failed; exit 74; fi
  fi
  sleep 1
done
[[ -n "$window_id" && "$window_id" =~ ^[0-9]+$ ]] || { result=no_window_within_25_seconds; exit 72; }
sleep 2
capture_frame first window-first.png
if ! grep -Eq '\[xclient\] client identity macos/(arm64|x64) 1\.0\.0-pre\.1\+10000401$' "$output/app.stdout.log"; then
  result=canonical_runtime_identity_not_verified
  exit 76
fi
printf 'canonical_runtime_identity=1.0.0-pre.1+10000401\nos_bundle_version=%s\nos_bundle_build=%s\n' \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")" >> "$output/receipt.txt"
settle_until=$((SECONDS + 15))
while (( SECONDS < settle_until )); do
  check_app_identity
  record_core_children
  (( SECONDS < observation_deadline )) || { result=smoke_time_budget_exhausted; exit 75; }
  sleep 1
done
capture_frame final window.png
result=captured_pending_manual_review
