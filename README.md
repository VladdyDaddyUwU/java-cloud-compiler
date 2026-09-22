# Java Cloud Compiler

A containerized Java REST service with user authentication and a PostgreSQL
database, deployed on Kubernetes. Built to demonstrate both **backend
engineering** (REST APIs, data persistence, authentication, password security)
and **Site Reliability Engineering** (containerization, health probing, resource
management, self-healing, zero-downtime deployments).

> **Status:** The reliability platform, PostgreSQL integration, and
> authentication system are complete and running. An online code-execution
> feature (sandboxed Java execution) is on the roadmap — see [Roadmap](#roadmap).

---

## Table of Contents
- [Tech Stack](#tech-stack)
- [Architecture](#architecture)
- [Backend Features](#backend-features)
- [Reliability (SRE) Features](#reliability-sre-features)
- [Security](#security)
- [Multi-Stage Docker Build](#multi-stage-docker-build)
- [Project Structure](#project-structure)
- [Running Locally](#running-locally)
- [API Reference](#api-reference)
- [Demonstrations](#demonstrations)
- [Design Decisions & Trade-offs](#design-decisions--trade-offs)
- [Roadmap](#roadmap)
- [License](#license)

---

## Tech Stack

| Layer            | Technology                                      |
|------------------|-------------------------------------------------|
| Language         | Java 21                                         |
| Framework        | Spring Boot 3.x                                 |
| Web              | Spring Web (REST controllers)                   |
| Persistence      | Spring Data JPA / Hibernate                     |
| Database         | PostgreSQL 16                                    |
| Connection Pool  | HikariCP (default)                              |
| Security         | Spring Security (BCrypt, session-based auth)    |
| Observability    | Spring Boot Actuator                            |
| Build            | Maven (multi-stage Docker build)                |
| Containerization | Docker                                          |
| Orchestration    | Kubernetes (local via Minikube)                 |

---

## Architecture

```
                          Client (curl / browser)
                                    |
                                    v
                     +------------------------------+
                     |  Service (NodePort)          |  <- external access,
                     |  java-cloud-compiler         |     load-balances pods
                     +------------------------------+
                                    |
                    +---------------+---------------+
                    v                               v
          +------------------+            +------------------+
          |  App Pod         |            |  App Pod         |   <- Deployment,
          |  (Spring Boot)   |            |  (Spring Boot)   |      replicas: 2,
          +------------------+            +------------------+      self-healing
                    |                               |
                    +---------------+---------------+
                                    |  connects by DNS name "postgres"
                                    v
                     +------------------------------+
                     |  Service (ClusterIP)         |  <- internal only,
                     |  postgres                    |     not exposed
                     +------------------------------+
                                    |
                                    v
                     +------------------------------+
                     |  Postgres Pod                |  <- Deployment,
                     |  (PostgreSQL 16)             |     replicas: 1,
                     |      |                       |     strategy: Recreate
                     |      v                       |
                     |  PersistentVolumeClaim (1Gi) |  <- durable storage,
                     +------------------------------+     survives pod restarts

  Credentials (POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB) are supplied to
  both the app pods and the Postgres pod from a single Kubernetes Secret.
```

**Key ideas:**
- The **application** runs as a stateless Deployment (2 replicas). Any pod is
  interchangeable, so Kubernetes can freely restart or reschedule them.
- The **database** runs as a stateful workload: a single-replica Deployment
  backed by a **PersistentVolumeClaim**, so data survives pod restarts.
- The app reaches the database by its **Service DNS name** (`postgres`), not a
  pod IP — so the connection keeps working even when the database pod is
  replaced.
- The database Service is **ClusterIP** (internal-only); only the app Service is
  externally reachable.

---

## Backend Features

- **REST API** built with Spring Web.
- **User registration and login** (`/api/auth/signup`, `/api/auth/login`).
- **PostgreSQL persistence** via Spring Data JPA / Hibernate — Java entities are
  mapped to database tables automatically.
- **Derived query repository** — `UserRepository` generates SQL from method
  names (e.g. `findByUsername`, `existsByUsername`) with no hand-written SQL.
- **Connection pooling** via HikariCP (Spring Boot default) — connections are
  reused rather than opened per request.
- **Schema management** — Hibernate auto-creates/updates tables from entity
  definitions in development (`ddl-auto: update`).

---

## Reliability (SRE) Features

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
  Service's load-balancer **without** restarting it.
- **Startup probe** — holds off the liveness and readiness probes until the app
  has finished booting, preventing a slow-starting JVM from being killed
  mid-startup.

**Key distinction:** liveness failure means *restart me*; readiness failure
means *stop sending me traffic but leave me running*.

### Readiness Tied to Database Health
Because the application declares a datasource, Spring Boot Actuator
**automatically adds a database health check to the readiness group**. If
PostgreSQL becomes unreachable, the app's readiness turns `DOWN` and Kubernetes
removes it from the load-balancer — but liveness stays `UP`, so the pod is **not
restarted**. This is the liveness-vs-readiness distinction made concrete: a
missing dependency means "stop sending traffic," not "restart," because
restarting the app cannot bring the database back. See
[Demonstrations](#demonstrations) to see this live.

### Graceful Shutdown
Configured in `application.yml` (`server.shutdown: graceful`). When Kubernetes
sends `SIGTERM` during a rolling update, the app stops accepting new requests but
finishes in-flight ones before terminating — preventing dropped connections
during deployments.

### Resource Requests & Limits
Each application container declares:
- **Requests** (guaranteed reservation, used for scheduling): 250m CPU, 256Mi memory
- **Limits** (hard ceiling): 500m CPU, 512Mi memory

Exceeding the CPU limit throttles the container; exceeding the memory limit
results in an `OOMKilled` termination. Limits protect the node from a single
runaway container starving its neighbors (the "noisy neighbor" problem).

### Self-Healing
The Deployment declares a desired replica count (2). A control loop
continuously reconciles actual state to desired state — if a pod is deleted or
crashes, a replacement is created automatically to restore the count.

### Zero-Downtime Rolling Updates
On a new image version, Kubernetes performs a rolling update: it starts a new
pod, waits for its **readiness probe** to pass before routing traffic to it, then
retires an old pod — repeating until all are replaced. Two mechanisms together
make this truly zero-downtime:
1. The **readiness probe** keeps traffic off new pods until they can serve.
2. **Graceful shutdown** keeps terminating old pods from dropping in-flight
   requests.

Because deployments use **versioned image tags**, `kubectl rollout undo`
provides instant rollback to the previous version.

### Database as a Stateful Workload
PostgreSQL runs with:
- A **PersistentVolumeClaim** so data survives pod restarts (a pod's own
  filesystem is ephemeral and would lose data on restart).
- **`strategy: Recreate`** instead of a rolling update, because the storage
  volume can only be attached to one pod at a time — overlapping old and new
  pods would deadlock over the volume.
- **`exec` health probes** running `pg_isready` (the database speaks the
  Postgres protocol, not HTTP, so an HTTP probe would not work).

---

## Security

- **Passwords are never stored in plain text.** They are hashed with **BCrypt**
  before persistence, and only the hash is stored.
- **BCrypt** is used deliberately: it is a *slow*, adaptive hashing function with
  a **built-in per-password salt**. Slowness is a feature for password hashing —
  it makes brute-force attacks impractical. Fast hashes (e.g. SHA-256) are the
  wrong tool because they allow billions of guesses per second, and without a
  salt they are vulnerable to precomputed "rainbow table" attacks.
- **Password verification** is done with BCrypt's `matches()` — the stored hash
  is never reversed; the login attempt is re-hashed (using the salt embedded in
  the stored hash) and compared.
- **Username enumeration protection** — login returns an identical
  "Invalid username or password" response whether the username does not exist or
  the password is wrong, so an attacker cannot discover which usernames are
  valid.
- **Database-level uniqueness** — the `username` column is `UNIQUE NOT NULL`, so
  duplicate accounts are rejected by the database itself (defense in depth),
  independent of the application check.
- **Session-based authentication** — a successful login establishes a
  server-side session (the chosen approach over stateless JWTs; see
  [Design Decisions](#design-decisions--trade-offs)).
- **Secrets are not committed to the repository** — database credentials are
  stored in a Kubernetes Secret created via command line, and injected into pods
  as environment variables. They never appear in any manifest in Git.
- **Actuator endpoints are deliberately left open** in the security config so
  that Kubernetes probes can reach them — locking them would cause health checks
  to fail and pods to be killed.

---

## Multi-Stage Docker Build
The `Dockerfile` uses two stages:
1. **Build stage** — a Maven + JDK image compiles the application into a JAR.
   Dependencies are downloaded in a separate layer *before* the source is
   copied, so ordinary code changes reuse the cached dependency layer instead of
   re-downloading everything.
2. **Runtime stage** — a slim JRE image receives only the finished JAR.

The build toolchain (Maven, JDK) never ships in the final image, keeping it
small and reducing the attack surface. Anyone with only Docker installed can
build from source — no local Maven or JDK setup required.

---

## Project Structure
```
.
├── Dockerfile                      # Multi-stage build (Maven+JDK -> slim JRE)
├── pom.xml                         # Maven build + dependencies
├── src/
│   └── main/
│       ├── java/com/example/demo/
│       │   ├── DemoApplication.java    # Spring Boot entry point
│       │   ├── HelloController.java    # Root status endpoint
│       │   ├── User.java               # JPA entity -> "users" table
│       │   ├── UserRepository.java     # Spring Data repository
│       │   ├── AuthRequest.java        # DTO for signup/login request bodies
│       │   ├── AuthController.java     # Signup + login endpoints
│       │   └── SecurityConfig.java     # Spring Security rules + BCrypt bean
│       └── resources/
│           └── application.yml         # Server, datasource, JPA, Actuator config
└── k8s/
    ├── deployment.yaml             # App Deployment (probes, limits, secret env)
    ├── service.yaml                # App Service (NodePort)
    ├── postgres-pvc.yaml           # PersistentVolumeClaim for the database
    ├── postgres-deployment.yaml    # Postgres Deployment (PVC, exec probes)
    └── postgres-service.yaml       # Postgres Service (ClusterIP, internal-only)
```

---

## Running Locally

### Prerequisites
- Docker
- Minikube
- kubectl

### 1. Start the cluster
```bash
minikube start --driver=docker
minikube addons enable metrics-server   # enables `kubectl top` and HPA metrics
```

### 2. Create the database credentials Secret
Values are your choice; they are injected into both the app and the database.
They are **not** stored in any file in the repository.
```bash
kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_USER=appuser \
  --from-literal=POSTGRES_PASSWORD=<choose-a-password> \
  --from-literal=POSTGRES_DB=appdb
```

### 3. Deploy PostgreSQL
```bash
kubectl apply -f k8s/postgres-pvc.yaml
kubectl apply -f k8s/postgres-deployment.yaml
kubectl apply -f k8s/postgres-service.yaml
```

### 4. Build and load the application image
The image is built locally, then loaded into Minikube's internal registry
(the cluster cannot see host-built images otherwise).
```bash
docker build -t demo:latest .
minikube image load demo:latest
```
> If you reference `demo:latest` in `k8s/deployment.yaml`, keep the tag
> consistent. This project used incrementing tags (`demo:1.0`, `demo:2.0`, ...)
> during development to demonstrate rolling updates and rollbacks.

### 5. Deploy the application
```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

### 6. Confirm everything is running
```bash
kubectl get pods
# Expect 2 app pods + 1 postgres pod, all READY 1/1
kubectl get pvc
# Expect postgres-pvc STATUS: Bound
```

### 7. Access the application
```bash
minikube service java-cloud-compiler --url
# Keep this terminal open (the Docker driver on Windows requires it).
# Use the printed URL as the base for the API calls below.
```

---

## API Reference

Base URL is whatever `minikube service java-cloud-compiler --url` prints.

| Method | Endpoint                        | Description                       | Success | Failure |
|--------|---------------------------------|-----------------------------------|---------|---------|
| GET    | `/`                             | Status message                    | 200     | —       |
| POST   | `/api/auth/signup`              | Register a new user               | 201     | 409 if username taken |
| POST   | `/api/auth/login`               | Authenticate, establish a session | 200     | 401 if credentials invalid |
| GET    | `/actuator/health`              | Overall health (includes `db`)    | 200     | —       |
| GET    | `/actuator/health/liveness`     | Liveness state                    | 200     | —       |
| GET    | `/actuator/health/readiness`    | Readiness state (DB-aware)        | 200     | 503 if not ready |

### Examples

Register a user:
```bash
curl -X POST <base-url>/api/auth/signup \
  -H "Content-Type: application/json" \
  -d '{"username":"vlad","password":"secret123"}'
# -> 201  "User registered: vlad"
```

Log in:
```bash
curl -X POST <base-url>/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"vlad","password":"secret123"}'
# -> 200  "Login successful for vlad"
```

> **On Windows PowerShell**, `Invoke-RestMethod` handles JSON bodies more
> cleanly than `curl.exe` (use single quotes around the `-Body` JSON to avoid
> escaping):
> ```powershell
> Invoke-RestMethod -Uri "$url/api/auth/signup" -Method Post `
>   -ContentType "application/json" `
>   -Body '{"username":"vlad","password":"secret123"}'
> ```

---

## Demonstrations

### Self-Healing
```bash
kubectl delete pod <app-pod-name>
kubectl get pods
# A replacement pod is created automatically to restore the desired count.
```

### Zero-Downtime Rolling Update
```bash
# Deploy a new version and watch it roll out with no dropped requests
kubectl set image deployment/java-cloud-compiler app=demo:<new-tag>
kubectl rollout status deployment/java-cloud-compiler

# Roll back instantly if needed
kubectl rollout undo deployment/java-cloud-compiler
```

### Readiness Reacting to Database Health
This demonstrates the liveness-vs-readiness distinction concretely.
```bash
# Scale the database down to simulate an outage
kubectl scale deployment postgres --replicas=0

# Watch the app: readiness goes DOWN, but the pod is NOT restarted
kubectl get pods                       # app pods show 0/1 (not ready), no restarts
curl <base-url>/actuator/health        # "db" component reports DOWN

# Restore the database
kubectl scale deployment postgres --replicas=1
# Readiness returns to UP and the pods rejoin the load-balancer automatically.
```

### Verifying Passwords Are Hashed
```bash
kubectl exec -it <postgres-pod-name> -- \
  psql -U appuser -d appdb -c "SELECT id, username, password_hash FROM users;"
# password_hash is a BCrypt string ($2a$...), never the plain-text password.
```

---

## Design Decisions & Trade-offs

**PostgreSQL over a NoSQL store (e.g. Cassandra).**
Authentication data is relational, transactional, and low-volume — the textbook
case for a relational database. Cassandra is built for high-volume distributed
writes without joins, which is not this workload. Choosing a database by
workload fit (rather than name recognition) is the point.

**Session-based auth over JWT.**
Sessions were chosen because auth benefits from easy, immediate revocation and
Spring Security's hardened defaults. JWT's main advantage — stateless
verification — matters most for large horizontally-scaled or cross-service
systems, and it makes revocation awkward (typically requiring a server-side
blocklist that reintroduces state). *Note:* with multiple app replicas, a
production session setup would use a shared session store (e.g. Redis) so any
pod can serve any request.

**`ddl-auto: update` for schema.**
Convenient for development. In production, schema changes would be managed with
a migration tool (Flyway or Liquibase) rather than letting Hibernate alter
tables.

**CSRF disabled.**
Acceptable for an API tested with `curl`. A browser-based app using session
cookies would keep CSRF protection enabled.

**Single-instance database Deployment (not a StatefulSet).**
Sufficient for one database instance. A replicated, highly-available database
would use a StatefulSet, which gives each replica a stable network identity and
its own volume.

**Kubernetes Secrets.**
Secrets keep credentials out of the repository, but Kubernetes Secrets are
base64-encoded, **not encrypted**, at rest by default. A production setup would
add encryption-at-rest and a tool such as Sealed Secrets or HashiCorp Vault.

---

## Roadmap
- [ ] Enforce authentication on protected routes via the Spring Security context
- [ ] Sandboxed Java code execution in ephemeral, resource-limited containers
      (the "compiler" feature) — with strict CPU/memory caps, execution
      timeouts, and network isolation for untrusted code
- [ ] Shared session store (Redis) for multi-replica session consistency
- [ ] Database schema migrations with Flyway
- [ ] Integration tests using Testcontainers (ephemeral Postgres)
- [ ] Horizontal Pod Autoscaler driven by CPU metrics
- [ ] Prometheus metrics endpoint (`/actuator/prometheus`) and Grafana dashboards

---

## License
This project is licensed under the terms of the [LICENSE](LICENSE) file in this
repository.
