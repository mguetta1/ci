#!/bin/bash

set -e

REQUIRED_IMAGES=("quay.io/konveyor/kantra" "quay.io/konveyor/c-sharp-provider" "quay.io/konveyor/java-external-provider" "quay.io/konveyor/go-external-provider" "quay.io/konveyor/python-external-provider" "quay.io/konveyor/nodejs-external-provider")
kantra_image_regex=".*kantra.*"
java_provider_image_regex=".*java(-external)?-provider.*"
c_sharp_provider_image_regex=".*c-sharp-provider.*"
go_provider_image_regex=".*go(-external)?-provider.*"
python_provider_image_regex=".*python(-external)?-provider.*"
nodejs_provider_image_regex=".*nodejs(-external)?-provider.*"

echo "Checking for required podman images..."
echo "------------------------------------------------------------"

# Get list of all podman images
IMAGES=$(podman images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null)

if [ -z "$IMAGES" ]; then
    echo "No images found in podman."
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
        # Pattern matches: quay.io_konveyor_kantra--main_2026.02.18
        # But NOT: quay.io_konveyor_kantra--main_2026.02.18_amd64
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
            if podman pull "$img:$BASE_REF"; then
                DOWNLOAD_SUCCESS=1
                echo "Successfully pulled $img:$BASE_REF"
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

    # Load downloaded images into podman and optionally re-tag
    echo ""
    echo "Loading downloaded images into podman..."
    for image in $(find "$TEMP_DIR" -type f -name "*.tar"); do
        echo "Loading: ${image}"
        LOADED_IMAGE=$(podman load -i "${image}" | awk '{print $3}')
        echo "Loaded image: $LOADED_IMAGE"

        # Re-tag if we have a tag from found images
        if [ -n "$FOUND_TAG" ] && [ -n "$LOADED_IMAGE" ]; then
            # Extract the repository name (without the tag)
            IMAGE_REPO=$(echo "$LOADED_IMAGE" | cut -d':' -f1)
            NEW_TAG="${IMAGE_REPO}:${FOUND_TAG}"
            echo "Re-tagging to: $NEW_TAG"
            podman tag "$LOADED_IMAGE" "$NEW_TAG"
        fi
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
