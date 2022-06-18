#!/bin/sh -eux

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

echo "remove packages we don't need"
apt-get -y purge popularity-contest friendly-recovery laptop-detect motd-news-config usbutils grub-legacy-ec2

echo "remove the console font"
apt-get -y purge fonts-ubuntu-console || true;

echo "remove multipath-tools"
apt-get -y purge --auto-remove multipath-tools

echo "remove snap"
snap remove lxd
snap remove core20
snap remove snapd
apt-get -y purge --auto-remove snapd

# Exclude the files we don't need w/o uninstalling linux-firmware
echo "Setup dpkg excludes for linux-firmware"
cat <<_EOF_ | cat >> /etc/dpkg/dpkg.cfg.d/excludes
#BENTO-BEGIN
path-exclude=/lib/firmware/*
path-exclude=/usr/share/doc/linux-firmware/*
#BENTO-END
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

# Add Cloudinit configs
#
echo "Add Cloudinit configs"
cat << EOF > /etc/cloud/cloud.cfg.d/05_logging.cfg
## This yaml formated config file handles setting
## logger information.  The values that are necessary to be set
## are seen at the bottom.  The top '_log' are only used to remove
## redundency in a syslog and fallback-to-file case.
##
## The 'log_cfgs' entry defines a list of logger configs
## Each entry in the list is tried, and the first one that
## works is used.  If a log_cfg list entry is an array, it will
## be joined with '\n'.
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
# Array entries in this list will be joined into a string
# that defines the configuration.
#
# If you want logs to go to syslog, uncomment the following line.
# - [ *log_base, *log_syslog ]
#
# The default behavior is to just log to a file.
# This mechanism that does not depend on a system service to operate.
 - [ *log_base, *log_file ]
# A file path can also be used.
# - /etc/log.conf

# This tells cloud-init to redirect its stdout and stderr to
# 'tee -a /var/log/cloud-init-output.log' so the user can see output
# there without needing to look on the console.
output: {all: '| tee -a /var/log/cloud-init-output.log'}
EOF

cat << EOF > /etc/cloud/cloud.cfg.d/90_dpkg.cfg
# to update this file, run dpkg-reconfigure cloud-init
datasource_list: [ NoCloud, AltCloud, VMware, None ]
EOF

echo "disable cloud-init network configuration"
cat << EOF > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
network: {config disbaled}
EOF

echo "remove the contents of /tmp and /var/tmp"
rm -rf /tmp/* /var/tmp/*

echo "remove installer netplan config"
rm /etc/netplan/00-installer-config.yaml

echo "force a new random seed to be generated"
rm -f /var/lib/systemd/random-seed

echo "clear the history so our install isn't there"
rm -f /root/.wget-hsts
export HISTSIZE=0
