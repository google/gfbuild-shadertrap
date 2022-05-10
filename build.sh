#!/usr/bin/env bash

# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -x
set -e
set -u

WORK="$(pwd)"

help | head

uname

case "$(uname)" in
"Linux")
  NINJA_OS="linux"
  BUILD_PLATFORM="Linux_x64"
  PYTHON="python3"
  # Needed to get EGL
  sudo DEBIAN_FRONTEND=noninteractive apt-get -qy install libegl1-mesa-dev
  df -h
  sudo swapoff -a
  sudo rm -f /swapfile
  sudo apt clean
  # shellcheck disable=SC2046
  docker rmi $(docker image ls -aq)
  df -h
  ;;

"MINGW"*|"MSYS_NT"*)
  NINJA_OS="win"
  BUILD_PLATFORM="Windows_x64"
  PYTHON="python.exe"
  ;;

*)
  echo "Unknown OS"
  exit 1
  ;;
esac

TARGET_REPO_ORG="google"
TARGET_REPO_NAME="shadertrap"
BUILD_REPO_ORG="google"
BUILD_REPO_NAME="gfbuild-shadertrap"

COMMIT_ID="$(cat "${WORK}/COMMIT_ID")"

ARTIFACT="${BUILD_REPO_NAME}"
ARTIFACT_VERSION="${COMMIT_ID}"
GROUP_DOTS="github.${BUILD_REPO_ORG}"
GROUP_SLASHES="github/${BUILD_REPO_ORG}"
TAG="${GROUP_SLASHES}/${ARTIFACT}/${ARTIFACT_VERSION}"

BUILD_REPO_SHA="${GITHUB_SHA}"
POM_FILE="${BUILD_REPO_NAME}-${ARTIFACT_VERSION}.pom"
# We append Release or Debug to INSTALL_DIR_PREFIX
INSTALL_DIR_PREFIX="${ARTIFACT}-${ARTIFACT_VERSION}-${BUILD_PLATFORM}_"
SHADERTRAP_NDK_INSTALL_DIR="${ARTIFACT}-${ARTIFACT_VERSION}-android_ndk"

export PATH="${HOME}/bin:$PATH"

mkdir -p "${HOME}/bin"

pushd "${HOME}/bin"

# Install github-release-retry.
"${PYTHON}" -m pip install --user 'github-release-retry==1.*'

# Install ninja.
curl -fsSL -o ninja-build.zip "https://github.com/ninja-build/ninja/releases/download/v1.9.0/ninja-${NINJA_OS}.zip"
unzip ninja-build.zip

ls

popd

git clone https://github.com/${TARGET_REPO_ORG}/${TARGET_REPO_NAME}.git "${TARGET_REPO_NAME}"
cd "${TARGET_REPO_NAME}"
git checkout "${COMMIT_ID}"
git submodule update --init

case "$(uname)" in
"Linux")
  # Source the dev shell to download clang-tidy and other tools.
  # Developers should *run* the dev shell, but we want to continue executing this script.
  export SHADERTRAP_SKIP_BASH=1

  # Skip additional checks after building. These are part of ShaderTrap CI, and
  # are not necessary when releasing.
  export SHADERTRAP_SKIP_CHECK_COMPILE_COMMANDS=1

  source ./dev_shell.sh.template

  check_build.sh
  ;;

"MINGW"*|"MSYS_NT"*)
  # Needed to get EGL
  mkdir -p "${HOME}/angle-release"
  pushd "${HOME}/angle-release"
    curl -fsSL -o angle-release.zip https://github.com/paulthomson/build-angle/releases/download/v-592879ad24e66c7c68c3a06d4e2227630520da36/MSVC2015-Release-x64.zip
    unzip angle-release.zip
    ls
  popd
  export CMAKE_PREFIX_PATH="${HOME}/angle-release"
  CMAKE_OPTIONS+=("-DCMAKE_C_COMPILER=cl.exe" "-DCMAKE_CXX_COMPILER=cl.exe")
  for config in "Debug" "Release"; do
    mkdir "temp/build-${config}"
    pushd "temp/build-${config}"
      cmake -G Ninja .. -DCMAKE_BUILD_TYPE="${CONFIG}" "${CMAKE_OPTIONS[@]}"
      cmake --build . --config "${CONFIG}"
      cmake -DCMAKE_INSTALL_PREFIX=./install -DBUILD_TYPE="${CONFIG}" -P cmake_install.cmake
    popd
  done
  ;;

*)
  echo "Unknown OS"
  exit 1
  ;;
esac

GRAPHICSFUZZ_COMMIT_SHA="b82cf495af1dea454218a332b88d2d309657594d"
OPEN_SOURCE_LICENSES_URL="https://github.com/google/gfbuild-graphicsfuzz/releases/download/github/google/gfbuild-graphicsfuzz/${GRAPHICSFUZZ_COMMIT_SHA}/OPEN_SOURCE_LICENSES.TXT"

# Get licenses file.
curl -fsSL -o OPEN_SOURCE_LICENSES.TXT "${OPEN_SOURCE_LICENSES_URL}"

for config in "Debug" "Release"; do
  INSTALL_DIR="${INSTALL_DIR_PREFIX}${config}"
  mkdir -p "${INSTALL_DIR}/bin"
  cp "temp/build-${config}/src/shadertrap/shadertrap" "${INSTALL_DIR}/bin/"

  case "$(uname)" in
  "Linux")
    ;;

  "MINGW"*|"MSYS_NT"*)
    # Required as EGL is not available on Windows in a standard way.
    cp "${HOME}/angle-release/libEGL.dll" "${INSTALL_DIR}/bin/"
    ;;

  *)
    echo "Unknown OS"
    exit 1
    ;;
  esac

  cp OPEN_SOURCE_LICENSES.TXT "${INSTALL_DIR}/"

  # zip file.
  pushd "${INSTALL_DIR}"
  zip -r "../${INSTALL_DIR}.zip" ./*
  popd

  sha1sum "${INSTALL_DIR}.zip" >"${INSTALL_DIR}.zip.sha1"

done

# POM file.
sed -e "s/@GROUP@/${GROUP_DOTS}/g" -e "s/@ARTIFACT@/${ARTIFACT}/g" -e "s/@VERSION@/${ARTIFACT_VERSION}/g" "../fake_pom.xml" >"${POM_FILE}"

sha1sum "${POM_FILE}" >"${POM_FILE}.sha1"

DESCRIPTION="$(echo -e "Automated build for ${TARGET_REPO_NAME} version ${COMMIT_ID}.\n$(git log --graph -n 3 --abbrev-commit --pretty='format:%h - %s <%an>')")"

# Do the Android zip step when on Linux.
case "$(uname)" in
"Linux")

  mkdir -p "${SHADERTRAP_NDK_INSTALL_DIR}/bin"

  cp "temp/build-android-Debug/src/shadertrap/shadertrap" "${SHADERTRAP_NDK_INSTALL_DIR}/bin/"
  cp OPEN_SOURCE_LICENSES.TXT "${SHADERTRAP_NDK_INSTALL_DIR}/"

  pushd "${SHADERTRAP_NDK_INSTALL_DIR}"
  zip -r "../${SHADERTRAP_NDK_INSTALL_DIR}.zip" ./*
  popd

  sha1sum "${SHADERTRAP_NDK_INSTALL_DIR}.zip" >"${SHADERTRAP_NDK_INSTALL_DIR}.zip.sha1"

  ;;

*)
  echo "Skipping Android zip step."
  ;;
esac

# Only release from main branch commits.
# shellcheck disable=SC2153
if test "${GITHUB_REF}" != "refs/heads/main"; then
  exit 0
fi

# We do not use the GITHUB_TOKEN provided by GitHub Actions.
# We cannot set enviroment variables or secrets that start with GITHUB_ in .yml files,
# but the github-release-retry tool requires GITHUB_TOKEN, so we set it here.
export GITHUB_TOKEN="${GH_TOKEN}"

for config in "Debug" "Release"; do
  INSTALL_DIR="${INSTALL_DIR_PREFIX}${config}"

  "${PYTHON}" -m github_release_retry.github_release_retry \
    --user "${BUILD_REPO_ORG}" \
    --repo "${BUILD_REPO_NAME}" \
    --tag_name "${TAG}" \
    --target_commitish "${BUILD_REPO_SHA}" \
    --body_string "${DESCRIPTION}" \
    "${INSTALL_DIR}.zip"

  "${PYTHON}" -m github_release_retry.github_release_retry \
    --user "${BUILD_REPO_ORG}" \
    --repo "${BUILD_REPO_NAME}" \
    --tag_name "${TAG}" \
    --target_commitish "${BUILD_REPO_SHA}" \
    --body_string "${DESCRIPTION}" \
    "${INSTALL_DIR}.zip.sha1"
done

# Do the Android release step when on Linux.
case "$(uname)" in
"Linux")

  "${PYTHON}" -m github_release_retry.github_release_retry \
    --user "${BUILD_REPO_ORG}" \
    --repo "${BUILD_REPO_NAME}" \
    --tag_name "${TAG}" \
    --target_commitish "${BUILD_REPO_SHA}" \
    --body_string "${DESCRIPTION}" \
    "${SHADERTRAP_NDK_INSTALL_DIR}.zip"

  "${PYTHON}" -m github_release_retry.github_release_retry \
    --user "${BUILD_REPO_ORG}" \
    --repo "${BUILD_REPO_NAME}" \
    --tag_name "${TAG}" \
    --target_commitish "${BUILD_REPO_SHA}" \
    --body_string "${DESCRIPTION}" \
    "${SHADERTRAP_NDK_INSTALL_DIR}.zip.sha1"

  ;;

*)
  echo "Skipping Android release step."
  ;;
esac

# Don't fail if pom cannot be uploaded, as it might already be there.

"${PYTHON}" -m github_release_retry.github_release_retry \
  --user "${BUILD_REPO_ORG}" \
  --repo "${BUILD_REPO_NAME}" \
  --tag_name "${TAG}" \
  --target_commitish "${BUILD_REPO_SHA}" \
  --body_string "${DESCRIPTION}" \
  "${POM_FILE}" || true

"${PYTHON}" -m github_release_retry.github_release_retry \
  --user "${BUILD_REPO_ORG}" \
  --repo "${BUILD_REPO_NAME}" \
  --tag_name "${TAG}" \
  --target_commitish "${BUILD_REPO_SHA}" \
  --body_string "${DESCRIPTION}" \
  "${POM_FILE}.sha1" || true

# Don't fail if OPEN_SOURCE_LICENSES.TXT cannot be uploaded, as it might already be there.

"${PYTHON}" -m github_release_retry.github_release_retry \
  --user "${BUILD_REPO_ORG}" \
  --repo "${BUILD_REPO_NAME}" \
  --tag_name "${TAG}" \
  --target_commitish "${BUILD_REPO_SHA}" \
  --body_string "${DESCRIPTION}" \
  "OPEN_SOURCE_LICENSES.TXT" || true
