#!/bin/bash
# Read-only post-start check: a rebuilt tag must match each running container.
# Arguments are the complete Compose command, including project/files/profiles.
bt_verify_running_images() {
    local ids id record image actual expected
    ids=$("$@" ps -q) || return 1
    for id in $ids; do
        record=$(docker inspect --format '{{.Config.Image}} {{.Image}}' "$id") || return 1
        image=${record% *}
        actual=${record##* }
        expected=$(docker image inspect --format '{{.Id}}' "$image") || return 1
        if [ "$actual" != "$expected" ]; then
            echo "Error: $id is running $actual, but $image resolves to $expected. Recreate this service before testing." >&2
            return 1
        fi
        echo "Verified running image: $image ($actual)"
    done
}
