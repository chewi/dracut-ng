#!/usr/bin/env bash
set -e

[ -z "${USE_NETWORK-}" ] && USE_NETWORK="network"

# shellcheck disable=SC2034
TEST_DESCRIPTION="root filesystem on NFS with $USE_NETWORK"

test_check() {
    if ! type -p dhclient &> /dev/null; then
        echo "Test needs dhclient for server networking... Skipping"
        return 1
    fi

    if ! type -p curl &> /dev/null; then
        echo "Test needs curl for url-lib... Skipping"
        return 1
    fi

    command -v exportfs &> /dev/null
}

# Uncomment this to debug failures
#DEBUGFAIL="rd.debug loglevel=7 rd.break=initqueue rd.shell"
#SERVER_DEBUG="rd.debug loglevel=7"
#SERIAL="unix:/tmp/server.sock"

run_server() {
    # Start server first
    echo "NFS TEST SETUP: Starting DHCP/NFS server"
    declare -a disk_args=()
    # shellcheck disable=SC2034
    declare -i disk_index=0
    qemu_add_drive disk_index disk_args "$TESTDIR"/server.img root 0 1

    "$testdir"/run-qemu \
        "${disk_args[@]}" \
        -net socket,listen=127.0.0.1:12320 \
        -net nic,macaddr=52:54:00:12:34:56,model=virtio \
        -serial "${SERIAL:-"file:$TESTDIR/server.log"}" \
        -append "panic=1 oops=panic softlockup_panic=1 root=LABEL=dracut rootfstype=ext4 rw console=ttyS0,115200n81 ${SERVER_DEBUG-}" \
        -initrd "$TESTDIR"/initramfs.server \
        -pidfile "$TESTDIR"/server.pid -daemonize
    chmod 644 "$TESTDIR"/server.pid

    if ! [[ ${SERIAL-} ]]; then
        wait_for_server_startup
    else
        echo Sleeping 10 seconds to give the server a head start
        sleep 10
    fi
}

client_test() {
    local test_name="$1"
    local mac=$2
    local cmdline="$3"
    local server="$4"
    local check_opt="$5"
    local nfsinfo opts found expected

    echo "CLIENT TEST START: $test_name"

    # Need this so kvm-qemu will boot (needs non-/dev/zero local disk)
    declare -a disk_args=()
    # shellcheck disable=SC2034
    declare -i disk_index=0
    qemu_add_drive disk_index disk_args "$TESTDIR"/marker.img marker 1
    qemu_add_drive disk_index disk_args "$TESTDIR"/marker2.img marker2 1
    cmdline="$cmdline rd.net.timeout.dhcp=30"

    "$testdir"/run-qemu \
        "${disk_args[@]}" \
        -net nic,macaddr="$mac",model=virtio \
        -net socket,connect=127.0.0.1:12320 \
        -append "$TEST_KERNEL_CMDLINE $cmdline ro" \
        -initrd "$TESTDIR"/initramfs.testing

    # shellcheck disable=SC2181
    if [[ $? -ne 0 ]] || ! test_marker_check nfs-OK; then
        echo "CLIENT TEST END: $test_name [FAILED - BAD EXIT]"
        return 1
    fi

    # nfsinfo=( server:/path nfs{,4} options )
    read -r -a nfsinfo < <(awk '{print $2, $3, $4; exit}' "$TESTDIR"/marker.img)

    if [[ ${nfsinfo[0]%%:*} != "$server" ]]; then
        echo "CLIENT TEST INFO: got server: ${nfsinfo[0]%%:*}"
        echo "CLIENT TEST INFO: expected server: $server"
        echo "CLIENT TEST END: $test_name [FAILED - WRONG SERVER]"
        return 1
    fi

    found=0
    expected=1
    if [[ ${check_opt:0:1} == '-' ]]; then
        expected=0
        check_opt=${check_opt:1}
    fi

    opts=${nfsinfo[2]},
    while [[ $opts ]]; do
        if [[ ${opts%%,*} == "$check_opt" ]]; then
            found=1
            break
        fi
        opts=${opts#*,}
    done

    if [[ $found -ne $expected ]]; then
        echo "CLIENT TEST INFO: got options: ${nfsinfo[2]%%:*}"
        if [[ $expected -eq 0 ]]; then
            echo "CLIENT TEST INFO: did not expect: $check_opt"
            echo "CLIENT TEST END: $test_name [FAILED - UNEXPECTED OPTION]"
        else
            echo "CLIENT TEST INFO: missing: $check_opt"
            echo "CLIENT TEST END: $test_name [FAILED - MISSING OPTION]"
        fi
        return 1
    fi

    if ! test_marker_check nfsfetch-OK marker2.img; then
        echo "CLIENT TEST END: $test_name [FAILED - NFS FETCH FAILED]"
        return 1
    fi

    echo "CLIENT TEST END: $test_name [OK]"
    return 0
}

test_nfsv3() {
    # MAC numbering scheme:
    # NFSv3: last octet starts at 0x00 and works up
    # NFSv4: last octet starts at 0x80 and works up

    client_test "NFSv3 root=dhcp DHCP path only" 52:54:00:12:34:00 \
        "root=dhcp" 192.168.50.1 -wsize=4096

    client_test "NFSv3 Legacy root=/dev/nfs nfsroot=IP:path" 52:54:00:12:34:01 \
        "root=/dev/nfs nfsroot=192.168.50.1:/nfs/client" 192.168.50.1 -wsize=4096

    client_test "NFSv3 Legacy root=/dev/nfs DHCP path only" 52:54:00:12:34:00 \
        "root=/dev/nfs" 192.168.50.1 -wsize=4096

    client_test "NFSv3 Legacy root=/dev/nfs DHCP IP:path" 52:54:00:12:34:01 \
        "root=/dev/nfs" 192.168.50.2 -wsize=4096

    client_test "NFSv3 root=dhcp DHCP IP:path" 52:54:00:12:34:01 \
        "root=dhcp" 192.168.50.2 -wsize=4096

    client_test "NFSv3 root=dhcp DHCP proto:IP:path" 52:54:00:12:34:02 \
        "root=dhcp" 192.168.50.3 -wsize=4096

    client_test "NFSv3 root=dhcp DHCP proto:IP:path:options" 52:54:00:12:34:03 \
        "root=dhcp" 192.168.50.3 wsize=4096

    client_test "NFSv3 root=nfs:..." 52:54:00:12:34:04 \
        "root=nfs:192.168.50.1:/nfs/client" 192.168.50.1 -wsize=4096

    client_test "NFSv3 Bridge root=nfs:..." 52:54:00:12:34:04 \
        "root=nfs:192.168.50.1:/nfs/client bridge net.ifnames=0" 192.168.50.1 -wsize=4096

    client_test "NFSv3 Legacy root=IP:path" 52:54:00:12:34:04 \
        "root=192.168.50.1:/nfs/client" 192.168.50.1 -wsize=4096

    client_test "NFSv3 root=dhcp DHCP path,options" 52:54:00:12:34:05 \
        "root=dhcp" 192.168.50.1 wsize=4096

    client_test "NFSv3 root=dhcp DHCP IP:path,options" 52:54:00:12:34:06 \
        "root=dhcp" 192.168.50.2 wsize=4096

    client_test "NFSv3 root=dhcp DHCP proto:IP:path,options" 52:54:00:12:34:07 \
        "root=dhcp" 192.168.50.3 wsize=4096

    # TODO FIXME
    #    client_test "NFSv3 Bridge Customized root=dhcp DHCP path,options" 52:54:00:12:34:05 \
    #        "root=dhcp bridge=foobr0:enp0s1" 192.168.50.1 wsize=4096

    return 0
}

test_nfsv4() {
    # There is a mandatory 90 second recovery when starting the NFSv4
    # server, so put these later in the list to avoid a pause when doing
    # switch_root

    client_test "NFSv4 root=dhcp DHCP proto:IP:path" 52:54:00:12:34:82 \
        "root=dhcp" 192.168.50.3 -wsize=4096

    client_test "NFSv4 root=dhcp DHCP proto:IP:path:options" 52:54:00:12:34:83 \
        "root=dhcp" 192.168.50.3 wsize=4096

    client_test "NFSv4 root=nfs4:..." 52:54:00:12:34:84 \
        "root=nfs4:192.168.50.1:/client" 192.168.50.1 -wsize=4096

    client_test "NFSv4 root=dhcp DHCP proto:IP:path,options" 52:54:00:12:34:87 \
        "root=dhcp" 192.168.50.3 wsize=4096

    client_test "NFSv4 Overlayfs root=nfs4:..." 52:54:00:12:34:84 \
        "root=nfs4:192.168.50.1:/client rd.live.overlay.overlayfs=1 " 192.168.50.1 -wsize=4096

    client_test "NFSv4 Live Overlayfs root=nfs4:..." 52:54:00:12:34:84 \
        "root=nfs4:192.168.50.1:/client rd.live.image rd.live.overlay.overlayfs=1" 192.168.50.1 -wsize=4096

    return 0
}

test_run() {
    if [[ -s server.pid ]]; then
        kill -TERM "$(cat "$TESTDIR"/server.pid)"
        rm -f -- "$TESTDIR"/server.pid
    fi

    if ! run_server; then
        echo "Failed to start server" 1>&2
        return 1
    fi

    test_nfsv3 \
        && test_nfsv4

    ret=$?

    if [[ -s $TESTDIR/server.pid ]]; then
        kill -TERM "$(cat "$TESTDIR"/server.pid)"
        rm -f -- "$TESTDIR"/server.pid
    fi

    return $ret
}

test_setup() {
    export kernel=$KVERSION
    export srcmods="/lib/modules/$kernel/"
    # Detect lib paths

    rm -rf -- "$TESTDIR"/overlay
    (
        mkdir -p "$TESTDIR"/server/overlay/source
        # shellcheck disable=SC2030
        export initdir=$TESTDIR/server/overlay/source
        # shellcheck disable=SC1090
        . "$PKGLIBDIR"/dracut-init.sh

        (
            cd "$initdir" || exit
            mkdir -p dev sys proc run etc var/run tmp var/lib/{dhcpd,rpcbind}
            mkdir -p var/lib/nfs/{v4recovery,rpc_pipefs}
            chmod 777 var/lib/rpcbind var/lib/nfs
        )

        inst_multiple sh ls shutdown poweroff cat ps ln ip \
            dmesg mkdir cp exportfs \
            modprobe rpc.nfsd rpc.mountd \
            sleep mount chmod rm
        for _terminfodir in /lib/terminfo /etc/terminfo /usr/share/terminfo; do
            if [ -f "${_terminfodir}"/l/linux ]; then
                inst_multiple -o "${_terminfodir}"/l/linux
                break
            fi
        done
        type -P portmap > /dev/null && inst_multiple portmap
        type -P rpcbind > /dev/null && inst_multiple rpcbind

        [ -f /etc/netconfig ] && inst_multiple /etc/netconfig
        type -P dhcpd > /dev/null && inst_multiple dhcpd
        instmods nfsd sunrpc ipv6 lockd af_packet
        inst ./server-init.sh /sbin/init
        inst_simple /etc/os-release
        inst ./exports /etc/exports
        inst ./dhcpd.conf /etc/dhcpd.conf
        inst_multiple -o {,/usr}/etc/nsswitch.conf {,/usr}/etc/rpc \
            {,/usr}/etc/protocols {,/usr}/etc/services
        inst_multiple -o rpc.idmapd /etc/idmapd.conf

        inst_libdir_file 'libnfsidmap_nsswitch.so*'
        inst_libdir_file 'libnfsidmap/*.so*'
        inst_libdir_file 'libnfsidmap*.so*'

        _nsslibs=$(
            cat "${dracutsysrootdir-}"/{,usr/}etc/nsswitch.conf 2> /dev/null \
                | sed -e '/^#/d' -e 's/^.*://' -e 's/\[NOTFOUND=return\]//' \
                | tr -s '[:space:]' '\n' | sort -u | tr -s '[:space:]' '|'
        )
        _nsslibs=${_nsslibs#|}
        _nsslibs=${_nsslibs%|}
        inst_libdir_file -n "$_nsslibs" 'libnss_*.so*'

        inst /etc/passwd /etc/passwd
        inst /etc/group /etc/group

        cp -a /etc/ld.so.conf* "$initdir"/etc
        ldconfig -r "$initdir"
        dracut_kernel_post
    )

    # Make client root inside server root
    # shellcheck disable=SC2031
    export initdir=$TESTDIR/server/overlay/source/nfs/client

    "$DRACUT" -N --keep --tmpdir "$TESTDIR" \
        --add-confdir test-root \
        -a "url-lib nfs" \
        -I "ip grep setsid" \
        -f "$TESTDIR"/initramfs.root "$KVERSION" || return 1

    mkdir -p "$initdir" && mv "$TESTDIR"/dracut.*/initramfs/* "$initdir" && rm -rf "$TESTDIR"/dracut.*
    echo "TEST FETCH FILE" > "$initdir"/root/fetchfile
    cp ./client-init.sh "$initdir"/sbin/init

    # second, install the files needed to make the root filesystem
    (
        # shellcheck disable=SC2030
        # shellcheck disable=SC2031
        export initdir=$TESTDIR/server/overlay
        # shellcheck disable=SC1090
        . "$PKGLIBDIR"/dracut-init.sh
        inst_multiple mkfs.ext4 poweroff cp umount sync dd
        inst_hook initqueue 01 ./create-root.sh
        inst_hook initqueue/finished 01 ./finished-false.sh
    )

    # create an initramfs that will create the target root filesystem.
    # We do it this way so that we do not risk trashing the host mdraid
    # devices, volume groups, encrypted partitions, etc.
    "$DRACUT" -i "$TESTDIR"/server/overlay / \
        -a "bash rootfs-block kernel-modules qemu" \
        -d "piix ide-gd_mod ata_piix ext4 sd_mod" \
        --nomdadmconf \
        --no-hostonly-cmdline -N \
        -f "$TESTDIR"/initramfs.makeroot "$KVERSION"
    rm -rf -- "$TESTDIR"/server

    declare -a disk_args=()
    # shellcheck disable=SC2034
    declare -i disk_index=0
    qemu_add_drive disk_index disk_args "$TESTDIR"/marker.img marker 1
    qemu_add_drive disk_index disk_args "$TESTDIR"/server.img root 1

    # Invoke KVM and/or QEMU to actually create the target filesystem.
    "$testdir"/run-qemu \
        "${disk_args[@]}" \
        -append "root=/dev/dracut/root rw rootfstype=ext4 quiet console=ttyS0,115200n81" \
        -initrd "$TESTDIR"/initramfs.makeroot
    test_marker_check dracut-root-block-created

    # Make an overlay with needed tools for the test harness
    (
        # shellcheck disable=SC2031
        # shellcheck disable=SC2030
        export initdir="$TESTDIR"/overlay
        mkdir -p "$TESTDIR"/overlay
        # shellcheck disable=SC1090
        . "$PKGLIBDIR"/dracut-init.sh
        inst_multiple poweroff shutdown
        inst_simple ./client.link /etc/systemd/network/01-client.link
    )

    # Make client's dracut image
    test_dracut \
        --no-hostonly --no-hostonly-cmdline \
        -a "dmsquash-live ${USE_NETWORK}"

    (
        # shellcheck disable=SC2031
        export initdir="$TESTDIR"/overlay
        # shellcheck disable=SC1090
        . "$PKGLIBDIR"/dracut-init.sh
        rm "$initdir"/etc/systemd/network/01-client.link
        inst_simple ./server.link /etc/systemd/network/01-server.link
        inst_hook pre-mount 99 ./wait-if-server.sh
    )
    # Make server's dracut image
    "$DRACUT" -i "$TESTDIR"/overlay / \
        -a "network-legacy ${SERVER_DEBUG:+debug}" \
        -d "af_packet piix ide-gd_mod ata_piix ext4 sd_mod i6300esb virtio_net" \
        --no-hostonly-cmdline -N \
        -f "$TESTDIR"/initramfs.server "$KVERSION"
}

test_cleanup() {
    if [[ -s $TESTDIR/server.pid ]]; then
        kill -TERM "$(cat "$TESTDIR"/server.pid)"
        rm -f -- "$TESTDIR"/server.pid
    fi
}

# shellcheck disable=SC1090
. "$testdir"/test-functions
