#!/bin/sh

. /etc/os-release
. /etc/openwrt_release
. /etc/device_info

SYSUPGRADE_PATH=${SYSUPGRADE_PATH:-"/etc/sysupgrade"}
USER_INSTALLED_PACKAGES_FILE=${USER_INSTALLED_PACKAGES_FILE:-"user-installed-packages"}

SYSUPGRADE_OS_ID=${SYSUPGRADE_OS_ID:-${ID}}
SYSUPGRADE_VERSION=${SYSUPGRADE_VERSION:-}
SYSUPGRADE_TARGET=${SYSUPGRADE_TARGET:-${DISTRIB_TARGET}}
SYSUPGRADE_MAKE=${SYSUPGRADE_MAKE:-${DEVICE_MANUFACTURER}}
SYSUPGRADE_MODEL=${SYSUPGRADE_MODEL:-${DEVICE_PRODUCT}}

if [ "${SYSUPGRADE_MAKE}" = "OpenWrt" ] && [ "${SYSUPGRADE_MODEL}" = "Generic" ]; then
  SYSUPGRADE_MAKE=$(cat /tmp/sysinfo/model | cut -d" " -f1)
  SYSUPGRADE_MODEL=$(cat /tmp/sysinfo/model | cut -d" " -f2)
fi

SYSUPGRADE_MAKE=$(echo "${SYSUPGRADE_MAKE}" | awk '{print tolower($0)}')
SYSUPGRADE_MODEL=$(echo "${SYSUPGRADE_MODEL}" | awk '{print tolower($0)}')

SYSUPGRADE_TARGET_DASH=${SYSUPGRADE_TARGET_DASH:-$(echo ${SYSUPGRADE_TARGET} | sed -e "s/\//-/")}

USER_INSTALLED_PACKAGES_FILE_PATH=${USER_INSTALLED_PACKAGES_FILE_PATH:-"${SYSUPGRADE_PATH}/${USER_INSTALLED_PACKAGES_FILE}"}

SYSUPGRADE_FILENAME="${SYSUPGRADE_OS_ID}-${SYSUPGRADE_VERSION}-${SYSUPGRADE_TARGET_DASH}-${SYSUPGRADE_MAKE}_${SYSUPGRADE_MODEL}-squashfs-sysupgrade.bin"
SYSUPGRADE_URL=${SYSUPGRADE_URL:-"http://downloads.openwrt.org/releases/${SYSUPGRADE_VERSION}/targets/${SYSUPGRADE_TARGET}/${SYSUPGRADE_FILENAME}"}
SYSUPGRADE_HASHES_URL=${SYSUPGRADE_HASHES_URL:-"http://downloads.openwrt.org/releases/${SYSUPGRADE_VERSION}/targets/${SYSUPGRADE_TARGET}/sha256sums"}

SYSUPGRADE_LOGGER_TAG=${SYSUPGRADE_LOGGER_TAG:-$(basename ${0} | cut -d. -f1)}

log() {
  echo $@
  logger -t "sysupgrade.${SYSUPGRADE_LOGGER_TAG}" "$@"
}

askYesNo() {
  prompt=${1:-'Do you wish to continue? [y/n] : '}
  while true; do
    read -p "${prompt}" yn
    case $yn in
      [Yy]* ) return 0;;
      [Nn]* ) return 1;;
      * ) echo 'Please answer y or n.';;
    esac
  done
}

getUserInstalledPackages() {
  logger "Getting user-installed packages"
  kernel_install_time="$(opkg status kernel | grep Installed-Time | sed "s/Installed-Time: //")";
  opkg info | awk -v kernel_install_time="${kernel_install_time}" -v RS="" -v FS=$'\n' -v OFS=$'\t' '{ delete vars; for(i = 1; i <= NF; ++i) { n = index($i, ": "); if(n) { key = substr($i, 1, n - 1); value = substr($i, n + 2); vars[key] = value } } } { if (vars["Installed-Time"] && vars["Installed-Time"] > kernel_install_time && index(vars["Status"], "user")) { print vars["Package"] } }' | sort
}

writeUserInstalledPackagesToFile() {
  logger "Writing user-installed packages to file"
  getUserInstalledPackages > "${USER_INSTALLED_PACKAGES_FILE}"
}

verifyChecksum() {
  logger "Verifying checksum: ${1}"
  grep "${1}" "${2}" | sha256sum -c
}

doSysupgrade() {

  log "Starting sysupgrade"

  if [ -z "${SYSUPGRADE_VERSION}" ]; then
    log "No target version given."
    echo "SYSUPGRADE_VERSION=<target version> $0"
    exit
  fi

  log "Detected details (these must match the details in your device URL for the sysupgrade to perform properly)"

  log "Device OS           : ${SYSUPGRADE_OS_ID}"
  log "Device Manufacturer : ${SYSUPGRADE_MAKE}"
  log "Device Model        : ${SYSUPGRADE_MODEL}"
  log "Device Target       : ${SYSUPGRADE_TARGET}"
  log "Current Version     : ${VERSION_ID}"
  log "Target Version      : ${SYSUPGRADE_VERSION}"

  if ! askYesNo 'Does this look correct? [y/n] : '; then
    log "User cancelled"
    echo ""
    echo "Device OS           : SYSUPGRADE_OS_ID   : ${SYSUPGRADE_OS_ID}"
    echo "Device Manufacturer : SYSUPGRADE_MAKE    : ${SYSUPGRADE_MAKE}"
    echo "Device Model        : SYSUPGRADE_MODEL   : ${SYSUPGRADE_MODEL}"
    echo "Device Target       : SYSUPGRADE_TARGET  : ${SYSUPGRADE_TARGET}"
    echo "Current Version     : VERSION_ID         : ${VERSION_ID}"
    echo "Target Version      : SYSUPGRADE_VERSION : ${SYSUPGRADE_VERSION}"
    echo ""
    echo 'use `ENV_VAR=<value> $0` to change sysupgrade parameters'
    echo ""
    echo "e.g. SYSUPGRADE_VERSION=18.06.5 $0"
    return 1
  fi

  log ${SYSUPGRADE_URL}
  log ${SYSUPGRADE_HASHES_URL}

  cd /tmp
  curl "${SYSUPGRADE_URL}" --output "${SYSUPGRADE_FILENAME}"
  curl "${SYSUPGRADE_HASHES_URL}" --output "hashes.txt"

  logger "Retrieved update file and hashes"

  if ! verifyChecksum "${SYSUPGRADE_FILENAME}" "hashes.txt"; then
    log "Checksum failed"
    return 1
  fi

  log "Checksum passed"

  sysupgrade -i -v "${SYSUPGRADE_FILENAME}"
}

SYSUPGRADE_WAN_SCRIPT_FILE_PATH="/etc/hotplug.d/iface/99-ifup-wan-opkg-reinstall"

removeWanUpScript() {
  log "Removing WAN script"
  rm -f "${SYSUPGRADE_WAN_SCRIPT_FILE_PATH}"
}

createWanUpScript() {
  log "Creating WAN script"
  cat<<'EOF' > "${SYSUPGRADE_WAN_SCRIPT_FILE_PATH}"
#!/bin/sh
. /etc/sysupgrade/common.sh
[ "$ACTION" = "ifup" -a "$INTERFACE" = "wan" ] && {
    log "ifup detected on wan, running post sysupgrade actions"
    sh -x /etc/sysupgrade/post.sh
}
exit 0
EOF
}

installPackagesFromFile() {
  packages=$(cat "${USER_INSTALLED_PACKAGES_FILE_PATH}" | sed -e "s/\n/ /")
  log "Reinstalling packages from file: ${packages}"
  opkg update && opkg install $packages
}
