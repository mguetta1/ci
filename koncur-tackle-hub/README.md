# Koncur Tackle Hub Action

A composite GitHub Action for running Konveyor Hub API tests in a Kubernetes environment using Kind and the Koncur testing framework.

## Features

- Creates a Kind (Kubernetes in Docker) cluster for testing
- Installs Tackle Hub operator and components
- Loads custom-built images from artifacts or downloads from nightly builds
- Supports Maven local resources for Java application testing
- Automatic test result collection and failure diagnostics
- Comprehensive debugging output on failures

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `skip_maven` | Whether to setup access to the testing maven packages | No | `true` |
| `image_pattern` | The pattern used to download images that have been built to test (e.g., `*hub*`, `*addon*`, `*provider*`) | No | - |
| `ref` | The ref of koncur to use for testing (branch, tag, or commit SHA) | No | `main` |

## Outputs

The action uploads artifacts on completion:

- **`koncur-hub-summary`** (retention: 3 days): Test results in YAML format (`test-hub.yaml`)
- **`koncur-hub-failures`** (retention: 5 days): Full test output and logs from `.koncur/output/` (only on failure)

## Usage Examples

### Basic Usage

Run Hub tests with default configuration:

```yaml
- name: Run Hub tests
  uses: konveyor/ci/koncur-tackle-hub@main
```

### Using Custom-Built Images

Test with images built in a previous job:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Build Hub image
        uses: konveyor/ci/build-image@main
        with:
          repo: konveyor/tackle2-hub
          ref: main
          image_name: quay.io/konveyor/tackle2-hub
          image_tag: pr-${{ github.event.pull_request.number }}

      - name: Build Analyzer addon
        uses: konveyor/ci/build-image@main
        with:
          repo: konveyor/tackle2-addon-analyzer
          ref: main
          image_name: quay.io/konveyor/tackle2-addon-analyzer
          image_tag: pr-${{ github.event.pull_request.number }}

  test:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - name: Run Hub tests with built images
        uses: konveyor/ci/koncur-tackle-hub@main
        with:
          image_pattern: "*tackle2*"
```

### Testing with Maven Applications

Enable Maven local resources for Java application analysis:

```yaml
- name: Run Hub tests with Maven
  uses: konveyor/ci/koncur-tackle-hub@main
  with:
    skip_maven: false
```

### Using Specific Koncur Version

Test with a specific Koncur version:

```yaml
- name: Run Hub tests with Koncur v1.0.0
  uses: konveyor/ci/koncur-tackle-hub@main
  with:
    ref: v1.0.0
```

### Complete PR Testing Workflow

Test a Hub PR with all components:

```yaml
name: Test Hub PR

on:
  pull_request:
    branches: [main]

jobs:
  build-images:
    runs-on: ubuntu-latest
    steps:
      - name: Build Hub
        uses: konveyor/ci/build-image@main
        with:
          repo: konveyor/tackle2-hub
          ref: ${{ github.head_ref }}
          image_name: quay.io/konveyor/tackle2-hub
          image_tag: pr-${{ github.event.pull_request.number }}

      - name: Build Analyzer Addon
        uses: konveyor/ci/build-image@main
        with:
          repo: konveyor/tackle2-addon-analyzer
          ref: main
          image_name: quay.io/konveyor/tackle2-addon-analyzer
          image_tag: pr-${{ github.event.pull_request.number }}

      - name: Build Java Provider
        uses: konveyor/ci/build-image@main
        with:
          repo: konveyor/java-external-provider
          ref: main
          image_name: quay.io/konveyor/java-external-provider
          image_tag: pr-${{ github.event.pull_request.number }}

  test-hub:
    needs: build-images
    runs-on: ubuntu-latest
    steps:
      - name: Run Hub API tests
        uses: konveyor/ci/koncur-tackle-hub@main
        with:
          image_pattern: "*tackle2*|*provider*"
          skip_maven: false

      - name: Display test results
        if: always()
        run: |
          if [ -f test-hub.yaml ]; then
            echo "## Test Results"
            cat test-hub.yaml
          fi
```

## How It Works

### 1. Setup Tools

The action installs required tools on the Ubuntu runner:
- **Koncur**: Checked out from GitHub and built from source (Go 1.25)
- **Kind v0.25.0**: For creating local Kubernetes clusters
- **kubectl**: Latest stable version for cluster interaction

### 2. Create Kind Cluster

Creates a Kubernetes cluster using `make kind-create` from the Koncur repository:
```bash
kind create cluster --name koncur-test
```

The cluster runs in a Docker container named `koncur-test-control-plane`.

### 3. Image Loading

If `image_pattern` is provided:
1. Downloads artifacts matching the pattern from previous jobs
2. Loads `.tar` files into the Kind cluster using `kind load image-archive`
3. Sets environment variables for discovered images:
   - `HUB` - Tackle2 Hub image
   - `ANALYZER_ADDON` - Analyzer addon image
   - `DISCOVERY_ADDON` - Discovery addon image
   - `PLATFORM_ADDON` - Platform addon image
   - `JAVA_PROVIDER_IMG` - Java provider image
   - `CSHARP_PROVIDER_IMG` - C# provider image
   - `GO_PROVIDER_IMG` - Go provider image
   - `PYTHON_PROVIDER_IMG` - Python provider image
   - `NODEJS_PROVIDER_IMG` - Node.js provider image

If image download fails or no pattern is provided:
- Falls back to `check_images.sh` which downloads from the last successful nightly build
- If nightly artifacts are unavailable (expired), falls back to pulling images tagged with the target branch (e.g., `release-0.9`, `main`) from quay.io

### 4. Install Tackle Hub

Installs the Tackle Hub operator and components using `make hub-install` from Koncur.

The environment variables from image loading are passed to the installation, allowing custom images to be used instead of the defaults.

### 5. Wait for Readiness

Waits for Hub to be fully operational:
1. **Pod readiness**: Waits up to 5 minutes for all Hub pods to be ready
   ```bash
   kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=tackle-hub \
     -n konveyor-tackle --timeout=300s
   ```

2. **Port forwarding**: Forwards Hub service to `localhost:8081`
   ```bash
   kubectl port-forward -n konveyor-tackle svc/tackle-hub 8081:8080
   ```

3. **API availability**: Polls the `/applications` endpoint until it responds (up to 2.5 minutes)

### 6. Maven Configuration (Optional)

If `skip_maven: false`:
1. Starts HTTP server on port 8085 serving `local-maven-resources/`
2. Detects Kind cluster gateway IP from inside the container:
   ```bash
   docker exec koncur-test-control-plane ip route | grep default | awk '{print $3}'
   ```
3. Creates Maven settings file with custom repository pointing to gateway:8085
4. Creates Hub config at `.koncur/config/target-tackle-hub.yaml`:
   ```yaml
   type: tackle-hub
   tackleHub:
     url: http://localhost:8081
     mavenSettings: '/path/to/settings.xml'
   ```

### 7. Test Execution

Runs Koncur tests targeting Tackle Hub:
```bash
koncur run tests -t tackle-hub \
  --target-config .koncur/config/target-tackle-hub.yaml \
  -o yaml --output-file test-hub.yaml
```

### 8. Failure Diagnostics

On test failure, automatically collects debugging information:
- Pod status: `kubectl get pods -n konveyor-tackle`
- Pod logs: Last 100 lines from Hub pods
- Tackle CR status: Full YAML of the Tackle custom resource

### 9. Cleanup

Always runs cleanup (even on failure):
```bash
kind delete cluster --name koncur-test
```

## Environment Variables Set

These environment variables are available to the Hub installation and subsequent steps:

| Variable | Description | Example |
|----------|-------------|---------|
| `HUB` | Tackle2 Hub image | `quay.io/konveyor/tackle2-hub:latest` |
| `ANALYZER_ADDON` | Analyzer addon image | `quay.io/konveyor/tackle2-addon-analyzer:latest` |
| `DISCOVERY_ADDON` | Discovery addon image | `quay.io/konveyor/tackle2-addon-discovery:latest` |
| `PLATFORM_ADDON` | Platform addon image | `quay.io/konveyor/tackle2-addon-platform:latest` |
| `JAVA_PROVIDER_IMG` | Java provider image | `quay.io/konveyor/java-external-provider:latest` |
| `CSHARP_PROVIDER_IMG` | C# provider image | `quay.io/konveyor/c-sharp-provider:latest` |
| `GO_PROVIDER_IMG` | Go provider image | `quay.io/konveyor/go-external-provider:latest` |
| `PYTHON_PROVIDER_IMG` | Python provider image | `quay.io/konveyor/python-external-provider:latest` |
| `NODEJS_PROVIDER_IMG` | Node.js provider image | `quay.io/konveyor/nodejs-external-provider:latest` |
| `KIND_GATEWAY` | Kind cluster gateway IP | `172.18.0.1` |

## Troubleshooting

### Hub Pods Not Ready

**Issue**: Hub pods fail to reach ready state within timeout

**Solution**: Check pod logs and events:
```bash
kubectl describe pod -n konveyor-tackle -l app.kubernetes.io/name=tackle-hub
kubectl logs -n konveyor-tackle -l app.kubernetes.io/name=tackle-hub --tail=200
```

The action automatically outputs this information on failure.

### Port Forward Fails

**Issue**: Cannot connect to Hub API on localhost:8081

**Solution**: Verify the service exists and has endpoints:
```bash
kubectl get svc -n konveyor-tackle tackle-hub
kubectl get endpoints -n konveyor-tackle tackle-hub
```

### Maven Tests Fail

**Issue**: Java application analysis fails to download dependencies

**Solution**: 
1. Ensure `skip_maven: false` is set
2. Verify the HTTP server is running on port 8085
3. Check that `KIND_GATEWAY` is correctly detected:
   ```bash
   docker exec koncur-test-control-plane ip route
   ```

### Images Not Found in Kind Cluster

**Issue**: `check_images.sh` can't find images in cluster

**Solution**:
1. Verify images were loaded: 
   ```bash
   docker exec koncur-test-control-plane crictl images
   ```
2. Check `image_pattern` matches artifact names
3. Ensure build job uploaded artifacts with correct retention

### Kind Cluster Creation Fails

**Issue**: `make kind-create` fails with errors

**Solution**:
1. Check Docker is running and accessible
2. Verify no conflicting cluster exists:
   ```bash
   kind delete cluster --name koncur-test
   ```
3. Check disk space for pulling images

## Testing Shared Test Cases

The action automatically runs tests defined in the [shared_tests/](../shared_tests/) directory through the Hub API. Test cases are defined in `test_cases.yml`:

```yaml
book-server_deps:
  description: book-store source + deps analysis
  application:
    name: book-server
    repository:
      url: https://github.com/migtools/book-server
      kind: git
      branch: v0.0.1
  sources: [java-ee, springboot]
  targets: [cloud-readiness, linux, quarkus]
  withDeps: true
```

The Hub will:
1. Create an application in Tackle
2. Submit an analysis task with the specified sources and targets
3. Wait for task completion
4. Validate the results match expected output files

See [shared_tests/README.md](../shared_tests/README.md) for more information on defining test cases.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ GitHub Actions Runner (Ubuntu)                          │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │ Docker Container (Kind Node)                       │ │
│  │                                                     │ │
│  │  ┌──────────────────────────────────────────────┐  │ │
│  │  │ Kubernetes Cluster (koncur-test)             │  │ │
│  │  │                                               │  │ │
│  │  │  Namespace: konveyor-tackle                   │  │ │
│  │  │  ├─ tackle-hub (deployment)                   │  │ │
│  │  │  ├─ tackle-postgres (statefulset)             │  │ │
│  │  │  ├─ tackle-keycloak (deployment)              │  │ │
│  │  │  └─ analyzer-addon (taskgroup/pods)           │  │ │
│  │  │                                               │  │ │
│  │  └──────────────────────────────────────────────┘  │ │
│  │                                                     │ │
│  │  Port Forward: 8081 → tackle-hub:8080              │ │
│  └────────────────────────────────────────────────────┘ │
│                                                          │
│  HTTP Server: :8085 (Maven local resources)             │
│  Koncur CLI → http://localhost:8081 (Hub API)           │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

## Platform Requirements

- **OS**: Linux (ubuntu-latest recommended)
- **Docker**: Required for Kind cluster
- **Disk Space**: ~10GB for images and cluster
- **Memory**: 4GB minimum, 8GB recommended
- **Network**: Outbound access for image pulls and repository clones

## Related Actions

- **[build-image](../build-image/)** - Build container images for testing
- **[koncur-kantra](../koncur-kantra/)** - Run CLI tests across multiple platforms

## References

- [Koncur Testing Framework](https://github.com/konveyor/koncur)
- [Tackle Hub](https://github.com/konveyor/tackle2-hub)
- [Kind - Kubernetes in Docker](https://kind.sigs.k8s.io/)
- [Konveyor Project](https://github.com/konveyor)
- [Shared Test Cases](../shared_tests/)

## License

This action is part of the Konveyor CI tools.
