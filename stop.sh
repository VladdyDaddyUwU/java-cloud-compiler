#!/usr/bin/env bash
section() { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

section "Removing application resources"
kubectl delete -f k8s/deployment.yaml --ignore-not-found
kubectl delete -f k8s/service.yaml --ignore-not-found
kubectl delete -f k8s/execution-networkpolicy.yaml --ignore-not-found
kubectl delete -f k8s/executor-rbac.yaml --ignore-not-found
kubectl delete -f k8s/postgres-deployment.yaml --ignore-not-found
kubectl delete -f k8s/postgres-service.yaml --ignore-not-found

printf "\n\033[33mNote: the database volume (PVC) and secret are left intact so your data persists.\033[0m\n"
printf "To remove them too:\n"
printf "  kubectl delete -f k8s/postgres-pvc.yaml\n"
printf "  kubectl delete secret postgres-secret\n"
printf "To stop the cluster entirely: minikube stop\n"