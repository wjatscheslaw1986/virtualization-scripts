#!/bin/sh

# The script to create a QEMU QCOW2 image with a backing file
# Usage: create_vm_image.sh <backing_file> <new_image>

set -eu

# Check if running as root
if [ "$(id -u)" = "0" ]; then
    echo "ERROR: This script must NOT be run as root" >&2
    exit 1
fi

# Validate arguments
if [ $# -ne 2 ]; then
    echo "Usage: $0 <backing_file> <new_image>" >&2
    echo "  backing_file: Path to the existing base QCOW2 image" >&2
    echo "  new_image:    Path for the new QCOW2 image to create" >&2
    exit 1
fi

BACKING_FILE="$1"
NEW_IMAGE="$2"

# Validate backing file exists
if [ ! -f "$BACKING_FILE" ]; then
    echo "ERROR: Backing file '$BACKING_FILE' does not exist" >&2
    exit 1
fi

# Validate backing file is readable
if [ ! -r "$BACKING_FILE" ]; then
    echo "ERROR: Backing file '$BACKING_FILE' is not readable" >&2
    exit 1
fi

# Check if new image already exists
if [ -e "$NEW_IMAGE" ]; then
    echo "ERROR: New image '$NEW_IMAGE' already exists" >&2
    exit 1
fi

# Create the new QCOW2 image with backing file
echo "Creating QCOW2 image '$NEW_IMAGE' with backing file '$BACKING_FILE'"
qemu-img create -f qcow2 -b "$BACKING_FILE" -F qcow2 "$NEW_IMAGE"

echo "Successfully created '$NEW_IMAGE'"
exit 0
