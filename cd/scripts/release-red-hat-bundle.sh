#!/usr/bin/env bash

set -eo pipefail

USAGE="
Usage:
  $(basename "$0")

Publishes the red hat operator lifecycle manager bundle for an ACK service controller as part 
of prowjob when a service controller repository is tagged with a semver format '^v\d+\.\d+\.\d+$'
See: https://github.com/aws-controllers-k8s/test-infra/prow/jobs/jobs.yaml for prowjob configuration.

Environment variables:
  REPO_NAME:                Name of the service controller repository. Ex: apigatewayv2-controller
                            This variable is injected into the pod by Prow.
  PULL_BASE_REF:            The value of tag on service controller repository that triggered the
                            postsubmit prowjob. The value will either be in the format '^v\d+\.\d+\.\d+$'
                            or 'stable'.
                            This variable is injected into the pod by Prow.
  DOCKER_REPOSITORY:        Name for the Docker repository to push to
                            Default: $DEFAULT_DOCKER_REPOSITORY
  AWS_SERVICE_DOCKER_IMG:   Controller container image tag
                            Default: <AWS_SERVICE>-controller:<VERSION>
                            VERSION is calculated from $PULL_BASE_REF
  QUIET:                    Build controller container image quietly (<true|false>)
                            Default: false
"

# find out the service name and semver tag from the prow environment variables.
AWS_SERVICE=$(echo "$REPO_NAME" | rev | cut -d"-" -f2- | rev | tr '[:upper:]' '[:lower:]')
VERSION=$PULL_BASE_REF

# Important Directory references based on prowjob configuration.
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SCRIPTS_DIR=$DIR
CD_DIR=$DIR/..
TEST_INFRA_DIR=$CD_DIR/..
WORKSPACE_DIR=$TEST_INFRA_DIR/..
SERVICE_CONTROLLER_DIR="$WORKSPACE_DIR/$AWS_SERVICE-controller"

# Check all the dependencies are present in container.
source "$SCRIPTS_DIR"/lib/common.sh
check_is_installed buildah
check_is_installed git

if [[ $PULL_BASE_REF = stable ]]; then
  pushd "$WORKSPACE_DIR"/"$AWS_SERVICE"-controller 1>/dev/null
  echo "Triggering for the stable branch"
  _semver_tag=$(git describe --tags --abbrev=0 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    echo "Unable to find semver tag on the 'stable' branch"
    exit 2
  fi
  echo "Semver tag on stable branch is $_semver_tag"

  if ! (echo "$_semver_tag" | grep -Eq "^v[0-9]+\.[0-9]+\.[0-9]+$"); then
    echo "semver tag on stable branch should have format ^v[0-9]+\.[0-9]+\.[0-9]+$"
    exit 2
  fi

  _major_version=$(echo "$_semver_tag" | cut -d"." -f1)
  if [[ -z "$_major_version" ]]; then
    echo "Unable to determine major version from latest semver tag on 'stable' branch"
    exit 2
  fi

  VERSION="$_major_version-stable"
  popd 1>/dev/null
fi

echo "VERSION is $VERSION"

# Setup the destination repository for buildah
perform_red_hat_connect_login

# Get Red Hat Connect Project ID
DEFAULT_RED_HAT_OSPID="unknown"
TARGET_RED_HAT_OSPID=$(get_red_hat_ospid $AWS_SERVICE-bundle)
RED_HAT_OSPID=${TARGET_OSPID:-"$DEFAULT_OSPID"}

if [[ "$RED_HAT_OSPID" == "unknown" ]]; then
  echo "Refusing to attempt to publish with an unknown Red Hat OSP-ID"
  exit 2
fi

# Do not rebuild controller image for stable releases
if ! (echo "$VERSION" | grep -Eq "stable$"); then
  # Determine parameters for docker-build command
  pushd "$WORKSPACE_DIR"/"$AWS_SERVICE"-controller 1>/dev/null

  SERVICE_CONTROLLER_GIT_COMMIT=$(git rev-parse HEAD)
  QUIET=${QUIET:-"false"}
  BUILD_DATE=$(date +%Y-%m-%dT%H:%M)
  CONTROLLER_IMAGE_DOCKERFILE_PATH=$CD_DIR/olm/bundle.Dockerfile

  DEFAULT_DOCKER_REPOSITORY="scan.connect.redhat.com"
  DOCKER_REPOSITORY=${DOCKER_REPOSITORY:-"$DEFAULT_DOCKER_REPOSITORY"}

  AWS_SERVICE_DOCKER_IMG_NAME="$AWS_SERVICE-controller"
  DEFAULT_AWS_SERVICE_DOCKER_IMG_TAG="$AWS_SERVICE_DOCKER_IMG_NAME:$AWS_SERVICE${VERSION}"
  AWS_SERVICE_DOCKER_IMG_TAG=${AWS_SERVICE_DOCKER_IMG_TAG:-"$DEFAULT_AWS_SERVICE_DOCKER_IMG_TAG"}
  AWS_SERVICE_DOCKER_IMG=${AWS_SERVICE_DOCKER_IMG:-"$DOCKER_REPOSITORY/$RED_HAT_OSPID:$AWS_SERVICE_DOCKER_IMG_TAG"}
  DOCKER_BUILD_CONTEXT="$WORKSPACE_DIR"

  popd 1>/dev/null

  cd "$WORKSPACE_DIR"

  if [[ $QUIET = "false" ]]; then
      echo "building '$AWS_SERVICE' controller docker image with tag: ${AWS_SERVICE_DOCKER_IMG}"
      echo " git commit: $SERVICE_CONTROLLER_GIT_COMMIT"
  fi

  # build controller image
  buildah bud \
    --quiet="$QUIET" \
    -t "$AWS_SERVICE_DOCKER_IMG" \
    -f "$CONTROLLER_IMAGE_DOCKERFILE_PATH" \
    --build-arg service_alias="$AWS_SERVICE" \
    --build-arg service_controller_git_version="$VERSION" \
    --build-arg service_controller_git_commit="$SERVICE_CONTROLLER_GIT_COMMIT" \
    --build-arg build_date="$BUILD_DATE" \
    "${DOCKER_BUILD_CONTEXT}"

  if [ $? -ne 0 ]; then
    exit 2
  fi

  echo "Pushing '$AWS_SERVICE' controller image with tag: ${AWS_SERVICE_DOCKER_IMG_TAG}"

  buildah push "${AWS_SERVICE_DOCKER_IMG}"

  if [ $? -ne 0 ]; then
    exit 2
  fi
fi
