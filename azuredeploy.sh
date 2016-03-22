#!/bin/bash

#set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

#if [ $# != 7 ]; then
#    echo "Usage: $0 <MasterHostname> <WorkerHostnamePrefix> <WorkerNodeCount> <HPCUserName> <TemplateBaseUrl> <MasterOS> <WorkerOS> <HPCUser> <TOKEN> <GITRepo>"
#    exit 1
#fi

# Set user args
MASTER_HOSTNAME=$1
MASTER_OS=$6
WORKER_HOSTNAME_PREFIX=$2
WORKER_COUNT=$3
WORKER_OS=$7
TEMPLATE_BASE_URL="$5"
LAST_WORKER_INDEX=$(($WORKER_COUNT - 1))

# Shares
SHARE_PATH=/share
SHARE_HOME=/share/home
SHARE_PROJ=/share/projects
SHARE_SOFT=/share/easybuild
SHARE_CONF=/share/configspace
SHARE_UTIL=/share/utils

# Munged
MUNGE_USER=munge
MUNGE_UID=994
MUNGE_GROUP=munge
MUNGE_GID=994
MUNGE_VERSION=0.5.11

# SLURM
SLURM_USER=slurm
SLURM_UID=506
SLURM_GROUP=slurm
SLURM_GID=506
SLURM_VERSION=15-08-8
SLURM_CONF_DIR=$SHARE_CONF/system_files/etc/slurm

# Admin User
ADMIN_USER=$4
ADMIN_UID=1000
ADMIN_GROUP=$4
ADMIN_GID=1000

# Hpc User
HPC_USER=$8
HPC_UID=5674
HPC_GROUP=nesi
HPC_GID=5000

# GITHUB REPO
TOKEN=$9
PRIVATE_REPO=${10}


# Returns 0 if this node is the master node.
is_master()
{
    hostname | grep "$MASTER_HOSTNAME"
    return $?
}

is_first_worker()
{
    hostname | grep "${WORKER_HOSTNAME_PREFIX}0"
    return $?
}

# Add the SLES 12 SDK repository which includes all the packages for compilers and headers.
add_sdk_repo()
{
    repoFile="/etc/zypp/repos.d/SMT-http_smt-azure_susecloud_net:SLE-SDK12-Pool.repo"
    if [ -e "$repoFile" ]; then
        echo "SLES 12 SDK Repository already installed"
        return 0
    fi
	wget ${TEMPLATE_BASE_URL}sles12sdk.repo
	cp sles12sdk.repo "$repoFile"
    # init new repo
    zypper -n search nfs > /dev/null 2>&1
}

# Partitions all data disks attached to the VM and creates a RAID-0 volume with them.
setup_data_disks()
{
    mountPoint="$1"
	createdPartitions=""

    # Loop through and partition disks until not found
    for disk in sdc sdd sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp sdq sdr; do
        fdisk -l /dev/$disk || break
        fdisk /dev/$disk << EOF
n
p
1


t
fd
w
EOF
        createdPartitions="$createdPartitions /dev/${disk}1"
	done

    # Create RAID-0 volume
    if [ -n "$createdPartitions" ]; then
        devices=`echo $createdPartitions | wc -w`
        mdadm --create /dev/md10 --level 0 --raid-devices $devices $createdPartitions
	    mkfs -t ext4 /dev/md10
	    echo "/dev/md10 $mountPoint ext4 defaults,nofail 0 2" >> /etc/fstab
        mkdir -p $mountPoint
	    mount /dev/md10
    fi
}

setup_filesystems()
{

    if is_master; then
        setup_data_disks $SHARE_PATH
        mkdir -p $SHARE_HOME
        mkdir -p $SHARE_PROJ
        mkdir -p $SHARE_SOFT
        mkdir -p $SHARE_UTIL
        echo "$SHARE_HOME    *(rw,async)" >> /etc/exports
        echo "$SHARE_PROJ    *(rw,async)" >> /etc/exports
        echo "$SHARE_SOFT    *(rw,async)" >> /etc/exports
        echo "$SHARE_CONF    *(rw,async)" >> /etc/exports
        echo "$SHARE_UTIL    *(rw,async)" >> /etc/exports

        systemctl enable rpcbind || echo "Already enabled"
        systemctl enable nfs-server || echo "Already enabled"
        systemctl start rpcbind || echo "Already enabled"
        systemctl start nfs-server || echo "Already enabled"
    else
        mkdir -p $SHARE_HOME
        mkdir -p $SHARE_PROJ
        mkdir -p $SHARE_SOFT
        mkdir -p $SHARE_CONF
        echo "master:$SHARE_HOME /home          nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        echo "master:$SHARE_PROJ /projects      nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        echo "master:$SHARE_SOFT $SHARE_SOFT    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        echo "master:$SHARE_CONF $SHARE_CONF    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        echo "master:$SHARE_UTIL $SHARE_UTIL    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        mount -a
    fi
}

setup_configspace()
{
    if is_master; then
        chown $ADMIN_USER:$ADMIN_USER $SHARE_PATH
        su - $ADMIN_USER -c "cd $SHARE_PATH; git clone -b azure https://$TOKEN:x-oauth-basic@$PRIVATE_REPO "
    fi
}

setup_admin_user()
{
    if is_master; then
        #groupmod -g $ADMIN_GID $ADMIN_GROUP
        #usermod -c "Admin User" -g $ADMIN_GID -d $SHARE_HOME/$ADMIN_USER -s /bin/bash -m -u $ADMIN_UID $ADMIN_USER
        # Configure public key auth for the HPC user
        mkdir -p $SHARE_HOME/$ADMIN_USER/.ssh
        chown -R $ADMIN_USER $SHARE_HOME/$ADMIN_USER
        sudo -u $ADMIN_USER ssh-keygen -t rsa -f $SHARE_HOME/$ADMIN_USER/.ssh/id_rsa -q -P ""
        cat $SHARE_HOME/$ADMIN_USER/.ssh/id_rsa.pub > $SHARE_HOME/$ADMIN_USER/.ssh/authorized_keys
        echo "Host *" > $SHARE_HOME/$ADMIN_USER/.ssh/config
        echo "    StrictHostKeyChecking no" >> $SHARE_HOME/$ADMIN_USER/.ssh/config
        echo "    UserKnownHostsFile /dev/null" >> $SHARE_HOME/$ADMIN_USER/.ssh/config
        echo "    PasswordAuthentication no" >> $SHARE_HOME/$ADMIN_USER/.ssh/config
        chown $ADMIN_USER:$ADMIN_GROUP $SHARE_HOME/$ADMIN_USER/.ssh/authorized_keys
        chown $ADMIN_USER:$ADMIN_GROUP $SHARE_HOME/$ADMIN_USER/.ssh/config
        chown $ADMIN_USER:$ADMIN_GROUP $SHARE_PROJ
        chmow 755 $SHARE_PROJ $SHARE_HOME $SHARE_SOFT
    else
        #useradd -c "Admin User" -g $ADMIN_GROUP -d $SHARE_HOME/$ADMIN_USER -s /bin/bash -u $ADMIN_UID $ADMIN_USER
        echo "nothing to do here"
    fi
    # Don't require password for Admin user sudo
    echo "$ADMIN_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
}

setup_hpc_user()
{
    if is_master; then
        groupmod -g $HPC_GID $HPC_GROUP
        useradd -c "HPC User" -g $HPC_GID -d $SHARE_HOME/$HPC_USER -s /bin/bash -m -u $HPC_UID $HPC_USER
        # Configure public key auth for the HPC user
        sudo -u $HPC_USER ssh-keygen -t rsa -f $SHARE_HOME/$HPC_USER/.ssh/id_rsa -q -P ""
        cat $SHARE_HOME/$HPC_USER/.ssh/id_rsa.pub > $SHARE_HOME/$HPC_USER/.ssh/authorized_keys
        echo "Host *" > $SHARE_HOME/$HPC_USER/.ssh/config
        echo "    StrictHostKeyChecking no" >> $SHARE_HOME/$HPC_USER/.ssh/config
        echo "    UserKnownHostsFile /dev/null" >> $SHARE_HOME/$HPC_USER/.ssh/config
        echo "    PasswordAuthentication no" >> $SHARE_HOME/$HPC_USER/.ssh/config
        chown $HPC_USER:$HPC_GROUP $SHARE_HOME/$HPC_USER/.ssh/authorized_keys
        chown $HPC_USER:$HPC_GROUP $SHARE_HOME/$HPC_USER/.ssh/config
    else
        useradd -c "HPC User" -g $HPC_GROUP -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER
    fi
}

# Setup SSH daemons, hosts keys and root SSH keys
setup_ssh()
{
    if is_master; then
        setup_admin_user
        mkdir -p $SHARE_CONF/system_files/etc/ssh/
        cp -pr /etc/ssh/ssh_host_* $SHARE_CONF/system_files/etc/ssh/
        mkdir -p /root/.ssh
        cp -p $SHARE_HOME/$ADMIN_USER/.ssh/authorized_keys /root/.ssh/authorized_keys
        chown -R root:root /root/.ssh
        chmod 700 .ssh
        chmod 640 .ssh/authorized_keys
    else
        setup_admin_user
        setup_hpc_user
        cp -pr $SHARE_CONF/system_files/etc/ssh/ssh_host_* /etc/ssh/
        cp -p $SHARE_CONF/system_files/etc/ssh/shosts.equiv /etc/ssh/
        chmod u+s /usr/lib64/ssh/ssh-keysign
        cp -p /etc/ssh/shosts.equiv /root/.shosts
        mkdir -p /root/.ssh
        cp -p /home/$ADMIN_USER/.ssh/authorized_keys /root/.ssh/authorized_keys
        chown -R root:root /root/.ssh
        chmod 700 .ssh
        chmod 640 .ssh/authorized_keys
        systemctl restart sshd
    fi
}

setup_env()
{
    if ! is_master; then
        # Set unlimited mem lock
        echo "@$HPC_GROUP hard stack unlimited" >> /etc/security/limits.conf
        echo "@$HPC_GROUP soft stack unlimited" >> /etc/security/limits.conf
        echo "@$HPC_GROUP soft memlock unlimited" >> /etc/security/limits.conf
        echo "@$HPC_GROUP soft memlock unlimited" >> /etc/security/limits.conf
        echo "*           hard   nofile    1024000" >> /etc/security/limits.conf
        echo "*           soft   nofile    1024000" >> /etc/security/limits.conf
        # User enviroment setup
        cp -p $SHARE_CONF/system_files/etc/profile.d/easybuild.sh /etc/profile.d/
        cp -p $SHARE_CONF/system_files/etc/cpu-id-map.conf /etc/
    fi
}

install_software()
{
    case $1 in
        Debian*)
            pkgs="build-essential libbz2-1.0 libssl-dev nfs-client rpcbind curl wget gawk patch unzip libibverbs libibverbs-devel python-devel python-pip apt-transport-https ca-certificates members git parallel vim"
            if ! is_master; then
                pkgs="$pkgs Lmod tcl tcl-devel"
            fi
            INSTALLER="apt-get -y install"
            apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
            echo "deb https://apt.dockerproject.org/repo debian-jessie main" > /etc/apt/sources.list.d/docker.list
            apt-get -y update
        ;;
        Ubuntu*)
            pkgs="build-essential libbz2-1.0 libssl-dev nfs-client rpcbind curl wget gawk libibverbs libibverbs-devel python-devel python-pip apt-transport-https ca-certificates members git parallel vim"
            if ! is_master; then
                pkgs="$pkgs Lmod tcl tcl-devel"
            fi
            INSTALLER="apt-get -y install"
            apt-get -y update
        ;;
        RHEL*|CentOS*)
            pkgs="epel-release @base @development-tools lsb libdb flex perl perl-Data-Dumper perl-Digest-MD5 perl-JSON perl-Parse-CPAN-Meta perl-CPAN pcre pcre-devel zlib zlib-devel bzip2 bzip2-devel bzip2-libs openssl openssl-devel openssl-libs nfs-utils rpcbind mdadm wget curl gawk patch unzip libibverbs libibverbs-devel python-devel python-pip members git parallel vim"
            if ! is_master; then
                pkgs="$pkgs Lmod tcl tcl-devel"
            fi
            INSTALLER="yum -y install"
            yum -y update
       ;;
       SLES*|OpenSUSE*)
            add_sdk_repo
            #zypper -n --gpg-auto-import-keys ar http://download.opensuse.org/repositories/network:/cluster/SLE_12/network:cluster.repo
            pkgs="libbz2-1 libz1 openssl libopenssl-devel gcc gcc-c++ nfs-client rpcbind wget curl gawk libibverbs libibverbs-devel python-devel python-pip members git parallel vim"
            if ! is_master; then
                pkgs="$pkgs Lmod tcl tcl-devel"
            fi
            INSTALLER="zypper -n install"
       ;;
   esac
   $INSTALLER $pkgs
}

setup_software()
{
    if is_master; then
        install_software $MASTER_OS
    else
        install_software $WORKER_OS
        install_easybuild
    fi
}

install_lmod()
{
    if is_first_worker; then
        yum install lua lua-filesystem lua-posix -y
        su - $HPC_USER -c "git clone https://github.com/TACC/Lmod.git; cd Lmod; ./configure --prefix=/share/utils; make; make install"
        ln -s /share/utils/lmod/lmod/init/profile /etc/profile.d/lmod.sh
        ln -s /share/utils/lmod/lmod/init/cshrc /etc/profile.d/lmod.csh
        echo "Lmod installed"
    fi
}

install_easybuild()
{
    if is_first_worker; then
        chown $HPC_USER:$HPC_GROUP $SHARE_SOFT
        cd $SHARE_SOFT
        curl -O https://raw.githubusercontent.com/hpcugent/easybuild-framework/develop/easybuild/scripts/bootstrap_eb.py
        su - $HPC_USER -c "source /etc/profile.d/easybuild.sh; python $SHARE_SOFT/bootstrap_eb.py $SHARE_SOFT"
        echo "Easybuild installed"
    fi
}

install_docker()
{
    case $1 in
        Debian*)
            apt-get -y purge lxc-docker*
            apt-get -y purge docker.io*
            apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
            echo "deb https://apt.dockerproject.org/repo debian-jessie main" > /etc/apt/sources.list.d/docker.list
            apt-get -y update
            apt-cache policy docker-engine
            apt-get -y install docker-engine
            groupadd docker
            gpasswd -a $ADMIN_USER docker
            service docker restart
        ;;
        Ubuntu*)
            apt-get -y install linux-image-extra-$(uname -r)
            apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
            echo "deb https://apt.dockerproject.org/repo ubuntu-wily main" > /etc/apt/sources.list.d/docker.list
            apt-get -y update
            apt-get -y purge lxc-docker
            apt-cache policy docker-engine
            apt-get -y install docker-engine
            usermod -aG docker $ADMIN_USER
            echo "GRUB_CMDLINE_LINUX=\"cgroup_enable=memory swapaccount=1\"" >> /etc/default/grub
            update-grub
            service docker start
            systemctl enable docker
        ;;
        RHEL*|CentOS*)
            yum -y update
            curl -sSL https://get.docker.com/ | sh
            usermod -aG docker $ADMIN_USER
            chkconfig docker on
            service docker start
       ;;
       SLES*|OpenSUSE*)
           zypper -n --no-gpg-checks in docker
           /usr/sbin/usermod -a -G docker $ADMIN_USER
           echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
           sysctl -p /etc/sysctl.conf
           systemctl start docker
           systemctl enable docker
       ;;
   esac
}

setup_docker()
{
    if is_master; then
        install_docker $MASTER_OS
        curl -L https://github.com/docker/compose/releases/download/1.6.0/docker-compose-`uname -s`-`uname -m` > /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        su - $ADMIN_USER -c "cd $SHARE_CONF/docker_files; docker-compose up -d"
    else
        echo "Nothing to be done yet"
    fi
}

setup_ldap_client()
{
    if ! is_master; then
        yum install sssd -y
        cp -p /share/configspace/system_files/etc/sssd/sssd.conf.cn /etc/sssd/sssd.conf
        chown root:root /etc/sssd/sssd.conf
        chmod 600 /etc/sssd/sssd.conf
        systemctl enable sssd.service
        systemctl start sssd.service
    fi
}

install_slurm()
{
    if ! is_master; then
        groupadd -g $SLURM_GID slurm
        adduser -u $SLURM_UID -g $SLURM_GID -s /bin/false slurm
        yum install munge munge-devel -y
        cp -p /share/configspace/system_files/etc/munge/munge.key /etc/munge/munge.key
        chown -R munge:munge /etc/munge
        chmod 600 /etc/munge/munge.key
        systemctl enable munge.service
        systemctl start munge.service
        yum groupinstall 'Development Tools' -y
        yum install ncurses gtk2 rrdtool libcgroup hwloc lua pam-devel numactl hdf5 perl-DBI perl-Switch -y
        sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/sysconfig/selinux 
        chkconfig iptables off
        cd /share/projects/RHEL/7.2/x86_64/
        rpm -ivh slurm-15.08.8-1.el7.centos.x86_64.rpm slurm-lua-15.08.8-1.el7.centos.x86_64.rpm slurm-munge-15.08.8-1.el7.centos.x86_64.rpm slurm-pam_slurm-15.08.8-1.el7.centos.x86_64.rpm slurm-perlapi-15.08.8-1.el7.centos.x86_64.rpm slurm-plugins-15.08.8-1.el7.centos.x86_64.rpm slurm-sjobexit-15.08.8-1.el7.centos.x86_64.rpm slurm-sjstat-15.08.8-1.el7.centos.x86_64.rpm
        cp -pr /share/configspace/system_files/etc/slurm/* /etc/slurm/
        mkdir -p /var/run/slurm /var/spool/slurmd /var/spool/slurm /var/log/slurm
        chown -R slurm:slurm /etc/slurm /var/spool/slurmd /var/spool/slurm /var/log/slurm
        echo "130.216.161.212 slurmdbd-01" >> /etc/hosts
        systemctl enable slurmd.service
        systemctl start slurmd.service
    fi
}

setup_software
setup_filesystems
setup_configspace
setup_ssh
setup_env
install_lmod
install_easybuild
install_slurm
setup_docker
