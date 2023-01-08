#!/bin/bash

RCB_INFO_NAME="ripe-country-blocker"
RCB_INFO_AUTHOR="ChillCode"
RCB_INFO_LICENSE="MIT"
RCB_INFO_REPO="https://github.com/chillcode/ripe-country-blocker"
RCB_INFO_DATE="2022-10-02"
RCB_INFO_VERSION="1.0.0"

#
# Display program usage
#
print_usage() {
    echo
    printf "%s %s %s\n" "Usage:" "${RCB_INFO_NAME}" "[--cc=XX]"
    echo
    echo "  --cc=XX     2-digit ISO-3166 country code to block."
    echo "              CH, US, IN, BR, RU"
    echo
    echo "  --f         Force update, do not check RIPE Queryt time."
    echo
    echo "  --v         Show debug output."
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
    echo "  A maximum of XX rules, XX is depending on the complexity of each rule."
    echo "  Don't expect to have so many rules."
}

#
# Get string length.
#
# @param  string The string being measured for length.
# @return Returns the length of the given string.
strlen() {
    echo "${1}" | awk '{print length()}'
}

#
# Get options.
#
while [ $# -gt 0  ]; do
    case "$1" in
        --cc=*)
            RCB_COUNTRY_ISO_CODE="$(echo "$1" | sed 's/--cc=//g')"
            ;;
        --f)
            RCB_FORCE_UPDATE=true
            ;;
        --h | --help)
            print_usage
            exit 0
            ;;
        --v)
            RCB_DEBUG=true
            ;;
        --gcloud)
            RCB_USE_GCLOUD=true
            ;;
        --o=*)
            RCB_TEMP_DIR="$(echo "$1" | sed 's/--o=//g')"
            ;;
        *)
            echo "Invalid argument: '${1}'."
            echo "Type '${RCB_INFO_NAME} --help' for available options."
            exit 1
            ;;
    esac
    shift
done

#
# Output message to console.
#
# @param  string The string to output.
# @return string Formatted message.
# @param  string Print usage.
# @param  string Exit with cde 1 if true.
output_message() {
    [ $RCB_DEBUG ] && echo "[${2}] [$(date)] ${1}"
    [ $RCB_DEBUG ] && [ "${3}" = true ] && print_usage

    [ "${4}" = true ] && exit 1
}

#
# Check if command exists.
#
# @param string Command to find.
check_command() {
    RCB_COMMAND_INSTALLED=$(command -v "${1}")

    if [ $? -ne 0 ]; then
        output_message "${1} not installed, try sudo apt-get install ${1}" "ERROR" false false
        exit 127
    fi

    output_message "Found ${RCB_COMMAND_INSTALLED}" "INFO" false false
}

#
# Check Required ISO 3166 Country Code parameter.
#
if [ -z "$RCB_COUNTRY_ISO_CODE" ]; then
    output_message "Invalid country code." "ERROR" false true
fi

# Check Country Code ISO 3166 length, must be 2-digit code.

RCB_COUNTRY_ISO_CODE_LEN=$(strlen "$RCB_COUNTRY_ISO_CODE")

if [ $RCB_COUNTRY_ISO_CODE_LEN -ne 2 ]; then
    output_message "Invalid argument: --cc=ISO Country code must be 2-sigit code." "ERROR" false false
    output_message "Type '${RCB_INFO_NAME} --help' for available options." "ERROR" false true
fi

# Format Country Code to uppercase for internal USE and to lowercase for GCloud Rules which only allows lowercase

RCB_COUNTRY_ISO_CODE=$(echo $RCB_COUNTRY_ISO_CODE | tr '[:lower:]' '[:upper:]')
RCB_COUNTRY_ISO_CODE_LOWER=$(echo $RCB_COUNTRY_ISO_CODE | tr '[:upper:]' '[:lower:]')

#
# Check required commands
#

# Check wget
check_command "wget"

# Check jq
check_command "jq"

if [ -z "$RCB_USE_GCLOUD" ]; then

    # Check iptables
    check_command "iptables"

    # Check ip6tables
    check_command "ip6tables"

    # Check ipset
    check_command "ipset"

else

    # Check gcloud
    check_command "gcloud"

fi

#
# Check directory.
#

RCB_TEMP_DIR=${RCB_TEMP_DIR:-/tmp}

#
# Prepare RIPE data.
#

# Create temp data file.
RCB_TEMP_DATA_FILE_PATH="/tmp/stat-ripe-country-resource-list-${RCB_COUNTRY_ISO_CODE}-XXXXX.json"
RCB_TEMP_DATA_FILE=$(mktemp -q ${RCB_TEMP_DATA_FILE_PATH})
RCB_TEMP_DATA_FILE_RESULT_CODE=$?

if [ $RCB_TEMP_DATA_FILE_RESULT_CODE -ne 0 ]; then
    output_message "mktemp failed creating temp ripe database: ${RCB_TEMP_DATA_FILE_PATH}" "ERROR" false true
fi

# Download RIPE JSON data file.

RCB_URL="https://stat.ripe.net/data/country-resource-list/data.json?v4_format=prefix&resource=${RCB_COUNTRY_ISO_CODE}"

RCB_WGET_RESULT=$(wget -q "$RCB_URL" -O $RCB_TEMP_DATA_FILE)
RCB_WGET_RESULT_CODE=$?

if [ $RCB_WGET_RESULT_CODE -ne 0 ]; then
    output_message "wget failed downloading RIPE database at $RCB_URL" "ERROR" false true
fi

# Check RIPE JSON data file.

RCB_DATA_STATUS=$(jq -r '.status' $RCB_TEMP_DATA_FILE)

if [ ! "$RCB_DATA_STATUS" = "ok" ]; then
    RCB_DATA_MESSAGES=$(jq -r -c '.messages' $RCB_TEMP_DATA_FILE)
    output_message "RIPE status $RCB_DATA_STATUS message $RCB_DATA_MESSAGES" "ERROR" false false
    output_message "RIPE response data file: $RCB_TEMP_DATA_FILE" "ERROR" false true
fi

# Get new RIPE JSON query time.

RCB_DATA_QUERY_TIME=$(jq -r '.data.query_time' $RCB_TEMP_DATA_FILE)
RCB_TEMP_DATA_FILE_TIME=$(date -d $RCB_DATA_QUERY_TIME +%s)

# Walk throug RIPE database.

for RCB_FAMILY in ipv4 ipv6; do
    #Check if local database exists and get file time.
    RCB_DATA_FILE="$RCB_TEMP_DIR/${RCB_FAMILY}-$RCB_COUNTRY_ISO_CODE"

    if [ -f "${RCB_DATA_FILE}" ]; then
        RCB_DATA_FILE_TIME=$(stat --printf "%Y" "${RCB_DATA_FILE}")
    else
        RCB_DATA_FILE_TIME=0
    fi

    #If remote database is not newer don't process it but if option --force is specified ignore this check.
    if [ ! $RCB_FORCE_UPDATE ] && [ ! $RCB_TEMP_DATA_FILE_TIME -gt $RCB_DATA_FILE_TIME ]; then
        output_message "$RCB_TEMP_DATA_FILE ($(date --date=@$RCB_TEMP_DATA_FILE_TIME)) is not newer than $RCB_DATA_FILE ($(date --date=@$RCB_DATA_FILE_TIME)), not updating ipset." "INFO" false false
    else
        #If remote database is newer process it.
        RCB_DATABASE_RESULT=$(jq -r ".data.resources.$RCB_FAMILY | .[]" $RCB_TEMP_DATA_FILE > $RCB_DATA_FILE.tmp)

        if [ $? -ne 0 ]; then
            output_message "RIPE database $RCB_TEMP_DATA_FILE not extracted to $RCB_DATA_FILE.tmp" "ERROR" false false
            continue
        else
            #Set RIPE query time to local database.
            RCB_UPDATE_FILE_TIME_RESULT=$(touch -d "$RCB_DATA_QUERY_TIME" "$RCB_DATA_FILE.tmp")

            #Lockup total entries to block.
            RCB_DATA_FILE_ENTRIES=$(awk 'END { print NR }' "$RCB_DATA_FILE.tmp")

            output_message "$RCB_DATA_FILE total entries $RCB_DATA_FILE_ENTRIES" "INFO" false false

            #Move temp database to local database.
            $(mv "$RCB_DATA_FILE.tmp" "$RCB_DATA_FILE")
        fi
    
        #Use gcloud
        if [ $RCB_USE_GCLOUD ]; then

            #
            # Get current rules if exists.
            #
            RCB_GCLOUD_RULES_TO_DELETE=$(gcloud compute firewall-rules list --filter="name:block-country-${RCB_COUNTRY_ISO_CODE_LOWER}-${RCB_FAMILY}*" --format="value(name)[terminator=' ']")

            if [ -n "${RCB_GCLOUD_RULES_TO_DELETE}" ]; then
                # Delete current rules if exists.
                RCB_GCLOUD_DELETE_RULES_RESULT=$(gcloud compute firewall-rules delete ${RCB_GCLOUD_RULES_TO_DELETE} --quiet --verbosity=none)
            fi

            #Walk the RIPE database and add all ip's to the ruleset
            RCB_COUNTER=0
            while read -r RCB_IPSET; do
                # Max VM instance GCloud Firewall entries 5000 and also we prevent too long argument error on Linux.
                if [ $RCB_COUNTER -gt 4999 ]; then
                    #Use a counter to append to rule name.
                    RCB_GCLOUD_COUNTER=$((RCB_COUNTER + RCB_GCLOUD_COUNTER))
                    RCB_GCLOUD_CREATE_RESULT=$(gcloud compute firewall-rules create "block-country-${RCB_COUNTRY_ISO_CODE_LOWER}-${RCB_FAMILY}-${RCB_GCLOUD_COUNTER}" --description="Block incoming traffic on all ports from ${RCB_COUNTRY_ISO_CODE}" --action=DENY --rules=all --direction=INGRESS --priority=1 --source-ranges="${RCB_CSV_LIST}")
                    #Reset list and counter after inserted.
                    RCB_CSV_LIST=""
                    RCB_COUNTER=0
                fi

                #Fill list with sources-ranges
                if [ -z $RCB_CSV_LIST ]; then
                    RCB_CSV_LIST="${RCB_IPSET}"
                else
                    RCB_CSV_LIST="${RCB_CSV_LIST},${RCB_IPSET}"
                fi

                RCB_COUNTER=$((RCB_COUNTER + 1))

            done < "${RCB_DATA_FILE}"

            #create rule instead with less than 5000 entries or last rule if there is pagination.
            if [ -z $RCB_GCLOUD_COUNTER ]; then
                RCB_GCLOUD_CREATE_RESULT=$(gcloud compute firewall-rules create "block-country-${RCB_COUNTRY_ISO_CODE_LOWER}-${RCB_FAMILY}-${RCB_COUNTER}" --description="Block incoming traffic on all ports from ${RCB_COUNTRY_ISO_CODE}" --action=DENY --rules=all --direction=INGRESS --priority=1 --source-ranges="${RCB_CSV_LIST}")

                unset RCB_CSV_LIST
                continue
            else
                RCB_GCLOUD_COUNTER=$((RCB_COUNTER + RCB_GCLOUD_COUNTER))
                RCB_GCLOUD_CREATE_RESULT=$(gcloud compute firewall-rules create "block-country-${RCB_COUNTRY_ISO_CODE_LOWER}-${RCB_FAMILY}-${RCB_GCLOUD_COUNTER}" --source-ranges="${RCB_CSV_LIST}" --description="Block incoming traffic on all ports from ${RCB_COUNTRY_ISO_CODE}" --action=DENY --rules=all --direction=INGRESS --priority=1)

                unset RCB_CSV_LIST
                unset RCB_GCLOUD_COUNTER
                continue
            fi
        else
            #Check if ipset already exists
            RCB_IPSET_SETNAME="country_block_${RCB_COUNTRY_ISO_CODE}_${RCB_FAMILY}"

            RCB_IPSET_LIST_RESULT=$(ipset -q -name list ${RCB_IPSET_SETNAME})

            if [ $? -ne 0 ]; then
                #If does not exists create a hash:net ipset
                if [ "$RCB_FAMILY" = "ipv6" ]; then
                $(ipset -q create ${RCB_IPSET_SETNAME} hash:net family inet6)
                else
                    $(ipset -q create ${RCB_IPSET_SETNAME} hash:net)
                fi
            else
                #If exists flush it
                $(ipset -q flush ${RCB_IPSET_SETNAME})
            fi

            while read -r RCB_IPSET; do
                RCB_IPSET_ADD_RESULT=$(ipset -q add ${RCB_IPSET_SETNAME} "$RCB_IPSET")
            done < "${RCB_DATA_FILE}"

            #Set command to use depending on ipset family
            if [ "$RCB_FAMILY" = "ipv6" ]; then
                RCB_IPTABLES_VERSION=ip6tables
            else
                RCB_IPTABLES_VERSION=iptables
            fi

            #Check if ipset is already added to iptables.
            RCB_IPTABLES_RESULT=$($RCB_IPTABLES_VERSION -nL | grep -e "DROP.*match-set.*${RCB_IPSET_SETNAME}.*src")

            if [ $? -ne 0 ]; then

                #Add ipset to iptables.
                RCB_IPTABLES_SET_RESULT=$($RCB_IPTABLES_VERSION -I INPUT 1 -m set --match-set ${RCB_IPSET_SETNAME} src -j DROP)

                RCB_IPTABLES_SET_RESULT_CODE=$?

                if [ $RCB_IPTABLES_SET_RESULT_CODE -ne 0 ]; then
                    output_message "${RCB_IPSET_SETNAME} not added to iptables!" "INFO" false false
                    exit $RCB_IPTABLES_SET_RESULT
                else
                    output_message "${RCB_IPSET_SETNAME} added to iptables, job finished!" "INFO" false false
                fi    
            else
                output_message "${RCB_IPSET_SETNAME} already added before to iptables, job finished!" "INFO" false false
            fi
        fi
    fi
done

exit 0
