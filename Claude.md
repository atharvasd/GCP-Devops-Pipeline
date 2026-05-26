# GCP DevOps Pipeline — Project Notes

## Project Context
- **Project ID:** `gcp-devops-pipeline-496410`
- **Region:** `asia-south1`
- **Stack:** Terraform + Docker + Cloud Run + Artifact Registry
- **App:** Node.js web app (port 3000)
- **State Backend:** GCS bucket `gcp-devops-pipeline-496410-tf-state`

---

## Errors Encountered & Fixes

### 1. Image Not Found in Artifact Registry
**Error:**
```
Image 'asia-south1-docker.pkg.dev/.../sample-web-app:latest' not found.
```
**Cause:** Terraform tried to deploy Cloud Run before the Docker image was built and pushed.

**Fix:** Added a `null_resource` with a `local-exec` provisioner to build and push the image before Cloud Run deployment.

```hcl
resource "null_resource" "docker_build_push" {
  triggers = {
    repo_id = google_artifact_registry_repository.app_repo.id
  }
  provisioner "local-exec" {
    command = <<EOT
      gcloud auth configure-docker asia-south1-docker.pkg.dev --quiet
      docker buildx build --platform linux/amd64 -t ${local.image_url} . --push
    EOT
  }
  depends_on = [google_artifact_registry_repository.app_repo]
}
```

---

### 2. Inconsistent Dependency Lock File
**Error:**
```
provider registry.terraform.io/hashicorp/null: required by this configuration but no version is selected
```
**Fix:**
```bash
terraform init -upgrade
```

---

### 3. Incorrect Attribute Value Type in `null_resource` Triggers
**Error:**
```
element "repo_id": string required, but have object.
```
**Cause:** Used the full resource object instead of its `.id` attribute.

**Fix:**
```hcl
# ❌ Wrong
repo_id = google_artifact_registry_repository.app_repo

# ✅ Correct
repo_id = google_artifact_registry_repository.app_repo.id
```

---

### 4. Wrong Platform Architecture
**Error:**
```
Container manifest type 'application/vnd.oci.image.index.v1+json' must support amd64/linux.
```
**Cause:** Image was built on Apple Silicon (ARM) but Cloud Run requires `amd64/linux`.

**Fix:** Use `--platform linux/amd64` flag:
```bash
docker buildx build --platform linux/amd64 -t <image_url> . --push
```
> Run `docker buildx create --use` once if buildx isn't set up.

---

### 5. Cloud Run Missing Artifact Registry Pull Permission
**Error:**
```
Permission "artifactregistry.repositories.downloadArtifacts" denied
```
**Cause:** Cloud Run's default Compute service account lacked permission to pull from Artifact Registry.

**Fix:** Grant `artifactregistry.reader` at project level:
```hcl
data "google_project" "project" {}

resource "google_project_iam_member" "cloud_run_ar_access" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}
```

---

### 6. Dependency Cycle
**Error:**
```
Cycle: google_cloud_run_v2_service_iam_binding.public_access, google_cloud_run_v2_service.app_service
```
**Cause:** `app_service` had `public_access` in its `depends_on`, while `public_access` already implicitly depends on `app_service` via `.location` and `.name` references.

**Fix:** Remove `public_access` from `app_service`'s `depends_on`:
```hcl
depends_on = [null_resource.docker_build_push, google_project_iam_member.cloud_run_ar_access]
```

---

## Optimisations Applied

### Docker

#### `.dockerignore` (new file)
Prevents large/unnecessary files from being sent to the Docker build context.
```
.git
.terraform          # 109MB provider binary — biggest win
.terraform.lock.hcl
node_modules
spec
*.tf
README.md
.gitignore
```

#### `Dockerfile`
- Non-root `node` user — limits blast radius if container is compromised
- `EXPOSE 3000` — documents the port, acts as a hint for Cloud Run
- `CMD ["npm", "start"]` — decouples Dockerfile from the entry point path

```dockerfile
FROM node:18-alpine
WORKDIR /app
COPY package.json yarn.lock* package-lock.json* ./
RUN npm install --production
COPY . .
RUN chown -R node:node /app
USER node
EXPOSE 3000
CMD ["npm", "start"]
```

---

### Terraform (`main.tf`)

#### Region in `locals`
`"asia-south1"` was hardcoded in multiple places. Now centralised:
```hcl
locals {
  region = "asia-south1"
  ...
  image_url = "${local.region}-docker.pkg.dev/${var.project_id}/${local.repo_id}/${local.app_name}:latest"
}
```

#### Cloud Run resource limits
```hcl
resources {
  limits = {
    cpu    = "1"
    memory = "512Mi"
  }
}
```

#### Startup probe
Cloud Run waits for the app to be genuinely ready before routing traffic:
```hcl
startup_probe {
  http_get {
    path = "/items"
    port = 3000
  }
  initial_delay_seconds = 5
  timeout_seconds        = 3
  period_seconds         = 10
  failure_threshold      = 3
}
```

---

### App Code

#### `src/persistence/sqlite.js` — `getItem`
```js
// Before — fetches all matching rows into array
db.all('SELECT * FROM todo_items WHERE id=?', [id], (err, rows) => {
    acc(rows.map(...)[0]);
});

// After — stops at first match, returns row directly
db.get('SELECT * FROM todo_items WHERE id=?', [id], (err, row) => {
    acc(row ? Object.assign({}, row, { completed: row.completed === 1 }) : undefined);
});
```

#### `src/persistence/mysql.js` — connection pool limit
```js
// Before
connectionLimit: 5,

// After — configurable via env var
connectionLimit: parseInt(process.env.MYSQL_CONNECTION_LIMIT || '5', 10),
```

#### `package.json` — `start` script
```json
"scripts": {
  "start": "node src/index.js",
  "dev": "nodemon -L src/index.js"
}
```

---

## Final Dependency Chain
```
Artifact Registry repo created
        ↓
docker buildx build --platform linux/amd64 (null_resource)
+
IAM permission granted to Compute SA (google_project_iam_member)
        ↓
Cloud Run service deployed
        ↓
IAM binding — allUsers invoker (public access)
```

---

## Final `main.tf`

```hcl
variable "project_id" {
  type = string
}

locals {
  env             = terraform.workspace
  resource_prefix = "sample-${local.env}"
  region          = "asia-south1"
  app_name        = "sample-web-app"
  repo_id         = "${local.resource_prefix}-demo-repo"
  image_url       = "${local.region}-docker.pkg.dev/${var.project_id}/${local.repo_id}/${local.app_name}:latest"
}

terraform {
  backend "gcs" {
    bucket = "gcp-devops-pipeline-496410-tf-state"
    prefix = "terraform/state"
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~>5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~>3.0"
    }
  }
}

provider "google" {
  project = "gcp-devops-pipeline-496410"
  region  = local.region
}

data "google_project" "project" {}

resource "google_artifact_registry_repository" "app_repo" {
  location      = local.region
  repository_id = local.repo_id
  description   = "Docker repo for Node js app"
  format        = "DOCKER"
}

resource "null_resource" "docker_build_push" {
  triggers = {
    repo_id = google_artifact_registry_repository.app_repo.id
  }
  provisioner "local-exec" {
    command = <<EOT
      gcloud auth configure-docker ${local.region}-docker.pkg.dev --quiet
      docker buildx build --platform linux/amd64 -t ${local.image_url} . --push
    EOT
  }
  depends_on = [google_artifact_registry_repository.app_repo]
}

resource "google_project_iam_member" "cloud_run_ar_access" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

resource "google_cloud_run_v2_service" "app_service" {
  name     = "${local.resource_prefix}-app-web-service"
  location = local.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    containers {
      image = local.image_url
      ports {
        container_port = 3000
      }
      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
      startup_probe {
        http_get {
          path = "/items"
          port = 3000
        }
        initial_delay_seconds = 5
        timeout_seconds        = 3
        period_seconds         = 10
        failure_threshold      = 3
      }
    }
  }

  depends_on = [null_resource.docker_build_push, google_project_iam_member.cloud_run_ar_access]
}

resource "google_cloud_run_v2_service_iam_binding" "public_access" {
  location = google_cloud_run_v2_service.app_service.location
  name     = google_cloud_run_v2_service.app_service.name
  role     = "roles/run.invoker"
  members  = ["allUsers"]
}

output "service_url" {
  value = google_cloud_run_v2_service.app_service.uri
}
```

---

## Up Next — Epic 4: CI/CD
- **Goal:** Push to GitHub → auto build, push image, deploy to Cloud Run
- **Service Account:** `github-deployer` (roles: `storage.admin`, `run.admin`)
- **Method:** Workload Identity Federation — no long-lived keys stored in GitHub

---

## Useful Commands
```bash
# Initialise / upgrade providers
terraform init -upgrade

# Plan
terraform plan -var="project_id=$PROJECT_ID"

# Apply
terraform apply -var="project_id=$PROJECT_ID"

# Set up buildx (once)
docker buildx create --use

# Verify image exists in registry
gcloud artifacts docker images list asia-south1-docker.pkg.dev/gcp-devops-pipeline-496410/sample-dev-demo-repo
```