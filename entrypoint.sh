#!/usr/bin/env bash

source /usr/bin/ssl-config-util.sh
source /usr/bin/nginx-config-util.sh

TLS_SECRET=${TLS_SECRET:-"tls"}
DHPARAM_SECRET=${DHPARAM_SECRET:-"dhparam"}

init () {
    local certbot_args=("$DOMAINS" "--cert-name" "$TLS_SECRET")

    if [ -z $EMAIL ]; then
        # create a test certificate if no EMAIL is present
        certbot_args+=("--register-unsafely-without-email" "--test-cert")
    else
        certbot_args+=("--email" "$EMAIL")
    fi

    if [ $K8S_ENV -eq 1 ]
    then
        init_k8s_tls_secrets "${certbot_args[@]}"
        init_k8s_dhparam_secrets $DHPARAM_SECRET
    else
        create_or_renew_certificate "${certbot_args[@]}"
        create_dhparam
    fi
}

# Gather parameters
while [[ $# -gt 0 ]]
do
case $1 in
    --run)
        RUN=true
        shift
    ;;
    --init)
        if [ -z $DOMAINS ]
        then
            echo "No DOMAINS env variable is present. It is required with --init option"
            exit 1;
        fi
        init
        shift
    ;;
    --tls-update)
        if [ $K8S_ENV -eq 1 ]
        then
            renew_certificates --renew-hook "sh -c \"source /usr/bin/ssl-config-util.sh; k8s_tls_renew_hook\""
        else
            renew_certificates --renew-hook "sh -c \"source /usr/bin/ssl-config-util.sh; docker_tls_renew_hook\""
        fi

        shift
    ;;
    --configure-nginx)
        if [ -z $DOMAINS ]
        then
            echo "No DOMAINS env variable is present. It is required with --configure-nginx option"
            exit 1;
        fi
        shift
        case $1 in
            single)
                configure_single_site $DOMAINS $TLS_SECRET
                shift
            ;;
            for-each)
                configure_site_foreach $DOMAINS $TLS_SECRET
                shift
            ;;
            ssl-only-single)
                configure_single_site $DOMAINS $TLS_SECRET
                make_site_ssl_only $TLS_SECRET
                shift
            ;;
            ssl-only-for-each)
                configure_site_foreach $DOMAINS $TLS_SECRET
                make_sites_ssl_only $DOMAINS
                shift
            ;;
            *)
                echo "Unrecognized nginx configuration option $1. available options are: single, for-each, ssl-only-single and ssl-only-for-each"
                exit 1
            ;;
        esac
        ;;
    *)
        echo "Unrecognized option $1. Available options are: --run, --init, --tls-update and --configure-nginx"
        exit 1
    ;;
esac
done

if [ $RUN = true ] ; then
    exec nginx -g "daemon off;"
fi