#!/usr/bin/env bash
# start.sh - One-command launcher for Java Cloud Compiler (macOS / Linux)
# Provisions the whole stack, then opens the app in your browser.

set -u  # treat unset variables as errors (but not -e; we handle failures ourselves)

APP_IMAGE="demo:latest"
APP_DEPLOYMENT="java-cloud-compiler"

section() { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
ok()      { printf "  \033[32m[OK]\033[0m %s\n" "$1"; }
info()    { printf "  %s\n" "$1"; }
fail()    { printf "  \033[31m[ERROR]\033[0m %s\n" "$1"; exit 1; }

# --- 0. Check prerequisites ---
section "Checking prerequisites"
for tool in docker minikube kubectl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        fail "'$tool' is not installed or not on PATH. Install Docker, Minikube, and kubectl, then re-run."
    fi
    ok "$tool found"
done

# Check the Docker engine is actually reachable
if docker info >/dev/null 2>&1; then
    ok "Docker is running"
else
    fail "Docker engine is not reachable. Start Docker (or Docker Desktop) and re-run."
fi

# --- 1. Start Minikube if needed ---
section "Starting Kubernetes cluster (Minikube)"
if [ "$(minikube status --format '{{.Host}}' 2>/dev/null)" = "Running" ]; then
    ok "Minikube already running"
else
    info "Starting Minikube (this can take a minute)..."
    minikube start --driver=docker || fail "Minikube failed to start."
    ok "Minikube started"
fi
minikube addons enable metrics-server >/dev/null 2>&1
ok "metrics-server enabled"

# --- 2. Ensure the database secret exists ---
section "Database credentials"
if kubectl get secret postgres-secret >/dev/null 2>&1; then
    ok "postgres-secret already exists"
else
    info "Creating postgres-secret with default dev credentials..."
    kubectl create secret generic postgres-secret \
        --from-literal=POSTGRES_USER=appuser \
        --from-literal=POSTGRES_PASSWORD=devpassword \
        --from-literal=POSTGRES_DB=appdb >/dev/null || fail "Failed to create secret."
    ok "postgres-secret created"
fi

# --- 3. Build and load the app image ---
section "Building the application image"
info "Running Maven build (skipping tests)..."
./mvnw clean package -DskipTests -q || fail "Maven build failed."
ok "JAR built"
info "Building Docker image $APP_IMAGE..."
docker build -t "$APP_IMAGE" . >/dev/null || fail "Docker build failed."
ok "Image built"
info "Loading image into Minikube..."
minikube image load "$APP_IMAGE" || fail "Failed to load image into Minikube."
ok "Image loaded"

# --- 4. Apply all manifests ---
section "Deploying to Kubernetes"
kubectl apply -f k8s/postgres-pvc.yaml >/dev/null
kubectl apply -f k8s/postgres-deployment.yaml >/dev/null
kubectl apply -f k8s/postgres-service.yaml >/dev/null
kubectl apply -f k8s/executor-rbac.yaml >/dev/null
kubectl apply -f k8s/execution-networkpolicy.yaml >/dev/null
kubectl apply -f k8s/service.yaml >/dev/null
kubectl apply -f k8s/deployment.yaml >/dev/null
ok "All manifests applied"

# Make sure the app rolls to the freshly built image
kubectl set image deployment/"$APP_DEPLOYMENT" app="$APP_IMAGE" >/dev/null 2>&1
kubectl rollout restart deployment/"$APP_DEPLOYMENT" >/dev/null 2>&1

# --- 5. Wait for everything to be ready ---
section "Waiting for pods to be ready"
info "Waiting for PostgreSQL..."
kubectl wait --for=condition=available --timeout=120s deployment/postgres >/dev/null || fail "PostgreSQL did not become ready in time."
ok "PostgreSQL ready"
info "Waiting for the application..."
kubectl wait --for=condition=available --timeout=120s deployment/"$APP_DEPLOYMENT" >/dev/null || fail "Application did not become ready in time."
ok "Application ready"

# --- 6. Open the app in the browser (keeps the tunnel alive) ---
section "Launching"
printf "  \033[32mOpening the app in your browser.\033[0m\n"
printf "  \033[33mKEEP THIS TERMINAL OPEN - closing it stops the connection to the app.\033[0m\n"
printf "  Press Ctrl+C here when you're done to stop the tunnel.\n\n"
minikube service "$APP_DEPLOYMENT"