#!/bin/sh

#
# sysctl -w kernel.core_pattern='|/usr/sbin/core-dump-handler.sh -c=%c -e=%e -p=%p -s=%s -t=%t
#
# Other setting in /etc/core-dump-handler.conf
#

PATH="/bin:/sbin:/usr/bin:/usr/sbin"

umask 0111

DIRECTORY="/var/log/core"
DIRECTORY_MAX_USAGE=4096
SCRIPTS_DIR="/etc/core-dump-handler.d"
ROTATE=10
WATCHDOG_USEC=600000000

if [ -z "$NOTIFY_SOCKET" ] ; then
    export NOTIFY_SOCKET=/run/systemd/notify
fi

if [ -f /etc/core-dump-handler.conf ] ; then
    source /etc/core-dump-handler.conf
fi

for i in "$@"
do
case $i in
    -c=*|--limit-size=*)
        LIMIT_SIZE="${i#*=}"; shift
    ;;
    -e=*|--exe-name=*)
        EXE_NAME="${i#*=}"; shift
    ;;
    -p=*|--pid=*)
        REAL_PID="${i#*=}"; shift
    ;;
    -s=*|--signal=*)
        SIGNAL="${i#*=}"; shift
    ;;
    -t=*|--timestamp=*)
        TS="${i#*=}"; shift
    ;;
    -d=*|--dir=*)
        DIRECTORY="${i#*=}"; shift
    ;;
    -b=*|--before-dir=*)
        SCRIPTS_DIR="${i#*=}"; shift
    ;;
    -r=*|--rotate=*)
        ROTATE="${i#*=}"; shift
    ;;
    -m=*|--max-usage=*)
        DIRECTORY_MAX_USAGE="${i#*=}"; shift
    ;;
    -w=*|--watchdog-timeout-usec=*)
        WATCHDOG_USEC="${i#*=}"; shift
    ;;
esac
done

EXE_NAME="${EXE_NAME// /_}" # replace spaces with _
EXE_NAME="${EXE_NAME//!/_}" # replace ! with _

SCRIPT_BEFORE="${SCRIPTS_DIR}/${EXE_NAME}.sh"
EXE_CONF="${SCRIPTS_DIR}/${EXE_NAME}.conf"

if [ -f ${EXE_CONF} ] ; then
    source ${EXE_CONF}
fi

if [[ "_0" = "_${LIMIT_SIZE}" ]]; then
    exit 0
fi

# Set systemd watchdog
systemd-notify --pid=${REAL_PID} WATCHDOG=1
systemd-notify --pid=${REAL_PID} WATCHDOG_USEC=${WATCHDOG_USEC}

# Select the compressor to use
if gzip --help >/dev/null 2>&1; then
    COMPRESSOR="gzip -9"
    EXT=.gz
elif lz4 --version >/dev/null 2>&1; then
    COMPRESSOR="lz4 -1"
    EXT=.lz4
elif lzop --version >/dev/null 2>&1; then
    COMPRESSOR="lzop -1"
    EXT=.lzo
else
    COMPRESSOR=cat
    EXT=
fi

CORE_EXTENSION=".core"
BASE_FILE="${TS}-${EXE_NAME}-${REAL_PID}-${SIGNAL}"
FILE_NAME="${BASE_FILE}${CORE_EXTENSION}${EXT}"
DUMP_FILE="${DIRECTORY}/${FILE_NAME}"

# Create directory if needed
if [[ ! -d "${DIRECTORY}" ]]; then
    mkdir -p "${DIRECTORY}"
    chown root:root "${DIRECTORY}"
    chmod 0777 "${DIRECTORY}"
else
    chmod a+rw "${DIRECTORY}"
fi

# Script to run before writing anything.
if [[ -x "${SCRIPT_BEFORE}" ]]; then
    echo "Executing '${SCRIPT_BEFORE}' before writing core dump"
    "${SCRIPT_BEFORE}"
fi

# Keep only #ROTATE files
find "${DIRECTORY}" -type f -name "*${EXT}" \
    | sort \
    | head -n "-${ROTATE}" \
    | while IFS= read -r file; do
        rm "$file"  # remove current file
        base_name=$(basename $file)
        base_name="${base_name%.*}"  # Get filename without extensions
        base_name="${base_name%${CORE_EXTENSION}}"  # Get filename without core extension
        if [ -n "$base_name" ]; then  # Validate name not empty
            find "${DIRECTORY}" -type f -name "${base_name}*" -delete  # Delete all files with the same base name
        fi
    done

VER_FILE="${DIRECTORY}/${BASE_FILE}.info.txt"
date >> "${VER_FILE}"

VERINFO=$(which verinfo)
if [ ! -z "${VERINFO}" ] && [ -x "${VERINFO}" ]
then
    ${VERINFO} >> "${VER_FILE}"
fi

# Write the coredump file
echo "Writing core dump to ${DUMP_FILE}"
head -c "${LIMIT_SIZE}" \
    | ${COMPRESSOR} > "${DUMP_FILE}"

JOURNALSEND=$(which journal-send)
if [ ! -z "${JOURNALSEND}" ] && [ -x "${JOURNALSEND}" ]
then
    ${JOURNALSEND} << EOM
    MESSAGE=Coredump ${FILE_NAME} generated
    PRIORITY=2
    SMP_LOG_PAGE_NAME=Reset
    SMP_LOG_CODE=$EXE_NAME
EOM
fi

# Delete oldest file until usage is OK
while [[ $(du "${DIRECTORY}" -sk | cut -f 1) -ge $DIRECTORY_MAX_USAGE ]]
 do
    if ( ! find "${DIRECTORY}" -type f -name "*${EXT}" \
            | sort \
            | head -n 1 \
            | while IFS= read -r file; do
                rm "$file"  # remove current file
                base_name=$(basename $file)
                base_name="${base_name%.*}"  # Get filename without extensions
                base_name="${base_name%${CORE_EXTENSION}}"  # Get filename without core extension
                if [ -n "$base_name" ]; then  # Validate name not empty
                    find "${DIRECTORY}" -type f -name "${base_name}*" -delete  # Delete all files with the same base name
                fi
                done
        )
    then
        break
    fi
done

# Sync
sync
