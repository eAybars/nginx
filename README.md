# Nginx with SSL for Kubernetes
This is an extension of the official nginx image to provide automation of SSL encryption on kubernetes environment as well as on plain docker containers.

## How does it work
### With Kubernetes Ingress
If you are using [Kubernetes Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/) object to manage http(s) traffic, you can use this image as a job and a cron job to automate generation and renewal of SSL certificates respectively. 
#### Initial configuration
To do initial configuration, just create a [Kubernetes Jon](https://kubernetes.io/docs/concepts/workloads/controllers/jobs-run-to-completion/) using this image with `--init-or-update-cert` argument with the following environment variables:
- **DOMAINS**: A comma separated list of domain names which should be included in the generated SSL certificate
- **EMAIL** A valid email address which will be used for registration to Lets Encrypt when the certificate is generated for the first time. See [here](https://letsencrypt.org/docs/expiration-emails/) for the use of email information. ***Note that if this environment variable is omitted, an unsafe registration to Let's Encrypt will be used, which is highly discouraged*** 
- **TLS_SECRET**: A name for the automatically generated and maintained [Kubernetes Secret](https://kubernetes.io/docs/concepts/configuration/secret/) object. You need to reference this same value in `secretName` under the [ingress object's tls spec](https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.12/#ingresstls-v1beta1-extensions) If this variable is omitted its value will default to ***"tls"***
- **UPDATE_INGRESS**: if you want your ingress definition to be updated whenever a ssl certificate is renewed to force the reloading of the secrets you can provide this variable to have this effect.

If the ingress controller needs some time to be able to health check and mark this service alive, (i.e google cloud default ingress controller) you can specify a time to wait before attempting to retrieve the certificate by including `--wait` argument and corresponding wait time. For example specifying `--wait 300` will cause the job to start nginx and wait 5 minutes before attempting to retrieve the certificate 

#### Certificate Renewal
Create a [Kubernetes Cron Job](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/) using this image with `--renew-certs` argument to renew previously retrieved ssl certificates and update their corresponding secrets. No need to specify any particular environment variables. However if your Kubernetes ingress does not pick up the change in the updated tls secret, you can specify your ingress name via `UPDATE_INGRESS` environment variable to enforce an update on your ingress object whenever a certificate is renewed.
 
See the [ingress example](examples/k8s/ingress/README.md) for details.

### Without Kubernetes Ingress
Since this is a nginx image, it can also be used as a Kubernetes Deployment for reverse proxy and load balancing as a substitution for Kubernetes Ingress object. This setup consists of 3 parts:
- A [Kubernetes Jon](https://kubernetes.io/docs/concepts/workloads/controllers/jobs-run-to-completion/) for initial setup. This job does 2 things. First, by specifying`--init-or-update-cert`argument we have it retrieve an SSL certificate and store it on a Kuberntes secret which then will be used in the Kubernetes Deployment (see next part). Second, specifying `--init-dhparam` argument instructs it to create and store a [Diffie Hellman Ephemeral Parameters](https://en.wikipedia.org/wiki/Diffie%E2%80%93Hellman_key_exchange) key for stronger SSL security and stores it on a Kubernetes secret which then will be used in the deployment.  
- A [Kubernetes Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) running plain nginx with mounted configuration and secrets. To run as plain nginx, do not specify arguments or just use `--run` argument. 
- A [Kubernetes Cron Job](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/) which runs with `--renew-certs` argument and renews ssl certificates and updates deployments to enforce refreshment of the mounted secrets in deployment. You need to provide the name of the Kubernetes Deployment to refresh through `UPDATE_DEPLOYMENT` environment variable. If you skip this variable, your deployment will not be updated and therefore updated secrets will not take effect on the deployment.

See [deployment example](examples/k8s/deployment/README.md) for more details

#### Nginx Configuration
You need to configure nginx to serve meaningful content or act as reverse proxy and/or load balancer, To make things easier, you can optionally use the `--configure-nginx` argument with one of the following options to generate basic configurations from [this template configuration file](ssl-site-template.conf) which has ssl configuration and references the generated ssl certificates. 
- **single**: Generate a single configuration file replacing `SERVER_NAME` with the value of DOMAINS env var, `DEFAULT_SERVER` with string "default_server" and finally replacing both `CONFIG_NAME` and `CERT_NAME` with the value of TLS_SECRET env var.
- **for-each**: Generates a separate configuration file for each domain by replacing both `CONFIG_NAME` and`SERVER_NAME` with the corresponding domain name, `DEFAULT_SERVER` with empty string and finally `CERT_NAME` with the value of TLS_SECRET env var. 
- **ssl-only-single**: Basicly the same configuration with `single` option but additionaly makes nginx redirect all http requests to https
- **ssl-only-for-each**: Basicly the same configuration with `for-each` option but additionaly makes nginx redirect all http requests to https
 
### Plain Docker
To run as plain nginx container:
```bash
docker run -p 80:80 -p 443:443 -d --name nginx-ssl eaybars/nginx
```

To run as automatically configured for ssl: 
```bash
docker run -p 80:80 -p 443:443 -d --name nginx-ssl -e DOMAINS=eample.com EMAIL=myemail@example.com -v /data/ssl/letsencrypt:/etc/letsencrypt -v /data/ssl/certs:/etc/ssl/certs eaybars/nginx --run --init-or-update-cert --init-dhparam --configure-nginx
```
Note the following volume mounts:
- **/etc/letsencrypt** to persist the obtained certificates and management data
- **/etc/ssl/certs** to persist the dhparam key and active certificates which are used in the auto generated nginx config. If you are providing your own configuration (in that case omitting `--configure-nginx` argument) instead of the auto generated ones, you may not need to mount this directory.

Also note that `--init-or-update-cert` can also trigger a renewal of a certificate if it already exists with the same configuration

## Advanced Configuration
### Certificate retrieval and/or update
When `--init-or-update-cert` is specified, `certbot certonly` command will be used to retrieve and/or update certificates. You can pass any additional arguments to the `certbot certonly` following `--init-or-update-cert`. For example:
```bash
docker run -p 80:80 -p 443:443 -d --name nginx-ssl eaybars/nginx --init-or-update-cert --dry-run
``` 
will trigger a test run. When passing arguments to `certbot certonly` the following conditions apply:
- If DOMAINS env var exists, it's value will be passed to the `certbot certonly` first via `--domains` certbot argument. Any additional `-d`, `--domain` and `--domains` arguments will be passed separately after that. It is perfectly valid to omit DOMAINS env var and provide domain information via any of the `-d`, `--domain` and `--domains` arguments.
- If either `--email` or `--register-unsafely-without-email` is specified, the value of the EMAIL env var will be ignored. If none is specified and EMAIL exists, than the value of the EMAIL will be passed to `certbot certonly` with `--email` argument. If neither `--email` nor `--register-unsafely-without-email` is specified and there is no EMAIL env var value, than `--register-unsafely-without-email` will be passed to `certbot certonly`
- If `--cert-name` is specified, its value will override TLS_SECRET and therefore will be used as the name of the [Kubernetes Secret](https://kubernetes.io/docs/concepts/configuration/secret/) object which will hold the certificate content.

### Certificate renewal
When `--renew-certs` is specified, `certbot renew` command will be used to renew the certificates which are about to expire. You can pass any additional arguments to the `certbot renew` following `--renew-certs`. For example:
```bash
docker run -p 80:80 -p 443:443 -d --name nginx-ssl -v /data/ssl/letsencrypt:/etc/letsencrypt -v /data/ssl/certs:/etc/ssl/certs eaybars/nginx --renew-certs -q
```
will quietly renew the certificates, or
```bash
docker run -p 80:80 -p 443:443 -d --name nginx-ssl -v /data/ssl/letsencrypt:/etc/letsencrypt -v /data/ssl/certs:/etc/ssl/certs eaybars/nginx --renew-certs --force-renewal
```
will forcibly renew the certificates