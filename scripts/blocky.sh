#!/usr/bin/env bash

# home-ops discord throwback
# run such as:
#  - ./blocky.sh status
#  - ./blocky.sh disable 5m

ACTION=$1
DURATION=$2
BLOCKY_GROUPS=ads #could turn this to variable later, but i only have 'default' group present. comma-delimited. won't be required with v0.24
NAMESPACE=networking
PAUSE_SECONDS=3s

BLOCKY_PODS=$(kubectl get pods -n $NAMESPACE -o=jsonpath="{range .items[*]}{.metadata.name} " -l app.kubernetes.io/name=blocky)

echo "Starting Blocky Script in ${PAUSE_SECONDS}..."

sleep ${PAUSE_SECONDS}

for pod in $BLOCKY_PODS; do
    case "${ACTION}" in
        status)
            kubectl exec -n $NAMESPACE "${pod}" -- /app/blocky blocking status;
        ;;
        enable)
            kubectl exec -n $NAMESPACE "${pod}" -- /app/blocky blocking enable;
        ;;
        disable)
            if [ -z "${DURATION}" ]; then
                kubectl exec -n $NAMESPACE "${pod}" -- /app/blocky blocking disable --groups "${BLOCKY_GROUPS}"
            else
                kubectl exec -n $NAMESPACE "${pod}" -- /app/blocky blocking disable --duration "${DURATION}" --groups "${BLOCKY_GROUPS}";
            fi
        ;;
    esac
done

echo "Script complete."
sleep 1s
