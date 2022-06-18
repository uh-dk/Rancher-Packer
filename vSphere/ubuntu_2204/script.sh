# Remove snap
snap remove core18
snap remove core20
snap remove lxd
snap remove snapd
# Apply updates and cleanup Apt cache
# packer build --var-file=variables.json ubuntu-2204.json
#apt-get install docker.io -y
apt-get update ; apt-get -y dist-upgrade
apt-get -y autoremove
apt-get -y clean
apt-get purge --auto-remove multipath-tools snapd -y
apt-get install mc original-awk

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
