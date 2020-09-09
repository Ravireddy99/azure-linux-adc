#!/bin/bash

#############################################################
# Program: azure-linux-adc.sh
# Description:
# Authors: Alex Campos, James Low, Donavan Morris
# Version: 1.0.0
#############################################################


#Global variables definition
distro_name="none"
distro_ver="none"

#Read command line parameters
while getopts u:p:U:t:e:f:W:s: option
do
  case "${option}"
  in
      u) ADMIN_USERNAME=${OPTARG};;
      p) ADMIN_PASSWORD=${OPTARG};;
      U) OS_PATCHES=${OPTARG};;
      t) TIME_ZONE=$OPTARG;;
      e) SFT_ENROLLMENT_TOKEN=$OPTARG;;
      f) FILE_URL=$OPTARG;;
      W) WEB_ARGUMENTS=$OPTARG;;
      s) SAS_TOKEN=$OPTARG;;
  esac
done

function local_hostname()
{
  hostname=`hostname`
  echo "127.0.0.1 ${hostname}" >> /etc/hosts
}

function get_osdistro()
{
  if [[ -e /etc/redhat-release ]]; then
    RELEASERPM=$(rpm -qf /etc/redhat-release)
    case $RELEASERPM in
      redhat*)
        distro_name=RHEL
        ;;
      centos*)
        distro_name=CentOS
        ;;
      *)
        echo "Could not determine if OS is RHEL or CentOS from redhat-release package." >> /root/adclog-`date +%Y%m%d`
        exit 1
        ;;
    esac
    distro_ver=$(rpm -q --qf '%{VERSION}' $RELEASERPM | cut -b1)
  else
    distro_name=`lsb_release -si`
    distro_ver=`lsb_release -rs | cut -d\. -f1`
    if [[ $distro_name != "Ubuntu" ]]
    then
      echo "Only Red Hat, CentOS and Ubuntu operating systems are suported." >> /root/adclog-`date +%Y%m%d`
      exit 1
    fi
  fi
}


function install_packages()
{
  case $distro_name in
    RHEL|CentOS*)
      yum -y install @core
      yum -y install @base
      yum -y install autoconf automake bison boost compat-libstdc++-33 \
        device-mapper device-mapper-event device-mapper-multipath elfutils \
        gcc iptables-services kernel-devel kernel-headers m4 nc \
        net-tools perl-Crypt-SSLeay \
        perl-libwww-perl psmisc screen sharutils \
        strace python-hwdata mcelog nmap xfsprogs wget yum-utils yum-cron telnet nano vim
      if [[ $distro_ver -eq 6 ]]
      then
        chkconfig yum-cron on
        /etc/init.d/yum-cron start
      else
        sed -i -e 's/^apply_updates.*/apply_updates = yes/g' -e 's/^update_messages.*/update_messages = no/g' -e 's/^random_sleep.*/random_sleep = 60/g' /etc/yum/yum-cron.conf
        systemctl enable yum-cron
        systemctl start yum-cron.service
      fi
      ;;
    Ubuntu)
      #apt-get clean && apt-get -qq update && apt-get upgrade -y --force-yes
      echo -e "APT::Periodic::Update-Package-Lists \"1\";\nAPT::Periodic::Unattended-Upgrade \"1\";" > /etc/apt/apt.conf.d/20auto-upgrades
      ;;
  esac
}


function install_scaleft()
{
  case $distro_name in
   RHEL|CentOS*|Red*)
   # Perform ScaleFT Server Installation as per : https://www.scaleft.com/docs/sftd-redhat/
   printf " WARN -\tInstalling ScaleFT software..\n"

   # Add the ScaleFT yum repository
   curl -C - https://www.scaleft.com/dl/scaleft_yum.repo |  tee /etc/yum.repos.d/scaleft.repo
   # Trust the repository signing key
   rpm --import https://www.scaleft.com/dl/scaleft_rpm_key.asc
   yum install scaleft-server-tools --nogpg -y

   if [ -d "/var/lib/sftd" ]; then
       echo "$SFT_ENROLLMENT_TOKEN" > /var/lib/sftd/enrollment.token
   else
      mkdir /var/lib/sftd
      echo "$SFT_ENROLLMENT_TOKEN" > /var/lib/sftd/enrollment.token
   fi

   systemctl start sftd
    ;;
   Ubuntu)
    # Perform ScaleFT Server Installation as per : https://www.scaleft.com/docs/sftd-ubuntu/
    # Add the ScaleFT apt repo to your /etc/apt/sources.list system config file:
    echo "deb http://pkg.scaleft.com/deb linux main" | tee -a /etc/apt/sources.list

    # Trust the repository signing key:
    curl -C - https://www.scaleft.com/dl/scaleft_deb_key.asc | apt-key add -

    # Retrieve information about new packages
    if [ -d "/var/lib/sftd" ]; then
       echo "$SFT_ENROLLMENT_TOKEN" > /var/lib/sftd/enrollment.token
    else
      mkdir /var/lib/sftd
      echo "$SFT_ENROLLMENT_TOKEN" > /var/lib/sftd/enrollment.token
    fi
    apt-get update
    apt-get install scaleft-server-tools -y

   ;;
  esac
}



#Create file to mark completion and store useful info.
function validate_scaleft()
{

  for i in {1..30}
  do
    if [ -f "/var/lib/sftd/device.token" ]; then
      IS_VALID=1
      break
    else
      IS_VALID=0
    fi
    sleep 1s
  done

}

function install_updates()
{
  case $distro_name in
    RHEL|CentOS*)
      yum clean all && yum --exclude=WALinuxAgent* update -y
      ;;
    Ubuntu)
      apt-mark hold walinuxagent
      apt-get clean && apt-get -qq update && apt-get upgrade -y
      apt-mark unhold walinuxagent
      ;;
  esac
}

function install_recap()
{
  # Install required packages
  case $distro_name in
    RHEL|CentOS*)
      yum install git bc elinks net-tools sysstat iotop make -y
      ;;
    Ubuntu)
      apt-get install git bc elinks net-tools sysstat iotop make -y
      ;;
  esac

  # Install Recap
  git clone https://github.com/rackerlabs/recap.git /root/recap
  make install -C /root/recap/
  rm -rf /root/recap/

  # Configure Recap
  sed 's/USEMYSQL=.*/USEMYSQL=no/' /etc/recap -i
  RECAPLOC=`which recap`
  RECAPLOG=`which recaplog`
  echo "@reboot root ${RECAPLOC} -B
*/5 * * * * root ${RECAPLOC}
0 1 * * * root ${RECAPLOG}" > /etc/cron.d/recap
}

function disable_selinux()
{
  case $distro_name in
    RHEL|CentOS*)
      sed 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config -i
      setenforce 0
      ;;
  esac
}

function disable_firewall()
{
  case $distro_name in
    RHEL|CentOS*)
      if [[ $distro_ver -eq 6 ]]
      then
        iptables -F
        /etc/init.d/iptables save
      elif [[ $distro_ver -eq 7 ]]
      then
        yum remove firewalld firewalld-filesystem -y
        iptables -F
        iptables-save > /etc/sysconfig/iptables
      fi
      ;;
    Ubuntu)
      if [[ $distro_ver -lt 16 ]]
      then
        service ufw stop
        update-rc.d ufw disable
        iptables -F
      else
        systemctl stop ufw.service
        systemctl disable ufw.service
        iptables -F
      fi
      ;;
  esac
}


function install_ius()
{
  case $distro_name in
    RHEL)
      rpm --import https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-${distro_ver}
      yum -q -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-${distro_ver}.noarch.rpm
      yum -q -y install https://${distro_name}${distro_ver}.iuscommunity.org/ius-release.rpm
      rpm --import /etc/pki/rpm-gpg/IUS-COMMUNITY-GPG-KEY
      ;;
    CentOS)
      yum -q -y install https://${distro_name}${distro_ver}.iuscommunity.org/ius-release.rpm
      rpm --import /etc/pki/rpm-gpg/IUS-COMMUNITY-GPG-KEY
      ;;
  esac
}

function mount_drive()
{
  # Install LVM package
  case $distro_name in
    RHEL|CentOS*)
      yum install lvm2 -y
      ;;
    Ubuntu)
      echo -e "\nmounts:\n - [ ephemeral0, /mnt/resource, auto, \"defaults,nofail,relatime\", \"0\", \"2\" ]" >> /etc/cloud/cloud.cfg
      apt-get install lvm2 -y
      sed '/cloud\/azure.*\t\/mnt/s/\/mnt/\/mnt\/resource/g' /etc/fstab -i
      sed '/^ResourceDisk\.MountPoint/s/\/mnt/\/mnt\/resource/g' /etc/waagent.conf -i
      umount /mnt
      mkdir /mnt/resource
      ;;
  esac

  DRIVES=(`fdisk -l | grep \/dev\/ | grep ^Disk | egrep -v ram?? | awk '{print $2}' | cut -d: -f1 | sort | tail -n +3`)
  DRIVECOUNT=${#DRIVES[@]}
  COUNTER=0

  # Partition disk and create LVM
  while [[ ${COUNTER} -lt ${DRIVECOUNT} ]]
  do
    echo "n
p
1


t
8e
w
" | fdisk ${DRIVES[${COUNTER}]}

    COUNTERPAD=$(echo ${COUNTER} | awk '{printf("%02d", $1)}')
    pvcreate ${DRIVES[${COUNTER}]}1
    vgcreate data${COUNTERPAD} ${DRIVES[${COUNTER}]}1
    lvcreate -n root -l +100%FREE data${COUNTERPAD}

    mkdir /mnt/disk${COUNTERPAD}
    echo -e "/dev/mapper/data${COUNTERPAD}-root\t\t\t/mnt/disk${COUNTERPAD}\text4\tdefaults,nofail,noatime,nodiratime\t0 0" >> /etc/fstab

    COUNTER=$[${COUNTER}+1]
  done

  # Format disks in parallel
  if [[ ${DRIVECOUNT} -gt 0 ]]
  then
    for i in $(seq -w 00 ${DRIVECOUNT});
    do
      (
        mkfs.ext4 /dev/mapper/data${i}-root;
        tune2fs -c 0 -i 0d -m 0 /dev/mapper/data${i}-root;
      ) &
    done; wait
  fi

  mount -a
}

function add_adminuser()
{
  echo "Adding Admin user $ADMIN_USERNAME to the system."
  case $distro_name in
   RHEL|CentOS*)
    useradd $ADMIN_USERNAME
    usermod -a -G wheel $ADMIN_USERNAME
    echo "$ADMIN_PASSWORD" | passwd --stdin $ADMIN_USERNAME 
    echo "$ADMIN_USERNAME ALL=(ALL) ALL" > /etc/sudoers.d/admins
    sed '0,/^\#.*\%wheel/s//\%wheel/' /etc/sudoers -i
    ;;
   Ubuntu)
    useradd $ADMIN_USERNAME -s /bin/bash -m
    usermod -a -G sudo $ADMIN_USERNAME
    echo -e "$ADMIN_PASSWORD\n$ADMIN_PASSWORD" | passwd $ADMIN_USERNAME 
    ;;
  esac
}

function set_timezone()
{
  TZ=`curl --connect-timeout 10 --retry 10 -m 120 -s https://raw.githubusercontent.com/whyneus/ghetto-bash/master/misc/timezones.txt | grep "^${TIME_ZONE}" | head -n1 | awk -F\  '{ print $NF }'`
  if [[ -z ${TZ} || -z ${TIME_ZONE} ]]
  then
    TZ="/Etc/UTC"
  fi

  case $distro_name in
    RHEL|CentOS*)
      if [[ $distro_ver -eq 6 ]]
      then
        echo "ZONE=\"${TZ}\"" > /etc/sysconfig/clock
        rm -f /etc/localtime
        ln -s /usr/share/zoneinfo/${TZ} /etc/localtime
      elif [[ $distro_ver -eq 7 ]]
      then
        timedatectl set-timezone ${TZ}
      fi
      ;;
    Ubuntu)
      if [[ $distro_ver -eq 14 ]] || [[ $distro_ver -eq 16 ]]
      then
        timedatectl set-timezone ${TZ}
      fi
      ;;
  esac
}

function check_run()
{
  if [ -f /root/.adc_done ]; then
    echo "This script ran once, remove /root/.adc_done to force a re-run."
    exit 0
  fi

}

#Create file to mark completion and store useful info.
function adc_done()
{
   echo $distro_name > /root/.adc_done
}

function reboot_server()
{
  shutdown -rf +m 2
}



function install_webserver()
{
  wget -O /usr/local/src/azure-linux-webserver.sh ${FILE_URL}azure-linux-webserver.sh${SAS_TOKEN}
  chmod u+x /usr/local/src/azure-linux-webserver.sh
  echo "DEBUG: /usr/local/src/azure-linux-webserver.sh $WEB_ARGUMENTS"
  /usr/local/src/azure-linux-webserver.sh $WEB_ARGUMENTS

}
###########################################
#
#             MAIN PROGRAM
#
###########################################

echo "DEBUG: received parameters: "
echo "-u $ADMIN_USERNAME"
echo "-p $ADMIN_PASSWORD"
echo "-U $OS_PATCHES"
echo "-t $TIME_ZONE"
echo "-e $SFT_ENROLLMENT_TOKEN"
echo "-f $FILE_URL"
echo "-W $WEB_ARGUMENTS"
echo "-s $SAS_TOKEN"


check_run
local_hostname
get_osdistro
add_adminuser
set_timezone
disable_selinux
install_ius
if [ "$OS_PATCHES" == "Yes" ]; then
   echo "Installing OS Patches"
   install_updates
else
  echo "Skipping installation of OS patches"
fi
install_packages
disable_firewall
install_recap
mount_drive

if [[ $WEB_ARGUMENTS != "none" ]]; then
  install_webserver
fi

#install_scaleft
#validate_scaleft

adc_done
#reboot_server
