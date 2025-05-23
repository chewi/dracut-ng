#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

if [ "$(getarg rd.multipath)" = "default" ] && [ ! -e /etc/multipath.conf ]; then
    # mpathconf requires /etc/multipath to already exist
    mkdir -p /etc/multipath
    mpathconf --enable --user_friendly_names n
fi

if getargbool 1 rd.multipath && [ -e /etc/multipath.conf ]; then
    modprobe dm-multipath
    multipathd -B || multipathd
    need_shutdown
else
    rm -- /etc/udev/rules.d/??-multipath.rules 2> /dev/null
fi
