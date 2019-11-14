#!/bin/sh

. /etc/sysupgrade/common.sh

writeUserInstalledPackagesToFile && createWanUpScript && doSysupgrade || removeWanUpScript
