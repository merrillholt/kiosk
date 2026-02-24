#!/bin/bash
# Usage: persist-upload.sh copy <src_path> <dest_filename>
#        persist-upload.sh delete <dest_filename>
# Deployed to /usr/local/bin/persist-upload.sh with chmod 755
# Called via: sudo /usr/local/bin/persist-upload.sh ...
UPLOADS_DIR="/home/merrill/building-directory/server/uploads"

validate_filename() {
    [[ -z "$1" || "$1" =~ [/\\] || ! "$1" =~ ^[a-zA-Z0-9._-]+$ ]] && { echo "Invalid filename" >&2; exit 1; }
}

case "$1" in
    copy)
        validate_filename "$3"
        [[ ! -f "$2" ]] && { echo "Source not found: $2" >&2; exit 1; }
        # Stage to /run — overlayroot-chroot bind-mounts /run from the live system,
        # so the chroot can see files placed there. /tmp is NOT bind-mounted.
        STAGE="/run/persist-stage-$$-$3"
        cp "$2" "$STAGE" || { echo "Stage copy failed" >&2; exit 1; }
        overlayroot-chroot mkdir -p "$UPLOADS_DIR"
        overlayroot-chroot cp "$STAGE" "$UPLOADS_DIR/$3"
        COPY_STATUS=$?
        rm -f "$STAGE"
        exit $COPY_STATUS
        ;;
    delete)
        validate_filename "$2"
        overlayroot-chroot rm -f "$UPLOADS_DIR/$2"
        ;;
    *) echo "Unknown action: $1" >&2; exit 1 ;;
esac
