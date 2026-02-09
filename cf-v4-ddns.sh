cat > /usr/local/bin/cf-ddns.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Cloudflare DDNS (safer & more robust)
# - HTTPS WAN IP fetch
# - jq JSON parsing
# - proper -t handling
# - safer cache files
# - better error messages

CFKEY="${CFKEY:-}"
CFZONE_NAME="${CFZONE_NAME:-}"
CFRECORD_NAME="${CFRECORD_NAME:-}"
CFRECORD_TYPE="${CFRECORD_TYPE:-A}"   # A | AAAA
CFTTL="${CFTTL:-120}"                 # 120..86400
FORCE="${FORCE:-false}"

usage() {
  cat <<USAGE
Usage:
  cf-ddns.sh -k <api_token> -z <zone> -h <host> [-t A|AAAA] [-f true|false] [-l <cache_dir>]

Examples:
  cf-ddns.sh -k "CF_TOKEN" -z example.com -h home -t A
  cf-ddns.sh -k "CF_TOKEN" -z example.com -h home.example.com -t AAAA -f true

Env vars supported:
  CFKEY, CFZONE_NAME, CFRECORD_NAME, CFRECORD_TYPE, CFTTL, FORCE
USAGE
}

CACHE_DIR="${HOME}/.cache/cf-ddns"
while getopts ":k:h:z:t:f:l:" opts; do
  case "${opts}" in
    k) CFKEY="${OPTARG}" ;;
    h) CFRECORD_NAME="${OPTARG}" ;;
    z) CFZONE_NAME="${OPTARG}" ;;
    t) CFRECORD_TYPE="${OPTARG}" ;;
    f) FORCE="${OPTARG}" ;;
    l) CACHE_DIR="${OPTARG}" ;;
    *) usage; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl not found"
command -v jq   >/dev/null 2>&1 || die "jq not found (install jq first)"

# Validate inputs
[[ -n "${CFKEY}" ]]       || die "Missing API token. Provide -k or set CFKEY."
[[ -n "${CFZONE_NAME}" ]] || die "Missing zone name. Provide -z or set CFZONE_NAME."
[[ -n "${CFRECORD_NAME}" ]] || die "Missing hostname. Provide -h or set CFRECORD_NAME."
[[ "${CFRECORD_TYPE}" == "A" || "${CFRECORD_TYPE}" == "AAAA" ]] || die "CFRECORD_TYPE must be A or AAAA"
[[ "${CFTTL}" =~ ^[0-9]+$ ]] || die "CFTTL must be a number"
(( CFTTL >= 120 && CFTTL <= 86400 )) || die "CFTTL must be between 120 and 86400"

# Normalize hostname to FQDN
if [[ "${CFRECORD_NAME}" != "${CFZONE_NAME}" && "${CFRECORD_NAME}" != *".${CFZONE_NAME}" ]]; then
  CFRECORD_NAME="${CFRECORD_NAME}.${CFZONE_NAME}"
fi

# Pick WAN IP endpoint (HTTPS)
WANIPSITE_V4="https://api.ipify.org"
WANIPSITE_V6="https://api64.ipify.org"

WANIPSITE="${WANIPSITE_V4}"
if [[ "${CFRECORD_TYPE}" == "AAAA" ]]; then
  WANIPSITE="${WANIPSITE_V6}"
fi

mkdir -p "${CACHE_DIR}"
chmod 700 "${CACHE_DIR}" || true

# Use safe filenames
safe_name="$(echo "${CFRECORD_NAME}_${CFRECORD_TYPE}" | tr '/:@' '___')"
WAN_IP_FILE="${CACHE_DIR}/wan_ip_${safe_name}.txt"
ID_FILE="${CACHE_DIR}/ids_${safe_name}.json"

get_wan_ip() {
  # -f: fail on HTTP errors, -sS: silent but show errors, --max-time: avoid hanging
  local ip
  ip="$(curl -fsS --max-time 10 "${WANIPSITE}" | tr -d ' \r\n\t')"

  if [[ "${CFRECORD_TYPE}" == "A" ]]; then
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Invalid IPv4 from ${WANIPSITE}: '${ip}'"
  else
    # basic IPv6 sanity check (not perfect but good enough)
    [[ "${ip}" == *:* ]] || die "Invalid IPv6 from ${WANIPSITE}: '${ip}'"
  fi
  echo "${ip}"
}

cf_api() {
  local method="$1"; shift
  local url="$1"; shift
  curl -fsS --max-time 20 -X "${method}" "${url}" \
    -H "Authorization: Bearer ${CFKEY}" \
    -H "Content-Type: application/json" \
    "$@"
}

# Load old WAN IP
OLD_WAN_IP=""
if [[ -f "${WAN_IP_FILE}" ]]; then
  OLD_WAN_IP="$(cat "${WAN_IP_FILE}" | tr -d ' \r\n\t' || true)"
fi

WAN_IP="$(get_wan_ip)"

if [[ "${WAN_IP}" == "${OLD_WAN_IP}" && "${FORCE}" == "false" ]]; then
  echo "WAN IP unchanged (${WAN_IP}); use -f true to force update."
  exit 0
fi

# Load cached IDs if present and matching
CFZONE_ID=""
CFRECORD_ID=""
if [[ -f "${ID_FILE}" ]]; then
  cached_zone="$(jq -r '.zone_name // empty' "${ID_FILE}" 2>/dev/null || true)"
  cached_record="$(jq -r '.record_name // empty' "${ID_FILE}" 2>/dev/null || true)"
  cached_type="$(jq -r '.record_type // empty' "${ID_FILE}" 2>/dev/null || true)"
  if [[ "${cached_zone}" == "${CFZONE_NAME}" && "${cached_record}" == "${CFRECORD_NAME}" && "${cached_type}" == "${CFRECORD_TYPE}" ]]; then
    CFZONE_ID="$(jq -r '.zone_id // empty' "${ID_FILE}")"
    CFRECORD_ID="$(jq -r '.record_id // empty' "${ID_FILE}")"
  fi
fi

if [[ -z "${CFZONE_ID}" || -z "${CFRECORD_ID}" ]]; then
  echo "Fetching zone_id & record_id from Cloudflare..."
  zone_json="$(cf_api GET "https://api.cloudflare.com/client/v4/zones?name=${CFZONE_NAME}")"
  success="$(echo "${zone_json}" | jq -r '.success')"
  [[ "${success}" == "true" ]] || die "Cloudflare zones API failed: $(echo "${zone_json}" | jq -c '.errors')"

  CFZONE_ID="$(echo "${zone_json}" | jq -r '.result[0].id // empty')"
  [[ -n "${CFZONE_ID}" ]] || die "Zone not found: ${CFZONE_NAME}"

  rec_json="$(cf_api GET "https://api.cloudflare.com/client/v4/zones/${CFZONE_ID}/dns_records?type=${CFRECORD_TYPE}&name=${CFRECORD_NAME}")"
  success="$(echo "${rec_json}" | jq -r '.success')"
  [[ "${success}" == "true" ]] || die "Cloudflare dns_records API failed: $(echo "${rec_json}" | jq -c '.errors')"

  CFRECORD_ID="$(echo "${rec_json}" | jq -r '.result[0].id // empty')"
  [[ -n "${CFRECORD_ID}" ]] || die "DNS record not found: ${CFRECORD_NAME} (${CFRECORD_TYPE})"

  jq -n \
    --arg zone_id "${CFZONE_ID}" \
    --arg record_id "${CFRECORD_ID}" \
    --arg zone_name "${CFZONE_NAME}" \
    --arg record_name "${CFRECORD_NAME}" \
    --arg record_type "${CFRECORD_TYPE}" \
    '{zone_id:$zone_id, record_id:$record_id, zone_name:$zone_name, record_name:$record_name, record_type:$record_type}' \
    > "${ID_FILE}"
  chmod 600 "${ID_FILE}" || true
fi

echo "Updating ${CFRECORD_NAME} (${CFRECORD_TYPE}) => ${WAN_IP}"

update_json="$(cf_api PUT "https://api.cloudflare.com/client/v4/zones/${CFZONE_ID}/dns_records/${CFRECORD_ID}" \
  --data "$(jq -nc \
    --arg type "${CFRECORD_TYPE}" \
    --arg name "${CFRECORD_NAME}" \
    --arg content "${WAN_IP}" \
    --argjson ttl "${CFTTL}" \
    '{type:$type,name:$name,content:$content,ttl:$ttl}')" )"

if [[ "$(echo "${update_json}" | jq -r '.success')" == "true" ]]; then
  echo "Updated successfully!"
  echo "${WAN_IP}" > "${WAN_IP_FILE}"
  chmod 600 "${WAN_IP_FILE}" || true
else
  die "Update failed: $(echo "${update_json}" | jq -c '.errors')"
fi
EOF

chmod 700 /usr/local/bin/cf-ddns.sh
