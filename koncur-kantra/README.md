# Koncur Kantra Action

A composite GitHub Action for running Konveyor CLI (Kantra) tests across multiple platforms using the Koncur testing framework.

## Features

- Cross-platform Kantra CLI testing (Linux, macOS, Windows)
- Automatic Podman setup and configuration for each platform
- Loads custom-built images from artifacts or downloads from nightly builds
- Supports Maven local resources for Java application testing
- Automatic test result collection and failure diagnostics
- Platform-specific networking configuration

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `skip_maven` | Whether to setup access to the testing maven packages | No | `true` |
| `os` | OS that the action is running on, one of `linux`, `macos`, or `windows` | Yes | - |
| `image_pattern` | The pattern used to download images that have been built to test (e.g., `*kantra*`, `*provider*`) | No | - |
| `ref` | The ref of koncur to use for testing (branch, tag, or commit SHA) | No | `main` |

## Outputs

The action uploads artifacts on completion:

- **`koncur-kantra-{os}-summary`** (retention: 3 days): Test results in YAML format (`test.yaml`)
- **`koncur-kantra-{os}-failures`** (retention: 5 days): Full test output and logs (only on failure)

## Usage Examples

### Basic Usage - Linux

Run Kantra tests on Linux with default configuration:

```yaml
- name: Run Kantra tests
  uses: konveyor/ci/koncur-kantra@main
  with:
    os: linux
```

### Cross-Platform Testing

Test across all supported platforms:

```yaml
jobs:
  test-kantra:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
        include:
          - os: ubuntu-latest
            os_name: linux
          - os: macos-latest
            os_name: macos
          - os: windows-latest
            os_name: windows
    runs-on: ${{ matrix.os }}
    steps:
      - name: Run Kantra tests
        uses: konveyor/ci/koncur-kantra@main
        with:
          os: ${{ matrix.os_name }}
```

### Using Custom-Built Images

Test with images built in a previous job:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Build Kantra image
        uses: konveyor/ci/build-image@main
        with:
          repo: konveyor/kantra
          ref: main
          image_name: quay.io/konveyor/kantra
          image_tag: pr-${{ github.event.pull_request.number }}

  test:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - name: Run Kantra tests with built image
        uses: konveyor/ci/koncur-kantra@main
        with:
          os: linux
          image_pattern: "*kantra*"
```

### Testing with Maven Applications

Enable Maven local resources for Java application testing:

```yaml
- name: Run Kantra tests with Maven
  uses: konveyor/ci/koncur-kantra@main
  with:
    os: linux
    skip_maven: false
```

### Using Specific Koncur Version

Test with a specific Koncur version or branch:

```yaml
- name: Run Kantra tests with Koncur v1.0.0
  uses: konveyor/ci/koncur-kantra@main
  with:
    os: linux
    ref: v1.0.0
```

### Complete PR Testing Workflow

Test a Kantra PR across all platforms:

```yaml
name: Test Kantra PR

on:
  pull_request:
    branches: [main]

jobs:
  build-kantra:
    runs-on: ubuntu-latest
    steps:
      - name: Build Kantra from PR
        uses: konveyor/ci/build-image@main
        with:
          repo: konveyor/kantra
          ref: ${{ github.head_ref }}
          image_name: quay.io/konveyor/kantra
          image_tag: pr-${{ github.event.pull_request.number }}

  test-kantra:
    needs: build-kantra
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-26-large, windows-latest]
        include:
          - os: ubuntu-latest
            os_name: linux
          - os: macos-26-large
            os_name: macos
          - os: windows-latest
            os_name: windows
    runs-on: ${{ matrix.os }}
    steps:
      - name: Run Kantra tests
        uses: konveyor/ci/koncur-kantra@main
        with:
          os: ${{ matrix.os_name }}
          image_pattern: "*kantra*"
          skip_maven: false

      - name: Check test results
        if: always()
        run: |
          if [ -f test.yaml ]; then
            cat test.yaml
          fi
```

## How It Works

### 1. Podman Setup

The action installs and configures Podman for each platform:

**Linux:**
- Uses pre-installed Podman
- Configures host networking with `allow_host_loopback=true`
- Sets `NETWORK_GATEWAY=host.containers.internal`

**macOS:**
- Installs Podman via Homebrew
- Initializes Podman machine with 8GB RAM and 2 CPUs
- Sets `NETWORK_GATEWAY=host.containers.internal`

**Windows:**
- Installs Podman CLI via Chocolatey
- Initializes Podman machine with 10GB RAM and 3 CPUs
- Detects WSL2 network gateway IP
- Adds `$HOME\.local\bin` to PATH

### 2. Image Loading

If `image_pattern` is provided:
1. Downloads artifacts matching the pattern from previous jobs
2. Loads `.tar` files into Podman
3. Sets environment variables for discovered images:
   - `RUNNER_IMG` - Kantra image
   - `JAVA_PROVIDER_IMG` - Java provider image
   - `CSHARP_PROVIDER_IMG` - C# provider image
   - `GO_PROVIDER_IMG` - Go provider image
   - `PYTHON_PROVIDER_IMG` - Python provider image
   - `NODEJS_PROVIDER_IMG` - Node.js provider image

If image download fails or no pattern is provided:
- Falls back to `check_images.sh` which downloads from the last successful nightly build
- If nightly artifacts are unavailable (expired), falls back to pulling images tagged with the target branch (e.g., `release-0.9`, `main`) from quay.io

### 3. Kantra Installation

The action extracts the Kantra binary from the container image:
- **Linux**: Extracts `kantra` binary
- **macOS**: Extracts `darwin-kantra` binary
- **Windows**: Extracts `windows-kantra.exe` binary

All binaries are installed to `$HOME/.local/bin/kantra` (or `kantra.exe` on Windows).

### 4. Koncur Setup

1. Checks out the [konveyor/koncur](https://github.com/konveyor/koncur) repository
2. Sets up Go 1.25
3. Builds Koncur from source: `go build -o $HOME/.local/bin/koncur ./cmd/koncur/main.go`

### 5. Maven Configuration (Optional)

If `skip_maven: false`:
1. Starts HTTP server on port 8085 serving `local-maven-resources/`
2. Configures firewall rules (Windows only)
3. Creates Maven settings file with custom repository pointing to localhost:8085
4. Creates Kantra config at `.koncur/config/target-kantra.yaml`:
   ```yaml
   type: kantra
   kantra:
     mavenSettings: '/path/to/settings.xml'
   ```

### 6. Test Execution

Runs Koncur tests targeting Kantra:
```bash
koncur run tests -t kantra -o yaml --output-file test.yaml
```

### 7. Artifact Upload

- **On success**: Uploads `test.yaml` summary (3 day retention)
- **On failure**: Uploads `.koncur/output/` directory with full diagnostics (5 day retention)

## Platform-Specific Notes

### Linux
- Fastest execution (no VM overhead)
- Uses native Podman installation
- Host networking for container communication
- Recommended for most testing scenarios

### macOS
- Requires Podman machine initialization (~2 min overhead)
- ARM64 runners recommended for M-series Mac support
- Uses `host.containers.internal` for host networking
- Higher resource requirements (8GB RAM)

### Windows
- Requires Podman machine initialization with WSL2
- Uses PowerShell for WSL network detection
- PATH configuration for `$HOME\.local\bin`
- Firewall rules needed for Maven HTTP server
- Highest resource requirements (10GB RAM)

## Environment Variables Set

These environment variables are set and available to subsequent steps:

| Variable | Description | Example |
|----------|-------------|---------|
| `RUNNER_IMG` | Kantra container image | `quay.io/konveyor/kantra:latest` |
| `JAVA_PROVIDER_IMG` | Java provider image | `quay.io/konveyor/java-external-provider:latest` |
| `CSHARP_PROVIDER_IMG` | C# provider image | `quay.io/konveyor/c-sharp-provider:latest` |
| `GO_PROVIDER_IMG` | Go provider image | `quay.io/konveyor/go-external-provider:latest` |
| `PYTHON_PROVIDER_IMG` | Python provider image | `quay.io/konveyor/python-external-provider:latest` |
| `NODEJS_PROVIDER_IMG` | Node.js provider image | `quay.io/konveyor/nodejs-external-provider:latest` |
| `NETWORK_GATEWAY` | Host gateway IP for containers | `host.containers.internal` or WSL IP |
| `MAVEN_SETTINGS_PATH` | Path to Maven settings file | `$HOME/.koncur/temp/settings.xml` |

## Troubleshooting

### Tests Fail on macOS

**Issue**: Podman machine initialization fails or times out

**Solution**: Increase runner timeout and ensure sufficient resources:
```yaml
timeout-minutes: 45
runs-on: macos-26-large  # Use large runners for better performance
```

### Windows Firewall Blocks Maven Server

**Issue**: Maven tests can't reach local HTTP server

**Solution**: The action automatically configures firewall rules, but you can verify:
```powershell
netsh advfirewall firewall show rule name="WSL2-Auto"
```

### Images Not Found

**Issue**: `check_images.sh` fails to find required images

**Solution**: 
1. Verify `image_pattern` matches your artifact names
2. Check that build job uploaded artifacts
3. Ensure artifacts haven't expired (1 day default retention)

### Koncur Build Fails

**Issue**: Go build errors during Koncur compilation

**Solution**: Verify Go version compatibility:
```yaml
- name: Setup go
  uses: actions/setup-go@v6
  with:
    go-version: '1.25'
```

## Related Actions

- **[build-image](../build-image/)** - Build container images for testing
- **[koncur-tackle-hub](../koncur-tackle-hub/)** - Run Hub API tests in Kubernetes

## References

- [Koncur Testing Framework](https://github.com/konveyor/koncur)
- [Kantra CLI](https://github.com/konveyor/kantra)
- [Konveyor Project](https://github.com/konveyor)
- [Shared Test Cases](../shared_tests/)

## License

This action is part of the Konveyor CI tools.
