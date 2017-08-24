#!/bin/bash
#
# Build DPDK and OVS-DPDK from GIT and integrate it in Ubuntu 16.04.
# The dpdk source tar contains patches for setting vhost-owner and another fix.
#
# Mar 21, 2017 - Timo Koehler

# The OVS 2.6.90 and DPDK 16.07 code is pre-release from git from around May 2016.
# It misses some fixes from OVS 2.6.1 and DPDK 16.07.2 released code. 
#
# This script rebuilds ovs and ovs-dpdk after apt update/upgrade.
#
dpdk_code="dpdk-16.07-vhostowner.tar.gz"
ovs_dpdk_code="ovs26.tar.gz"
dpdk_code_md5="0df14069e1d922e9b152911a9cbb4754"
ovs_dpdk_code_md5="30e2a613fe4dee052a7de7e501215386"
code_dir="/home/localadmin"

if [ ! $UID -eq 0 ]; then
    echo "Need to run this script with root privileges!"
    exit 1
fi

dpdk_code_path="$code_dir/$dpdk_code"
ovs_dpdk_code_path="$code_dir/$ovs_dpdk_code"
if [ ! -f "${dpdk_code_path}" ] || [ ! -f "${ovs_dpdk_code_path}" ]; then
    echo "Source tar files are missing!"
    exit 1
fi

sum1=$(md5sum $dpdk_code_path | cut -d' ' -f1)
sum2=$(md5sum $ovs_dpdk_code_path | cut -d' ' -f1)
if [ $sum1 != $dpdk_code_md5 ] || [ $sum2 != $ovs_dpdk_code_md5 ]; then
    echo "Checksum mismatch!"
    exit 1
fi

echo -n "Building and installing dpdk and ovs-dpdk from source [y/n]? > "
read r
if [ "$r" != "y" ]; then
    echo "exit.."
    exit 1
fi

echo "Install the default dpdk and ovs-dpdk to remove it later without its dependencies."
# Install OpenVswitch-DPDK which implicitely removes openvswitch-switch
# Apt removal of openvswitch-switch would otherwise also remove all its dependencies: nova, neutron.
sudo apt-get -y install openvswitch-switch-dpdk
sudo update-alternatives --set ovs-vswitchd /usr/lib/openvswitch-switch-dpdk/ovs-vswitchd-dpdk

echo "Stopping services"
service nova-compute stop
service neutron-openvswitch-agent stop
service openvswitch-switch stop
sleep 4

echo "Backup the Ubuntu 16.04 dpdk-init and remove the old versions"
cp /lib/dpdk/dpdk-init /home/localadmin/
apt remove -y openvswitch-switch-dpdk dpdk
apt -y autoremove
sleep 4

echo "Install the build environment"
apt install -y unzip make gcc clang openssl autoconf libtool \
    python3-pyftpdlib pkg-config libssl-dev libsslcommon2-dev libcap-ng-dev

# DPDK
rm -rf /usr/src/dpdk-16.07
cd /usr/src
mv $dpdk_code_path .
tar xvfz $dpdk_code
export DPDK_DIR=/usr/src/dpdk-16.07
cd $DPDK_DIR
export DPDK_TARGET=x86_64-native-linuxapp-gcc
export DPDK_BUILD=$DPDK_DIR/$DPDK_TARGET
make install T=$DPDK_TARGET DESTDIR=install

# OVS
rm -rf /usr/src/ovs
cd /usr/src
mv $ovs_dpdk_code_path .
tar xvfz $ovs_dpdk_code
export OVS_DIR=/usr/src/ovs
cd $OVS_DIR
./boot.sh
./configure --with-dpdk=$DPDK_BUILD --localstatedir=/var --runstatedir=/var/run
make install

echo "Initialize the ovs db"
mv /etc/openvswitch /etc/openvswitch.off
mkdir -p /etc/openvswitch
ovsdb-tool create /etc/openvswitch/conf.db /usr/local/share/openvswitch/vswitch.ovsschema

/usr/local/sbin/ovsdb-server /etc/openvswitch/conf.db -vconsole:emer -vsyslog:err -vfile:info \
			     --remote=punix:/var/run/openvswitch/db.sock \
			     --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
			     --private-key=db:Open_vSwitch,SSL,private_key \
			     --certificate=db:Open_vSwitch,SSL,certificate \
			     --bootstrap-ca-cert=db:Open_vSwitch,SSL,ca_cert \
			     --no-chdir --log-file=/var/log/openvswitch/ovsdb-server.log \
			     --pidfile=/var/run/openvswitch/ovsdb-server.pid --detach --monitor

sleep 6
ovs-vsctl --no-wait init
sleep 6

echo "Configure the vswitchd"
ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-init=true
ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="4096,4096"
ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-lcore-mask=0x307
ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-extra="--vhost-owner libvirt-qemu:kvm --vhost-perm 0664"
echo "Configuration:"
ovs-vsctl get Open_vSwitch . other_config
sleep 4
ovs-appctl -t ovsdb-server exit

echo "Integrate dpdk 16.07"
ln -s /usr/src/dpdk-16.07/install/share/dpdk/tools/dpdk-devbind.py /sbin/dpdk_nic_bind
systemctl unmask dpdk.service
mkdir -p /lib/dpdk/
cp /home/localadmin/dpdk-init /lib/dpdk/dpdk-init
cp /usr/src/dpdk-16.07/install/sbin/dpdk-devbind /sbin/dpdk-devbind
systemctl restart dpdk.service
echo "DPDK service started"
sleep 6

echo "Integrate ovs 2.6"
mkdir -p /usr/lib/openvswitch-switch-dpdk
cp /usr/local/sbin/ovs-vswitchd /usr/lib/openvswitch-switch-dpdk/ovs-vswitchd-dpdk
cp /usr/local/sbin/ovs-vswitchd /usr/lib/openvswitch-switch/ovs-vswitchd
cp /usr/local/sbin/ovsdb-server /usr/sbin/ovsdb-server
cp /usr/local/sbin/ovs-vswitchd /usr/sbin/ovs-vswitchd
mkdir -p /usr/share/openvswitch/scripts
cp /usr/local/share/openvswitch/scripts/ovs-lib /usr/share/openvswitch/scripts/ovs-lib
cp /usr/local/share/openvswitch/vswitch.ovsschema /usr/share/openvswitch/vswitch.ovsschema
sed -i /etc/default/openvswitch-switch -e 's/^\(DPDK_OPTS.*\)/#\1/g'
cp /usr/local/bin/ovs* /usr/bin/
sleep 6
systemctl unmask openvswitch-switch.service
systemctl start openvswitch-switch.service
echo "OVS-DPDK service started"
sleep 6

# Again, vswitchd. The reason, systemctl start script cleans the ovs db.
ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-init=true
ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="4096,4096"
ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-lcore-mask=0x307
ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-extra="--vhost-owner libvirt-qemu:kvm --vhost-perm 0664"
echo "vswitchd configuration:"
ovs-vsctl get Open_vSwitch . other_config

systemctl restart openvswitch-switch.service
echo "OVS-DPDK service restarted"
sleep 6

# In Ubuntu 16.04 the L2 agent starts with config-file=/etc/neutron/plugins/ml2/openvswitch_agent.ini
# so it ignores ml2 [ovs] startup options.
# - Because the L2 agent is supposed to create br-int with 'datapath_type=netdev' this fails
#   and br-int is created with system datapath (kernelspace).
# - The bridge_mappings are not in openvswitch_agent.ini; if bridge_mappings are missing then port
#   binding fails.
sudo sed -i /etc/init.d/neutron-openvswitch-agent -e "s/^DAEMON_ARGS=.*/DAEMON_ARGS=\"--config-file=\/etc\/neutron\/plugins\/ml2\/ml2_conf.ini\"/g"
sudo service neutron-openvswitch-agent restart
sleep 6
sudo ovs-vsctl list bridge br-int | grep datapath_type

echo "OVS-DPDK integration test"
ovs-vsctl show
ovs-vsctl get Open_vSwitch . other_config
ovs-vsctl get Open_vSwitch . iface_types
ovs-vsctl del-br br-data
ovs-vsctl add-br br-data -- set bridge br-data datapath_type=netdev
ovs-vsctl show
sudo ovs-vsctl list bridge br-data | grep datapath_type

shutdown -r +1 "New ovs-dpdk is installed. Rebooting now.."

