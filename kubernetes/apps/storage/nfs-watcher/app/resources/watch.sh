#!/bin/sh
set -eu

HOST_KUBELET_PODS="${HOST_KUBELET_PODS:-/host/var/lib/kubelet/pods}"
WATCH_INTERVAL_SECONDS="${WATCH_INTERVAL_SECONDS:-120}"
PROBE_TIMEOUT_SECONDS="${PROBE_TIMEOUT_SECONDS:-8}"
FAILURES_BEFORE_RESTART="${FAILURES_BEFORE_RESTART:-2}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-900}"
SUMMARY_INTERVAL_SECONDS="${SUMMARY_INTERVAL_SECONDS:-3600}"
STATE_DIR="${STATE_DIR:-/tmp/nfs-watcher}"

mkdir -p "$STATE_DIR"

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

read_number_file() {
    file="$1"
    default="${2:-0}"
    value="$default"

    if [ -f "$file" ]; then
        value="$(cat "$file" 2>/dev/null || echo "$default")"
    fi

    case "$value" in
        ''|*[!0-9]*)
            value="$default"
            ;;
    esac

    printf '%s\n' "$value"
}

log_summary() {
    mount_count="$1"
    controller_count="$2"
    failed_mount_count="$3"
    failed_controller_count="$4"
    last_summary_file="${STATE_DIR}/last_summary"
    now="$(date +%s)"

    [ "$SUMMARY_INTERVAL_SECONDS" -gt 0 ] || return 0

    last_summary="$(read_number_file "$last_summary_file" 0)"
    if [ "$((now - last_summary))" -ge "$SUMMARY_INTERVAL_SECONDS" ]; then
        log "summary node=${NODE_NAME} mounts=${mount_count} controllers=${controller_count} failed_mounts=${failed_mount_count} failed_controllers=${failed_controller_count}"
        echo "$now" > "$last_summary_file"
    fi
}

state_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

list_node_pods() {
    kubectl get pods -A \
        --field-selector "spec.nodeName=${NODE_NAME},status.phase=Running" \
        -o jsonpath='{range .items[*]}{.metadata.uid}{"|"}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.metadata.ownerReferences[0].kind}{"|"}{.metadata.ownerReferences[0].name}{"\n"}{end}'
}

list_nfs_mounts() {
    prefix="${HOST_KUBELET_PODS}/"

    awk -v prefix="$prefix" '
        {
            sep = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "-") {
                    sep = i
                    break
                }
            }
            if (sep == 0) {
                next
            }
            fs = $(sep + 1)
            src = $(sep + 2)
            mp = $5
            gsub(/\\040/, " ", mp)
            if ((fs == "nfs" || fs == "nfs4") && index(mp, prefix) == 1) {
                rest = substr(mp, length(prefix) + 1)
                split(rest, parts, "/")
                uid = parts[1]

                # Avoid recursive copies exposed by pods that hostPath-mount kubelet internals.
                is_pod_volume = 0
                if (parts[2] == "volumes" && (parts[3] == "kubernetes.io~csi" || parts[3] == "kubernetes.io~nfs")) {
                    is_pod_volume = 1
                }
                if (parts[2] == "volume-subpaths") {
                    is_pod_volume = 1
                }

                if (uid != "" && is_pod_volume == 1) {
                    print uid "|" mp "|" fs "|" src
                }
            }
        }
    ' /proc/self/mountinfo | sort -u
}

probe_mount() {
    mount_path="$1"

    timeout "$PROBE_TIMEOUT_SECONDS" sh -c '
        mount_path="$1"
        stat "$mount_path" >/dev/null 2>&1 || exit 1
        find "$mount_path" -maxdepth 1 -mindepth 1 -print -quit >/dev/null 2>&1 || exit 1
    ' sh "$mount_path"
}

pod_for_uid() {
    uid="$1"
    pod_map="$2"

    awk -F '|' -v uid="$uid" '$1 == uid { print; found = 1; exit } END { exit found ? 0 : 1 }' "$pod_map"
}

resolve_controller() {
    namespace="$1"
    pod_name="$2"
    owner_kind="$3"
    owner_name="$4"

    case "$owner_kind" in
        Deployment)
            printf 'deployment|%s\n' "$owner_name"
            ;;
        StatefulSet)
            printf 'statefulset|%s\n' "$owner_name"
            ;;
        DaemonSet)
            printf 'daemonset|%s\n' "$owner_name"
            ;;
        ReplicaSet)
            rs_owner="$(kubectl -n "$namespace" get rs "$owner_name" -o jsonpath='{.metadata.ownerReferences[0].kind}{"|"}{.metadata.ownerReferences[0].name}' 2>/dev/null || true)"
            rs_kind="${rs_owner%%|*}"
            rs_name="${rs_owner#*|}"
            if [ "$rs_kind" = "Deployment" ] && [ -n "$rs_name" ] && [ "$rs_name" != "$rs_owner" ]; then
                printf 'deployment|%s\n' "$rs_name"
                return 0
            fi
            log "unsupported ReplicaSet owner for ${namespace}/${pod_name}: ${rs_owner:-unknown}"
            return 1
            ;;
        *)
            log "unsupported owner for ${namespace}/${pod_name}: ${owner_kind:-none}/${owner_name:-none}"
            return 1
            ;;
    esac
}

restart_target() {
    namespace="$1"
    kind="$2"
    name="$3"
    reason="$4"
    key="$(state_key "${namespace}_${kind}_${name}")"
    last_restart_file="${STATE_DIR}/${key}.last_restart"
    now="$(date +%s)"

    last_restart="$(read_number_file "$last_restart_file" 0)"
    if [ "$last_restart" -gt 0 ] && [ "$((now - last_restart))" -lt "$COOLDOWN_SECONDS" ]; then
        log "cooldown active for ${namespace}/${kind}/${name}; skipping restart after: ${reason}"
        return 0
    fi

    stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    patch="$(printf '{"spec":{"template":{"metadata":{"annotations":{"ops.vember31.xyz/nfs-watcher-restartedAt":"%s","ops.vember31.xyz/nfs-watcher-node":"%s"}}}}}' "$stamp" "$NODE_NAME")"

    log "patching ${namespace}/${kind}/${name} after stale NFS detection: ${reason}"
    if kubectl -n "$namespace" patch "$kind" "$name" --type merge -p "$patch"; then
        echo "$now" > "$last_restart_file"
        echo 0 > "${STATE_DIR}/${key}.failures"
    else
        log "failed to patch ${namespace}/${kind}/${name}"
        return 1
    fi
}

check_mounts() {
    pod_map="${STATE_DIR}/pods.map"
    seen_file="${STATE_DIR}/seen.controllers"
    bad_file="${STATE_DIR}/bad.controllers"

    : > "$seen_file"
    : > "$bad_file"

    pods="$(list_node_pods 2>&1)" || {
        log "failed to list pods on ${NODE_NAME}: ${pods}"
        return 0
    }
    printf '%s\n' "$pods" > "$pod_map"

    mounts="$(list_nfs_mounts || true)"
    if [ -z "$mounts" ]; then
        log_summary 0 0 0 0
        return 0
    fi

    mount_count="$(printf '%s\n' "$mounts" | awk 'NF { count++ } END { print count + 0 }')"

    printf '%s\n' "$mounts" | while IFS='|' read -r uid mount_path fs source; do
        [ -n "$uid" ] || continue

        pod_line="$(pod_for_uid "$uid" "$pod_map" 2>/dev/null || true)"
        if [ -z "$pod_line" ]; then
            log "NFS mount has no running pod on ${NODE_NAME}; uid=${uid} mount=${mount_path}"
            continue
        fi

        IFS='|' read -r _ namespace pod_name owner_kind owner_name <<EOF
$pod_line
EOF

        controller="$(resolve_controller "$namespace" "$pod_name" "$owner_kind" "$owner_name" || true)"
        if [ -z "$controller" ]; then
            continue
        fi

        controller_kind="${controller%%|*}"
        controller_name="${controller#*|}"
        controller_key="${namespace}|${controller_kind}|${controller_name}"
        printf '%s\n' "$controller_key" >> "$seen_file"

        if ! probe_mount "$mount_path"; then
            printf '%s|%s %s %s %s\n' "$controller_key" "$pod_name" "$fs" "$source" "$mount_path" >> "$bad_file"
        fi
    done

    if [ ! -s "$seen_file" ]; then
        log_summary "$mount_count" 0 0 0
        return 0
    fi

    controller_count="$(sort -u "$seen_file" | awk 'NF { count++ } END { print count + 0 }')"
    failed_mount_count="$(awk 'NF { count++ } END { print count + 0 }' "$bad_file")"
    failed_controller_count="$(awk -F '|' 'NF { key = $1 "|" $2 "|" $3; seen[key] = 1 } END { for (key in seen) count++; print count + 0 }' "$bad_file")"

    sort -u "$seen_file" | while IFS='|' read -r namespace kind name; do
        [ -n "$namespace" ] || continue
        key="$(state_key "${namespace}_${kind}_${name}")"
        failures_file="${STATE_DIR}/${key}.failures"

        matching_bad="$(awk -F '|' -v ns="$namespace" -v kind="$kind" -v name="$name" '$1 == ns && $2 == kind && $3 == name { print $4 }' "$bad_file" | tr '\n' ';')"
        if [ -z "$matching_bad" ]; then
            previous_failures="$(read_number_file "$failures_file" 0)"
            if [ "$previous_failures" -gt 0 ]; then
                log "NFS probe recovered for ${namespace}/${kind}/${name} after failures=${previous_failures}"
            fi
            echo 0 > "$failures_file"
            continue
        fi

        failures="$(read_number_file "$failures_file" 0)"
        failures="$((failures + 1))"
        echo "$failures" > "$failures_file"

        log "NFS probe failed for ${namespace}/${kind}/${name}; failures=${failures}; ${matching_bad}"

        if [ "$failures" -ge "$FAILURES_BEFORE_RESTART" ]; then
            restart_target "$namespace" "$kind" "$name" "$matching_bad"
        fi
    done

    log_summary "$mount_count" "$controller_count" "$failed_mount_count" "$failed_controller_count"
}

log "starting nfs-watcher on node ${NODE_NAME}; interval=${WATCH_INTERVAL_SECONDS}s probe_timeout=${PROBE_TIMEOUT_SECONDS}s failures_before_restart=${FAILURES_BEFORE_RESTART} cooldown=${COOLDOWN_SECONDS}s summary_interval=${SUMMARY_INTERVAL_SECONDS}s"

while true; do
    check_mounts
    sleep "$WATCH_INTERVAL_SECONDS"
done
