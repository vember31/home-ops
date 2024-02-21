#!/usr/bin/env bash

ACTION=$1
DURATION=$2
BLOCKY_GROUPS=default #could turn this to variable later, but i only have 'default' group present. comma-delimited
NAMESPACE=networking
PAUSE_SECONDS=1s
KUBECTL_LOCATION=/home/olivetin/kubectl
KUBECTL_DIRECTORY=/home/olivetin

# First check to see if kubectl exists
echo "Checking for existence of kubectl..."

if [ -e "$KUBECTL_LOCATION" ]; then
    echo "Kubectl exists. Proceeding to Blocky script."
else
    echo "Kubectl does not exist - downloading."
    curl -LO --output-dir "$KUBECTL_DIRECTORY" https://dl.k8s.io/release/v1.29.2/bin/linux/amd64/kubectl
    chmod +x $KUBECTL_LOCATION
    echo "Kubectl downloaded & executable."
fi

echo "Starting Blocky Script in $PAUSE_SECONDS ..."
BLOCKY_PODS=$($KUBECTL_LOCATION get pods -n $NAMESPACE -o=jsonpath="{range .items[*]}{.metadata.name} " -l app.kubernetes.io/name=blocky)

sleep "$PAUSE_SECONDS"

for pod in $BLOCKY_PODS; do
    case "${ACTION}" in
        status)
            ${KUBECTL_LOCATION} exec -n $NAMESPACE "${pod}" -- /app/blocky blocking status;
        ;;
        enable)
            ${KUBECTL_LOCATION} exec -n $NAMESPACE "${pod}" -- /app/blocky blocking enable;
        ;;
        disable)
            if [ -z "${DURATION}" ]; then
                ${KUBECTL_LOCATION} exec -n $NAMESPACE "${pod}" -- /app/blocky blocking disable --groups "${BLOCKY_GROUPS}"
            else
                ${KUBECTL_LOCATION} exec -n $NAMESPACE "${pod}" -- /app/blocky blocking disable --duration "${DURATION}" --groups "${BLOCKY_GROUPS}";
            fi
        ;;
    esac
done

echo "Script complete."
sleep "1s"
