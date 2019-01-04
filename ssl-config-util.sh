#!/usr/bin/env bash

NAMESPACE="default"
if [ -f  /var/run/secrets/kubernetes.io/serviceaccount/namespace ]
then
    NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
fi

K8S_ENV=0
if [ -f /var/run/secrets/kubernetes.io/serviceaccount/ca.crt ]; then K8S_ENV=1; fi

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

find_parameter_value () {
    local parameter=$1
    shift
    while [[ $# -gt 0 ]]
    do
        case $1 in
            "$parameter")
                printf $2
                return 0
                ;;
            *)
                shift
                ;;
        esac
    done
}

create_or_renew_certificate () {
    local certbot_args=("certonly" "--agree-tos" "--non-interactive" "--webroot" "--webroot-path" "/usr/share/nginx/html" "$@")

    echo "Invoking: certbot ${certbot_args[@]}"

    if [ ! -f /var/run/nginx.pid ]
    then
        # start nginx and invoke certbot to retrieve new SSL certificates for new domains
        nginx && certbot "${certbot_args[@]}"

        exit_code=$?
        nginx -s stop && wait_nginx_stop
        if [ $exit_code -ne 0 ] ; then exit $exit_code; fi
    else
        certbot "${certbot_args[@]}" && nginx -s reload
    fi
}


renew_certificates () {
    local renew_args=("renew" "--quiet" "$@")

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

create_dhparam () {
    echo "Creating dhparam, this will take a while. Consider mounting /etc/ssl/certs/dhparam for future use"
    mkdir -p /etc/ssl/certs/dhparam && \
        openssl dhparam -out /etc/ssl/certs/dhparam/dhparam.pem 2048 > /dev/null 2>&1
    echo "dhparam is generated here: /etc/ssl/certs/dhparam/dhparam.pem"
}

copy_certificates () {
    cert_name=$1
    if [ -z $cert_name ]
    then
        echo "No certificate name specified for copy_certificates"
        return 1;
    fi

    mkdir -p /etc/ssl/certs/$cert_name && \
            cp -L /etc/letsencrypt/live/$cert_name/privkey.pem /etc/ssl/certs/$cert_name/tls.key && \
            cp -L /etc/letsencrypt/live/$cert_name/fullchain.pem /etc/ssl/certs/$cert_name/tls.crt
}

docker_tls_renew_hook () {
    copy_certificates "${RENEWED_LINEAGE##*/}"
    if [ -f /var/run/nginx.pid ]; then nginx -s reload; fi
}

# -------- KUBERNETES RELATED UTILITIES -----------------

# $1 is the target object i.e. secret, pod etc
k8s_call () {
    if [ $K8S_ENV -eq 0 ]; then return 1; fi

    local curl_args=("-k" "--cacert" "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" "-H" "\"Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\"" "-H" "\"Accept: application/json, */*\"")

    # add target url from first parameter
    curl_args+=("https://kubernetes/api/v1/namespaces/${NAMESPACE}/$1")
    shift

    # add remaining parameters of the function to curl arguments
    curl_args+=("$@")

    curl "${curl_args[@]}"
}

is_k8s_object_exists () {
    if [ $(k8s_call $1 -s -o /dev/null -I -w "%{http_code}") -eq 200 ]
    then
        return 0;
    else
        return 1;
    fi
}

# $1 a path to generate secret data from contents
# $2 name of the secret, defaults to directory name of the first argument
print_k8s_secret () {
    if [ -z $1 ]
    then
        echo "print_k8s_secret requires a path as first argument, no path argument found to generate secret!"
        return 1;
    fi


    local secret_name=${2:-"${1##*/}"}
    local secret_json="\
{\n\
  \"kind\": \"Secret\",\n\
  \"apiVersion\": \"v1\",\n\
  \"metadata\": {\n\
    \"name\": \"$secret_name\",\n\
    \"namespace\": \"$NAMESPACE\"\n\
  },\n\
  \"type\": \"Opaque\",\n\
  \"data\": {\n"

    local prefix=""

    for f in $(ls $1); do
      secret_json="$secret_json$prefix   \"$f\": \"$(cat ${1}/$f | base64 | tr -d '\n')\""
      prefix=",\n"
    done

    secret_json="$secret_json \n  }\n}\n"

    printf "$secret_json"
}

create_k8s_secret () {
    local secret_json=$(print_k8s_secret $1 $2)
    if [ $? -nq 0 ]; then return 0; fi

    local secret_name=${2:-"${1##*/}"}

    printf "$secret_json" > /tmp/$secret_name.json
    k8s_call secrets -X POST -d "@/tmp/$secret_name.json"
    exit_code=$?
    rm /tmp/$secret_name.json
    return exit_code
}

update_k8s_secret () {
    local secret_json=$(print_k8s_secret $1 $2)
    if [ $? -nq 0 ]; then return 0; fi

    local secret_name=${2:-"${1##*/}"}

    printf "$secret_json" > /tmp/$secret_name.json

    # update secret
    k8s_call "secrets/${secret_name}" -H "Content-Type: application/strategic-merge-patch+json" "-XPATCH" -d "@/tmp/secret-patch.json"
    exit_code=$?
    rm /tmp/$secret_name.json
    return exit_code
}

update_k8s_tls_secret () {
    local cert_name=$1

    copy_certificates $cert_name

    is_k8s_object_exists secrets/$cert_name
    if [ $? -nq 0 ]
    then
        echo "Creating kubernetes object secrets/$cert_name"
        create_k8s_secret /etc/ssl/certs/$cert_name || exit 1
    else
        echo "Updating kubernetes object secrets/$cert_name"
        update_k8s_secret /etc/ssl/certs/$cert_name || exit 1
    fi
}

k8s_tls_renew_hook () {
    update_k8s_tls_secret "${RENEWED_LINEAGE##*/}"
}

init_k8s_tls_secrets () {
    local cert_name=$(find_parameter_value "--cert-name" "$@")

    if [ -z $cert_name ]
    then
        cert_name=$(find_parameter_value "--domains" "$@")
        if [ -z $cert_name ]; then cert_name=$(find_parameter_value "-d" "$@"); fi
        if [ -z $cert_name ]
        then
            echo "Cannot determine certificate name"
            exit 1
        else
            cert_name="$(echo $cert_name | cut -f1 -d',')"
        fi
    fi

    create_or_renew_certificate "$@" && update_k8s_tls_secret $cert_name
}

# $1 dhparam secret name
init_k8s_dhparam_secret () {
    if [ -z $1 ]
    then
        echo "init_k8s_dhparam_secrets requires a secret name as first argument, no secret name argument found to generate secret!"
        return 1;
    fi

    is_k8s_object_exists secrets/$1
    if [ $? -nq 0 ]
    then
        if [ ! -f /etc/ssl/certs/dhparam/dhparam.pem ]
        then
            create_dhparam && create_k8s_secret /etc/ssl/certs/dhparam $1
        else
            create_k8s_secret /etc/ssl/certs/dhparam $1
        fi
    fi
}



print_test () {
    echo "test string from ssl-config-util.sh"
}