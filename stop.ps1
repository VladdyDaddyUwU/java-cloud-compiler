# stop.ps1 - Tear down the Java Cloud Compiler stack

function Section($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

Section "Removing application resources"
kubectl delete -f k8s\deployment.yaml --ignore-not-found
kubectl delete -f k8s\service.yaml --ignore-not-found
kubectl delete -f k8s\execution-networkpolicy.yaml --ignore-not-found
kubectl delete -f k8s\executor-rbac.yaml --ignore-not-found
kubectl delete -f k8s\postgres-deployment.yaml --ignore-not-found
kubectl delete -f k8s\postgres-service.yaml --ignore-not-found

Write-Host "`nNote: the database volume (PVC) and secret are left intact so your data persists." -ForegroundColor Yellow
Write-Host "To remove them too, run:" -ForegroundColor Gray
Write-Host "  kubectl delete -f k8s\postgres-pvc.yaml" -ForegroundColor Gray
Write-Host "  kubectl delete secret postgres-secret" -ForegroundColor Gray
Write-Host "To stop the cluster entirely: minikube stop" -ForegroundColor Gray