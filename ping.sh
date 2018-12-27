#!/usr/bin/env bash

# ---- Liveness and Readiness Checks --------

# check process file
if [ ! -f /var/run/nginx.pid ]; then exit 1; fi

# check if the process is alive
kill -0 $(cat /var/run/nginx.pid)

exit_code=$?

if [ $exit_code -ne 0 ] ; then
       exit $exit_code
fi

# check that we have /etc/nginx/lastUpdateTime file, so that we know entry point script is completed
if [ ! -f /etc/nginx/lastUpdateTime ]; then exit 1; fi

# nginx is running


# ----- Renew the certificates if timeout is expired which defaults to 2 days --------

SSL_UPDATE_INTERVAL=${1:-172800}

lastModified=$(date +%s -r /etc/nginx/lastUpdateTime)
now=$(date +%s)

if [ $((now-lastModified)) -gt SSL_UPDATE_INTERVAL ]
then
    touch /etc/nginx/lastUpdateTime
    certbot renew --quiet && nginx -s reload
fi


exit 0