# Example SSL automation on Kubernetes with ingress
First you need to have an ingress definition which has at least the following configuration:

```yaml
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: my-existing-ingress
spec:
  rules:
  - host: example.com # your actual domain name is written instead
    http:
      paths:
      - path: /.well-known # this part is required for ssl certificate generation and must be a permanent part of your ingress definition
        backend:
          serviceName: ssl-management-service
          servicePort: 9980

``` 

You also may need to modify the [letsencrypt-volume.yaml](letsencrypt-volume.yaml) file to provide a better suited volume definition for your environment before proceeding further. Alternatively you could just use PersistentVolumeClaim without PersistentVolume if auto provisioning is enabled.

Note that the service account used for this pod must have edit privileges for it to be able to create secrets. To make sure apply the [service-account.yaml](service-account.yaml) file and create a role binding by running:
```bash
kubectl create rolebinding ssl-management-role \
  --clusterrole=edit \
  --serviceaccount=default:ssl-management-service-account \
  --namespace=default
```

After you modified the [job.yaml](job.yaml) file with your data, you need to apply it to have the container obtain ssl certificates and create a [Kubernetes Secret](https://kubernetes.io/docs/concepts/configuration/secret/) object to store them. To apply job.yaml with all its dependencies you can run
 
```bash
kubectl apply -f letsencrypt-volume.yaml && \
    kubectl apply -f letsencrypt-volume-claim.yaml && \
    kubectl apply -f service.yaml && \
    kubectl apply -f job.yaml
```

Alternatively [install.sh](install.sh) file has all the scripts mentioned up to this point for convenience, you can simply run that:
```bash
./install.sh
```

At this point you should be able to see the automatically generated secret by running:
```bash
kubectl get secrets
```

Now it is time to reconfigure your ingress definition with tls:
```yaml
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: my-existing-ingress
spec:
  tls:
    - hosts: ["example.com"]
      secretName: "tls-certs" # the value of the TLS_SECRET env var in job.yaml
  rules:
  - host: example.com # your actual domain name is written insted
    http:
      paths:
      - path: /.well-known # this part is required for ssl certificate generation and must be a permanent part of your ingress definition
        backend:
          serviceName: ssl-management-service
          servicePort: 9980

``` 

Finally apply the [cron-job.yaml](cron-job.yaml). This is a cron job to periodically check and renew your certificates and update your secrets after a successfull renewal. To create the job simply run
```bash
kubectl apply -f cron-job.yaml
```

If your ingress controller does not pick up the change in the updated secret, add the following environment variable to [cron-job.yaml](cron-job.yaml)
```yaml
        env:
        - name: UPDATE_INGRESS
          value: "my-existing-ingress" # your actual ingress name here

```
This will force an update on your ingress definition after a successful certificate renewal