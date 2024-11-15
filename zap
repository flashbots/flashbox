#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Early detection if this is a cloud operation
is_cloud_operation() {
    [[ "$1" == "azure" ]] || [[ "$1" == "gcp" ]] || \
    [[ "$2" == "azure" ]] || [[ "$2" == "gcp" ]]
}

if is_cloud_operation "$1" "$2"; then
    exec "${SCRIPT_DIR}/lib/cloud.sh" "$@"
else
    exec "${SCRIPT_DIR}/lib/bm.sh" "$@"
fi
