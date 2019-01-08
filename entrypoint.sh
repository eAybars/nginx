#!/usr/bin/env bash

source /usr/bin/ssl-config-util.sh
source /usr/bin/nginx-config-util.sh

RUN=false
TLS_SECRET=${TLS_SECRET:-"tls"}
DHPARAM_SECRET=${DHPARAM_SECRET:-"dhparam"}

init_tls_certs () {
    echo "Initializing certificate..."
    local certbot_args=("--domains" "$DOMAINS" "--cert-name" "$TLS_SECRET")

    if [ -z $EMAIL ]; then
        # create a test certificate if no EMAIL is present
        certbot_args+=("--register-unsafely-without-email" "--test-cert")
    else
        certbot_args+=("--email" "$EMAIL")
    fi

    if [ $K8S_ENV -eq 1 ]
    then
        init_k8s_tls_secrets "${certbot_args[@]}"
    else
        create_or_renew_certificate "${certbot_args[@]}"
    fi
}

init_or_update_tls () {
    if [ ! -d /etc/letsencrypt/live/$TLS_SECRET ]
    then # No certificate, so we need to init
        init_tls_certs || exit 1
    else # Certificate exists, renew if required
        if [ $K8S_ENV -eq 1 ]
        then
            # first create secret if not already exists
            is_k8s_secret_exists $TLS_SECRET || create_or_update_k8s_tls_secret $TLS_SECRET
            renew_certificates --renew-hook "renew-hooks.sh --k8s"
        else
            renew_certificates --renew-hook "renew-hooks.sh --docker"
        fi
    fi
}

init_dhparam () {
    if [ $K8S_ENV -eq 1 ]
    then
        init_k8s_dhparam_secret $DHPARAM_SECRET
    elif [ ! -f /etc/ssl/certs/dhparam/dhparam.pem ]
    then
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
    --init-dhparam)
        shift
        init_dhparam || exit 1
    ;;
    --init-or-update-tls)
        if [ -z $DOMAINS ]
        then
            echo "No DOMAINS env variable is present. It is required with --tls-update option"
            exit 1;
        fi
        init_or_update_tls || exit 1
        shift
    ;;
    --configure-nginx)
        if [ -z $DOMAINS ]
        then
            echo "No DOMAINS env variable is present. It is required with --configure-nginx option"
            exit 1;
        fi
        shift
        if [ -z $1 ]
        then
            echo "You need to specify an option for --configure-nginx. Available options are: single, for-each, ssl-only-single and ssl-only-for-each"
            exit 1
        fi
        shift
        case $1 in
            single)
                configure_single_site $DOMAINS $TLS_SECRET || exit 1
                shift
            ;;
            for-each)
                configure_site_foreach $DOMAINS $TLS_SECRET || exit 1
                shift
            ;;
            ssl-only-single)
                configure_single_site $DOMAINS $TLS_SECRET && make_site_ssl_only $TLS_SECRET || exit 1
                shift
            ;;
            ssl-only-for-each)
                configure_site_foreach $DOMAINS $TLS_SECRET && make_sites_ssl_only $DOMAINS || exit 1
                shift
            ;;
            *)
                echo "Unrecognized nginx configuration option $1. Available options are: single, for-each, ssl-only-single and ssl-only-for-each"
                exit 1
            ;;
        esac
        ;;
    *)
        echo "Unrecognized option $1. Available options are: --run, --tls-update and --configure-nginx"
        exit 1
    ;;
esac
done

if [[ $RUN = true ]]
then
    exec nginx -g "daemon off;"
fi
