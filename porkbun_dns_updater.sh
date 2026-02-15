#!/usr/bin/env bash

########################################
# Shell Safety (Strict Mode)
########################################

set -o errexit  # Exit immediately if a command fails
set -o nounset  # Treat unset variables as an error
set -o pipefail # Return the exit code of the last command in a pipe that failed
IFS=$'\n\t'     # Set Internal Field Separator to newline/tab for safer path handling

########################################
# Dependency Checks
########################################

# Require Bash 4.3+ for nameref and mapfile support
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    printf "ERROR: Bash 4.3+ required (Current: %s)\n" "$BASH_VERSION" >&2
    exit 1
fi

# Ensure required binary tools are installed
check_dependencies() {
    local missing=()
    local -a required_bins=(
        cat
        curl
        cut
        date
        grep
        jq
        mktemp
        mv
        rm
        sed
        sleep
        tail
        tee
    )

    for bin in "${required_bins[@]}"; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done

    if (( ${#missing[@]} > 0 )); then
        printf "ERROR: Missing required utilities:\n" >&2
        for bin in "${missing[@]}"; do
            printf "  - %s\n" "$bin" >&2
        done
        return 1
    fi

    return 0
}

########################################
# Paths & Constants
########################################

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# File paths
ENV_FILE="${SCRIPT_DIR}/porkbun_dns_updater.env"
LOG_FILE="${SCRIPT_DIR}/porkbun_dns_updater.log"

# Per-run temporary log buffer (used to prepend logs)
RUN_LOG="$(mktemp -t porkbun_dns_updater.run.XXXXXX)"

# Ensure temp file is always cleaned up
cleanup() {
    finalize_log
    rm -f "$RUN_LOG"
}
trap cleanup EXIT

if [[ -z "$RUN_LOG" || ! -w "$RUN_LOG" ]]; then
    printf "FATAL: Failed to create writable RUN_LOG\n" >&2
    exit 1
fi

# Metadata to placate the Porkbun and IP Fetcher APIs
VERSION="1.0.0" # Current script revision
USER_AGENT="PorkbunDNSUpdater/${VERSION}"

# Just in case Porkbun changes the base API URL again
PORKBUN_API_BASE="https://api.porkbun.com/api/json/v3"

# Dual-Stack ready fetchers for public IP discovery
IPFETCHERS=(
    "https://icanhazip.com"
    "https://ifconfig.me/ip"
    "https://api.ipify.org"
)

# Global IP placeholders
IPv4=""
IPv6=""

########################################
# Log Helpers
########################################

# Output line to terminal/log
log_line() {
    printf "%s\n" "$1" | tee -a "$RUN_LOG"
}

# Output line/block to terminal/log with trailing newline (for readability)
log_block() {
    printf "%s\n\n" "$1" | tee -a "$RUN_LOG"
}

# Format and log successful DNS update/check
log_record() {
    local ts="$1" fqdn="$2" type="$3" ip="$4" ttl="$5" result="$6"
    local old_ip="${7:-}" old_ttl="${8:-}"
    local output

    # Only show "old > new" transition if value actually changed
    [[ "$old_ip" == "$ip" ]] && old_ip=""
    [[ "$old_ttl" == "$ttl" ]] && old_ttl=""

    # Build the record block
    output="$ts
$fqdn
	Type   : $type
	IP     : ${old_ip:+$old_ip > }$ip
	TTL    : ${old_ttl:+$old_ttl > }$ttl
	Result : $result"

    log_block "$output"
}

# Format and log structured error block
log_error() {
    local ts="$1" scope="$2" op="$3" cause="$4" detail="${5:-}"
    local output

    # Build the error block
    output="$ts
$scope
ERROR
	Operation : $op
	Cause     : $cause${detail:+
	Detail    : $detail}"

    log_block "$output"
}

# Trim logfile to keep only the last N runs
trim_log_runs() {
    local start_pattern="=== Starting Porkbun DNS Update ==="
    [[ ! -f "$LOG_FILE" ]] && return

    # Count how many total runs are in the file
    local total_runs
    total_runs=$(grep -c "$start_pattern" "$LOG_FILE" || echo 0)

    # Only trim if we exceed the MAX_RUNS limit
    if (( total_runs > MAX_RUNS )); then
        # Determine which occurrence of the start pattern to keep from
        local target_occurrence=$(( total_runs - MAX_RUNS + 1 ))

        # Find the line number of that specific occurrence
        local start_line
        start_line=$(grep -n "$start_pattern" "$LOG_FILE" | sed -n "${target_occurrence}p" | cut -d: -f1)

        if [[ -n "$start_line" ]]; then
            # 'tail -n +X' outputs starting from line X to the end
            tail -n +"$start_line" "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

finalize_log() {
    set +o errexit

    # Trim OLD log first (oldest-first logic)
    trim_log_runs || true

    # Prepend this run's log to the main log file
    if [[ -f "$LOG_FILE" ]]; then
        cat "$RUN_LOG" "$LOG_FILE" > "${LOG_FILE}.new"
    else
        cat "$RUN_LOG" > "${LOG_FILE}.new"
    fi

    mv "${LOG_FILE}.new" "$LOG_FILE"
}

########################################
# Environment Bootstrap
########################################

# Generate an environment file on first run or if missing
if [[ ! -f "$ENV_FILE" ]]; then
    cat <<EOF > "$ENV_FILE"
# Porkbun DNS Updater Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

# API Credentials **REQUIRED** (https://porkbun.com/account/api)
# -----------------------------------------------------------------------------
# APIKEY="pk1_..."
# SECRETAPIKEY="sk1_..."
APIKEY=""
SECRETAPIKEY=""

# API Pacing and Log Retention
# -----------------------------------------------------------------------------
# API_DELAY : Seconds between API calls (default if empty: 2)
# MAX_RUNS : Max runs to log (default if empty: 432, 3 days if 10m interval)
API_DELAY=""
MAX_RUNS=""

# Records Format: "subdomain:domain:ttl:ipmode"
# -----------------------------------------------------------------------------
# subdomain : '@' (apex), '*' (wildcard), or name (default if empty: @)
# domain    : base domain (example.com) **REQUIRED**
# ttl       : time-to-live in seconds (minimum/default if empty: 600)
# ipmode    : 'v4' (A only), 'v6' (AAAA only), (default if empty: Dual-Stack)
RECORDS=(
  "@:example.com::"
# ":example.com::" also valid for apex
  "*.example.com::v4"
  "name:example.com:900:v6"
)
EOF

    if [[ ! -f "$ENV_FILE" ]]; then
        printf "ERROR: Failed to generate configuration template at:\
        \n%s\n\nCheck permissions or disk space.\n" "$ENV_FILE" >&2
        exit 1
    fi

    printf "SUCCESS: Created configuration template at:\
    \n%s\n\nPlease edit the file and rerun the script.\n" "$ENV_FILE"
    exit 0
fi

########################################
# Load Configuration
########################################

# shellcheck source=/dev/null
if ! source "$ENV_FILE"; then
    printf "ERROR: Failed to source %s\n" "$ENV_FILE" >&2
    exit 1
fi

# Validation: Check for required API credentials
if [[ -z "${APIKEY:-}" || -z "${SECRETAPIKEY:-}" ]]; then
    printf "ERROR: APIKEY and SECRETAPIKEY must be set in %s\n" "$ENV_FILE" >&2
    exit 1
fi

# Validation: Ensure at least one record is configured
if (( ${#RECORDS[@]} == 0 )); then
    printf "ERROR: No records defined in RECORDS array in %s\n" "$ENV_FILE" >&2
    exit 1
fi

# Apply numeric fallbacks to prevent errors if variables are empty or invalid
[[ ! "${API_DELAY:-}" =~ ^[0-9]+$ ]] && API_DELAY=2
[[ ! "${MAX_RUNS:-}" =~ ^[0-9]+$ ]] && MAX_RUNS=432

########################################
# IP Detection
########################################

# Fetch public IP for given family (4 or 6)
fetch_ip() {
    local family="$1" url="$2"
    # --fail: return error on 4xx/5xx; -sS: silent but show errors;
    # --connect-timeout: fail fast on bad routes
    curl "-$family" --fail -sS \
        --user-agent "$USER_AGENT" \
        --connect-timeout 5 \
        --max-time 10 \
        "$url" 2>/dev/null || echo ""
}

# shellcheck disable=SC2034
detect_ip() {
    local family="$1"
    declare -n target_var="IPv$family"
    local raw_ip clean_ip

    target_var=""

    for url in "${IPFETCHERS[@]}"; do
        raw_ip=$(fetch_ip "$family" "$url")
        # Strip whitespace
        clean_ip="${raw_ip//[[:space:]]/}"

        if [[ -n "$clean_ip" ]]; then
            # IPv4 regex validation
            if [[ "$family" == 4 && "$clean_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                target_var="$clean_ip"
                return 0
            # IPv6 basic colon check
            elif [[ "$family" == 6 && "$clean_ip" == *:* ]]; then
                target_var="$clean_ip"
                return 0
            fi
        fi
    done
    return 1
}

########################################
# API Wrapper
########################################

api_call() {
    local payload="$1" url="$2"
    local resp exit_code
    local max_attempts=3 attempt=1

    while (( attempt <= max_attempts )); do
        # -f: fail silently on server errors; 2>&1 captures both body and error msgs
        resp=$(curl -fsS --max-time 15 -X POST \
            -H "Content-Type: application/json" \
            --user-agent "$USER_AGENT" \
            -d "$payload" \
            "$url" 2>&1)
        exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            printf "%s" "$resp"
            return 0
        fi

        if (( attempt < max_attempts )); then
            # Redirect warnings to stderr to keep them out of JSON result variables
            printf "API Warning: Attempt %d failed. Retrying in 5s...\n" "$attempt" >&2
            sleep 5
        else
            printf "%s" "$resp"
            return "$exit_code"
        fi
        ((attempt++))
    done
}

########################################
# Record Processing Logic
########################################

process_record() {
    local name="$1" type="$2" ip="$3" domain="$4" ttl="$5"
    local fqdn ts resp status count id old_ip old_ttl auth_payload

    ts=$(date '+%Y-%m-%d %H:%M:%S')

    # Format FQDN for log; handle Apex (@) correctly
    if [[ -z "$name" || "$name" == "@" ]]; then
        fqdn="$domain"
    else
        fqdn="${name}.${domain}"
    fi

    # Build base auth payload once
    auth_payload=$(jq -n --arg ak "$APIKEY" --arg sk "$SECRETAPIKEY" \
        '{"apikey": $ak, "secretapikey": $sk}')

    # Retrieve existing record
    local retrieve_name="${name//@/}"
    resp=$(api_call "$auth_payload" \
        "$PORKBUN_API_BASE/dns/retrieveByNameType/$domain/$type${retrieve_name:+/$retrieve_name}")

    # Parse JSON results into array (results[0]=status, [1]=count, etc.)
    mapfile -t results < <(echo "$resp" | jq -r '
        .status // "ERROR",
        (.records | length // 0),
        (.records[0].id // ""),
        (.records[0].content // ""),
        (.records[0].ttl // "")
    ' 2>/dev/null)

    status="${results[0]:-ERROR}"
    count="${results[1]:-0}"
    id="${results[2]:-}"
    old_ip="${results[3]:-}"
    old_ttl="${results[4]:-}"

    if [[ "$status" != "SUCCESS" || ${#results[@]} -lt 2 ]]; then
        log_error "$ts" "$fqdn" "retrieve" "API error or malformed response" "$resp"
        return
    fi

    if (( count > 1 )); then
        log_error "$ts" "$fqdn" "retrieve" "Multiple matching records found" "Manual cleanup required"
        return
    fi

    # CREATE path
    if [[ -z "$id" ]]; then
        resp=$(api_call "$(echo "$auth_payload" | jq \
            --arg n "$name" --arg t "$type" --arg c "$ip" --arg tl "$ttl" \
            '. + {name: $n, type: $t, content: $c, ttl: $tl}')" \
            "$PORKBUN_API_BASE/dns/create/$domain")

        if [[ "$(echo "$resp" | jq -r '.status')" == "SUCCESS" ]]; then
            log_record "$ts" "$fqdn" "$type" "$ip" "$ttl" "CREATED"
        else
            log_error "$ts" "$fqdn" "create" "API rejected creation" "$resp"
        fi
        return
    fi

    # NO CHANGE path
    if [[ "$old_ip" == "$ip" && "$old_ttl" == "$ttl" ]]; then
        log_record "$ts" "$fqdn" "$type" "$ip" "$ttl" "UNCHANGED"
        return
    fi

    # UPDATE path
    resp=$(api_call "$(echo "$auth_payload" | jq --arg c "$ip" --arg tl "$ttl" \
        '. + {content: $c, ttl: $tl}')" \
        "$PORKBUN_API_BASE/dns/editByNameType/$domain/$type${retrieve_name:+/$retrieve_name}")

    if [[ "$(echo "$resp" | jq -r '.status')" == "SUCCESS" ]]; then
        log_record "$ts" "$fqdn" "$type" "$ip" "$ttl" "UPDATED" "$old_ip" "$old_ttl"
    else
        log_error "$ts" "$fqdn" "edit" "API rejected update" "$resp"
    fi
}

########################################
# Start Execution
########################################

log_block "=== Starting Porkbun DNS Update ==="

# Detect IPs: '|| true' ensures script continues even if one family
# (typically IPv6) isn't available on current network.
detect_ip 4 || true
detect_ip 6 || true

# Fatal Error: No internet connectivity or IP services down
if [[ -z "${IPv4:-}" && -z "${IPv6:-}" ]]; then
    log_error "$(date '+%Y-%m-%d %H:%M:%S')" "GLOBAL" "ip-detect" \
        "No public IP detected" \
        "Check network connection or IP fetcher availability"
    exit 1
fi

# Log detected IPs for visibility
[[ -n "${IPv4:-}" ]] && log_line "IPv4 Address: $IPv4"
[[ -n "${IPv6:-}" ]] && log_line "IPv6 Address: $IPv6"

log_line ""

########################################
# Main Loop
########################################

for rec in "${RECORDS[@]}"; do
    # Ignore empty entries or accidental whitespace in RECORDS array
    [[ -z "${rec// /}" ]] && continue

    # Split record string using local IFS
    IFS=':' read -r subdomain domain ttl ipmode <<< "$rec"

    # Validation: Ensure a base domain exists
    if [[ -z "$domain" ]]; then
        log_line "WARNING: Skipping invalid entry (missing domain): $rec"
        continue
    fi

    # TTL Enforcement: Default to 600 or enforce Porkbun's API minimum
    if [[ ! "$ttl" =~ ^[0-9]+$ ]] || (( ttl < 600 )); then
        ttl=600
    fi

    # Apex Mapping: Standardize '@' to an empty string for the API
    [[ "$subdomain" == "@" ]] && subdomain=""

    # Processing
    # Handle IPv4 (A) updates
    if [[ -n "${IPv4:-}" && ( -z "$ipmode" || "$ipmode" == "v4" ) ]]; then
        process_record "$subdomain" "A" "$IPv4" "$domain" "$ttl"
    fi

    # Handle IPv6 (AAAA) updates
    if [[ -n "${IPv6:-}" && ( -z "$ipmode" || "$ipmode" == "v6" ) ]]; then
        process_record "$subdomain" "AAAA" "$IPv6" "$domain" "$ttl"
    fi

    # API Pacing: Prevent triggering rate limits
    sleep "${API_DELAY:-2}"
done

########################################
# End Run
########################################

log_block "=== Porkbun DNS Update Complete ==="
