# start.ps1 - One-command launcher for Java Cloud Compiler
# Provisions the whole stack, then opens the app in your browser.

$ErrorActionPreference = "Continue"
$APP_IMAGE = "demo:latest"
$APP_DEPLOYMENT = "java-cloud-compiler"

function Section($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Ok($msg)      { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Info($msg)    { Write-Host "  $msg" -ForegroundColor Gray }

# --- 0. Check prerequisites ---
Section "Checking prerequisites"
foreach ($tool in @("docker", "minikube", "kubectl")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "  [MISSING] '$tool' is not installed or not on PATH." -ForegroundColor Red
        Write-Host "  Please install Docker, Minikube, and kubectl, then re-run." -ForegroundColor Red
        exit 1
    }
    Ok "$tool found"
}

# Check Docker is actually running
cmd /c "docker info >nul 2>nul"
if ($LASTEXITCODE -eq 0) {
    Ok "Docker is running"
} else {
    Write-Host "  [ERROR] Docker engine is not reachable. Start Docker Desktop (whale icon steady) and re-run." -ForegroundColor Red
    exit 1
}

# --- 1. Start Minikube if needed ---
Section "Starting Kubernetes cluster (Minikube)"
$status = (minikube status --format "{{.Host}}" 2>$null)
if ($status -eq "Running") {
    Ok "Minikube already running"
} else {
    Info "Starting Minikube (this can take a minute)..."
    minikube start --driver=docker
    Ok "Minikube started"
}
minikube addons enable metrics-server *> $null
Ok "metrics-server enabled"

# --- 2. Ensure the database secret exists ---
Section "Database credentials"
$secretExists = kubectl get secret postgres-secret --ignore-not-found 2>$null
if ($secretExists) {
    Ok "postgres-secret already exists"
} else {
    Info "Creating postgres-secret with default dev credentials..."
    kubectl create secret generic postgres-secret `
        --from-literal=POSTGRES_USER=appuser `
        --from-literal=POSTGRES_PASSWORD=devpassword `
        --from-literal=POSTGRES_DB=appdb | Out-Null
    Ok "postgres-secret created"
}

# --- 3. Build and load the app image ---
Section "Building the application image"
Info "Running Maven build (skipping tests)..."
.\mvnw.cmd clean package -DskipTests -q
Ok "JAR built"
Info "Building Docker image $APP_IMAGE..."
docker build -t $APP_IMAGE . | Out-Null
Ok "Image built"
Info "Loading image into Minikube..."
minikube image load $APP_IMAGE
Ok "Image loaded"

# --- 4. Apply all manifests ---
Section "Deploying to Kubernetes"
kubectl apply -f k8s\postgres-pvc.yaml | Out-Null
kubectl apply -f k8s\postgres-deployment.yaml | Out-Null
kubectl apply -f k8s\postgres-service.yaml | Out-Null
kubectl apply -f k8s\executor-rbac.yaml | Out-Null
kubectl apply -f k8s\execution-networkpolicy.yaml | Out-Null
kubectl apply -f k8s\service.yaml | Out-Null
kubectl apply -f k8s\deployment.yaml | Out-Null
Ok "All manifests applied"

# Make sure the app rolls to the freshly built image
kubectl set image deployment/$APP_DEPLOYMENT app=$APP_IMAGE | Out-Null
kubectl rollout restart deployment/$APP_DEPLOYMENT | Out-Null

# --- 5. Wait for everything to be ready ---
Section "Waiting for pods to be ready"
Info "Waiting for PostgreSQL..."
kubectl wait --for=condition=available --timeout=120s deployment/postgres | Out-Null
Ok "PostgreSQL ready"
Info "Waiting for the application..."
kubectl wait --for=condition=available --timeout=120s deployment/$APP_DEPLOYMENT | Out-Null
Ok "Application ready"

# --- 6. Open the app in the browser (keeps the tunnel alive) ---
Section "Launching"
Write-Host "  Opening the app in your browser." -ForegroundColor Green
Write-Host "  KEEP THIS WINDOW OPEN - closing it stops the connection to the app." -ForegroundColor Yellow
Write-Host "  Press Ctrl+C here when you're done to stop the tunnel.`n" -ForegroundColor Gray
minikube service $APP_DEPLOYMENT