#!/usr/bin/env bash
#

VERSION="0.1"
DEBUG=1
LOG_TO_SYSLOG="YES"
LOGGER=$(which logger)
TIMEOUT=$(which timeout)
SPLIT=$(which split)
TIMEOUT_SECONDS=10
SWIFT=$(which swift)
CURL=$(which curl)
GNOCCHIRC=
DATE=$(date +%Y%m%d-%H%M%S)
BUCKET_NAME=measure
MEASURELIST=list-${BUCKET_NAME}-$(hostname)-${DATE}.txt
DELETE_DOWNLOAD=YES
#DELETE_DOWNLOAD=NO
SWIFTDOWNLOAD=$(mktemp -t -d swiftdownload.XXXXX)

function log_syslog {
    # TODO: make facility.level a parameter 
    FACILITY=local7.info
    if [ "${LOG_TO_SYSLOG}" == "YES" ]; then
        $LOGGER -p $FACILITY $1
    fi
}

function log_debug {
    if [ $DEBUG -gt 0 ]; then
        s="DEBUG $(basename $0) $(date +%Y%m%d-%H%M%S) - $1"
        echo "$s"
    fi
    s="$(basename $0) $(date +%Y%m%d-%H%M%S) - $1"
    log_syslog "$s"
}

function delete_download {
    if [[ "${DELETE_DOWNLOAD}" == "YES"  ]]; then
        log_debug "Delete directory ${SWIFTDOWNLOAD}"
        rm -Rf $SWIFTDOWNLOAD
    fi
}

function usage_help {
    delete_download
    echo "Usage: $(basename $0) gnocchirc"
    echo "       version: ${VERSION}"
    echo "       "
    echo "       This script requires to run under tmux|screen session!!!"
    exit 1
}

log_debug "Starting on $(hostname)"

if [[ "$TERM" =~ "screen".* ]]; then
    log_debug "We are on screen or tmux session... continue"
else
    log_debug "Error! Not on screen or tmux session... exit"
    usage_help
fi

# check parameter
if [ $# -gt 0 ]; then
    if [ "$1" == "-h" -o "$1" == "--help" ]; then
        usage_help
    else
        GNOCCHIRC=$1
    fi
else
    usage_help
fi

log_debug "gnocchirc file: ${GNOCCHIRC}"

# check if gnocchirc is readable
if [ -r ${GNOCCHIRC} ]; then
    . ${GNOCCHIRC}
else
    echo "Error: Can't read gnocchirc file ${GNOCCHIRC}"
    echo "Exit..."
    exit 1
fi

log_debug "Run with $TIMEOUT"

$TIMEOUT $TIMEOUT_SECONDS $SWIFT list $BUCKET_NAME > ${SWIFTDOWNLOAD}/${MEASURELIST}

if [ -r ${SWIFTDOWNLOAD}/${MEASURELIST} ]; then
    log_debug "Downloaded file ${SWIFTDOWNLOAD}/${MEASURELIST}"
else
    log_debug "Error! File ${SWIFTDOWNLOAD}/${MEASURELIST} not found... exit"
    exit 1
fi

# write bucket name as prefix
log_debug "Insert bucket name ${BUCKET_NAME} prefix in ${SWIFTDOWNLOAD}/${MEASURELIST}"
sed -i "s/^/$BUCKET_NAME\//g" ${SWIFTDOWNLOAD}/${MEASURELIST}

# now split the file to 10000 lines
SPLITNAME="split-${BUCKET_NAME}-$(hostname)-${DATE}-"
log_debug "Split file name: ${SPLITNAME}"
log_debug "Run split..."
$SPLIT -l 10000 ${SWIFTDOWNLOAD}/${MEASURELIST} ${SWIFTDOWNLOAD}/${SPLITNAME}

# get the object number before the delete
OBJECT_START=$($SWIFT stat $BUCKET_NAME | egrep Objects | sed 's/[[:blank:]]*Objects: //g')
log_debug "Found object number: $OBJECT_START"


for f in $(ls ${SWIFTDOWNLOAD}/${SPLITNAME}*); do
    log_debug "Found splitted file $f"
    # reload gnocchirc
    log_debug "Remove all OS_ env vars"
    for key in $( set | awk '{FS="="}  /^OS_/ {print $1}' ); do unset $key ; done
    log_debug "Load gnocchirc file ${GNOCCHIRC}"
    . ${GNOCCHIRC}
    # run eval swift auth
    log_debug "Run eval ${SWIFT} auth)"
    eval $(${SWIFT} auth)
    log_debug "Var OS_STORAGE_URL $OS_STORAGE_URL"
    log_debug "Var OS_AUTH_TOKEN $OS_AUTH_TOKEN"
    log_debug "Run curl with bulk-delete"
    time $CURL -i -H "Content-Type: text/plain" -X DELETE "${OS_STORAGE_URL}/measure?bulk-delete" -H "X-Auth-Token: ${OS_AUTH_TOKEN}" -T "$f"
done

OBJECT_END=$($SWIFT stat $BUCKET_NAME | egrep Objects | sed 's/[[:blank:]]*Objects: //g')
log_debug "Found object start number: $OBJECT_START"
log_debug "Found object end number: $OBJECT_END"
OBJECT_DELETED=$(($OBJECT_START-$OBJECT_END))
log_debug "Deleted: $OBJECT_DELETED"

log_debug "End"
delete_download
