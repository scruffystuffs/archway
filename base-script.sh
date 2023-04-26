#! /bin/bash

set -euo pipefail

DEVICE=/dev/sda
BOOT_PARTITION="${DEVICE}1"
LVM_PARTITION="${DEVICE}2"
ROOT_FS=/dev/vg0/lv_root
HOME_FS=/dev/vg0/lv_home
POST_INSTALL_NAME=".run_postinstall"
LOCALE_GEN="en_US.UTF-8 UTF-8"
MOUNT_PREFIX="/mnt/newsys"
INIT_USER=kate
TIMEZONE="America/Los_Angeles"
HOSTNAME=kates-arch
SELF_NAME="archway.sh"

# LONG VARS
# Read will return 1 if EOF is hit, which it always is when using -d ''.
# We have to ignore failure on those cases because of -e in the shebang.

read -rd '' _sfdisk_script <<'EOF' || true
label: gpt

size=+500MiB, type=uefi
type=lvm
EOF

read -rd '' _startup_runner_script <<EOF || true

# Run the post OS-install setup if the flag file exists
if [ -f ~/$POST_INSTALL_NAME ]; then
    ~/$SELF_NAME
fi
EOF

read -rsp "Enter the new root password:" _root_passwd
echo
read -rsp "Enter the new password for user '$INIT_USER':" _user_passwd
echo

# HELPERS

ch() {
    arch-chroot $MOUNT_PREFIX bash -c "$*"
}

# BUSINESS LOGIC

execute() {
    if [ -f ~/$POST_INSTALL_NAME ]; then
        execute_post_boot
    else
        execute_pre_boot
    fi
}

execute_pre_boot() {
    echo executing pre-boot steps
    do_disk_setup
    do_distro_install
    do_boot_setup
    touch $MOUNT_PREFIX/home/$INIT_USER/$POST_INSTALL_NAME
    umount -a
    systemctl -i reboot
}

do_disk_setup() {
    create_base_partitions
    format_boot_partition
    setup_lvm_partition
    generate_fs_table
    create_swapfile
}

do_distro_install() {
    bootstrap_pacman
    install_initial_packages
}

do_boot_setup() {
    enable_startup_services
    setup_locale
    add_boot_hooks
    generate_initrd
    user_updates
    update_sudoers
    mount_efi_volume
    install_bootloader
    install_startup_runner
}

execute_post_boot() {
    echo executing post-boot steps
    set_timezone
    set_hostname
    post_installs
    remove_autorun
}

create_base_partitions() {
    echo "$_sfdisk_script" | sfdisk $DEVICE
}

format_boot_partition() {
    mkfs.fat -F32 $BOOT_PARTITION
}

setup_lvm_partition() {
    pvcreate --dataalignment 1m $DEVICE
    vgcreate vg0 $LVM_PARTITION
    lvcreate -L 30GB vg0 -n lv_root
    lvcreate -l 100%FREE vg0 -n lv_home
    modprobe dm_mod
    vgscan
    vgchange -ay
    mkfs.ext4 $ROOT_FS
    mkfs.ext4 $HOME_FS
    mount --mkdir $ROOT_FS $MOUNT_PREFIX
    mount --mkdir $HOME_FS $MOUNT_PREFIX/home
    mkdir -p $MOUNT_PREFIX/etc
}

generate_fs_table() {
    genfstab -U -p $MOUNT_PREFIX >>$MOUNT_PREFIX/etc/fstab
}

create_swapfile() {
    dd if=/dev/zero of=$MOUNT_PREFIX/swapfile bs=1M count=2048
    chmod 600 $MOUNT_PREFIX/swapfile
    mkswap $MOUNT_PREFIX/swapfile
    echo "/swapfile none swap sw 0 0" >>$MOUNT_PREFIX/etc/fstab
}

bootstrap_pacman() {
    pacstrap $MOUNT_PREFIX base
}

install_initial_packages() {
    ch pacman -S --noconfirm \
        linux \
        linux-headers \
        linux-lts \
        linux-lts-headers \
        vim \
        nano \
        base-devel \
        sudo \
        openssh \
        networkmanager \
        wpa_supplicant \
        wireless_tools \
        netctl \
        lvm2 \
        grub \
        efibootmgr \
        dosfstools \
        mtools \
        os-prober
}

enable_startup_services() {
    ch systemctl enable NetworkManager sshd
}

setup_locale() {
    # Ensure that we're using a valid locale
    if ! grep -q "$LOCALE_GEN" $MOUNT_PREFIX/etc/locale.gen; then
        echo "ERROR: invalid locale:" "$LOCALE_GEN"
        exit 1
    fi

    # Instead of in-place editing, we just append the known locale to the file uncommented
    echo "$LOCALE_GEN" >>$MOUNT_PREFIX/etc/locale.gen
    ch locale-gen
}

add_boot_hooks() {
    eval "$(cat $MOUNT_PREFIX/etc/mkinitcpio.conf | grep HOOKS)"
    needle=block
    idx=-1

    for i in "${!HOOKS[@]}"; do
        if [ "${HOOKS[$i]}" = "${needle}" ]; then
            idx=$((i + 1))
        fi
    done

    if [ "${idx}" = "-1" ]; then
        echo 'Failed to add build hook, could not find "block" hook'
        exit 1
    fi
    new_hooks=("${HOOKS[@]:0:$idx}" "lvm2" "${HOOKS[@]:idx}")
    echo "HOOKS=(" "${new_hooks[@]}" ")" >$MOUNT_PREFIX/etc/mkinitcpio.conf
}

generate_initrd() {
    ch mkinitcpio -p linux -p linux-lts
}

user_updates() {
    ch useradd -mG wheel $INIT_USER
    ch echo "root:${_root_passwd}\n${INIT_USER}:${_user_passwd}" | chpasswd
}

update_sudoers() {
    echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' >>$MOUNT_PREFIX/etc/sudoers.d/wheel
    chmod 440 $MOUNT_PREFIX/etc/sudoers.d/wheel
    # Use visudo to check the format is correct
    if ! visudo -c; then
        echo "WARNING: Invalid sudoers file, wheel group will not have NOPASSWD tag"
        rm $MOUNT_PREFIX/etc/sudoers.d/wheel
    fi
}

mount_efi_volume() {
    ch mount --mkdir "$BOOT_PARTITION" /boot/EFI
}

install_bootloader() {
    ch grub-install --target=x86_64-efi --bootloader-id=grub_uefi --recheck
    mkdir -p $MOUNT_PREFIX/boot/grub/locale
    cp $MOUNT_PREFIX/usr/share/locale/en\@quot/LC_MESSAGES/grub.mo $MOUNT_PREFIX/boot/grub/locale/en.mo
    cp $MOUNT_PREFIX/etc/default/grub $MOUNT_PREFIX/etc/default/grub.bak
    echo 'GRUB_DEFAULT=saved' >>$MOUNT_PREFIX/etc/default/grub
    echo 'GRUB_SAVEDEFAULT=true' >>$MOUNT_PREFIX/etc/default/grub
    ch grub-mkconfig -o /boot/grub/grub.cfg
}

install_startup_runner() {
    echo "$_startup_runner_script" >>$MOUNT_PREFIX/home/$INIT_USER/.profile
    touch ~/$POST_INSTALL_NAME
    cp "$0" "$MOUNT_PREFIX/home/$INIT_USER/$SELF_NAME"
    chmod a+x "$MOUNT_PREFIX/home/$INIT_USER/$SELF_NAME"
}

set_timezone() {
    timedatectl set-timezone $TIMEZONE
    timedatectl set-ntp true
}

set_hostname() {
    hostnamectl set-hostname $HOSTNAME
    echo '127.0.0.1 localhost' >>/etc/hosts
    echo "127.0.1.1 $HOSTNAME" >>/etc/hosts
}

post_installs() {
    pacman -S --noconfirm \
        amd-ucode \
        xorg-server \
        virtualbox-guest-utils \
        xf86-video-vmware \
        xfce4 \
        xfce4-goodies \
        lightdm \
        lightdm-gtk-greeter
    systemctl enable vboxservice lightdm
}

remove_autorun() {
    rm ~/$POST_INSTALL_NAME ~/$SELF_NAME
}

execute
