#!/bin/bash
# shellcheck disable=SC1091

################################################################################
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################

set -eu

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# shellcheck source=sbin/common/config_init.sh
source "$SCRIPT_DIR/sbin/common/config_init.sh"

# shellcheck source=sbin/common/constants.sh
source "$SCRIPT_DIR/sbin/common/constants.sh"

# shellcheck source=sbin/common/common.sh
source "$SCRIPT_DIR/sbin/common/common.sh"

ARCHIVE=""
SIGNING_CERTIFICATE=""
WORKSPACE=$(pwd)
TMP_DIR_NAME="tmp"
TMP_DIR="${WORKSPACE}/${TMP_DIR_NAME}/"

# List of valid timestamp servers:
# http://timestamp.comodoca.com/authenticode -> OK 02/08/2030 -> Sectigo RSA Time Stamping Signer #1
# http://timestamp.sectigo.com -> OK 02/08/2030 -> Sectigo RSA Time Stamping Signer #1 .. same as previous but with another url
# http://timestamp.comodoca.com/rfc3161 -> OK 02/08/2030 -> Sectigo RSA Time Stamping Signer #1 .. same as previous but with another url
# http://tsa.startssl.com/rfc3161 -> OK 15/08/2028 -> WoSign Time Stamping Signer ( buyed by WoTrus )
# http://tsa.starfieldtech.com -> OK 17/09/2027 -> Starfield Timestamp Authority - G2
# http://timestamp.globalsign.com/scripts/timstamp.dll -> OK 24/06/2027 -> GlobalSign TSA for MS Authenticode - G2
# http://timestamp.digicert.com -> OK 22/10/2024 -> DigiCert Timestamp Responder
TIMESTAMP_SERVER_CONFIG="./serverTimestamp.properties"

checkSignConfiguration() {
  if [[ "${OPERATING_SYSTEM}" == "windows" ]] ; then
    if [ ! -f "${SIGNING_CERTIFICATE}" ]
    then
      echo "Could not find certificate at: ${SIGNING_CERTIFICATE}"
      exit 1
    fi

    if [ -z "${SIGN_PASSWORD+x}" ]
    then
      echo "If signing is enabled on window you must set SIGN_PASSWORD"
      exit 1
    fi
  fi
}

# Sign the built binary
signRelease()
{
  TIMESTAMPSERVERS=$(cut -d= -f2 < "$WORKSPACE/$TIMESTAMP_SERVER_CONFIG" | tr -d \\\\r)

  case "$OPERATING_SYSTEM" in
    "windows")
      echo "Signing Windows release"
      signToolPath=${signToolPath:-"/cygdrive/c/Program Files (x86)/Windows Kits/10/bin/10.0.17763.0/x64/signtool.exe"}

      # Sign .exe files
      FILES=$(find . -type f -name '*.exe' -o -name '*.dll')
      for f in $FILES
      do
        echo "Signing ${f}"
        if [ "$SIGN_TOOL" = "eclipse" ]; then
          echo "Signing $f using Eclipse Foundation codesign service"
          dir=$(dirname "$f")
          file=$(basename "$f")
          mv "$f" "${dir}/unsigned_${file}"
          curl -o "$f" -F file="@${dir}/unsigned_${file}" https://cbi.eclipse.org/authenticode/sign
          chmod --reference="${dir}/unsigned_${file}" "$f"
          rm -rf "${dir}/unsigned_${file}"
        else
          STAMPED=false
          for SERVER in $TIMESTAMPSERVERS; do
            if [ "$STAMPED" = "false" ]; then
              echo "Signing $f using $SERVER"
              if [ "$SIGN_TOOL" = "ucl" ]; then
                ucl sign-code --file "$f" -n WindowsSHA -t "${SERVER}" --hash SHA256
              else
                "$signToolPath" sign /f "${SIGNING_CERTIFICATE}" /p "$SIGN_PASSWORD" /fd SHA256 /t "${SERVER}" "$f"
              fi
              RC=$?
              if [ $RC -eq 0 ]; then
                STAMPED=true
              else
                echo "RETRYWARNING: Failed to sign ${f} at $(date +%T): Possible timestamp server error at ${SERVER} - Trying new server in 5 seconds"
                sleep 2
              fi
            fi
          done
          if [ "$STAMPED" = "false" ]; then
            echo "Failed to sign ${f} using any time server - aborting"
            exit 1
          fi
        fi
      done
    ;;

    "mac"*)
      # TODO: Remove this completly once https://github.com/adoptium/openjdk-jdk11u/commit/b3250adefed0c1778f38a7e221109ae12e7c421e has been backported to JDK8u
      echo "Signing OSX release"

      ENTITLEMENTS="$WORKSPACE/entitlements.plist"
      # Sign all files with the executable permission bit set.
      FILES=$(find "${TMP_DIR}" -perm +111 -type f -o -name '*.dylib'  -type f || find "${TMP_DIR}" -perm /111 -type f -o -name '*.dylib'  -type f)

      if [ "$SIGN_TOOL" = "eclipse" ]; then
        for f in $FILES
        do
          echo "Signing $f using Eclipse Foundation codesign service"
          dir=$(dirname "$f")
          file=$(basename "$f")
          mv "$f" "${dir}/unsigned_${file}"
          curl -o "$f" -F file="@${dir}/unsigned_${file}" -F entitlements="@$ENTITLEMENTS" https://cbi.eclipse.org/macos/codesign/sign
          chmod --reference="${dir}/unsigned_${file}" "$f"
          rm -rf "${dir}/unsigned_${file}"
        done
        JDK_DIR=$(ls -d "${TMP_DIR}"/jdk*)
        JDK=$(basename "${JDK_DIR}")
        ENTITLEMENTS="${JDK_DIR}/Contents/Info.plist"   
        cd "${TMP_DIR}"
        zip -q -r "${TMP_DIR}/unsigned.zip" "${JDK}"
        cd -
        curl -o "${TMP_DIR}/signed.zip" -F file="@${TMP_DIR}/unsigned.zip" -F entitlements="@$ENTITLEMENTS" https://cbi.eclipse.org/macos/codesign/sign
        rm -rf "${JDK_DIR}"
        unzip -q -d "${TMP_DIR}" "${TMP_DIR}/signed.zip"
      else
        # Login to KeyChain
        # shellcheck disable=SC2046
        # shellcheck disable=SC2006
        security unlock-keychain -p `cat ~/.password` login.keychain-db
        xattr -cr .
        # If you're using this script, make sure to update the certificate with your developer application ID
        echo "$FILES" | while read -r f; do codesign --entitlements "$ENTITLEMENTS" --options runtime --timestamp --sign "Developer ID Application: XXX" "$f"; done
      fi
      ;;

    "linux"*)
      echo "Signing Linux release"

      # Sign all executables files in bin and lib and all shared libraries
      FILES=$(find . -type f -executable -o -name *.so )

      if [ "$SIGN_TOOL" = "ucl" ]; then
        for f in $FILES
        do
            echo "Signing ${f}"
            ucl sign --hash SHA256 -n WindowsSHA -i "${f}" -o "${f}.sig"
        done
      else
        echo "Unknow $SIGN_TOOL, skipping code signing on $OPERATING_SYSTEM"
      fi
      ;;

    *)
      echo "Skipping code signing as it's not supported on $OPERATING_SYSTEM"
      ;;
  esac
}

function parseArguments() {
  parseConfigurationArguments "$@"

  while [[ $# -gt 1 ]] ; do
    shift;
  done

  ARCHIVE="$1";
  SIGNING_CERTIFICATE=""

  if [[ $# -ge 2 ]]; then
    SIGNING_CERTIFICATE="$2";
  fi
}

function extractArchive {
  rm -rf "${TMP_DIR}" || true
  mkdir "${TMP_DIR}"
  if [[ "${OPERATING_SYSTEM}" == "windows" ]]; then
    unzip -q "${ARCHIVE}" -d "${TMP_DIR}"
  elif [[ "${OPERATING_SYSTEM}" == "mac" ]] || [[ "${OPERATING_SYSTEM}" == "linux" ]]; then
    gunzip -dc "${ARCHIVE}" | tar xf - -C "${TMP_DIR}"
  else
    echo "could not detect archive type"
    exit 1
  fi
}

if [ "${OPERATING_SYSTEM}" != "windows" ] && [ "${OPERATING_SYSTEM}" != "mac" ] && [ "${OPERATING_SYSTEM}" != "linux" ]; then
  echo "Skipping code signing as it's not supported on ${OPERATING_SYSTEM}"
  exit 0;
fi

configDefaults
parseArguments "$@"
extractArchive

if [ "${OPERATING_SYSTEM}" = "windows" ]; then
  # this is because the windows signing is performed by a Linux machine now. It needs this variable set to know to create a zipfile instead of a tarball
  BUILD_CONFIG[OS_KERNEL_NAME]="cygwin"
fi

# Set jdkDir to the top level directory from the tarball/zipball
# shellcheck disable=SC2012
jdkDir=$(ls -1 "${TMP_DIR}" | head -1 | xargs basename)

cd "${TMP_DIR}/${jdkDir}" || exit 1
signRelease

cd "${TMP_DIR}"
createOpenJDKArchive "${jdkDir}" "OpenJDK"
archiveExtension=$(getArchiveExtension)
signedArchive="${TMP_DIR}/OpenJDK${archiveExtension}"

cd "${WORKSPACE}"
mv "${signedArchive}" "${ARCHIVE}"

if [ "$OPERATING_SYSTEM" = "linux" ] && [ "$SIGN_TOOL" = "ucl" ]; then
    # sign the tarball
    echo "Sign archive ${ARCHIVE}"
    ucl sign --hash SHA256 -n WindowsSHA -i "${ARCHIVE}" -o "${ARCHIVE}.sig"
fi

rm -rf "${TMP_DIR}"
