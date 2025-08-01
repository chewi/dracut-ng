#!/bin/bash
# This file is part of dracut.
# SPDX-License-Identifier: GPL-2.0-or-later

# Prerequisite check(s) for module.
check() {

    # If the binary(s) requirements are not fulfilled the module can't be installed
    require_binaries "$systemdutildir"/systemd-sysctl || return 1

    # Return 255 to only include the module, if another module requires it.
    return 255
}

# Install the required file(s) for the module in the initramfs.
install() {

    inst_multiple -o \
        /usr/lib/sysctl.d/*.conf \
        "$sysctld/*.conf" \
        "$systemdsystemunitdir"/systemd-sysctl.service \
        "$systemdsystemunitdir"/sysinit.target.wants/systemd-sysctl.service \
        "$systemdutildir"/systemd-sysctl

    # Install the hosts local user configurations if enabled.
    if [[ ${hostonly-} ]]; then
        inst_multiple -H -o \
            /etc/sysctl.conf \
            /etc/sysctl.d/*.conf \
            "$sysctlconfdir/*.conf" \
            "$systemdsystemconfdir"/systemd-sysctl.service \
            "$systemdsystemconfdir/systemd-sysctl.service.d/*.conf"
    fi

    # Enable the systemd type service unit for sysctl.
    $SYSTEMCTL -q --root "$initdir" enable systemd-sysctl.service
}
