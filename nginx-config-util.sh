#!/usr/bin/env bash

source /usr/bin/ssl-config-util.sh

# $1; comma separated list of domain names
# $2; certificate name, defaults to first domain name
# $3: configuration name, defaults to certification name
configure_single_site () {
    if [ -z $1 ]
    then
        echo "configure_site requires coma separated list of domain names as its first argument"
        return 1
    fi

    local cert_name=${2:-"$(echo $1 | cut -f1 -d',')"}
    local config_name=${3:-"$cert_name"}

    echo "Generating configuration for $1 using certificate $cert_name"

    # create dhparam if not exists
    if [ ! -d "/etc/ssl/certs/dhparam" ]
    then
        create_dhparam
    fi

    # create dhparam if not exists
    if [ ! -d "/etc/ssl/certs/$cert_name" ]
    then
        copy_certificates $cert_name
    fi

    cat /etc/nginx/archive.d/ssl-site-template.conf | \
        sed "s/SERVER_NAME/${1}/" | \
        sed "s/CERT_NAME/${cert_name}/" | \
        sed "s/CONFIG_NAME/${config_name}/" | \
        > /etc/nginx/conf.d/$1.conf

    mkdir -p /etc/nginx/conf.d/$config_name/http/ /etc/nginx/conf.d/$config_name/https/

    echo "Created config file: "
    cat /etc/nginx/conf.d/$1.conf
    return 0
}

# $1; comma separated list of domain names
# $2; certificate name, defaults to first domain name
configure_site_foreach () {
    if [ -z $1 ]
    then
        echo "configure_site requires comma separated list of domain names as its first argument"
        return 1
    fi
    local cert_name=${2:-"$(echo $1 | cut -f1 -d',')"}
    local domain_names=()

    IFS=',' read -ra domain_names <<< "$1"
    for domain_name in "${domain_names[@]}"; do
        configure_single_site domain_name cert_name domain_name
    done
}

# $1 config name
make_site_ssl_only () {
    if [ -z $1 ]
    then
        echo "make_site_ssl_only requires a config names as its first argument"
        return 1
    fi

    if [ $? -eq 0 ] && [ -d /etc/nginx/conf.d/$1/http ]
    then
        printf 'location / { return 301 https://$server_name$request_uri; }\n' >> /etc/nginx/conf.d/$1/http/ssl-redirect.conf
        echo "Added https redirect for $1"
    fi
}

make_sites_ssl_only () {
    if [ -z $1 ]
    then
        echo "make_sites_ssl_only requires comma separated list of config names as its first argument"
        return 1
    fi

    local config_names=()
    IFS=',' read -ra config_names <<< "$1"
    for config_name in "${config_names[@]}"; do
        make_site_ssl_only config_name
    done
}