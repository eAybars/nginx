#!/usr/bin/env bash

# first we need to create a service account which can edit secrets
kubectl apply -f service-account.yaml || exit 1

# Namespace is assumed to be default, you can change it if you are operating in a different namespace, just replace all "default" occurrences below
kubectl create rolebinding ssl-management-role \
  --clusterrole=edit \
  --serviceaccount=default:ssl-management-service-account \
  --namespace=default


kubectl apply -f letsencrypt-volume.yaml && \
    kubectl apply -f letsencrypt-volume-claim.yaml && \
    kubectl apply -f service.yaml && \
    kubectl apply -f job.yaml