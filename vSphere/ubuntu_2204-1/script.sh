#!/bin/sh -eux

### Network ###
echo "# Network..."

sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0 \1"/g' /target/etc/default/grub;
sed -i 's/^#*\(send dhcp-client-identifier\).*$/\1 = hardware;/' /target/etc/dhcp/dhclient.conf;

echo "removing all netplan configs"
find /target/etc/netplan/ -name "*.yaml" -exec sh -c 'mv "$1" "$1-orig"' _ {} \;

echo "create netplan DHCP config"
cat <<EOF | sudo tee /target/etc/netplan/01-netcfg.yaml
      network:
        version: 2
        renderer: NetworkManager
        ethernets:
          eth0:
            dhcp4: true
            dhcp-identifier: mac
EOF

echo "apply netplan config"
netplan generate;
netplan apply;
systemctl enable NetworkManager.service;

### Update ###
echo "## Update..."

export DEBIAN_FRONTEND=noninteractive

echo "disable release-upgrades"
sed -i.bak 's/^Prompt=.*$/Prompt=never/' /etc/update-manager/release-upgrades;

echo "disable systemd apt timers/services"
systemctl stop apt-daily.timer;
systemctl stop apt-daily-upgrade.timer;
systemctl disable apt-daily.timer;
systemctl disable apt-daily-upgrade.timer;
systemctl mask apt-daily.service;
systemctl mask apt-daily-upgrade.service;
systemctl daemon-reload;

# Disable periodic activities of apt to be safe
cat <<EOF >/etc/apt/apt.conf.d/10periodic;
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

echo "remove the unattended-upgrades and ubuntu-release-upgrader-core packages"
rm -rf /var/log/unattended-upgrades;
apt-get -y purge unattended-upgrades ubuntu-release-upgrader-core;

echo "update the package list"
apt-get -y update;

echo "upgrade all installed packages incl. kernel and kernel headers"
apt-get -y dist-upgrade -o Dpkg::Options::="--force-confnew";


### Cleanup ###
echo "### Cleanup..."

echo "remove linux-headers"
dpkg --list \
  | awk '{ print $2 }' \
  | grep 'linux-headers' \
  | xargs apt-get -y purge;

echo "remove specific Linux kernels, such as linux-image-3.11.0-15-generic but keeps the current kernel and does not touch the virtual packages"
dpkg --list \
    | awk '{ print $2 }' \
    | grep 'linux-image-.*-generic' \
    | grep -v `uname -r` \
    | xargs apt-get -y purge;

echo "remove old kernel modules packages"
dpkg --list \
    | awk '{ print $2 }' \
    | grep 'linux-modules-.*-generic' \
    | grep -v `uname -r` \
    | xargs apt-get -y purge;

echo "remove linux-source package"
dpkg --list \
    | awk '{ print $2 }' \
    | grep linux-source \
    | xargs apt-get -y purge;

echo "remove all development packages"
dpkg --list \
    | awk '{ print $2 }' \
    | grep -- '-dev\(:[a-z0-9]\+\)\?$' \
    | xargs apt-get -y purge;

echo "remove docs packages"
dpkg --list \
    | awk '{ print $2 }' \
    | grep -- '-doc$' \
    | xargs apt-get -y purge;

echo "remove X11 libraries"
apt-get -y purge libx11-data xauth libxmuu1 libxcb1 libx11-6 libxext6;

echo "remove obsolete networking packages"
apt-get -y purge ppp pppconfig pppoeconf;

echo "remove the console font"
apt-get -y purge fonts-ubuntu-console || true;

echo "remove snap"
snap remove lxd
snap remove core20
snap remove snapd

echo "remove packages we don't need"
apt-get -y purge popularity-contest friendly-recovery laptop-detect motd-news-config usbutils grub-legacy-ec2 multipath-tools snapd;

# Exclude the files we don't need w/o uninstalling linux-firmware
echo "Setup dpkg excludes for linux-firmware"
cat <<_EOF_ | cat >> /etc/dpkg/dpkg.cfg.d/excludes
path-exclude=/lib/firmware/*
path-exclude=/usr/share/doc/linux-firmware/*
_EOF_

echo "delete the massive firmware files"
rm -rf /lib/firmware/*
rm -rf /usr/share/doc/linux-firmware/*

echo "autoremoving packages and cleaning apt data"
apt-get -y autoremove;
apt-get -y clean;

echo "remove /usr/share/doc/"
rm -rf /usr/share/doc/*

echo "remove /var/cache"
find /var/cache -type f -exec rm -rf {} \;

echo "truncate any logs that have built up during the install"
find /var/log -type f -exec truncate --size=0 {} \;

# Disable swap - generally recommended for K8s, but otherwise enable it for other workloads
echo "Disabling Swap"
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Reset the machine-id value. This has known to cause issues with DHCP
#
echo "Reset Machine-ID"
truncate -s 0 /etc/machine-id
rm /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

# Reset any existing cloud-init state
#
echo "Reset Cloud-Init"
rm /etc/cloud/cloud.cfg.d/*.cfg
cloud-init clean -s -l

echo "force a new random seed to be generated"
rm -f /var/lib/systemd/random-seed

# Clean tmp
#
echo "remove the contents of /tmp and /var/tmp"
rm -rf /tmp/* /var/tmp/*

# Add logging cfg
#
echo "adding 05_logging.cfg"
cat << EOF > /etc/cloud/cloud.cfg.d/05_logging.cfg
_log:
 - &log_base |
   [loggers]
   keys=root,cloudinit
   
   [handlers]
   keys=consoleHandler,cloudLogHandler
   
   [formatters]
   keys=simpleFormatter,arg0Formatter
   
   [logger_root]
   level=DEBUG
   handlers=consoleHandler,cloudLogHandler
   
   [logger_cloudinit]
   level=DEBUG
   qualname=cloudinit
   handlers=
   propagate=1
   
   [handler_consoleHandler]
   class=StreamHandler
   level=WARNING
   formatter=arg0Formatter
   args=(sys.stderr,)
   
   [formatter_arg0Formatter]
   format=%(asctime)s - %(filename)s[%(levelname)s]: %(message)s
   
   [formatter_simpleFormatter]
   format=[CLOUDINIT] %(filename)s[%(levelname)s]: %(message)s
 - &log_file |
   [handler_cloudLogHandler]
   class=FileHandler
   level=DEBUG
   formatter=arg0Formatter
   args=('/var/log/cloud-init.log', 'a', 'UTF-8')
 - &log_syslog |
   [handler_cloudLogHandler]
   class=handlers.SysLogHandler
   level=DEBUG
   formatter=simpleFormatter
   args=("/dev/log", handlers.SysLogHandler.LOG_USER)

log_cfgs:
 - [ *log_base, *log_file ]
output: {all: '| tee -a /var/log/cloud-init-output.log'}
EOF

# Add datsourece list cfg
#
echo "adding 90_dpkg.cfg" 
cat << EOF > /etc/cloud/cloud.cfg.d/90_dpkg.cfg
# to update this file, run dpkg-reconfigure cloud-init
datasource_list: [ AltCloud, VMware, NoCloud, None ]
EOF

# Disable cloudinit network config
#
echo "adding 99-disable-network-config.cfg"
cat << EOF > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
network: {config disbaled}
EOF

# Clear history
#
echo "clear the history so our install isn't there"
rm -f /root/.wget-hsts
export HISTSIZE=0
