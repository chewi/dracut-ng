#!/bin/bash

# called by dracut
check() {
    swap_on_netdevice() {
        local _dev
        for _dev in "${swap_devs[@]}"; do
            block_is_netdevice "$(get_maj_min "$_dev")" && return 0
        done
        return 1
    }

    # If hostonly check if we want to include the resume module
    if [[ ${hostonly-} ]] || [[ $mount_needs ]]; then
        # Resuming won't work if swap is on a netdevice
        swap_on_netdevice && return 255
        if grep -rq 'resume=' /proc/cmdline /etc/cmdline /etc/cmdline.d /etc/kernel/cmdline /usr/lib/kernel/cmdline 2> /dev/null; then
            # hibernation support requested on kernel command line
            return 0
        else
            # resume= not set on kernel command line
            if [[ -f /sys/power/resume ]]; then
                if [[ "$(< /sys/power/resume)" == "0:0" ]]; then
                    # hibernation supported by the kernel, but not enabled
                    return 255
                else
                    # hibernation supported by the kernel and enabled
                    return 0
                fi
            else
                # resume file doesn't exist, hibernation not supported by kernel
                return 255
            fi
        fi
    else
        return 0
    fi
}

# called by dracut
depends() {
    if ! dracut_module_included "systemd"; then
        echo initqueue
    fi
    return 0
}

# called by dracut
cmdline() {
    local _resume

    for dev in "${!host_fs_types[@]}"; do
        [[ ${host_fs_types[$dev]} =~ ^(swap|swsuspend|swsupend)$ ]] || continue
        _resume=$(shorten_persistent_dev "$(get_persistent_dev "$dev")")
        [[ -n ${_resume} ]] && printf " resume=%s" "${_resume}"
    done
}

# called by dracut
install() {
    local _bin
    local _resumeconf

    if [[ $hostonly_cmdline == "yes" ]]; then
        _resumeconf=$(cmdline)
        [[ $_resumeconf ]] && printf "%s\n" "$_resumeconf" >> "${initdir}/etc/cmdline.d/95resume.conf"
    fi

    # if systemd is included and has the hibernate-resume tool, use it and nothing else
    if dracut_module_included "systemd" && [[ -x "${dracutsysrootdir-}$systemdutildir/systemd-hibernate-resume" ]]; then
        inst_multiple -o \
            "$systemdutildir"/system-generators/systemd-hibernate-resume-generator \
            "$systemdsystemunitdir"/systemd-hibernate-resume.service \
            "$systemdsystemunitdir"/systemd-hibernate-resume@.service \
            "$systemdutildir"/systemd-hibernate-resume
        return 0
    fi

    # Optional uswsusp support
    for _bin in /usr/sbin/resume /usr/lib/suspend/resume /usr/lib64/suspend/resume /usr/lib/uswsusp/resume /usr/lib64/uswsusp/resume; do
        [[ -x "${dracutsysrootdir-}${_bin}" ]] && {
            inst "${_bin}" /usr/sbin/resume
            [[ ${hostonly-} ]] && [[ -f "${dracutsysrootdir-}/etc/suspend.conf" ]] && inst -H /etc/suspend.conf
            break
        }
    done

    if ! dracut_module_included "systemd"; then
        inst_hook cmdline 10 "$moddir/parse-resume.sh"
    else
        inst_script "$moddir/parse-resume.sh" /lib/dracut/parse-resume.sh
    fi

    inst_script "$moddir/resume.sh" /lib/dracut/resume.sh
}
