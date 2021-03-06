#!/usr/bin/env bash

set -euo pipefail

image="cockroachdb/builder"

# Grab the builder tag from the acceptance tests. We're looking for a
# variable named builderTag, splitting the line on double quotes (")
# and taking the second component.
version=$(awk -F\" '/builderTag *=/ {print $2}' \
            "$(dirname "${0}")"/../pkg/acceptance/cluster/localcluster.go)
if [ -z "${version}" ]; then
  echo "unable to determine builder tag"
  exit 1
fi

function init() {
  docker build --tag="${image}" "$(dirname "${0}")"
}

if [ "${1-}" = "pull" ]; then
  docker pull "${image}"
  exit 0
fi

if [ "${1-}" = "init" ]; then
  init
  exit 0
fi

if [ "${1-}" = "push" ]; then
  init
  tag="$(date +%Y%m%d-%H%M%S)"
  docker tag "${image}" "${image}:${tag}"
  docker push "${image}:${tag}"
  exit 0
fi

if [ "${1-}" = "version" ]; then
  echo "${version}"
  exit 0
fi

gopath0="${GOPATH%%:*}"
gocache=${GOCACHEPATH-$gopath0}

if [ -t 0 ]; then
  tty="--tty"
fi

# Absolute path to the toplevel cockroach directory.
cockroach_toplevel="$(dirname "$(cd "$(dirname "${0}")"; pwd)")"

# Ensure the artifact sub-directory always exists and redirect
# temporary file creation to it, so that CI always picks up temp files
# (including stray log files).
mkdir -p "${cockroach_toplevel}"/artifacts
export TMPDIR=$cockroach_toplevel/artifacts

# Make a fake passwd file for the invoking user.
#
# This setup is so that files created from inside the container in a mounted
# volume end up being owned by the invoking user and not by root.
# We'll mount a fresh directory owned by the invoking user as /root inside the
# container because the container needs a $HOME (without one the default is /)
# and because various utilities (e.g. bash writing to .bash_history) need to be
# able to write to there.
container_home="/root"
host_home="${cockroach_toplevel}/build/builder_home"
passwd_file="${host_home}/passwd"
username=$(id -un)
uid_gid="$(id -u):$(id -g)"
mkdir -p "${host_home}"
echo "${username}:x:${uid_gid}::${container_home}:/bin/bash" > "${passwd_file}"

# Ensure that all directories to which the container must be able to write are
# created as the invoking user. Docker would otherwise create them when
# mounting, but that would deny write access to the invoking user since docker
# runs as root.
mkdir -p "${HOME}"/.yarn-cache "${gocache}"/pkg/docker_amd64{,_msan,_musl,_race} "${gocache}/bin/docker_amd64"

# Since we're mounting both /root and its subdirectories in our container,
# Docker will create the subdirectories on the host side under the directory
# that we're mounting as /root, as the root user. This creates problems for CI
# processes trying to clean up the working directory, so we create them here
# as the invoking user to avoid root-owned paths.
#
# Note: this only happens on Linux. On Docker for Mac, the directories are
# still created, but they're owned by the invoking user already. See
# https://github.com/docker/docker/issues/26051.
mkdir -p "${host_home}"/.yarn-cache

# Run our build container with a set of volumes mounted that will
# allow the container to store persistent build data on the host
# computer.
#
# This script supports both circleci and development hosts, so it must
# support cases where the architecture inside the container is
# different from that outside the container. We can map /src/ directly
# into the container because it is architecture-independent. We then
# map certain subdirectories of ${GOPATH}/pkg into both ${GOPATH}/pkg
# and ${GOROOT}/pkg. The ${GOROOT} mapping is needed so they can be
# used to cache builds of the standard library. /bin/ is mapped
# separately to avoid clobbering the host's binaries. Note that the
# path used for the /bin/ mapping is also used in the defaultBinary
# function of localcluster.go.
#
# We always map the cockroach source directory that contains this script into
# the container's $GOPATH/src. By default, we also mount the host's $GOPATH/src
# directory to the container's $GOPATH/src. That behavior can be turned off by
# setting BUILDER_HIDE_GOPATH_SRC to 1, which results in only the cockroach
# source code (and its vendored dependencies) being available within the
# container. This setting is useful to prevent missing vendored dependencies
# from being accidentally resolved to the hosts's copy of those dependencies.

vols=""
vols="${vols} --volume=${passwd_file}:/etc/passwd"
vols="${vols} --volume=${host_home}:${container_home}"
if [ "${BUILDER_HIDE_GOPATH_SRC:-}" != "1" ]; then
  vols="${vols} --volume=${gopath0}/src:/go/src"
fi
vols="${vols} --volume=${cockroach_toplevel}:/go/src/github.com/cockroachdb/cockroach"
vols="${vols} --volume=${gocache}/pkg/docker_amd64:/go/pkg/linux_amd64"
vols="${vols} --volume=${gocache}/pkg/docker_amd64_msan:/go/pkg/linux_amd64_msan"
vols="${vols} --volume=${gocache}/pkg/docker_amd64_musl:/go/pkg/linux_amd64_musl"
vols="${vols} --volume=${gocache}/pkg/docker_amd64_race:/go/pkg/linux_amd64_race"
vols="${vols} --volume=${gocache}/pkg/docker_amd64:/usr/local/go/pkg/linux_amd64"
vols="${vols} --volume=${gocache}/pkg/docker_amd64_msan:/usr/local/go/pkg/linux_amd64_msan"
vols="${vols} --volume=${gocache}/pkg/docker_amd64_musl:/usr/local/go/pkg/linux_amd64_musl"
vols="${vols} --volume=${gocache}/pkg/docker_amd64_race:/usr/local/go/pkg/linux_amd64_race"
vols="${vols} --volume=${gocache}/bin/docker_amd64:/go/bin"
vols="${vols} --volume=${HOME}/.yarn-cache:${container_home}/.yarn-cache"

backtrace_dir="${cockroach_toplevel}/../../cockroachlabs/backtrace"
if test -d "${backtrace_dir}"; then
  vols="${vols} --volume=${backtrace_dir}:/opt/backtrace"
  vols="${vols} --volume=${backtrace_dir}/cockroach.cf:${container_home}/.coroner.cf"
fi

# If we're running in an environment that's using git alternates, like TeamCity,
# we must mount the path to the real git objects for git to work in the container.
alternates_file="${cockroach_toplevel}/.git/objects/info/alternates"
if test -e "${alternates_file}"; then
  alternates_path=$(cat "${alternates_file}")
  vols="${vols} --volume=${alternates_path}:${alternates_path}"
fi

# -i causes some commands (including `git diff`) to attempt to use
# a pager, so we override $PAGER to disable.

# shellcheck disable=SC2086
docker run --privileged -i ${tty-} --rm \
  -u "${uid_gid}" \
  ${vols} \
  --workdir="/go/src/github.com/cockroachdb/cockroach" \
  --env="TMPDIR=/go/src/github.com/cockroachdb/cockroach/artifacts" \
  --env="PAGER=cat" \
  --env="GOTRACEBACK=${GOTRACEBACK-all}" \
  "${image}:${version}" "${@-bash}"
