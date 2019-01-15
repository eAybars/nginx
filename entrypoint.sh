#!/usr/bin/env bash

source /usr/bin/ssl-config-util.sh
source /usr/bin/nginx-config-util.sh

RUN=false
TLS_SECRET=${TLS_SECRET:-"tls"}
DHPARAM_SECRET=${DHPARAM_SECRET:-"dhparam"}
# wait time can be used to give k8s ingress controller a change to health check our service before
# we attempt to retrieve certificates
WAIT=0

find_wait_time () {
    local argc=$#
    local argv=($@)

    for (( j=0; j<argc; j++ )); do
        if [ ${argv[j]} == "--wait" ]; then WAIT=${argv[j+1]}; fi
    done

    local re='^[0-9]+$'

    if ! [[ $WAIT =~ $re ]] ; then
        echo "error: --wait value is not a number" >&2; return 1
    fi
}

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
        if [ $WAIT -gt 0 ]
        then
            nginx && sleep $WAIT || return 1
            init_k8s_tls_secrets "${certbot_args[@]}"
            local exit_code=$?
            nginx -s stop && wait_nginx_stop || return 1
            return $exit_code
        else
            init_k8s_tls_secrets "${certbot_args[@]}"
        fi
    else
        create_or_renew_certificate "${certbot_args[@]}" && \
            copy_certificates $TLS_SECRET
    fi


}

update_tls_certs () {
    if [ $K8S_ENV -eq 1 ]
    then
        if [ $WAIT -gt 0 ]
        then
            nginx && sleep $WAIT || return 1
            renew_certificates --renew-hook "renew-hooks.sh --k8s"
            local exit_code=$?
            nginx -s stop && wait_nginx_stop || return 1
            return $exit_code
        else
            renew_certificates --renew-hook "renew-hooks.sh --k8s"
        fi
    else
        renew_certificates --renew-hook "renew-hooks.sh --docker"
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

# first initialize wait time
find_wait_time || exit 1

# Gather parameters
while [[ $# -gt 0 ]]
do
case $1 in
    --wait)
        shift # shift wait argument
        shift # shift wait value
    ;;
    --run)
        RUN=true
        shift
    ;;
    --init-dhparam)
        shift
        init_dhparam || exit 1
    ;;
    --init-tls)
        if [ -z $DOMAINS ]
        then
            echo "No DOMAINS env variable is present. It is required with --tls-update option"
            exit 1;
        fi
        init_tls_certs || exit 1
        shift
    ;;
    --update-tls)
        update_tls_certs || exit 1
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
        echo "Unrecognized option $1. Available options are: --run, --init-dhparam, --init-tls, --update-tls, --wait and --configure-nginx"
        exit 1
    ;;
esac
done

if [[ $RUN = true ]]
then
    exec nginx -g "daemon off;"
fi
