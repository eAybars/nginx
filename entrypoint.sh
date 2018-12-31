#!/usr/bin/env bash

source /usr/bin/ssl-config-util.sh

# Gather parameters
while [[ $# -gt 0 ]]
do
case $1 in
    --run)
        RUN=true
        shift
    ;;
    --configure-nginx)
        shift
        if [ -z $DOMAINS ]
        then
            echo "DOMAINS env variable is required to configure nginx"
            exit 1
        fi
        case $1 in
            ssl-only)
                configure_ssl_only_site
                shift
            ;;
            *)
                configure_site
                # parameter does not concern --configure-nginx directive, so do not shift here
            ;;
        esac
    ;;
    --create-or-renew-cert)
        if [ -z $DOMAINS ]
        then
            echo "DOMAINS env variable is required to create certificates"
            exit 1
        fi

        create_or_renew_certificate && update_secret
        shift
    ;;
    --renew-certs)
        if [ -z $DOMAINS ]
        then
            echo "DOMAINS env variable is required to renew certificates"
            exit 1
        fi

        renew_certificates --deploy-hook update_secret
        shift
    ;;
    *)
    echo "unrecognised option $1 is ignored"
    # do something
    shift # past argument
    ;;
esac
done

if [ $RUN = true ] ; then
    exec nginx -g "daemon off;"
fi