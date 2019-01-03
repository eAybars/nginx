FROM nginx

# install certbot to obtain ssl certificate from Lets Encrypt
RUN apt-get update -qq && \
    apt-get install -y -qq certbot && \
    apt-get install -y -qq curl && \
    apt-get clean all

# Generate Strong Diffie-Hellman Group
RUN openssl dhparam -out /etc/ssl/certs/dhparam/dhparam.pem 2048 > /dev/null 2>&1

# Define entrypoint for the image
ENTRYPOINT ["/usr/bin/entrypoint.sh"]

EXPOSE 443

# add template files
COPY well-known.conf /etc/nginx/default.d/
COPY ssl-site-template.conf /etc/nginx/archive.d/

CMD ["--run"]

# add scripts
COPY entrypoint.sh /usr/bin
COPY ssl-config-util.sh /usr/bin
COPY nginx-config-util.sh /usr/bin