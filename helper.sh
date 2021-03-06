#!/bin/bash -ex

# Retries a command on failure.
# $1 - the max number of attempts
# $2... - the command to run
# http://fahdshariff.blogspot.sg/2014/02/retrying-commands-in-shell-scripts.html

retry() {
    local -r -i max_attempts="$1"; shift
    local -r cmd="$@"
    local -i attempt_num=1
 
    until $cmd
    do
        if (( attempt_num == max_attempts ))
        then
            echo "Attempt $attempt_num failed and there are no more attempts left!"
            return 1
        else
            echo "Attempt $attempt_num failed! Trying again in $attempt_num seconds..."
            sleep $(( attempt_num++ ))
        fi
    done
}

export -f retry

start_multistrap(){
    # retry as apt-get sometimes fails on fetching archives
    retry 5 multistrap -f /work/${CONF} -a ${ARCH} -d ${ROOTFS}
    proot-helper sh -c "/var/lib/dpkg/info/dash.preinst install && \
        dpkg --configure -a || dpkg --configure -a"
}

setup_etc(){
    #edit hostname
    echo ${HOSTNAME} > ${ROOTFS}/etc/hostname
    echo -e '127.0.0.1\t'${HOSTNAME} >> ${ROOTFS}/etc/hosts

    # edit network interface
    cat << EOF > ${ROOTFS}/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
}

setup_apt(){
    cat <<EOF > ${ROOTFS}/etc/apt/sources.list.d/machinekit.list
deb http://deb.machinekit.io/debian jessie main
EOF

    # add public key
    cp /work/deb.machinekit.io.key ${ROOTFS}/tmp
    proot-helper sh -ex << EOF
apt-key add /tmp/deb.machinekit.io.key
EOF

    rm ${ROOTFS}/tmp/deb.machinekit.io.key
}

disable_daemons(){
    cat <<EOF > ${ROOTFS}/usr/sbin/policy-rc.d
#!/bin/sh
exit 101
EOF
    chmod a+x ${ROOTFS}/usr/sbin/policy-rc.d
}

configure_base(){
    # configure usbmount
    sed -i -e 's/""/"-fstype=vfat,flush,gid=plugdev,dmask=0007,fmask=0117"/g' \
        ${ROOTFS}/etc/usbmount/usbmount.conf

    # update sudoers
    sed -i "s/%sudo\tALL=(ALL:ALL)/%sudo\tALL=NOPASSWD:/g"  \
        ${ROOTFS}/etc/sudoers

    # fix ssh keys
    cp /work/ssh_gen_host_keys ${ROOTFS}/etc/init.d/
    LC_ALL=C LANGUAGE=C LANG=C proot-helper insserv /etc/init.d/ssh_gen_host_keys

    # add user
    proot-helper sh << EOF
adduser --disabled-password --gecos "${DEFUSR}" ${DEFUSR}
usermod -a -G sudo,staff,kmem,plugdev,adm,dialout,cdrom,audio,video,games,users,netdev ${DEFUSR}
echo -n ${DEFUSR}:${DEFPWD} | chpasswd
EOF

    # update wallpaper
    mkdir -p ${ROOTFS}/usr/share/images/desktop-base
    cp /work/debian-mk-wallpaper.svg ${ROOTFS}/usr/share/images/desktop-base/
    rm -f ${ROOTFS}/etc/alternatives/desktop-background
    ln -sf /usr/share/images/desktop-base/debian-mk-wallpaper.svg \
        ${ROOTFS}/etc/alternatives/desktop-background
    sed -i 's/login-background/debian-mk-wallpaper/g' \
        ${ROOTFS}/etc/lightdm/lightdm-gtk-greeter.conf

    # add missing devs
    mknod -m 0666 ${ROOTFS}/dev/null c 1 3
    mknod -m 0666 ${ROOTFS}/dev/zero c 1 5

    # remove unneeded packages
    proot-helper apt-get remove -y xserver-xorg-video-mach64 xserver-xorg-video-nouveau \
        xserver-xorg-video-r128 xserver-xorg-video-radeon xserver-xorg-video-vesa 
}

cleanup(){
    # cleanup APT
    rm -f ${ROOTFS}/var/lib/apt/lists/* || true
    LC_ALL=C LANGUAGE=C LANG=C proot-helper apt-get clean

    # remove our traces
    rm -f ${ROOTFS}/etc/resolv.conf
    echo > ${ROOTFS}/root/.bash_history
    rm -f ${ROOTFS}/usr/sbin/policy-rc.d
}

######################
# Install starts here
######################

# reuse rootfs if it exists
if [ -f /work/cache/rootfs.tgz ]; then
    mkdir -p ${ROOTFS}
    tar xf /work/cache/rootfs.tgz -C ${ROOTFS}
else
    start_multistrap

    setup_etc
    setup_apt
    disable_daemons
    configure_base

    tar czpf /work/cache/rootfs.tgz -C ${ROOTFS} .
fi

# run custom install
if [ -f /work/${CUSTOM_APP} ]; then
    /work/${CUSTOM_APP}
fi

cleanup

# run custom image
if [ -f /work/${CUSTOM_IMG} ]; then
    /work/${CUSTOM_IMG}
fi
