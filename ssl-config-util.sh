#!/usr/bin/env bash

# environment variables:
# -----------------------
# DOMAINS domain names which will be included in the retrieved certificate
# EMAIL registration email address, required by Let's Encrypt
# CERT_NAME certificate name
# KUBE_SECRET if operating within kubernetes, this secret file will be updated with contents of the certificate

# generated variables after execution
# -----------------------
# CERTBOT_ARGS arguments to invoke certbot
# CERT_NAME assigne to first domain name if not exists earlier

NAMESPACE="default"
if [ -f  /var/run/secrets/kubernetes.io/serviceaccount/namespace ]
then
    NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
fi
CERTBOT_ARGS=("certonly" "--agree-tos" "--non-interactive" "--webroot" "--webroot-path" "/usr/share/nginx/html")

# prepare certbot arguments
if [ -z $EMAIL ]; then
    CERTBOT_ARGS+=("--register-unsafely-without-email")
else
    CERTBOT_ARGS=("${CERTBOT_ARGS[@]}" "--email" "$EMAIL")
fi
if [ $DOMAINS ]
then
    CERT_NAME=${CERT_NAME:-"$(echo $DOMAINS | cut -f1 -d',')"}
    CERTBOT_ARGS=("${CERTBOT_ARGS[@]}" "--cert-name" "$CERT_NAME" "--domains" "$DOMAINS")
fi

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

create_or_renew_certificate () {
    if [ -z $DOMAINS ]; then return 1; fi

    echo "preparing to create certificates for $DOMAINS"

    certbot_args=("${CERTBOT_ARGS[@]}" "$@")

    echo "Invoking certbot with the following arguments:"
    echo ${certbot_args[@]}

    if [ ! -f /var/run/nginx.pid ]
    then
        # start nginx and invoke certbot to retrieve new SSL certificates for new domains
        nginx && certbot "${certbot_args[@]}"
        exit_code=$?
        nginx -s stop && wait_nginx_stop
        if [ $exit_code -ne 0 ] ; then exit $exit_code; fi
    else
        certbot "${certbot_args[@]}"
    fi
}

renew_certificates () {
    renew_args=("renew" "--quiet" "$@")

    if [ ! -f /var/run/nginx.pid ]
    then
        nginx && certbot "${renew_args[@]}"
        exit_code=$?

        nginx -s stop && wait_nginx_stop
        if [ $exit_code -ne 0 ] ; then exit $exit_code; fi
    else
        certbot "${renew_args[@]}"
    fi
}

patch_call_to_k8s () {
    curl_args=("-k" "--cacert" "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" "-H" "\"Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\"" "-H" "\"Accept: application/json, */*\"" "-H" "\"Content-Type: application/strategic-merge-patch+json\"" "-XPATCH")
    # add target url from first parameter
    curl_args+=("https://kubernetes/api/v1/namespaces/${NAMESPACE}/$1")
    shift

    # add remaining parameters of the function to curl arguments
    curl_args+=("$@")
    curl "${curl_args[@]}"
}

update_secret () {
    if [ -z $KUBE_SECRET ]; then return 1; fi
    # update kubernetes secret object if KUBE_SECRET variable is present
    CERTPATH=/etc/letsencrypt/live/$CERT_NAME

    cat /etc/nginx/secret-patch-template.json | \
        sed "s/NAMESPACE/${NAMESPACE}/" | \
        sed "s/NAME/${KUBE_SECRET}/" | \
        sed "s/TLSCERT/$(cat ${CERTPATH}/fullchain.pem | base64 | tr -d '\n')/" | \
        sed "s/TLSKEY/$(cat ${CERTPATH}/privkey.pem |  base64 | tr -d '\n')/" \
        > /tmp/secret-patch.json

    # update secret
    patch_call_to_k8s "secrets/${KUBE_SECRET}" -d @/tmp/secret-patch.json
    exit_code=$?
    rm /tmp/secret-patch.json
    if [ $exit_code -ne 0 ] ; then exit $exit_code; fi
}

configure_site () {
    if [ -z $DOMAINS ]; then return 1; fi

    cat /etc/nginx/archive.d/ssl-site-template.conf | \
        sed "s/CERT_NAME/${CERT_NAME}/" | \
        sed "s/SERVER_NAME/${DOMAINS}/" | \
        > /etc/nginx/conf.d/$CERT_NAME.conf

    mkdir -p /etc/nginx/conf.d/$CERT_NAME/http/ /etc/nginx/conf.d/$CERT_NAME/https/
    return 0
}

configure_ssl_only_site () {
    configure_site
    if [ -d /etc/nginx/conf.d/$CERT_NAME/http ]
    then
        cp /etc/nginx/archive.d/ssl-redirect.conf /etc/nginx/conf.d/$CERT_NAME/http/
    fi
}