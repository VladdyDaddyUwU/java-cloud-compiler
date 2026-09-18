# Java Cloud Compiler

A containerized Java REST service deployed on Kubernetes, built to demonstrate
Site Reliability Engineering (SRE) fundamentals: containerization, health
probing, resource management, and zero-downtime deployments.

> **Status:** The reliability platform documented here is complete. An online
> code-execution feature (user sign-up + sandboxed Java execution) is on the
> roadmap — see [Roadmap](#roadmap).

---

## Tech Stack

| Layer            | Technology                          |
|------------------|-------------------------------------|
| Language         | Java 21                             |
| Framework        | Spring Boot 3.x (Web, Actuator)     |
| Build            | Maven (multi-stage Docker build)    |
| Containerization | Docker                              |
| Orchestration    | Kubernetes (local via Minikube)     |

---

## Architecture

```
   Client
     │
     ▼
  Service  (stable address, load-balances across pods)
     │
     ├──────────────┬
     ▼              ▼
   Pod            Pod          ← managed by a Deployment (desired replicas: 2)
 (Spring app)   (Spring app)
```

- A **Deployment** declares the desired state (2 replicas) and continuously
  reconciles actual state to match it — this is what makes the app self-healing.
- A **Service** provides a stable network address in front of the pods, since
  pods are disposable and their IP addresses change when they are replaced.

---

## Reliability Features

### Health Probes
The application exposes health endpoints via Spring Boot Actuator, and
Kubernetes is configured to probe them:

- **Liveness probe** (`/actuator/health/liveness`) — answers "is this process
  healthy, or should it be restarted?" On repeated failure, Kubernetes restarts
  the container. It checks only the process itself, never external
  dependencies — an over-eager liveness check can restart a healthy app in a
  loop.
- **Readiness probe** (`/actuator/health/readiness`) — answers "is this pod
  ready to receive traffic?" On failure, Kubernetes removes the pod from the
  Service's load-balancer **without** restarting it. This is where external
  dependency checks belong: if a dependency is down, you want to stop sending
  traffic, not kill the app.
- **Startup probe** — holds off the liveness and readiness probes until the app
  has finished booting, preventing a slow-starting JVM from being killed
  mid-startup.

**Key distinction:** liveness failure means *restart me*; readiness failure
means *stop sending me traffic but leave me running*.

### Graceful Shutdown
Configured in `application.yml` (`server.shutdown: graceful`). When Kubernetes
sends SIGTERM during a rolling update, the app stops accepting new requests but
finishes in-flight ones before terminating — preventing dropped connections
during deployments.

### Resource Requests & Limits
Each container declares:
- **Requests** (guaranteed reservation, used for scheduling): 250m CPU, 256Mi memory
- **Limits** (hard ceiling): 500m CPU, 512Mi memory

Exceeding the CPU limit throttles the container; exceeding the memory limit
results in an `OOMKilled` termination. Limits protect the node from a single
runaway container starving its neighbors (the "noisy neighbor" problem).

### Zero-Downtime Rolling Updates
On a new image version, Kubernetes performs a rolling update: it starts a new
pod, waits for its readiness probe to pass before routing traffic to it, then
retires an old pod — repeating until all are replaced. Capacity never drops and
no request reaches an unready pod. Two mechanisms together make this truly
zero-downtime: the **readiness probe** keeps traffic off unready new pods, and
**graceful shutdown** keeps terminating old pods from dropping in-flight
requests. Because deployments use versioned image tags, `kubectl rollout undo`
provides instant rollback.

---

## Multi-Stage Docker Build
The `Dockerfile` uses two stages:
1. **Build stage** — a Maven + JDK image compiles the application into a JAR.
2. **Runtime stage** — a slim JRE image receives only the finished JAR.

The build toolchain never ships in the final image, keeping it small and
reducing the attack surface. Anyone with only Docker installed can build from
source — no local Maven or JDK setup required. Dependencies are downloaded in a
separate layer before the source is copied, so code changes don't trigger a full
re-download on rebuild.

---

## Running Locally

### Prerequisites
- Docker
- Minikube
- kubectl

### Steps

```PowerShell
# 1. Start the cluster
minikube start --driver=docker

# 2. Build the image
docker build -t demo:1.0 .

# 3. Load the image into Minikube's internal registry
#    (the cluster cannot see host-built images otherwise)
minikube image load demo:1.0

# 4. Deploy
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

# 5. Confirm pods are running
kubectl get pods

# 6. Get the service URL (keep this terminal open)
minikube service java-cloud-compiler --url
```

### Endpoints
| Endpoint                          | Description                    |
|-----------------------------------|--------------------------------|
| `GET /`                           | Returns a status message       |
| `GET /actuator/health`            | Overall health                 |
| `GET /actuator/health/liveness`   | Liveness state                 |
| `GET /actuator/health/readiness`  | Readiness state                |

---

## Demonstrating Self-Healing
```PowerShell
# Delete a pod and watch Kubernetes recreate it to maintain desired replicas
kubectl delete pod <pod-name>
kubectl get pods   # a replacement appears automatically
```

## Demonstrating a Rolling Update
```PowerShell
# Deploy a new version and watch it roll out with zero downtime
kubectl set image deployment/java-cloud-compiler app=demo:2.0
kubectl rollout status deployment/java-cloud-compiler

# Roll back instantly if needed
kubectl rollout undo deployment/java-cloud-compiler
```

---

## Project Structure
```
.
├── Dockerfile              # Multi-stage build
├── pom.xml                 # Maven build configuration
├── src/
│   └── main/
│       ├── java/com/example/demo/
│       │   ├── DemoApplication.java
│       │   └── HelloController.java
│       └── resources/
│           └── application.yml   # Graceful shutdown + Actuator probe config
└── k8s/
    ├── deployment.yaml     # Deployment with probes and resource limits
    └── service.yaml        # NodePort service
```

---

## Roadmap
- [ ] User sign-up and authentication
- [ ] PostgreSQL database (deployed as a separate pod), with the readiness probe
      tied to database connectivity
- [ ] Sandboxed Java code execution in ephemeral, resource-limited containers
- [ ] Horizontal Pod Autoscaler driven by CPU metrics
