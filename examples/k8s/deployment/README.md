# Example Kubernetes deployment without using ingress
First, you may need to modify the [letsencrypt-volume.yaml](letsencrypt-volume.yaml) file to provide a better suited volume definition for your environment before proceeding further. Alternatively you could just use PersistentVolumeClaim without PersistentVolume if auto provisioning is enabled.

Note that the service account used for this pod must have edit privileges for it to be able to create secrets. To make sure apply the [service-account.yaml](service-account.yaml) file and create a role binding by running:
```bash
kubectl create rolebinding ssl-management-role \
  --clusterrole=edit \
  --serviceaccount=default:ssl-management-service-account \
  --namespace=default
```


Next, Modify the [job.yaml](job.yaml) file with your data. You need to apply it to have the container obtain ssl certificates and create a [Kubernetes Secret](https://kubernetes.io/docs/concepts/configuration/secret/) object to store them. It also creates a [Diffie Hellman Ephemeral Parameters](https://en.wikipedia.org/wiki/Diffie%E2%80%93Hellman_key_exchange) key for stronger SSL security and stores it on a Kubernetes secret which then will be used in the deployment. To apply job.yaml with all its dependencies you can run
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

At this point you should be able to see the automatically generated secrets by running:
```bash
kubectl get secrets
```
Now that we have the secret objects created, we can use them in our [deployment.yaml](deployment.yaml) as volume definitions like:
```yaml
      volumes:
      - name: ssl-certs
        secret:
          secretName: "tls-certs" # value of the TLS_SECRET in job.yaml
      - name: dhparam
        secret:
          secretName: "dhparam" # value of the TLS_SECRET in job.yaml
``` 
Also note that we need to mount some container directories to these volumes:
```yaml
        volumeMounts:
          - name: ssl-certs
            mountPath: "/etc/ssl/certs/tls-certs" # replace tls-certs with the value of the TLS_SECRET in job.yaml if different
            readOnly: true
          - name: dhparam
            mountPath: "/etc/ssl/certs/dhparam"
            readOnly: true

```

You can (and probably should) define additional nginx configurations as Kubernetes ConfigMap objects as you need and mount them to proper locations to fully configure your setup. After you are done with all of that, you can now create the deployment by
```bash
kubectl apply -f deployment.yaml
```

Finally update the value of `UPDATE_DEPLOYMENT` env var in [cron-job.yaml](cron-job.yaml) to point to your deployment. This is a cron job to periodically check and renew your certificates and update your secrets and deployments after a successful renewal. To create the job simply run
```bash
kubectl apply -f cron-job.yaml
```
Note the following environment variable in [cron-job.yaml](cron-job.yaml)
```yaml
        env:
        - name: UPDATE_DEPLOYMENT # will force an update on the specified deployment, which should point to your nginx
          value: "nginx-ssl" # deployment name in deployment.yaml

```
This will force an update on your deployment after a successful certificate renewal