# Java Cloud Compiler

A containerized Java platform with a browser UI where **authenticated users
compile and run Java code**, and every submission executes inside its own
isolated, resource-limited, throwaway Kubernetes Job. Built to demonstrate both
**backend engineering** (REST APIs, persistence, authentication, password
security) and **Site Reliability / platform engineering** (containerization,
health probing, resource management, self-healing, zero-downtime deploys, and
safe execution of untrusted code).

> **Status:** Complete and running on a local Kubernetes cluster (Minikube).
> The reliability platform, PostgreSQL integration, enforced session-based
> authentication, the sandboxed code-execution engine, a login-gated browser
> frontend, and one-command launchers for Windows and macOS/Linux are all in
> place. Remaining items are production-hardening steps, documented under
> [Known Limitations](#known-limitations--production-hardening) and
> [Roadmap](#roadmap).

This README is intentionally detailed: it is both documentation **and** a
study/reference guide for the concepts the project uses.

---

## Table of Contents
- [Quick Start](#quick-start)
- [Tech Stack](#tech-stack)
- [High-Level Architecture](#high-level-architecture)
- [How It Works: Request Flows](#how-it-works-request-flows)
- [Web Interface](#web-interface)
- [Project Structure](#project-structure)
- [Reliability (SRE) Features](#reliability-sre-features)
- [Database Layer](#database-layer)
- [Authentication & Security](#authentication--security)
- [The Code Execution Sandbox](#the-code-execution-sandbox)
  - [Threat Model](#threat-model)
  - [Defense in Depth](#defense-in-depth)
  - [How a Submission Runs](#how-a-submission-runs)
- [Multi-Stage Docker Build](#multi-stage-docker-build)
- [Running Locally (manual)](#running-locally-manual)
- [API Reference](#api-reference)
- [Demonstrations](#demonstrations)
- [Design Decisions & Trade-offs](#design-decisions--trade-offs)
- [Known Limitations & Production Hardening](#known-limitations--production-hardening)
- [Glossary of Key Concepts](#glossary-of-key-concepts)
- [Roadmap](#roadmap)
- [License](#license)

---

## Quick Start

**Prerequisites:** Docker, Minikube, and kubectl installed, with Docker running.

- **Windows:** double-click **`start.bat`**
- **macOS / Linux:** `chmod +x start.sh` once, then **`./start.sh`**

Either launcher provisions the entire stack and opens the app in your browser:
- checks prerequisites and that the Docker engine is reachable,
- starts the Minikube cluster (if not already running),
- creates the database Secret (if missing),
- builds the app image and loads it into Minikube,
- applies all Kubernetes manifests in order,
- waits for the database and app to become ready,
- opens the browser to the app and holds the connection tunnel open.

Keep the launched window/terminal open while using the app (closing it stops the
tunnel). Tear down with **`stop.bat`** (Windows) or **`./stop.sh`**
(macOS/Linux); the database volume and Secret are preserved so your data
survives.

Notes:
- `start.bat` runs the setup script with a one-time execution-policy bypass — no
  system settings are changed.
- The launchers are idempotent (safe to run repeatedly) and fail with a clear
  message if a prerequisite is missing.
- If `start.sh` errors with `bad interpreter`, its line endings are CRLF —
  convert them to LF.

---

## Tech Stack

| Layer               | Technology                                        |
|---------------------|---------------------------------------------------|
| Language            | Java 21                                           |
| Framework           | Spring Boot 3.x                                    |
| Web (API)           | Spring Web (REST controllers)                     |
| Web (UI)            | Static HTML/CSS/JS served by Spring Boot          |
| Persistence         | Spring Data JPA / Hibernate                       |
| Database            | PostgreSQL 16                                      |
| Connection Pool     | HikariCP (Spring Boot default)                    |
| Security            | Spring Security (BCrypt, enforced session auth)   |
| Observability       | Spring Boot Actuator                              |
| K8s Integration     | Fabric8 Kubernetes Java Client                    |
| Build               | Maven (multi-stage Docker build)                  |
| Containerization    | Docker                                            |
| Orchestration       | Kubernetes (local via Minikube)                   |
| Code Execution      | Kubernetes Jobs (one ephemeral Job per run)       |
| Launchers           | `start.bat`/`start.ps1` (Win), `start.sh` (Unix)  |

---

## High-Level Architecture

```
                       Browser  (served the UI + calls the API, same origin)
                          |   must log in before code execution is allowed
                          v
                     +------------------------------+
                     |  Service (NodePort)          |  external access,
                     |  java-cloud-compiler         |  load-balances app pods
                     +------------------------------+
                                    |
                    +---------------+---------------+
                    v                               v
          +------------------+            +------------------+
          |  App Pod         |            |  App Pod         |   Deployment,
          |  (Spring Boot)   |            |  (Spring Boot)   |   replicas: 2,
          |  serves UI + API |            |  serves UI + API |   self-healing
          |  SA: executor-sa |            |  SA: executor-sa |
          +------------------+            +------------------+
                 |     |                          |
                 |     | (2) for an AUTHENTICATED request, creates a Job per
                 |     |     submission via the Kubernetes API (least-privilege RBAC)
                 |     v
                 |   +--------------------------------------------+
                 |   |  Ephemeral Execution Job (one per run)     |
                 |   |  - image: eclipse-temurin:21-jdk           |
                 |   |  - code mounted READ-ONLY from a ConfigMap |
                 |   |  - writable scratch dir (emptyDir, capped) |
                 |   |  - 15s timeout, mem/CPU caps, non-root,    |
                 |   |    read-only root FS, dropped capabilities,|
                 |   |    no API token, deny-all NetworkPolicy    |
                 |   |  --> compiles + runs, logs captured,       |
                 |   |      Job + ConfigMap destroyed afterward   |
                 |   +--------------------------------------------+
                 |
                 | (1) reads/writes users by DNS name "postgres"
                 v
       +------------------------------+
       |  Service (ClusterIP)         |  internal only, not exposed
       |  postgres                    |
       +------------------------------+
                    |
                    v
       +------------------------------+
       |  Postgres Pod                |  Deployment, replicas: 1,
       |  (PostgreSQL 16)             |  strategy: Recreate
       |      |                       |
       |      v                       |
       |  PersistentVolumeClaim (1Gi) |  durable storage,
       +------------------------------+  survives pod restarts

  Credentials (POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB) are supplied to
  both the app pods and the Postgres pod from a single Kubernetes Secret.
```

**Three subsystems:**
1. **The application** — a stateless Spring Boot service (serving both the browser
   UI and the REST API) running as a 2-replica Deployment behind a load-balancing
   Service.
2. **The database** — PostgreSQL as a stateful workload with durable storage.
3. **The execution engine** — for authenticated requests, the app creates a fresh,
   locked-down Kubernetes Job per code submission, then destroys it.

---

## How It Works: Request Flows

### Loading the UI
The Spring Boot app serves a static `index.html` at `/`. Because the page is
served by the same app that exposes the API, they share an **origin**, so the
page calls the API with no CORS configuration and the browser automatically
carries the session cookie on those calls.

### Signup / Login (enforced)
1. Client POSTs `{username, password}` to `/api/auth/signup` or `/api/auth/login`.
2. **Signup** checks the username isn't taken, hashes the password with BCrypt,
   saves a `User` row, then logs the user in immediately.
3. **Login** verifies credentials through Spring Security's `AuthenticationManager`
   (which loads the user via a `UserDetailsService` and checks the password with
   BCrypt).
4. On success the resulting **Authentication** is placed in Spring Security's
   **SecurityContext** and **persisted to the HTTP session**, so subsequent
   requests carrying the session cookie are recognized as authenticated.
5. **Logout** (`/api/auth/logout`) clears the session and context.

### Code Execution (requires authentication)
1. An authenticated user submits Java source (public class must be named `Main`).
2. Spring Security allows the request because the session carries a valid
   authentication; an unauthenticated request to `/api/execute` is rejected.
3. The app writes the code into a **ConfigMap** as `Main.java`.
4. The app creates a **Kubernetes Job** whose pod mounts that ConfigMap read-only
   at `/code`, has a writable scratch volume (`emptyDir`) at `/work`, and runs
   `javac -d /work /code/Main.java && java -cp /work Main`.
5. The app waits for the Job (bounded by a timeout), reads the pod's logs
   (compiler errors *or* program output), and truncates them to a cap.
6. The app **deletes the Job and the ConfigMap** — nothing persists.

---

## Web Interface

A single self-contained `index.html` (HTML + CSS + JS inline, no external
dependencies) served from `src/main/resources/static/`, with two views:

1. **Login / signup view** — shown first. Username and password fields with Log in
   and Sign up buttons; server error messages (e.g. "Invalid username or password",
   "Username already taken") are surfaced inline.
2. **Code-runner view** — revealed only after successful authentication. A code
   editor pre-filled with a sample program, a **Run** button that POSTs to
   `/api/execute`, an elapsed-time status, and an output pane for program output or
   compiler errors. A **Log out** button in the header returns to the login view.

All `fetch` calls use `credentials: 'same-origin'` so the session cookie rides
along. If an execution request ever returns 401/403 (expired session), the UI
gracefully bounces the user back to the login view.

Because Spring Boot serves `static/index.html` as the welcome page, no separate
web server or container is needed — one app serves both the UI and the API.

---

## Project Structure
```
.
├── start.bat / start.ps1            # Windows launcher (double-click start.bat)
├── stop.bat  / stop.ps1             # Windows teardown
├── start.sh                         # macOS / Linux launcher (./start.sh)
├── stop.sh                          # macOS / Linux teardown
├── Dockerfile                       # Multi-stage build (Maven+JDK -> slim JRE)
├── pom.xml                          # Maven build + dependencies
├── src/
│   └── main/
│       ├── java/com/example/demo/
│       │   ├── DemoApplication.java       # Spring Boot entry point
│       │   ├── HelloController.java       # Status endpoint at /api/status
│       │   ├── User.java                  # JPA entity -> "users" table
│       │   ├── UserRepository.java        # Spring Data repository
│       │   ├── AppUserDetailsService.java # Loads users for Spring Security
│       │   ├── AuthRequest.java           # DTO for signup/login bodies
│       │   ├── AuthController.java         # Signup/login/session establishment
│       │   ├── SecurityConfig.java        # Security rules, BCrypt, AuthManager, logout
│       │   ├── KubernetesConfig.java      # Fabric8 KubernetesClient bean
│       │   ├── ExecuteRequest.java        # DTO for code-execution body
│       │   ├── ExecutionController.java   # /api/execute endpoint (protected)
│       │   └── ExecutionService.java      # Creates/monitors/cleans up exec Jobs
│       └── resources/
│           ├── application.yml            # Server, datasource, JPA, Actuator config
│           └── static/
│               └── index.html             # Browser UI (login gate + editor)
└── k8s/
    ├── deployment.yaml              # App Deployment (probes, limits, SA, secret env)
    ├── service.yaml                 # App Service (NodePort)
    ├── postgres-pvc.yaml            # PersistentVolumeClaim for the database
    ├── postgres-deployment.yaml     # Postgres Deployment (PVC, exec probes)
    ├── postgres-service.yaml        # Postgres Service (ClusterIP, internal-only)
    ├── executor-rbac.yaml           # ServiceAccount + Role + RoleBinding (least privilege)
    └── execution-networkpolicy.yaml # Deny-all NetworkPolicy for execution pods
```

---

## Reliability (SRE) Features

### Health Probes
Exposed via Spring Boot Actuator and probed by Kubernetes:

- **Liveness** (`/actuator/health/liveness`) — "is this process healthy, or should
  it be restarted?" Repeated failure -> Kubernetes restarts the container. Checks
  only the process itself, never external dependencies (an over-eager liveness
  check can restart a healthy app in a loop).
- **Readiness** (`/actuator/health/readiness`) — "is this pod ready for traffic?"
  Failure -> Kubernetes removes the pod from the load-balancer **without**
  restarting it.
- **Startup** — holds off liveness/readiness until the app has booted, so a slow
  JVM start isn't misread as a failure.

**Key distinction:** liveness failure means *restart me*; readiness failure means
*stop sending me traffic but leave me running*.

### Readiness Tied to Database Health
Because the app declares a datasource, Actuator automatically adds a database
check to the readiness group. If PostgreSQL is unreachable, readiness turns
`DOWN` (pod pulled from the load-balancer) but liveness stays `UP` (pod is NOT
restarted) — because restarting the app can't fix a downstream dependency.

### Graceful Shutdown
`server.shutdown: graceful` in `application.yml`. On `SIGTERM` (sent during
rolling updates), the app stops accepting new requests but finishes in-flight ones
before exiting — no dropped connections during deploys.

### Resource Requests & Limits (application pods)
- **Requests** (guaranteed, used for scheduling): 250m CPU, 256Mi memory
- **Limits** (hard ceiling): 500m CPU, 512Mi memory

Exceeding the CPU limit throttles the container; exceeding memory triggers an
`OOMKilled` termination. Limits protect a node from a single runaway container
(the "noisy neighbor" problem).

### Self-Healing
The Deployment declares 2 replicas. A control loop continuously reconciles actual
state to desired state — delete or crash a pod and a replacement is created
automatically.

### Zero-Downtime Rolling Updates
On a new image version, Kubernetes starts a new pod, waits for its **readiness
probe** to pass before routing traffic, then retires an old pod — repeating until
all are replaced. Truly zero-downtime because of two mechanisms together: the
**readiness probe** (keeps traffic off unready pods) and **graceful shutdown**
(stops terminating pods dropping in-flight requests). Versioned image tags mean
`kubectl rollout undo` gives instant rollback.

---

## Database Layer

PostgreSQL runs as a **stateful** workload — the opposite of the stateless app:

- **PersistentVolumeClaim (1Gi)** — a pod's own filesystem is ephemeral and would
  lose data on restart; the PVC provides durable storage that survives pod
  replacement.
- **`strategy: Recreate`** — instead of a rolling update. The storage volume can
  attach to only one pod at a time, so overlapping old/new pods would deadlock
  over the volume.
- **`exec` health probes** running `pg_isready` — the database speaks the Postgres
  protocol, not HTTP, so HTTP probes wouldn't work. (Probes can be HTTP, TCP, or
  exec.)
- **ClusterIP Service** (`postgres`) — internal-only; the database is never
  exposed outside the cluster. The app connects by this **DNS name**, so the
  connection survives database pod replacement.

The app reaches it through the standard stack: **JPA/Hibernate** (maps Java
objects to rows) -> **HikariCP** (connection pooling) -> **JDBC driver** (Postgres
dialect). Schema is auto-created from entities in development (`ddl-auto: update`).

---

## Authentication & Security

Authentication is **enforced**: code execution requires a logged-in session.

- **Passwords are never stored in plain text** — hashed with **BCrypt** before
  persistence; only the hash is stored.
- **Why BCrypt:** it is a *slow*, adaptive hash with a **built-in per-password
  salt**. Slowness is a feature — it makes brute-force impractical. Fast hashes
  (e.g. SHA-256) are the wrong tool: they allow billions of guesses/second, and
  without a salt are vulnerable to precomputed "rainbow table" attacks.
- **How login is enforced (the mechanism):**
  - A `UserDetailsService` loads users from the database and adapts them to Spring
    Security's model.
  - An `AuthenticationManager` verifies the username/password (checking the stored
    BCrypt hash).
  - On success, the resulting **Authentication** is placed in the **Security
    context** and **persisted to the HTTP session**, so later requests carrying the
    session cookie are recognized as authenticated.
  - The security config marks `/api/execute` (and any non-public route) as
    requiring authentication; the page, static assets, `/api/status`,
    `/api/auth/**`, and `/actuator/**` are public.
  - A `/api/auth/logout` endpoint clears the session and context.
- **Username enumeration protection** — login returns an identical "Invalid
  username or password" whether the username is unknown or the password is wrong.
- **Database-level uniqueness** — the `username` column is `UNIQUE NOT NULL`, so
  the database itself rejects duplicates (defense in depth).
- **Actuator left open** in the security config so Kubernetes probes can reach the
  health endpoints — locking them would cause health checks to fail and pods to be
  killed.
- **Secrets kept out of the repo** — database credentials live in a Kubernetes
  Secret created via CLI and injected as environment variables; they never appear
  in any committed manifest.

---

## The Code Execution Sandbox

Authenticated users submit Java source, and the platform compiles and runs it
**inside an isolated, disposable Kubernetes Job** — never in the application
process itself. Running untrusted code safely is the hard part, and this section
documents the approach honestly, including its limits.

### Threat Model

Untrusted code can attempt to:
1. **Exhaust CPU** — e.g. `while (true) {}` pinning a core.
2. **Exhaust memory** — allocate unbounded memory until the host dies.
3. **Exhaust disk** — write huge files until the disk fills.
4. **Fork-bomb** — spawn processes/threads endlessly.
5. **Abuse the network** — attack others, exfiltrate data, download payloads.
6. **Access the filesystem** — read secrets/other users' data or write malicious
   files.
7. **Escape the container** — break out to the host (worst case).
8. **Flood output** — print gigabytes to exhaust the collector.

### Defense in Depth

Multiple independent layers, so if one fails others still contain the damage.
Each control maps to a threat above:

| Control | Threat addressed | Mechanism |
|---|---|---|
| `activeDeadlineSeconds: 15` (Job timeout) | 1 (CPU / infinite loops) | Kubernetes kills the Job after 15s regardless of what the code does |
| App-side wait timeout (25s backstop) | 1 | Second timer in case the first fails |
| Memory limit (256Mi) | 2 | Kernel OOM-kills the container if exceeded |
| CPU limit (500m) | 1 | Container throttled to its share |
| `emptyDir` `sizeLimit: 32Mi` | 3 (disk) | Caps the one writable directory |
| Read-only root filesystem | 3, 6 | Nothing writable except the scratch dir |
| `runAsNonRoot` + `runAsUser: 1000` | 6, 7 | Code runs unprivileged, not root |
| `allowPrivilegeEscalation: false` | 7 | Can't gain new privileges |
| `capabilities: drop ALL` | 7 | Removes all Linux kernel capabilities |
| `automountServiceAccountToken: false` | 7 | Execution pod gets NO Kubernetes API access |
| Deny-all NetworkPolicy | 5 (network) | No ingress/egress (see enforcement caveat below) |
| Output truncation (10,000 chars) | 8 | Bounds what is read back |
| One throwaway Job per run + cleanup | all | Fresh, known state each time; destroyed after |
| Authentication required on `/api/execute` | abuse/attribution | Only logged-in users can trigger execution |

**The two most important, most reliable controls are the timeout and the network
denial** — they eliminate the entire "runs forever" and "attack others /
exfiltrate" classes respectively.

> **Network enforcement caveat (important, and honest):** a Kubernetes
> NetworkPolicy is only a *declaration*; a CNI plugin must *enforce* it. The
> default Minikube CNI does **not** enforce NetworkPolicies, so on a stock local
> cluster this policy is **defined but not enforced** — verified by observing an
> execution pod successfully reach the internet. In production you would run a
> policy-enforcing CNI (e.g. Calico or Cilium) and **test** that egress is
> actually blocked rather than assuming the manifest suffices. An unenforced
> policy is a false sense of security; knowing that distinction is the point.
> To enforce it locally: `minikube start --driver=docker --cni=calico`.

### How a Submission Runs

1. **Authenticated request.** `/api/execute` is protected; only a logged-in session
   reaches the execution logic.
2. **Least-privilege API access.** The app runs under a dedicated **ServiceAccount**
   (`executor-sa`) bound to a namespaced **Role** granting only Job/Pod/ConfigMap
   access — not cluster-admin. A compromise of the app cannot take over the
   cluster.
3. **Code injection via ConfigMap.** The source is written to a ConfigMap and
   mounted read-only as `/code/Main.java` — no per-submission image builds, and
   arbitrary multi-line code is handled cleanly. (ConfigMap mounts are inherently
   read-only, which is why compiled output goes to a separate writable volume.)
4. **Compile + run in a Job.** The pod compiles with `javac -d /work` (writing
   `.class` files to the writable scratch dir) and runs `java -cp /work Main`. The
   **JDK** image is used deliberately — compilation needs `javac`, which the JRE
   lacks.
5. **Result capture.** Compiler errors and program output both land in the pod
   logs; the app reads and truncates them.
6. **Cleanup.** The Job and ConfigMap are deleted in a `finally` block, with
   `ttlSecondsAfterFinished` as a backstop.

> **Container escape — honest limitation:** standard containers share the host
> kernel, so a kernel-level exploit could still escape despite non-root, dropped
> capabilities, and no-privilege-escalation. True isolation needs a sandboxed
> runtime such as **gVisor** or microVMs (**Firecracker**). That is the primary
> "would harden for production" item.

---

## Multi-Stage Docker Build
The `Dockerfile` uses two stages:
1. **Build stage** — a Maven + JDK image compiles the app into a JAR. Dependencies
   are downloaded in a separate layer *before* the source is copied, so ordinary
   code changes reuse the cached dependency layer instead of re-downloading
   everything.
2. **Runtime stage** — a slim JRE image receives only the finished JAR.

The build toolchain never ships in the final image, keeping it small and reducing
the attack surface. Anyone with only Docker installed can build from source.

---

## Running Locally (manual)

For running the steps by hand instead of via a launcher.

### Prerequisites
- Docker, Minikube, kubectl

### Steps
```bash
# 1. Start the cluster
minikube start --driver=docker
minikube addons enable metrics-server

# 2. Create the database credentials Secret (not stored in the repo)
kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_USER=appuser \
  --from-literal=POSTGRES_PASSWORD=<choose-a-password> \
  --from-literal=POSTGRES_DB=appdb

# 3. Deploy PostgreSQL
kubectl apply -f k8s/postgres-pvc.yaml
kubectl apply -f k8s/postgres-deployment.yaml
kubectl apply -f k8s/postgres-service.yaml

# 4. Execution RBAC + network policy
kubectl apply -f k8s/executor-rbac.yaml
kubectl apply -f k8s/execution-networkpolicy.yaml

# 5. Build and load the app image
docker build -t demo:latest .
minikube image load demo:latest

# 6. Deploy the application
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

# 7. Confirm everything is running
kubectl get pods           # 2 app pods + 1 postgres pod, all READY 1/1
kubectl get pvc            # postgres-pvc STATUS: Bound

# 8. Open the app (holds the tunnel open)
minikube service java-cloud-compiler
```

---

## API Reference

Base URL is whatever `minikube service java-cloud-compiler --url` prints (or the
address a launcher opens).

| Method | Endpoint             | Description                          | Auth | Success | Failure |
|--------|----------------------|--------------------------------------|------|---------|---------|
| GET    | `/`                  | Browser UI (login gate + editor)     | no   | 200     | —       |
| GET    | `/api/status`        | Status message                       | no   | 200     | —       |
| POST   | `/api/auth/signup`   | Register a new user, log in          | no   | 201     | 409 if taken |
| POST   | `/api/auth/login`    | Authenticate, establish a session    | no   | 200     | 401 if invalid |
| POST   | `/api/auth/logout`   | Clear the session                    | yes  | 200     | —       |
| POST   | `/api/execute`       | Compile and run submitted Java       | yes  | 200     | 401/403 if not logged in; 400 if no code |
| GET    | `/actuator/health`   | Overall health (includes `db`)       | no   | 200     | —       |
| GET    | `/actuator/health/liveness`  | Liveness state               | no   | 200     | —       |
| GET    | `/actuator/health/readiness` | Readiness state (DB-aware)   | no   | 200     | 503 if not ready |

### Execute example (PowerShell, authenticated session)
```powershell
# Log in, capturing the session cookie
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
Invoke-RestMethod -Uri "$url/api/auth/login" -Method Post -ContentType "application/json" `
  -Body '{"username":"vlad","password":"secret123"}' -WebSession $session

# Execute using that authenticated session (public class must be named Main)
$body = @{ code = @"
public class Main {
    public static void main(String[] args) {
        System.out.println("Hello from user code!");
    }
}
"@ } | ConvertTo-Json

Invoke-RestMethod -Uri "$url/api/execute" -Method Post -ContentType "application/json" `
  -Body $body -WebSession $session
```

---

## Demonstrations

### Authentication Enforcement
```powershell
# Without a session -> blocked
try {
  Invoke-RestMethod -Uri "$url/api/execute" -Method Post -ContentType "application/json" `
    -Body '{"code":"public class Main{public static void main(String[] a){}}"}'
} catch { Write-Host "Blocked as expected: $($_.Exception.Response.StatusCode)" }
# With a logged-in session (see Execute example above) -> succeeds
```

### Self-Healing
```bash
kubectl delete pod <app-pod-name>
kubectl get pods     # a replacement is created automatically
```

### Zero-Downtime Rolling Update
```bash
kubectl set image deployment/java-cloud-compiler app=demo:<new-tag>
kubectl rollout status deployment/java-cloud-compiler
kubectl rollout undo deployment/java-cloud-compiler   # instant rollback
```

### Readiness Reacting to Database Health
```bash
kubectl scale deployment postgres --replicas=0   # simulate a DB outage
kubectl get pods                                 # app pods go 0/1, NOT restarted
curl <base-url>/actuator/health                  # "db" component reports DOWN
kubectl scale deployment postgres --replicas=1   # readiness returns to UP
```

### Sandbox Holding Against Attacks (paste into the UI while logged in)
Infinite loop — returns after the ~15s timeout, does not run forever:
```java
public class Main { public static void main(String[] a){ while(true){} } }
```
Memory bomb — OOM-killed at the 256Mi cap, does not consume host RAM:
```java
import java.util.*;
public class Main {
  public static void main(String[] a){
    List<long[]> l = new ArrayList<>();
    while(true){ l.add(new long[10_000_000]); }
  }
}
```

### Verifying Passwords Are Hashed
```bash
kubectl exec -it <postgres-pod-name> -- \
  psql -U appuser -d appdb -c "SELECT id, username, password_hash FROM users;"
# password_hash is a BCrypt string ($2a$...), never the plain-text password.
```

---

## Design Decisions & Trade-offs

**Kubernetes Jobs for execution (over spawning raw Docker containers).** Staying
inside Kubernetes means the same platform that runs and heals the app also
isolates untrusted execution — using the platform's own primitives (Jobs, resource
limits, security contexts, network policies, RBAC). Giving the app the Docker
socket instead would itself be a major escape risk.

**PostgreSQL over a NoSQL store (e.g. Cassandra).** Auth data is relational,
transactional, and low-volume — the textbook relational case. Cassandra targets
high-volume distributed writes without joins, a different workload. Choose by fit,
not name recognition.

**Session-based auth over JWT.** Sessions give easy, immediate revocation and
Spring Security's hardened defaults. JWT's stateless verification mainly benefits
large horizontally-scaled or cross-service systems and makes revocation awkward
(usually requiring a server-side blocklist that reintroduces state). With multiple
replicas, a production session setup would use a shared store (e.g. Redis) so any
pod can serve any request.

**Least-privilege RBAC for the executor.** A namespaced Role (not a ClusterRole)
limited to Jobs/Pods/ConfigMaps, so a compromise can't take over the cluster.

**Static UI served by the app.** Same-origin as the API, so no CORS setup, the
session cookie is carried automatically, and there's no separate frontend server
to run.

**`ddl-auto: update` for schema.** Convenient in development; production would use
migrations (Flyway/Liquibase).

**Single-instance database Deployment (not a StatefulSet).** Sufficient for one
instance; a replicated HA database would use a StatefulSet (stable identity +
per-replica volume).

---

## Known Limitations & Production Hardening

Being explicit about what is **not** production-grade is deliberate:

- **NetworkPolicy is not enforced on stock Minikube** — needs a policy-capable CNI
  (Calico/Cilium). Currently defined but not enforced locally. *(See the caveat in
  the sandbox section.)*
- **Container escape** — shared-kernel containers can in principle be escaped via
  kernel exploits; true isolation needs gVisor or microVMs (Firecracker).
- **CSRF protection is disabled** — acceptable for API testing, but because auth is
  now cookie/session-based in a browser, a production deployment should enable CSRF
  protection (or use a token scheme) to defend against cross-site request forgery.
- **Kubernetes Secrets are base64-encoded, not encrypted** at rest by default;
  production would add encryption-at-rest and a tool like Sealed Secrets or
  HashiCorp Vault.
- **No horizontal autoscaling yet** — resource requests/limits are set (so an HPA
  could be added), but no HPA is configured.
- **Single-replica session state** — sessions live per-pod; consistent multi-pod
  sessions would need a shared store (e.g. Redis).
- **`ddl-auto: update`** is used instead of managed migrations.
- **PID/thread limits** for execution pods are not separately enforced beyond CPU
  limits; a stricter setup would add explicit process caps.

---

## Glossary of Key Concepts

Quick reference for the ideas this project uses.

- **Container vs VM** — a VM virtualizes hardware and ships a whole guest OS
  (heavy); a container shares the host kernel and ships only the app + its
  dependencies (light).
- **Image vs Container** — an image is the read-only blueprint; a container is a
  running instance of it. (Class vs object.)
- **Fat JAR** — a self-contained JAR bundling the app, its dependencies, and an
  embedded web server, runnable with `java -jar`.
- **JDK vs JRE** — the JDK includes the compiler (`javac`) and build tools (needed
  to *build*/compile); the JRE is just enough to *run* a built app.
- **Multi-stage build** — compile in a throwaway stage with the full toolchain,
  then copy only the artifact into a slim runtime image.
- **Declarative / desired state** — you describe the end state; a control loop
  continuously reconciles actual state to match it (the heart of Kubernetes).
- **Pod** — the smallest deployable unit; wraps one (or a few) containers. Pods are
  disposable and get new IPs when replaced.
- **Deployment** — manages a set of identical pods: keeps N running, replaces
  failures, performs rolling updates. For stateless apps.
- **Job** — runs a pod to completion (a task that finishes), rather than keeping it
  running. Used here for code execution.
- **Service** — a stable network address in front of disposable pods. **ClusterIP**
  = internal only; **NodePort** = exposed on the node; a Service also provides a
  stable **DNS name**.
- **Probe** — Kubernetes health-checking a pod on a schedule (HTTP, TCP, or exec)
  and acting on the result. **Liveness** = restart if failing; **readiness** = stop
  sending traffic if failing; **startup** = wait for boot.
- **Requests vs Limits** — requests are the guaranteed reservation used for
  scheduling; limits are the hard ceiling. CPU over-limit is throttled; memory
  over-limit is `OOMKilled`.
- **Graceful shutdown / SIGTERM** — the signal Kubernetes sends on termination;
  graceful shutdown finishes in-flight requests before exiting.
- **PersistentVolume / PersistentVolumeClaim** — durable storage decoupled from
  pods; a PVC is a pod's request for storage that survives pod restarts.
- **StatefulSet** — like a Deployment but for stateful workloads: stable identity
  and per-replica storage.
- **ConfigMap** — holds config/data that can be mounted into a pod as files. Mounts
  are read-only.
- **emptyDir** — a temporary volume that lives only for the pod's lifetime; used
  here as writable scratch space, with a size cap.
- **Secret** — holds sensitive data; base64-encoded (NOT encrypted by default).
- **RBAC** — Role-Based Access Control. A **ServiceAccount** is a pod identity; a
  **Role/ClusterRole** lists allowed actions; a **RoleBinding** connects them.
- **NetworkPolicy** — a pod-level firewall. Only enforced if the cluster's CNI
  supports it.
- **CNI** — Container Network Interface; the plugin that implements pod networking
  and (optionally) NetworkPolicy enforcement.
- **ORM / JPA / Hibernate** — Object-Relational Mapping; work with Java objects
  instead of hand-written SQL. JPA is the standard; Hibernate is the
  implementation.
- **Connection pool / HikariCP** — reuses a set of open DB connections instead of
  opening one per request.
- **BCrypt / salt** — a slow, adaptive password hash with a built-in per-password
  salt, resistant to brute force and rainbow tables.
- **SecurityContext / Authentication** — Spring Security's holder for "who is
  logged in." Login populates it with an Authentication and persists it to the
  session so later requests are recognized as authenticated.
- **UserDetailsService** — Spring Security's interface for loading a user by
  username; here it adapts the app's `User` entity for the framework.
- **Same-origin / CORS** — a page can freely call an API served from the same
  host+port (same origin), and the browser carries its cookies; a different origin
  requires CORS configuration.
- **CSRF** — cross-site request forgery; a risk for cookie/session auth that
  production browser apps defend against with CSRF tokens.
- **Defense in depth** — layering independent controls so one failure doesn't mean
  total compromise.
- **Least privilege** — grant the minimum permissions necessary and nothing more.

---

## Roadmap
- [ ] Enforce the NetworkPolicy with a policy-capable CNI (Calico/Cilium)
- [ ] Enable CSRF protection for the browser session flow
- [ ] Stronger isolation for untrusted code (gVisor / Firecracker microVMs)
- [ ] Explicit PID/thread caps on execution pods
- [ ] Shared session store (Redis) for multi-replica session consistency
- [ ] Database schema migrations with Flyway
- [ ] Integration tests using Testcontainers (ephemeral Postgres)
- [ ] Horizontal Pod Autoscaler driven by CPU metrics
- [ ] Prometheus metrics (`/actuator/prometheus`) + Grafana dashboards
- [ ] Per-user history of past submissions
- [ ] Support languages beyond Java

---

## License
This project is licensed under the terms of the [LICENSE](LICENSE) file in this
repository.
