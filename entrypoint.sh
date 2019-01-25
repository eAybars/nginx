#!/usr/bin/env bash

source /usr/bin/ssl-config-util.sh
source /usr/bin/nginx-config-util.sh

RUN=false
TLS_SECRET=${TLS_SECRET:-"tls"}
DHPARAM_SECRET=${DHPARAM_SECRET:-"dhparam"}
# wait time can be used to give k8s ingress controller a change to health check our service before
# we attempt to retrieve certificates
WAIT=0
INIT_ARGS=()
RENEW_ARGS=()

ARG_ARRAY_TO_ADD="none"

print_invalid_option_message () {
    echo "unexpected option here: $1"
    echo "First use --init-or-update-cert to pass arguments to \"certbot certonly\", or use --renew-certs to pass arguments to \"certbot renew\""
}

update_k8s_object_data () {
    if [ $K8S_ENV -eq 1 ]; then
        if [ -z $UPDATE_DEPLOYMENT ]; then
            rm /etc/letsencrypt/live/$TLS_SECRET/deployment.name 2> /dev/null
        else
            mkdir -p /etc/letsencrypt/live/$TLS_SECRET && printf $UPDATE_DEPLOYMENT > /etc/letsencrypt/live/$TLS_SECRET/deployment.name
        fi
        if [ ! -z $UPDATE_INGRESS ]; then
            rm /etc/letsencrypt/live/$TLS_SECRET/ingress.name 2> /dev/null
        else
            mkdir -p /etc/letsencrypt/live/$TLS_SECRET && printf $UPDATE_INGRESS > /etc/letsencrypt/live/$TLS_SECRET/ingress.name
        fi
    fi
}

while [[ $# -gt 0 ]]
do
case $1 in
    --wait)
        ARG_ARRAY_TO_ADD="none"
        shift # shift wait argument
        if [ -z $1 ]; then echo "--wait argument requires a numeric value indicating time to wait in seconds" && exit 1; fi
        WAIT=$1
        shift # shift wait value
        if ! [[ $WAIT =~ $re ]] ; then
          echo "error: --wait value is not a number" >&2
          exit 1
        fi
    ;;
    --run)
        ARG_ARRAY_TO_ADD="none"
        RUN=true
        shift
    ;;
    --init-dhparam)
        ARG_ARRAY_TO_ADD="none"
        shift
        if [ $K8S_ENV -eq 1 ]; then
            init_k8s_dhparam_secret $DHPARAM_SECRET || exit 1
        elif [ ! -f /etc/ssl/certs/dhparam/dhparam.pem ]; then
            create_dhparam || exit 1
        fi
    ;;
    --init-or-update-cert)
        if [ ${#INIT_ARGS[@]} -gt 1 ]; then echo "You cannot specify --init-or-update-cert more than once" && exit 1; fi
        ARG_ARRAY_TO_ADD="INIT_ARGS"
        RENEW_ARGS=("--renew-hook" "renew-hooks.sh")

        if [ ! -z $DOMAINS ]
        then
            INIT_ARGS+=("--domains" "$DOMAINS")
        fi
        shift
    ;;
    --update-deployment)
        if [ $ARG_ARRAY_TO_ADD != "INIT_ARGS" ]; then echo "--update-deployment can only be used with --init-or-update-cert" && exit 1; fi
        shift
        if [ -z $1 ]; then echo "--update-deployment requires a value indicating which k8s deployment object to annotate" && exit 1; fi
        UPDATE_DEPLOYMENT="$1"
    ;;
    --update-ingress)
        if [ $ARG_ARRAY_TO_ADD != "INIT_ARGS" ]; then echo "--update-ingress can only be used with --init-or-update-cert" && exit 1; fi
        shift
        if [ -z $1 ]; then echo "--update-ingress requires a value indicating which k8s ingress object to annotate" && exit 1; fi
        UPDATE_INGRESS="$1"
    ;;
    --cert-name)
        if [ $ARG_ARRAY_TO_ADD != "INIT_ARGS" ]; then print_invalid_option_message "$1" && exit 1; fi
        shift
        if [ -z $1 ]; then echo "--cert-name requires a value indicating name of the certificate and K8S secret name to store it" && exit 1; fi
        TLS_SECRET="$1"
        INIT_ARGS=("--cert-name" "$TLS_SECRET")
        shift
    ;;
    -d|--domains|--domain)
        if [ $ARG_ARRAY_TO_ADD != "INIT_ARGS" ]; then print_invalid_option_message "$1" && exit 1; fi
        INIT_ARGS+=("$1" "$2")
        shift
        if [ -z $DOMAINS ]
        then
            DOMAINS="$1"
        else
            DOMAINS="$DOMAINS,$1"
        fi
        shift
    ;;
    --renew-certs)
        if [ ${#RENEW_ARGS[@]} -gt 0 ]; then echo "You cannot specify --renew-certs more than once" && exit 1; fi
        ARG_ARRAY_TO_ADD="RENEW_ARGS"
        RENEW_ARGS=("--renew-hook" "renew-hooks.sh")
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
        if [ $ARG_ARRAY_TO_ADD == "INIT_ARGS" ]
        then
            INIT_ARGS+=("$1")
        elif [ $ARG_ARRAY_TO_ADD == "RENEW_ARGS" ]
        then
            RENEW_ARGS+=("$1")
        else
            print_invalid_option_message "$1"
            exit 1
        fi
        shift
    ;;
esac
done

if [ $WAIT -gt 0 ] && [ $K8S_ENV -eq 1 ] && { [ ${#INIT_ARGS[@]} -gt 0 ] || [ ${#RENEW_ARGS[@]} -gt 0 ]; }
then
    nginx || exit 1
    echo "Waiting $WAIT seconds as requested..."
    sleep $WAIT
    echo "Resuming task now"
fi

EXIT_CODE=0

if [ ${#INIT_ARGS[@]} -gt 0 ]; then
    if ! find_parameter_value "--cert-name" "${INIT_ARGS[@]}" &> /dev/null
    then
        INIT_ARGS+=("--cert-name" "$TLS_SECRET")
    fi
    if ! find_parameter_value "--email" "${INIT_ARGS[@]}" &> /dev/null && ! find_parameter_value "--register-unsafely-without-email" "${INIT_ARGS[@]}" &> /dev/null
    then
        if [ -z $EMAIL ]; then
            # create a test certificate if no EMAIL is present
            INIT_ARGS+=("--register-unsafely-without-email")
        else
            INIT_ARGS+=("--email" "$EMAIL")
        fi
    fi
    if [ -z $DOMAINS ]
    then
        echo "--init-or-update-cert specified but no domain information is available. Use DOMAINS env var or -d, --domain or --domains arguments to provide domain information"
        EXIT_CODE=1
    else
        if [ -d /etc/letsencrypt/live/$TLS_SECRET/ ]; then
            update_k8s_object_data
            existing_certificate=1
        else #certificate does not exist, we will attempt to get it
            export RENEWED_LINEAGE="/etc/letsencrypt/live/$TLS_SECRET/"
            existing_certificate=0
        fi

        create_or_update_certificate "${INIT_ARGS[@]}"
        EXIT_CODE=$?

        if [ $EXIT_CODE == 0 ] && [ $existing_certificate == 0 ] && ! find_parameter_value "--dry-run" "${INIT_ARGS[@]}" &> /dev/null; then
            # call hooks
            /usr/bin/renew-hooks.sh && update_k8s_object_data
            EXIT_CODE=$?
        fi
    fi
fi

if [ $EXIT_CODE -eq 0 ] && [ ${#RENEW_ARGS[@]} -gt 0 ]; then
    renew_certificates "${RENEW_ARGS[@]}"
    EXIT_CODE=$?
fi

if [ -f /var/run/nginx.pid ]; then
    nginx -s stop && wait_nginx_stop || exit 1
fi

if [ $EXIT_CODE -gt 0 ]; then exit $EXIT_CODE; fi

if [[ $RUN = true ]]
then
    exec nginx -g "daemon off;"
fi
