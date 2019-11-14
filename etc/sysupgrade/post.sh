#!/bin/sh

. /etc/sysupgrade/common.sh

installPackagesFromFile && removeWanUpScript && reboot
