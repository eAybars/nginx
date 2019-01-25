#!/usr/bin/env bash

source /usr/bin/ssl-config-util.sh

EXIT_CODE=0
cert_name="${RENEWED_LINEAGE##*/}"

if [ -z $cert_name ]; then
    echo "Cannot determine certificate name"
    exit 1
fi

if [ $K8S_ENV -eq 1 ]; then
    create_or_update_k8s_tls_secret $cert_name
    EXIT_CODE=$?
    if [ $EXIT_CODE == 0 ]; then
        if [ -f /etc/letsencrypt/live/$cert_name/deployment.name ]; then
            update_deployment $(cat /etc/letsencrypt/live/$cert_name/deployment.name)
            EXIT_CODE=$?
        fi
        if [ $EXIT_CODE == 0 ] && [ -f /etc/letsencrypt/live/$cert_name/ingress.name ]; then
            update_ingress $(cat /etc/letsencrypt/live/$cert_name/ingress.name)
            EXIT_CODE=$?
        fi
    fi
else
    copy_certificates $cert_name
    EXIT_CODE=$?
    if [ $EXIT_CODE == 0 ] && [ -f /var/run/nginx.pid ]; then nginx -s reload; fi
fi
exit $EXIT_CODE