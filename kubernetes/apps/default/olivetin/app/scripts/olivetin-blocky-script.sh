#!/usr/bin/env bash

ACTION=$1
DURATION=$2
BLOCKY_GROUPS=$3 # this should be not required with v0.24, but it is now. use 'ads'
NAMESPACE=networking
PAUSE_SECONDS=1s
KUBECTL_LOCATION=/home/olivetin/kubectl
KUBECTL_DIRECTORY=/home/olivetin

# First check to see if kubectl exists
echo "Checking for existence of kubectl..."

if [ -e "$KUBECTL_LOCATION" ]; then
    echo "Kubectl already exists."
else
    echo "Kubectl does not exist - downloading."
    curl -LO --output-dir "$KUBECTL_DIRECTORY" curl -LO curl -LO https://dl.k8s.io/release/v1.29.2/bin/linux/amd64/kubectl
    chmod +x $KUBECTL_LOCATION
    echo "Kubectl downloaded & executable."
fi

echo "Beginning Blocky Script"
BLOCKY_PODS=$($KUBECTL_LOCATION get pods -n $NAMESPACE -o=jsonpath="{range .items[*]}{.metadata.name} " -l app.kubernetes.io/name=blocky)

#

for pod in $BLOCKY_PODS; do
    case "$ACTION" in
        status)
            $KUBECTL_LOCATION exec -n $NAMESPACE "$pod" -- /app/blocky blocking status;
        ;;
        enable)
            $KUBECTL_LOCATION exec -n $NAMESPACE "$pod" -- /app/blocky blocking enable;
        ;;
        disable)
            if [ -z "$DURATION" ]; then
                $KUBECTL_LOCATION exec -n $NAMESPACE "$pod" -- /app/blocky blocking disable --groups "$BLOCKY_GROUPS"
            else
                $KUBECTL_LOCATION exec -n $NAMESPACE "$pod" -- /app/blocky blocking disable --duration "$DURATION" --groups "$BLOCKY_GROUPS";
            fi
        ;;
    esac
done

echo "Script complete."
