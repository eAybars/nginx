#!/usr/bin/env bash

RUN=false
DOMAINS=()
CERTBOT_ARGS=("-n" "--agree-tos")
WEBROOT_SET=false

update_certname_if_needed () {
    if [ -z "$CERTNAME" ]
    then
        for current in /etc/letsencrypt/live/*; do
            CERTNAME=${current:22}
            break
         done

         if [ -z "$CERTNAME" ] && [ ${#DOMAINS[@]} -gt 0 ]
         then
            CERTNAME=${DOMAINS[0]}
         fi
    fi
}

add_to_domains () {
    IFS=',' read -ra DOMAIN_NAMES <<< "$1"
    for DOMAIN_NAME in "${DOMAIN_NAMES[@]}"; do
        DOMAIN_EXISTS=false
        for domain in "${DOMAINS[@]}"; do
            if [ "$DOMAIN_NAME" == "$domain" ]
            then
                DOMAIN_EXISTS=true
                break
            fi
        done
        if [ $DOMAIN_EXISTS = false ]
        then
            if [ $WEBROOT_SET = false ] ; then
                CERTBOT_ARGS+=("-w")
                CERTBOT_ARGS+=("/usr/share/nginx/html/")
                WEBROOT_SET=true
            fi
            DOMAINS+=($DOMAIN_NAME)
            CERTBOT_ARGS+=("-d")
            CERTBOT_ARGS+=($DOMAIN_NAME)
        fi
    done
}

configure_site () {
    DOMAIN_NAME=$1
    SERVER_NAME="$@"
    DEFAULT_SERVER=""

    if [ $DOMAIN_NAME == "${DOMAINS[0]}" ] ; then
        DEFAULT_SERVER="default_server"
    fi

    printf "server {\n\
                listen 80 ;\n\
                listen [::]:80 ;\n\
                server_name $SERVER_NAME;\n\
                include /etc/nginx/conf.d/$DOMAIN_NAME/http/*.conf;\n\
                add_header X-Frame-Options \"SAMEORIGIN\";\n\
                add_header X-Content-Type-Options nosniff;\n\
                add_header X-XSS-Protection \"1; mode=block\";\n\
            }\n\
            server { \n\
                listen 443 ssl $DEFAULT_SERVER;\n\
                listen [::]:443 ssl $DEFAULT_SERVER;\n\
                server_name $SERVER_NAME;\n\
                include /etc/nginx/conf.d/$DOMAIN_NAME/https/*.conf;\n\
                resolver 8.8.8.8 8.8.4.4 valid=300s;\n\
                resolver_timeout 5s;\n\
                add_header X-Frame-Options \"SAMEORIGIN\";\n\
                add_header X-Content-Type-Options nosniff;\n\
                add_header Strict-Transport-Security \"max-age=63072000; includeSubdomains\";\n\
                add_header X-XSS-Protection \"1; mode=block\";\n\
                ssl_protocols TLSv1 TLSv1.1 TLSv1.2;\n\
                ssl_prefer_server_ciphers on;\n\
                ssl_ciphers \"EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH\";\n\
                ssl_ecdh_curve secp384r1;\n\
                ssl_session_cache shared:SSL:10m;\n\
                ssl_session_tickets off;\n\
                ssl_stapling on;\n\
                ssl_stapling_verify on;\n\
                ssl_dhparam /etc/ssl/certs/dhparam.pem;\n\
                ssl_certificate /etc/letsencrypt/live/$CERTNAME/fullchain.pem;\n\
                ssl_certificate_key /etc/letsencrypt/live/$CERTNAME/privkey.pem;\n\
            }\n" \
        > /etc/nginx/conf.d/$DOMAIN_NAME.conf && \
        printf "Successfully created configuration file for $SERVER_NAME\n"

    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "Failed to create configuration file for: $DOMAIN_NAME \n"
        return $exit_code
    fi

    return 0
}

wait_nginx_stop () {
    for i in {1..150}; do # timeout for 5 minutes
       if [ ! -f /var/run/nginx.pid ]; then
          # process does not exist eny more
          return 0
       fi
       sleep 1
    done
    echo ""
    echo "Timeout while waiting nginx to stop"

    exit 1
}

# Gather parameters
while [[ $# -gt 0 ]]
do
case $1 in
    --run)
    RUN=true
    shift # past argument
    ;;
    --create-nginx-conf)
    if [ -z "$2" ]
    then
        echo "Create option value is missing for --create-nginx-conf"
        exit 1
    fi
    case $2 in
        foreach|missing|single|none)
        NGINX_CONF="$2"
        ;;
        *)
        echo "Argument $2 is not recognised for --create-nginx-cnf option"
        exit 1
        ;;
    esac
    CREATE_CONFIG=true
    shift # past argument
    shift # past value
    ;;
    -r|--renew-all)
    nginx && certbot renew --quiet
    exit_code=$?

    nginx -s stop

    wait_nginx_stop

    if [ $exit_code -ne 0 ]; then
        echo "Certificate renewing failed"
        exit $exit_code
    fi
    shift # past argument
    ;;
    certonly)
    CERTBOT_COMMAND="$1"
    CERTBOT_ARGS=("--webroot" "${CERTBOT_ARGS[@]}")
    shift # past argument
    ;;
    renew|certificates|revoke|delete|register)
    CERTBOT_COMMAND="$1"
    shift # past argument
    ;;
    # ignore default arguments and those conflicting with the default arguments
    -n|--non-interactive|--noninteractive|--force-interactive|--webroot|--agree-tos|--apache|--standalone|--nginx|--manual|--dns-*|-h|--help)
    echo "Ignoring argument $1"
    shift # past argument
    ;;
    --configure-from-env)
    if [ ! -z "$CONTACT_EMAIL" ]
    then
        EMAIL="$CONTACT_EMAIL"
    fi

    for domain in $DOMAIN_NAMES
    do
        add_to_domains "$domain"
    done
    shift # past argument
    ;;
    -m|--email)
    if [ -z "$2" ] || [[ $2 == -* ]]
    then
        echo "Email value not set for $1 parameter"
        exit 1
    fi
    EMAIL="$2"
    shift # past argument
    shift # past value
    ;;
    -w|--webroot-path)
    if [ -z "$2" ] || [[ $2 == -* ]]
    then
        echo "Web root value not set for $1 parameter"
        exit 1
    fi

    WEBROOT_SET=true
    CERTBOT_ARGS+=("$1")
    CERTBOT_ARGS+=("$2")
    shift # past argument
    shift # past value
    ;;
    -d|--domains|--domain)
    if [ -z "$2" ] || [[ $2 == -* ]]
    then
        echo "domain name value not set for $1 parameter"
        exit 1
    fi

    add_to_domains $2
    shift # past argument
    shift # past value
    ;;
    --cert-name)
    if [ -z "$2" ] || [[ $2 == -* ]]
    then
        echo "Certificate name value not set for $1 parameter"
        exit 1
    fi
    CERTNAME="$2"
    CERTBOT_ARGS+=("$1")
    CERTBOT_ARGS+=("$2")
    shift # past argument
    shift # past value
    ;;
    *)    # other options to pass to certbot
    CERTBOT_ARGS+=("$1")
    shift # past argument
    ;;
esac
done


# Prepare certbot invocation to retrieve / update certificates
NUM_DOMAINS=${#DOMAINS[@]}

if [ ! -z "$CERTBOT_COMMAND" ] || [ $NUM_DOMAINS -gt 0 ] || [ ! -z "$CERTNAME" ]
then
    if [ -z "$CERTBOT_COMMAND" ] || [ $CERTBOT_COMMAND = "certonly" ] || [ $CERTBOT_COMMAND = "register" ]
    then
        if [ -z "$EMAIL" ]
        then
            CERTBOT_ARGS=("--register-unsafely-without-email" "${CERTBOT_ARGS[@]}")
        else
            CERTBOT_ARGS=("--email" "$EMAIL" "${CERTBOT_ARGS[@]}")
        fi
    fi

    if [ -z "$CERTBOT_COMMAND" ]
    then
        CERTBOT_ARGS=("certonly" "--webroot" "${CERTBOT_ARGS[@]}")
    else
        CERTBOT_ARGS=("$CERTBOT_COMMAND" "${CERTBOT_ARGS[@]}")
    fi

    echo "Invoking certbot with the following arguments: ${CERTBOT_ARGS[@]}"

    # start nginx and invoke certbot to retrieve new SSL certificates for new domains
    nginx && certbot "${CERTBOT_ARGS[@]}"

    exit_code=$?

    nginx -s stop

    wait_nginx_stop

    if [ $exit_code -ne 0 ] ; then
           exit $exit_code
    fi

    if [ ! -z "$NGINX_CONF" ]
    then
        update_certname_if_needed

        case $NGINX_CONF in
            foreach|missing)
            for domain in "${DOMAINS[@]}"; do
                if [ $NGINX_CONF == "foreach" ] || [ ! -f /etc/nginx/conf.d/$domain.conf ]
                then
                    mkdir -p /etc/nginx/conf.d/$domain/http/ && \
                        configure_site "$domain" && \
                        cp /etc/nginx/archive.d/http-root.conf /etc/nginx/conf.d/$domain/http/
                fi
            done
            ;;
            single)
                domain="${DOMAINS[0]}"
                mkdir -p /etc/nginx/conf.d/$domain/http/ && \
                    configure_site "${DOMAINS[@]}" && \
                    cp /etc/nginx/archive.d/http-root.conf /etc/nginx/conf.d/$domain/http/
            ;;
            none)
            ;;
        esac

    fi

fi


if [ $RUN = true ] ; then
    touch /etc/nginx/lastUpdateTime
    exec nginx -g "daemon off;"
fi