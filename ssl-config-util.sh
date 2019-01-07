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

    return 1
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
        if [ $exit_code -ne 0 ] ; then return $exit_code; fi
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
        if [ $exit_code -ne 0 ] ; then return $exit_code; fi
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

# -------- KUBERNETES RELATED UTILITIES -----------------

# $1 is the target object i.e. secret, pod etc
k8s_call () {
    if [ $K8S_ENV -eq 0 ]; then return 1; fi

    local curl_args=("--http1.1" "-k" "--cacert" "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" "-H" "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" "-H" "Accept: application/json, */*")

    # add target url from first parameter
    curl_args+=("https://kubernetes.default.svc/$1")
    shift

    # add remaining parameters of the function to curl arguments
    curl_args+=("$@")

    curl "${curl_args[@]}"
}

is_k8s_object_exists () {
    if [ $(k8s_call $1 -s -o /dev/null -w "%{http_code}") -eq 200 ]
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
    local secret_name=${2:-"${1##*/}"}

    print_k8s_secret $1 $2 > /tmp/$secret_name.json && \
        k8s_call "api/v1/namespaces/${NAMESPACE}/secrets" -X POST -H "Content-Type: application/json" -d "@/tmp/$secret_name.json"
    exit_code=$?
    rm /tmp/$secret_name.json
    return $exit_code
}

update_k8s_secret () {
    local secret_name=${2:-"${1##*/}"}

    print_k8s_secret $1 $2 > /tmp/$secret_name.json && \
        k8s_call "api/v1/namespaces/${NAMESPACE}/secrets/${secret_name}" -H "Content-Type: application/strategic-merge-patch+json" "-XPATCH" -d "@/tmp/$secret_name.json"
    exit_code=$?
    rm /tmp/$secret_name.json
    return $exit_code
}

update_k8s_tls_secret () {
    local cert_name=$1

    copy_certificates $cert_name || exit 1

    if is_k8s_object_exists "api/v1/namespaces/${NAMESPACE}/secrets/$cert_name"
    then
        echo "Updating kubernetes object secrets/$cert_name"
        update_k8s_secret /etc/ssl/certs/$cert_name || return 1
    else
        echo "Creating kubernetes object secrets/$cert_name"
        create_k8s_secret /etc/ssl/certs/$cert_name || return 1
    fi
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
            return 1
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

    if is_k8s_object_exists "api/v1/namespaces/${NAMESPACE}/secrets/$1"
    then
        if [ ! -f /etc/ssl/certs/dhparam/dhparam.pem ]
        then
            create_dhparam && create_k8s_secret /etc/ssl/certs/dhparam $1
        else
            create_k8s_secret /etc/ssl/certs/dhparam $1
        fi
    fi
}

print_deployment_json () {
    printf "\
{\n\
  \"apiVersion\": \"$1\",\n\
  \"kind\": \"$2\",\n\
  \"metadata\": {\n\
    \"name\": \"$3\",\n\
    \"namespace\": \"$NAMESPACE\"\n\
  },\n\
  \"spec\": {\n\
    \"template\": {\n\
      \"metadata\": {
        \"annotations\": {
          \"ssl.reload.time\": \"$(date)\"\n\
         }\n\
       }\n\
     }\n\
   }\n\
}\n"
}

update_deployment () {
    print_deployment_json "apps/v1beta1" "Deployment" $1 > /tmp/$1-Deployment.json

    # update secret
    k8s_call "apis/extensions/v1beta1/namespaces/${NAMESPACE}/deployments/$1" -H "Content-Type: application/strategic-merge-patch+json" "-XPATCH" -d "@/tmp/$1-Deployment.json"
    exit_code=$?
    rm /tmp/$1-Deployment.json
    return $exit_code
}

update_ingress () {
    printf "\
{\n\
  \"apiVersion\": \"extensions/v1beta1\",\n\
  \"kind\": \"Ingress\",\n\
  \"metadata\": {\n\
    \"name\": \"$1\",\n\
    \"namespace\": \"$NAMESPACE\",\n\
    \"annotations\": {
      \"ssl.reload.time\": \"$(date)\"\n\
     }\n\
  }\n\
}\n\
" >> /tmp/$1-Ingress.json
    k8s_call "apis/extensions/v1beta1/namespaces/${NAMESPACE}/ingresses/$1" -H "Content-Type: application/strategic-merge-patch+json" "-XPATCH" -d "@/tmp/$1-Ingress.json"
    exit_code=$?
    rm /tmp/$1-Ingress.json
    return $exit_code
}


print_test () {
    echo "test string from ssl-config-util.sh"
}