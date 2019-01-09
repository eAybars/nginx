# Nginx with SSL for Kubernetes
This is an extension of the official nginx image to provide automation of SSL encryption on kubernetes environment as well as on plain docker containers.

## How does it work
### With Kubernetes Ingress
If you are using [Kubernetes Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/) object to manage http(s) traffic, you can use this image as a job and a cron job to automate generation and renewal of SSL certificates respectively. 
#### Initial configuration
To do initial configuration, just create a [Kubernetes Jon](https://kubernetes.io/docs/concepts/workloads/controllers/jobs-run-to-completion/) using this image with `--init-tls` argument with the following environment variables:
- **DOMAINS**: A comma separated list of domain names which should be included in the generated SSL certificate
- **EMAIL** A valid email address which will be used for registration to Lets Encrypt when the certificate is generated for the first time. See [here](https://letsencrypt.org/docs/expiration-emails/) for the use of email information. ***Note that if this environment variable is omitted, a test certificate is generated insted of a valid production grade certificate***. So omit this variable if you are testing your setup.
- **TLS_SECRET**: A name for the automatically generated and maintained [Kubernetes Secret](https://kubernetes.io/docs/concepts/configuration/secret/) object. You need to reference this same value in `secretName` under the [ingress object's tls spec](https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.12/#ingresstls-v1beta1-extensions) If this variable is omitted its value will default to ***"tls"***
- **UPDATE_INGRESS**: If you are specifying `--install-tls-to-ingress` argument, you need to provide ingress name through this variable. This will take care of installation of the generated SSL certificate to your ingress definition automatically. **Note that this assumes a single tls entry in your ingress definition. If this is not the case DO NOT USE THIS OPTION.** Additionally, if you want your ingress definition to be updated whenever a ssl certificate is renewed to force the reloading of the secrets you also need to provide this variable to have this effect. 

#### Certificate Renewal
Create a [Kubernetes Cron Job](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/) using this image with `--update-tls` argument to renew previously retrieved ssl certificates and update their corresponding secrets. No need to specify any particular environment variables. However if your Kubernetes ingress does not pick up the change in the updated tls secret, you can specify your ingress name via `UPDATE_INGRESS` environment variable to enforce an update on your ingress object whenever a certificate is renewed.
 
See the [ingress example](examples/k8s/ingress/README.md) for details.

### Without Kubernetes Ingress
Since this is a nginx image, it can also be used as a Kubernetes Deployment for reverse proxy and load balancing as a substitution for Kubernetes Ingress object. This setup consists of 3 parts:
- A [Kubernetes Jon](https://kubernetes.io/docs/concepts/workloads/controllers/jobs-run-to-completion/) for initial setup. This job does 2 things. First, by specifying`--init-tls`argument we have it retrieve an SSL certificate and store it on a Kuberntes secret which then will be used in the Kubernetes Deployment (see next part). Second, specifying `--init-dhparam` argument instructs it to create and store a [Diffie Hellman Ephemeral Parameters](https://en.wikipedia.org/wiki/Diffie%E2%80%93Hellman_key_exchange) key for stronger SSL security and stores it on a Kubernetes secret which then will be used in the deployment.  
- A [Kubernetes Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) running plain nginx with mounted configuration and secrets. To run as plain nginx, do not specify arguments or just use `--run` argument. 
- A [Kubernetes Cron Job](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/) which runs with `--update-tls` argument and renews ssl certificates and updates deployments to enforce refreshment of the mounted secrets in deployment. You need to provide the name of the Kubernetes Deployment to refresh through `UPDATE_DEPLOYMENT` environment variable. If you skip this variable, your deployment will not be updated and therefore updated secrets will not take effect on the deployment.

See [deployment example](examples/k8s/deployment/README.md) for more details

#### Configuration
You need to configure nginx to serve meaningful content or act as reverse proxy and/or load balancer, To make things easier, you can optionally use the `--configure-nginx` argument with one of the following options to generate basic configurations from [this template configuration file](ssl-site-template.conf) which has ssl configuration and references the generated ssl certificates. 
- **single**: Generate a single configuration file replacing `SERVER_NAME` with the value of DOMAINS env var, `DEFAULT_SERVER` with string "default_server" and finally replacing both `CONFIG_NAME` and `CERT_NAME` with the value of TLS_SECRET env var.
- **for-each**: Generates a separate configuration file for each domain by replacing both `CONFIG_NAME` and`SERVER_NAME` with the corresponding domain name, `DEFAULT_SERVER` with empty string and finally `CERT_NAME` with the value of TLS_SECRET env var. 
- **ssl-only-single**: Basicly the same configuration with `single` option but additionaly makes nginx redirect all http requests to https
- **ssl-only-for-each**: Basicly the same configuration with `for-each` option but additionaly makes nginx redirect all http requests to https
 
### Plain Docker
To run as plain nginx container:
```
docker run -p 80:80 -p 443:443 -d --name nginx-ssl eaybars/nginx
```

To run as automatically configured for ssl: 
```
docker run -p 80:80 -p 443:443 -d --name nginx-ssl -e DOMAINS=eample.com EMAIL=myemail@example.com -v /data/ssl/letsencrypt:/etc/letsencrypt -v /data/ssl/certs:/etc/ssl/certs eaybars/nginx --run --init-tls --init-dhparam --configure-nginx
```
Note the following volume mounts:
- **/etc/letsencrypt** to persist the obtained certificates and management data
- **/etc/ssl/certs** to persist the dhparam key and active certificates which are used in the auto generated nginx config. If you are providing your own configuration (in that case omitting `--configure-nginx` argument) instead of the auto generated ones, you may not need to mount this directory.

Also note that `--init-tls` will also causes a renewal of a certificate if it already exists with the same configuration 