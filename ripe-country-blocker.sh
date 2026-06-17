#!/usr/bin/env bash

set -u
set -o pipefail

IFS=$'\n\t'

readonly RCB_INFO_NAME="ripe-country-blocker"
readonly RCB_INFO_DESCRIPTION="Block countries using ripe database"
readonly RCB_INFO_AUTHOR="chillcode"
readonly RCB_INFO_LICENSE="MIT"
readonly RCB_INFO_REPO="https://github.com/chillcode/ripe-country-blocker"
readonly RCB_INFO_DATE="2022-10-02"
readonly RCB_INFO_UPDATE="2026-06-16"
readonly RCB_INFO_VERSION="2.0.0"

RCB_COUNTRY_ISO_CODE=""
RCB_DEBUG=false
RCB_DELETE=false
RCB_USE_GCLOUD=false
RCB_TEMP_DIR="/tmp"

RCB_BLOCK_INGRESS=false
RCB_BLOCK_EGRESS=false

#
# Display program usage.
#
print_usage() {
    echo
    printf "%s %s %s\n" "Usage:" "${RCB_INFO_NAME}" "[--cc=XX]"
    echo
    echo "  --cc=XX     2-digit ISO-3166 country code to block."
    echo "              CH, US, IN, BR, RU"
    echo
    echo "  --i         Block ingress traffic. (default iptables)"
    echo "  --e         Block egress traffic."
    echo "  --a         Block all traffic. (default GCloud)"
    echo
    echo "  --v         Show debug output."
    echo
    echo "  --D         Flush ipset for given country."
    echo "              To destroy the ipset iptables service needs to be stopped before we run ipset destroy SETNAME."
    echo "              Delete rules when using --gcloud."
    echo
    echo "  --gcloud    Use Google Cloud firewall instead of iptables and ipset."
    echo "              Requires gcloud command and a IAM user with the right permissions"
    echo
    echo "  --o=/tmp    RIPE databases output directory"
    echo
    echo "  --help, --h  Show this help."
    echo
    echo "  GCloud have some limits creating rules: "
    echo
    echo "  A maximum of 5000 entries per rule (can be CIDR notation)."
    echo "  A maximum of XXX rules, XXX is depending on the complexity of each rule."
    echo "  Don't expect to have so many rules"
}

#
# Get options.
#
while [ $# -gt 0  ]; do
    case "$1" in
        --cc=*)
            RCB_COUNTRY_ISO_CODE="${1#--cc=}"
            ;;
        --i)
            RCB_BLOCK_INGRESS=true
            ;;
        --e)
            RCB_BLOCK_EGRESS=true
            ;;
        --a)
            RCB_BLOCK_INGRESS=true
            RCB_BLOCK_EGRESS=true
            ;;
        --h | --help)
            print_usage
            exit 0
            ;;
        --v)
            RCB_DEBUG=true
            ;;
        --D)
            RCB_DELETE=true
            ;;
        --gcloud)
            RCB_USE_GCLOUD=true
            ;;
        --o=*)
            RCB_TEMP_DIR=="${1#--o=}"
            ;;
        *)
            echo "Invalid argument: '${1}'."
            echo "Type '${RCB_INFO_NAME} --help' for available options."
            exit 1
            ;;
    esac
    shift
done

if [[ "$RCB_BLOCK_INGRESS" == false && "$RCB_BLOCK_EGRESS" == false ]]; then
    if [[ "$RCB_USE_GCLOUD" == true ]]; then
        RCB_BLOCK_INGRESS=true
        RCB_BLOCK_EGRESS=true
    else
        RCB_BLOCK_INGRESS=true
        RCB_BLOCK_EGRESS=true
    fi
fi

#
# Output message to console.
#
# @param  string The string to output.
# @return string Formatted message.
# @param  string Print usage.
# @param  string Exit with code 1 if true.
# @return void
output_message() {
    [[ "$RCB_DEBUG" == true ]] && echo "[${2}] [$(date)] ${1}"
    [[ "$RCB_DEBUG" == true && "${3}" == true ]] && print_usage
    [[ "${4}" == true ]] && exit 1
}

#
# Check if command exists.
#
# @param string Command to find.
# @return void
check_command() {
    if ! command -v "${1}" >/dev/null 2>&1; then
        output_message "${1} not installed, try apt install ${1}" "ERROR" false false
        exit 127
    fi
    output_message "Found ${1}" "INFO" false false
}

#
# Check Required ISO 3166 Country Code parameter.
#
if [ -z "$RCB_COUNTRY_ISO_CODE" ]; then
    output_message "Invalid country code." "ERROR" false true
fi

if ! [[ "$RCB_COUNTRY_ISO_CODE" =~ ^[A-Za-z]{2}$ ]]; then
    output_message "Invalid argument: --cc=ISO Country code must be 2-sigit code." "ERROR" false false
    output_message "Type '${RCB_INFO_NAME} --help' for available options." "ERROR" false true
fi

# Format Country Code to uppercase for internal USE and to lowercase for GCloud Rules which only allows lowercase
RCB_COUNTRY_ISO_CODE=${RCB_COUNTRY_ISO_CODE^^}
RCB_COUNTRY_ISO_CODE_LOWER=${RCB_COUNTRY_ISO_CODE,,}

#
# Check required commands
#
check_command "wget"
check_command "jq"

if [[ "$RCB_USE_GCLOUD" == false ]]; then
    check_command "iptables"
    check_command "ip6tables"
    check_command "ipset"
else
    check_command "gcloud"
fi

#
# Delete GCloud rule if exists.
#
# @param string ISO code.
# @param string ip family.
# @return void
delete_gcloud_rule() {
    #
    # Get current rules if exists.
    #
    local RCB_GCLOUD_RULES_TO_DELETE

    if ! RCB_GCLOUD_RULES_TO_DELETE=$(gcloud compute firewall-rules list --filter="name:block-country-${1}-${2}-${3}*" --format="value(name)" --quiet --verbosity=none); then
        output_message "Unable to list GCloud firewall rules for ${1}-${2}-${3}, check gcloud configuration and IAM permissions" "ERROR" false true
    fi

    if [ -n "${RCB_GCLOUD_RULES_TO_DELETE}" ]; then
        # Delete current rules if exists.
        if ! gcloud compute firewall-rules delete ${RCB_GCLOUD_RULES_TO_DELETE} --quiet --verbosity=none >/dev/null 2>&1; then
            output_message "Failed to delete: ${RCB_GCLOUD_RULES_TO_DELETE}" "ERROR" false true
        else
            output_message "Deleted GCloud firewall rule for ${1}-${2}-${3}." "INFO" false false
        fi     
    else
        output_message "GCloud firewall rule for ${1}-${2}-${3} were not found, not deleting." "INFO" false false
    fi
}

#
# Delete ipset rule if exists.
#
# @param string ISO code.
# @param string ip family.
# @return void
delete_ipset_rule() {
    local RCB_IPSET_SETNAME="country_block_${1}_${2}"

    if ! ipset -q -name list "${RCB_IPSET_SETNAME}" >/dev/null 2>&1; then
        output_message "ipset ${RCB_IPSET_SETNAME} does not exists, not flushing" "INFO" false false
    else
        # If exists flush it, destroy option can cause a controlled exception: "Set cannot be destroyed: it is in use by a kernel component".
        # It can be manually destroyed stopping iptables an issuing "ipset destroy SETNAME" command.
        if ! ipset -q flush "${RCB_IPSET_SETNAME}" >/dev/null 2>&1; then
            output_message "could not flush ipset ${RCB_IPSET_SETNAME}" "ERROR" false true
        else
            output_message "ipset ${RCB_IPSET_SETNAME} flushed" "INFO" false false
        fi
    fi
}

if [[ "$RCB_DELETE" == true ]]; then
    for RCB_FAMILY in ipv4 ipv6; do
        if [[ "$RCB_USE_GCLOUD" == true ]]; then
            for RCB_DIRECTION in "INGRESS" "EGRESS"; do
                [[ "$RCB_DIRECTION" == "INGRESS" && "$RCB_BLOCK_INGRESS" == false ]] && continue
                [[ "$RCB_DIRECTION" == "EGRESS" && "$RCB_BLOCK_EGRESS" == false ]] && continue

                # Convert to to lower
                RCB_DIR_LOWER=${RCB_DIRECTION,,}

                delete_gcloud_rule "${RCB_COUNTRY_ISO_CODE_LOWER}" "${RCB_FAMILY}" "${RCB_DIR_LOWER}"
            done
        else
            delete_ipset_rule "${RCB_COUNTRY_ISO_CODE}" "${RCB_FAMILY}"
        fi
    done
    exit 0
fi

#
# Prepare RIPE data.
#

# Create temp data dir.
RCB_WORK_DIR=$(mktemp -d "${RCB_TEMP_DIR}/${RCB_INFO_NAME}.XXXXXX")

readonly RCB_WORK_DIR

if [[ ! -d "${RCB_WORK_DIR}" ]]; then
    output_message "mktemp failed creating temp ripe database: ${RCB_TEMP_DATA_FILE_PATH}" "ERROR" false true
fi

cleanup() {
    if [[ -d "${RCB_WORK_DIR}" ]]; then
        rm -rf "${RCB_WORK_DIR}"
    fi
}

trap cleanup EXIT INT TERM

# Create temp data file.
RCB_TEMP_DATA_FILE_PATH="${RCB_WORK_DIR}/stat-ripe-country-resource-list-${RCB_COUNTRY_ISO_CODE}-XXXX.json"
RCB_TEMP_DATA_FILE=$(mktemp -q "${RCB_TEMP_DATA_FILE_PATH}")

# Download RIPE JSON data file.
RCB_URL="https://stat.ripe.net/data/country-resource-list/data.json?v4_format=prefix&resource=${RCB_COUNTRY_ISO_CODE}"

if ! wget -q "$RCB_URL" -O "$RCB_TEMP_DATA_FILE"; then
    output_message "wget failed downloading RIPE database at $RCB_URL" "ERROR" false true
fi

# Check RIPE JSON data file.
RCB_DATA_STATUS=$(jq -r '.status' "$RCB_TEMP_DATA_FILE")

if [[ ! "$RCB_DATA_STATUS" = "ok" ]]; then
    RCB_DATA_MESSAGES=$(jq -r -c '.messages' "$RCB_TEMP_DATA_FILE")

    output_message "RIPE status $RCB_DATA_STATUS message $RCB_DATA_MESSAGES" "ERROR" false false
    output_message "RIPE response data file: $RCB_TEMP_DATA_FILE" "ERROR" false true
fi

# Walk throug RIPE database.
for RCB_FAMILY in ipv4 ipv6; do
    # Check if local database exists and get file time.
    RCB_DATA_FILE="$RCB_WORK_DIR/${RCB_FAMILY}-$RCB_COUNTRY_ISO_CODE"

    if ! RCB_JQ_ERROR=$(jq -r ".data.resources.$RCB_FAMILY | .[]" "$RCB_TEMP_DATA_FILE" 2>&1 1> "$RCB_DATA_FILE.tmp"); then
        output_message "Error extracting JSON data: $RCB_JQ_ERROR" "ERROR" false false
        output_message "RIPE error $RCB_JQ_ERROR, $RCB_TEMP_DATA_FILE not extracted to $RCB_DATA_FILE.tmp" "ERROR" false false
        continue
    fi

    # Lockup total entries to block.
    RCB_DATA_FILE_ENTRIES=$(awk 'END { print NR }' "$RCB_DATA_FILE.tmp")

    output_message "$RCB_DATA_FILE total entries $RCB_DATA_FILE_ENTRIES" "INFO" false false

    # Move temp database to local database.
    mv "$RCB_DATA_FILE.tmp" "$RCB_DATA_FILE"

    # Use gcloud
    if [[ "$RCB_USE_GCLOUD" == true ]]; then
        # Ingress/Egress Logic
        for RCB_DIRECTION in "INGRESS" "EGRESS"; do
            [[ "$RCB_DIRECTION" == "INGRESS" && "$RCB_BLOCK_INGRESS" == false ]] && continue
            [[ "$RCB_DIRECTION" == "EGRESS" && "$RCB_BLOCK_EGRESS" == false ]] && continue

            # Convert to to lower
            RCB_DIR_LOWER=${RCB_DIRECTION,,}

            # Delete current rules if exists. Faster than update at the time tests were done.
            delete_gcloud_rule ${RCB_COUNTRY_ISO_CODE_LOWER} ${RCB_FAMILY} ${RCB_DIR_LOWER}

            # Set direction
            RCB_RANGES_FLAG="--source-ranges"
            [[ "$RCB_DIRECTION" == "EGRESS" ]] && RCB_RANGES_FLAG="--destination-ranges"

            RCB_GCLOUD_COUNTER=0
            RCB_GCLOUD_CHUNK="${RCB_DATA_FILE}_chunk_"
            split -l 5000 "${RCB_DATA_FILE}" "${RCB_GCLOUD_CHUNK}"

            for CHUNK in "${RCB_GCLOUD_CHUNK}"*; do
                # Convert the chunk lines into a single CSV string
                RCB_CSV_LIST=$(paste -sd, "$CHUNK")
    
                # Run your GCloud command using the fast csv_list
                if ! gcloud compute firewall-rules create "block-country-${RCB_COUNTRY_ISO_CODE_LOWER}-${RCB_FAMILY}-${RCB_DIR_LOWER}-${RCB_GCLOUD_COUNTER}" \
                    --description="Block ${RCB_DIR_LOWER} traffic from/to ${RCB_COUNTRY_ISO_CODE}" \
                    --action=DENY \
                    --rules=all \
                    --direction=${RCB_DIRECTION} \
                    --priority=1 \
                    ${RCB_RANGES_FLAG}="${RCB_CSV_LIST}" --quiet --verbosity=none >/dev/null 2>&1;
                then
                    output_message "Unable to create GCloud firewall rule for ${RCB_COUNTRY_ISO_CODE_LOWER}-${RCB_FAMILY} (${RCB_DIRECTION})" "ERROR" false true
                else
                    output_message "Created GCloud firewall rule for ${RCB_COUNTRY_ISO_CODE_LOWER}-${RCB_FAMILY} (${RCB_DIRECTION})" "INFO" false false
                fi
    
                RCB_GCLOUD_COUNTER=$((RCB_GCLOUD_COUNTER + 1))
            done

            rm -f "${RCB_GCLOUD_CHUNK}"*
        done
    else
        # Check if ipset already exists.
        RCB_IPSET_SETNAME="country_block_${RCB_COUNTRY_ISO_CODE}_${RCB_FAMILY}"
        # Set command to use depending on ipset family.
        if [[ "$RCB_FAMILY" = "ipv6" ]]; then
            RCB_IPTABLES_VERSION=ip6tables
            RCB_IPSET_FAMILY="family inet6"
        else
            RCB_IPTABLES_VERSION=iptables
            RCB_IPSET_FAMILY="family inet"
        fi

        # ipset creation using restore parameter
        if ! {
            echo "create ${RCB_IPSET_SETNAME} hash:net ${RCB_IPSET_FAMILY} maxelem 200000 -exist"

            echo "flush ${RCB_IPSET_SETNAME}"

            sed "s/^/add ${RCB_IPSET_SETNAME} /" "${RCB_DATA_FILE}"
        } | ipset -q restore; then
            output_message "Failed to update ipset ${RCB_IPSET_SETNAME}" "ERROR" false true
        fi

        # Ingress Logic
        if [[ "$RCB_BLOCK_INGRESS" == true ]]; then
            if ! $RCB_IPTABLES_VERSION -C INPUT -m set --match-set "${RCB_IPSET_SETNAME}" src -j DROP 2>/dev/null; then
                if ! $RCB_IPTABLES_VERSION -I INPUT 1 -m set --match-set "${RCB_IPSET_SETNAME}" src -j DROP; then
                    output_message "${RCB_IPSET_SETNAME} ingress rules not added" "ERROR" false false
                    exit 1
                fi
                output_message "${RCB_IPSET_SETNAME} ingress rules added" "INFO" false false
            else
                output_message "${RCB_IPSET_SETNAME} ingress rules updated" "INFO" false false
            fi
        fi

        # Egress Logic
        if [[ "$RCB_BLOCK_EGRESS" == true ]]; then
            if ! $RCB_IPTABLES_VERSION -C OUTPUT -m set --match-set "${RCB_IPSET_SETNAME}" dst -j DROP 2>/dev/null; then
                if ! $RCB_IPTABLES_VERSION -A OUTPUT -m set --match-set "${RCB_IPSET_SETNAME}" dst -j DROP; then
                    output_message "${RCB_IPSET_SETNAME} egress rules not added" "ERROR" false false
                    exit 1
                fi
                output_message "${RCB_IPSET_SETNAME} egress rules added" "INFO" false false
            else
                output_message "${RCB_IPSET_SETNAME} egress rules updated" "INFO" false false
            fi
        fi
    fi
done

exit 0
