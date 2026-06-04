#!/bin/bash

set -e

REQUIRED_IMAGES=(
    "quay.io/konveyor/tackle2-hub"
    "quay.io/konveyor/tackle2-addon-analyzer"
    "quay.io/konveyor/tackle2-addon-discovery"
    "quay.io/konveyor/tackle2-addon-platform"
    "quay.io/konveyor/c-sharp-provider"
    "quay.io/konveyor/java-external-provider"
    "quay.io/konveyor/go-external-provider"
    "quay.io/konveyor/python-external-provider"
    "quay.io/konveyor/nodejs-external-provider"
)
hub_regex=".*tackle2-hub.*"
addon_regex=".*tackle2-addon-analyzer.*"
addon_discovery=".*tackle2-addon-discovery.*"
addon_platform=".*tackle2-addon-platform.*"
kantra_image_regex=".*kantra.*"
java_provider_image_regex=".*java(-external)?-provider.*"
c_sharp_provider_image_regex=".*c-sharp-provider.*"
go_provider_image_regex=".*go(-external)?-provider.*"
python_provider_image_regex=".*python(-external)?-provider.*"
nodejs_provider_image_regex=".*nodejs(-external)?-provider.*"

echo "Checking for required images in Kind cluster..."
echo "------------------------------------------------------------"

# Get list of all images in Kind cluster
IMAGES=$(docker exec koncur-test-control-plane crictl images -o json | jq -r '.images[] | .repoTags[]' 2>/dev/null)

if [ -z "$IMAGES" ]; then
    echo "No images found in Kind cluster."
    echo ""
    echo "Missing images:"
    for img in "${REQUIRED_IMAGES[@]}"; do
        echo "  - $img"
    done
    exit 1
fi

MISSING=()
FOUND=()
FOUND_TAG=""

# Check each required image
for required in "${REQUIRED_IMAGES[@]}"; do
    if echo "$IMAGES" | grep -qi "$required"; then
        MATCHED=$(echo "$IMAGES" | grep -i "$required" | head -n 1)
        FOUND+=("$required: $MATCHED")

        # Extract tag from the first found image
        if [ -z "$FOUND_TAG" ]; then
            FOUND_TAG=$(echo "$MATCHED" | cut -d':' -f2)
            echo "Extracted tag from found image: $FOUND_TAG"
        fi
    else
        MISSING+=("$required")
    fi
done

# Display found images
if [ ${#FOUND[@]} -gt 0 ]; then
    echo "Found images:"
    for img in "${FOUND[@]}"; do
        echo "  ✓ $img"
    done
fi

# Display missing images
if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    echo "Missing images:"
    for img in "${MISSING[@]}"; do
        echo "  ✗ $img"
    done
    echo "------------------------------------------------------------"
    echo "Status: ${#MISSING[@]} image(s) missing"
    echo ""

    if [ -n "$FOUND_TAG" ]; then
        echo "Will re-tag downloaded images to match: $FOUND_TAG"
    fi

    echo "Attempting to download missing images from last successful nightly run..."

    # Determine which nightly workflow to use based on the target branch
    BASE_REF="${BASE_REF:-main}"
    if [[ "$BASE_REF" =~ ^release-([0-9]+\.[0-9]+)$ ]]; then
        VERSION="${BASH_REMATCH[1]}"
        NIGHTLY_WORKFLOW="nightly-koncur-${VERSION}.yaml"
        echo "Trying release nightly workflow: $NIGHTLY_WORKFLOW"
        WORKFLOW_RUN=$(gh run list -R=konveyor/ci --workflow="$NIGHTLY_WORKFLOW" --branch=main --status=success --limit=1 --json databaseId --jq '.[0].databaseId')
        if [ -z "$WORKFLOW_RUN" ]; then
            echo "No successful run found for $NIGHTLY_WORKFLOW, falling back to nightly-koncur.yaml"
            NIGHTLY_WORKFLOW="nightly-koncur.yaml"
        fi
    else
        NIGHTLY_WORKFLOW="nightly-koncur.yaml"
        echo "Using main nightly workflow: $NIGHTLY_WORKFLOW"
    fi

    if [ -z "$WORKFLOW_RUN" ]; then
        WORKFLOW_RUN=$(gh run list -R=konveyor/ci --workflow="$NIGHTLY_WORKFLOW" --branch=main --status=success --limit=1 --json databaseId --jq '.[0].databaseId')
    fi

    if [ -z "$WORKFLOW_RUN" ]; then
        echo "Error: Could not find a successful nightly workflow run"
        exit 1
    fi

    echo "Found successful workflow run: $WORKFLOW_RUN"

    # Create temp directory for downloads
    TEMP_DIR=$(mktemp -d)
    echo "Using temp directory: $TEMP_DIR"

    DOWNLOAD_SUCCESS=0

    # Download artifacts for missing images (manifest lists only, not arch-specific)
    for img in "${MISSING[@]}"; do
        # Convert image name to artifact naming pattern
        # quay.io/konveyor/kantra -> quay.io_konveyor_kantra
        ARTIFACT_PREFIX="${img//\//_}"

        # Download only the manifest list (without _amd64 or _arm64 suffix)
        # Pattern matches: quay.io_konveyor_tackle2-hub--main_2026.02.18
        # But NOT: quay.io_konveyor_tackle2-hub--main_2026.02.18_amd64
        PATTERN="${ARTIFACT_PREFIX}--*_20[0-9][0-9].[0-9][0-9].[0-9][0-9]"
        echo "Downloading manifest list artifact matching: ${PATTERN}"
        
        # Use a more specific pattern that excludes architecture suffixes
        # We want artifacts that end with a date pattern, not _amd64/_arm64
        if OUTPUT=$(gh run download -R=konveyor/ci "$WORKFLOW_RUN" --pattern "$PATTERN" --dir "$TEMP_DIR" 2>&1); then
            DOWNLOAD_SUCCESS=1
            echo "Successfully downloaded artifact for $img"
        else
            # Only show error if it's not the expected "no artifact matches" message
            if ! echo "$OUTPUT" | grep -q "no artifact matches"; then
                echo "Error downloading artifact for $img:"
                echo "$OUTPUT"
            fi
            echo "Warning: Could not download manifest list artifact for $img"
        fi
    done

    # Check if any downloads succeeded
    if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
        # Fallback: try pulling images tagged with BASE_REF
        echo ""
        echo "Nightly download failed, trying fallback tag: $BASE_REF"

        for img in "${MISSING[@]}"; do
            echo "Pulling $img:$BASE_REF..."
            if docker pull "$img:$BASE_REF"; then
                DOWNLOAD_SUCCESS=1
                echo "Successfully pulled $img:$BASE_REF"
                # Load the pulled image into Kind
                kind load docker-image "$img:$BASE_REF" --name "${CLUSTER_NAME:-koncur-test}"
            else
                echo "Warning: Could not pull $img:$BASE_REF"
            fi
        done

        if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
            echo ""
            echo "Error: No artifacts were successfully downloaded (they may have expired) and no fallback tag succeeded"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
    fi

    # Load downloaded images into Kind cluster and optionally re-tag
    echo ""
    echo "Loading downloaded images into Kind cluster..."
    CLUSTER_NAME=${CLUSTER_NAME:-koncur-test}
    
    for image in $(find "$TEMP_DIR" -type f -name "*.tar"); do
        echo "Loading: ${image}"
        
        # Extract image name from tar file metadata
        # Try multiple methods to handle different tar formats
        LOADED_IMAGE=""
        
        # Method 1: Try with jq (most reliable if available)
        if command -v jq &> /dev/null; then
            LOADED_IMAGE=$(tar -xOf "${image}" manifest.json 2>/dev/null | jq -r '.[0].RepoTags[0] // empty' 2>/dev/null)
        fi
        
        # Method 2: Try with grep/sed if jq failed or not available
        if [ -z "$LOADED_IMAGE" ]; then
            LOADED_IMAGE=$(tar -xOf "${image}" manifest.json 2>/dev/null | grep -o '"RepoTags":\s*\[\s*"[^"]*"' | grep -o '"[^"]*"' | tail -1 | tr -d '"' 2>/dev/null)
        fi
        
        # Method 3: Try index.json for OCI format images
        if [ -z "$LOADED_IMAGE" ]; then
            LOADED_IMAGE=$(tar -xOf "${image}" index.json 2>/dev/null | grep -o '"org.opencontainers.image.ref.name":"[^"]*"' | cut -d'"' -f4 2>/dev/null)
        fi
        
        if [ -z "$LOADED_IMAGE" ]; then
            echo "Warning: Could not extract image name from ${image}, skipping..."
            echo "Debug: Listing tar contents:"
            tar -tf "${image}" 2>/dev/null | head -10
            continue
        fi
        
        echo "Image name: $LOADED_IMAGE"
        
        # Load image into Kind cluster
        kind load image-archive "${image}" --name "${CLUSTER_NAME}"
        
        # Use the extracted image name as-is (no re-tagging needed for Kind)
        NEW_TAG="$LOADED_IMAGE"
        echo "Loaded image: $NEW_TAG"
        if [[ "$image" =~ $kantra_image_regex ]]; then
            echo "Kantra Image Found Set Env Var: RUNNER_IMG=$NEW_TAG"
            echo "RUNNER_IMG=$NEW_TAG" >> $GITHUB_ENV
        fi
        if [[ "$image" =~ $java_provider_image_regex ]]; then
            echo "Java Provider Image Found Set Env Var: JAVA_PROVIDER_IMG=$NEW_TAG"
            echo "JAVA_PROVIDER_IMG=$NEW_TAG" >> $GITHUB_ENV
        fi
        if [[ "$image" =~ $c_sharp_provider_image_regex ]]; then
            echo "C Sharp Provider Found Set Env Var: CSHARP_PROVIDER_IMG=$NEW_TAG"
            echo "CSHARP_PROVIDER_IMG=$NEW_TAG" >> $GITHUB_ENV
        fi
        if [[ "$image" =~ $go_provider_image_regex ]]; then
            echo "Go Provider Image Found Set Env Var: GO_PROVIDER_IMG=$NEW_TAG"
            echo "GO_PROVIDER_IMG=$NEW_TAG" >> $GITHUB_ENV
        fi
        if [[ "$image" =~ $python_provider_image_regex ]]; then
            echo "Python Provider Image Found Set Env Var: PYTHON_PROVIDER_IMG=$NEW_TAG"
            echo "PYTHON_PROVIDER_IMG=$NEW_TAG" >> $GITHUB_ENV
        fi
        if [[ "$image" =~ $nodejs_provider_image_regex ]]; then
            echo "Node.js Provider Image Found Set Env Var: NODEJS_PROVIDER_IMG=$NEW_TAG"
            echo "NODEJS_PROVIDER_IMG=$NEW_TAG" >> $GITHUB_ENV
        fi
        if [[ "$image" =~ $addon_regex ]]; then
            echo "Addon-Analyzer Image Found Set Env Var: ANALYZER_ADDON=$NEW_TAG"
            echo "ANALYZER_ADDON=$NEW_TAG" >> $GITHUB_ENV
        fi
        if [[ "$image" =~ $addon_discovery ]]; then
            echo "Discovery Addon Image Found Set Env Var: DISCOVERY_ADDON=$NEW_TAG"
            echo "DISCOVERY_ADDON=$NEW_TAG" >> $GITHUB_ENV
        fi
        if [[ "$image" =~ $addon_platform ]]; then
            echo "Platform Addon Image Found Set Env Var: PLATFORM_ADDON=$NEW_TAG"
            echo "PLATFORM_ADDON=$NEW_TAG" >> $GITHUB_ENV
        fi
        if [[ "$image" =~ $hub_regex ]]; then
            echo "Hub Image Image Found Set Env Var: HUB=$NEW_TAG"
            echo "HUB=$NEW_TAG" >> $GITHUB_ENV
        fi
    done

    # Cleanup
    rm -rf "$TEMP_DIR"

    echo ""
    echo "Download and load complete. Re-checking images..."
    exec "$0"
else
    echo "------------------------------------------------------------"
    echo "Status: All required images are present"
    exit 0
fi
