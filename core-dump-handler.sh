#!/bin/bash

#
# sysctl -w kernel.core_pattern='|/usr/sbin/core-dump-handler.sh -c=%c -e=%e -p=%p -s=%s -t=%t -d=/var/log/core -r=10 -m=4096 -b=/etc/core-dump-handler.d'
#

PATH="/bin:/sbin:/usr/bin:/usr/sbin"

umask 0111

DIRECTORY="/var/log/core"
DIRECTORY_MAX_USAGE=4096
SCRIPTS_DIR="/etc/core-dump-handler.d"
ROTATE=10

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
esac
done

DUMP_FILE="${DIRECTORY}/${TS}-${EXE_NAME}-${REAL_PID}-${SIGNAL}.core${EXT}"
SCRIPT_BEFORE="${SCRIPTS_DIR}/${EXE_NAME}.sh"

if [[ "_0" = "_${LIMIT_SIZE}" ]]; then
    exit 0
fi

# Select the compressor to use
if gzip --version >/dev/null 2>&1; then
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
find "${DIRECTORY}" -type f -printf "%T@ %p\n" \
	| sort \
	| head --lines "-${ROTATE}" \
	| cut --delimiter ' ' --fields 2 \
	| xargs --no-run-if-empty rm

# Write the coredump file
echo "Writing core dump to ${DUMP_FILE}"
head --bytes "${LIMIT_SIZE}" \
    | ${COMPRESSOR} > "${DUMP_FILE}"

# Delete oldest file until usage is OK
while (( $(du "${DIRECTORY}" -sk -0 | cut --fields 1) > $DIRECTORY_MAX_USAGE ))
do
    if ( ! find "${DIRECTORY}" -type f -printf "%T@ %p\n" \
            | sort \
            | head --lines 1 \
            | cut --delimiter ' ' --fields 2 \
            | xargs --no-run-if-empty rm )
    then
        break
    fi
done

# Sync
sync
