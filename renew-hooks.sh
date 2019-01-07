#!/usr/bin/env bash

source /usr/bin/ssl-config-util.sh

k8s_tls_renew_hook () {
    update_k8s_tls_secret "${RENEWED_LINEAGE##*/}"
    if [ ! -z $UPDATE_DEPLOYMENT ]; then update_deployment $UPDATE_DEPLOYMENT; fi
    if [ ! -z $UPDATE_INGRESS ]; then update_deployment $UPDATE_INGRESS; fi
}

docker_tls_renew_hook () {
    copy_certificates "${RENEWED_LINEAGE##*/}"
    if [ -f /var/run/nginx.pid ]; then nginx -s reload; fi
}

while [[ $# -gt 0 ]]
do
case $1 in
    --k8s)
        k8s_tls_renew_hook
        shift
    ;;
    --docker)
        docker_tls_renew_hook
        shift
    ;;
    *)
        echo "Unrecognized option $1. Available options are: --k8s and --docker"
        exit 1
    ;;
esac
done