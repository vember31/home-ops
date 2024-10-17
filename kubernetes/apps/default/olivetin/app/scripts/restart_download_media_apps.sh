#!/usr/bin/env bash

KUBECTL_LOCATION=/home/olivetin/kubectl
KUBECTL_DIRECTORY=/home/olivetin

# First check to see if kubectl exists
echo "Checking for existence of kubectl..."

if [ -e "$KUBECTL_LOCATION" ]; then
    echo "Kubectl already exists."
else
    echo "Kubectl does not exist - downloading."
    curl -LO --output-dir "$KUBECTL_DIRECTORY" "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x $KUBECTL_LOCATION
    echo "Kubectl downloaded & executable."
fi

echo "Rebooting apps in the downloads & media namespaces..."

$KUBECTL_LOCATION rollout restart deployment --namespace=media && $KUBECTL_LOCATION rollout restart deployment --namespace=downloads