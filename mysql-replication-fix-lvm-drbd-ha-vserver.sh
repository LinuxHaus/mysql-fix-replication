#!/bin/bash
#MySQL Replikation wieder aufsetzen mit VServer/DRBD/LVM.
#  Plan: MySQL-VServer MASTER laeuft auf SEITEA, MySQL-VServer SLAVE laeuft auf SEITEB.
#  /var/lib/mysql ist $SIZE gross. Volumegroups heissen $VGSEITEA und $VGSEITEB.
#  DRBDIPA und DRBDIPA sind die IPs der Direktverbindung zwischen $SEITEA und $SEITEB.
#  Der Snapshot ist SIZESNAP gross.
#
#echo Versuch mit Parametrisierung, nicht als Skript geeignet.
#exit 1

SEITEB="otherside"
NOTMPLV="0"
TMPLV="temp"
TMPVG=""
VGSEITEB=""
LV=""
SIZE=""
SIZESNAP=""
MASTER=""
SLAVE=""
DRBD="1"
REPLINFO="/root/master-replication-info"

print_help() {
	echo "Usage: $0 --seiteb=otherside --tmplv=temp --tmpvg=vg --vgseiteb=vgname --lv=lvname --size=size --sizesnap=sizesnap --master=master --slave=slave --replinfo=replinfo" >&2
	echo "--nodrbd: no drbd involved" >&2
	echo "--notmplv: no tmplv, copy directly from snapshot" >&2
	echo "--seiteb: hostname/ip of other cluster host, defaults to 'otherside', make sure passwordless login works with ssh" >&2
	echo "--tmplv:  name of temporary logical volume on $SEITEB, defaults to 'temp'" >&2
	echo "--tmpvg:  name of volumegroup for temporary logical volume on $SEITEB, defaults to 'vg_$SEITEB'" >&2
	echo "--vgseitea: volume group to use on seitea" >&2
	echo "--vgseiteb: name of volumegroup containing the logical volume with drbd secondary containing the master mysql servers /var/lib/mysql, defaults to 'vg_$SEITEB'" >&2
	echo "--lv:  name of logical volume containing volume with drbd secondary containing the master mysql servers /var/lib/mysql, no default" >&2
	echo "--size:  Size of a temporary volume holding the whole of /var/lib/mysql, defaults to size of lv holding /var/lib/mysql" >&2
	echo "--sizesnap:  Size of snapshotvolume, defaults to size of lv holding /var/lib/mysql" >&2
	echo "--fs:  fstype of /var/lib/mysql, no default, no error checking" >&2
	echo "--master:  Name of VServer holding the MySQL master" >&2
	echo "--slave:  Name of VServer holding the MySQL slave" >&2
}
error() {
  print_help
  echo "$*"
  exit 1
}

TEMP=`getopt -o h --long help,nodrbd,seiteb:,notmplv,tmplv:,tmpvg:,vgseitea:,vgseiteb:,lv:,size:,sizesnap:,master:,slave:,fs:,replinfo: -- "$@"`
if [ $? != 0 ] ; then print_help >&2 ; exit 1 ; fi
eval set -- "$TEMP"
while true ; do
	case "$1" in
		--nodrbd) DRBD=0; shift 2;;
		--seiteb) SEITEB=$2; shift 2;;
		--notmplv) NOTMPLV=0; shift 1;;
		--tmplv) TMPLV=$2; shift 2;;
		--tmpvg) TMPVG=$2; shift 2;;
		--vgseitea) VGSEITEA=$2; shift 2;;
		--vgseiteb) VGSEITEB=$2; shift 2;;
		--lv) LV=$2; shift 2;;
		--size) SIZE=$2; shift 2;;
		--sizesnap) SIZESNAP=$2; shift 2;;
		--master) MASTER=$2; shift 2;;
		--slave) SLAVE=$2; shift 2;;
		--fs) FS=$2; shift 2;;
		--replinfo) REPLINFO=$2; shift 2;;
		--help|-h) print_help; shift 1; exit 0;;
		--) shift ; break ;;
		*) echo "Unknown parameter $1i, try -h" ; exit 1 ;;
	esac
done

echo "Checking parameters..."
if ! which fsfreeze >/dev/null 2>&1; then
	error "Install fsfreeze / util-linux version wheezy and up"
fi
if ! which mbuffer >/dev/null 2>&1; then
	error "Install mbuffer"
fi
if [ x$FS == x ]; then
	error "Missing parameter --fs"
fi
if [ x$SEITEB == x ]; then
	error "Missing parameter --seiteb"
else
	if ! ping -c1 $SEITEB >/dev/null 2>&1; then
		error "$SEITEB nicht per ping erreichbar, parameter --seiteb"
	fi
	if ! ssh -X -a $SEITEB true; then
		error "$SEITEB nicht per ssh erreichbar, parameter --seiteb"
	fi
fi
if [ x$NOTMPLV == x0 ] && [ x$TMPLV == x ]; then
	error "Missing parameter --tmplv and not using --notmplv"
else
	if [ x$TMPVG == x ]; then
		if [ x$DRBD == x1 ]; then
			TMPVG=vg_$SEITEB
		else
			TMPVG=$VGSEITEA
		fi
	fi
	if [ x$DRBD == x1 ]; then
		if ssh -X -a $SEITEB ls /dev/$TMPVG/$TMPLV >/dev/null 2>&1; then
			error "$SEITEB: /dev/$TMPVG/$TMPLV already exists, parameter --tmplv"
		elif ! ssh -X -a $SEITEB vgdisplay $TMPVG >/dev/null 2>&1; then
			error "$SEITEB: VG $TMPVG doesn't exist, parameter --tmpvg"
		fi
	else
		if ls /dev/$TMPVG/$TMPLV >/dev/null 2>&1; then
			error "$HOSTNAME: /dev/$TMPVG/$TMPLV already exists, parameter --tmplv"
		elif ! vgdisplay $TMPVG >/dev/null 2>&1; then
			error "$HOSTNAME: VG $TMPVG doesn't exist, parameter --tmpvg"
		fi
	fi
fi
if [ x$VGSEITEB == x ]; then
	VGSEITEB=vg_$SEITEB
fi
if ! ssh -X -a $SEITEB vgdisplay $VGSEITEB >/dev/null 2>&1; then
	error "$SEITEB: VG $VGSEITEB doesn't exist" 
	exit 1
fi
if [ x$LV == x ]; then
	error "Missing parameter --lv"
fi
if [ x$DRBD == x1 ]; then
	if ! ssh -X -a $SEITEB ls /dev/$VGSEITEB/$LV >/dev/null 2>&1; then
		error "$SEITEB: /dev/$VGSEITEB/$LV doesn't exist, parameters --vgseiteb and --lv"
	fi
else
	if ! ls /dev/$VGSEITEA/$LV >/dev/null 2>&1; then
		error "$HOSTNAME: /dev/$VGSEITEA/$LV doesn't exist, parameters --vgseitea and --lv"
	fi
fi
if [ x$SIZE == x ]; then
	if [ x$DRBD == x1 ]; then
		SIZE=$(ssh -X -a $SEITEB lvs --units s | awk '$2 ~ /^'$VGSEITEB'$/ && $1 ~ /^'$LV'$/ {print $4}')
	else
		SIZE=$(lvs --units s | awk '$2 ~ /^'$VGSEITEA'$/ && $1 ~ /^'$LV'$/ {print $4}')
	fi
fi
if [ x$SIZESNAP == x ]; then
	SIZESNAP=$SIZE
fi
if [ x$MASTER == x ]; then
	error "Missing parameter --master"
else
	if [ 1 -ne $(vserver-stat 2>/dev/null | awk '$8 ~ /^'$MASTER'$/' | wc -l) ]; then
		error "--master $MASTER not running here"
	elif [ ! -d /etc/vservers/$MASTER/vdir/var/lib/mysql/ ]; then
		error "/etc/vservers/$MASTER/vdir/var/lib/mysql/ is no directory"
	fi
fi
if [ x$SLAVE == x ]; then
	error "Missing parameter --slave"
fi
if [ 1 -ne $(ssh -X -a $SEITEB vserver-stat 2>/dev/null | awk '$8 ~ /^'$SLAVE'$/' | wc -l) ]; then
	error "--slave $SLAVE not running on $SEITEB"
elif ssh -X -a $SEITEB "[ ! -d /etc/vservers/$SLAVE/vdir/var/lib/mysql/ ]"; then
	error "$SEITEB:/etc/vservers/$MASTER/vdir/var/lib/mysql/ is no directory"
fi

echo "Parameters:
SEITEB=\"$SEITEB\"
NOTMPLV=\"$NOTMPLV\"
TMPLV=\"$TMPLV\"
TMPVG=\"$TMPVG\"
DRBD=\"$DRBD\"
VGSEITEB=\"$VGSEITEB\"
LV=\"$LV\"
SIZE=\"$SIZE\"
SIZESNAP=\"$SIZESNAP\"
MASTER=\"$MASTER\"
SLAVE=\"$SLAVE\"
REPLINFO=\"$REPLINFO\"
Resulting in
$0 --seiteb=$SEITEB --tmplv=$TMPLV --tmpvg=$TMPVG --vgseiteb=$VGSEITEB --lv=$LV --size=$SIZE --sizesnap=$SIZESNAP --master=$MASTER --slave=$SLAVE --replinfo=$REPLINFO
"

read -p "Type 'Yes, I understand this might destroy all my data' to continue: " GO
if [ "x$GO" != "xYes, I understand this might destroy all my data" ]; then
  echo aborted
  exit 1
fi

# auf $SEITEA, 1 shell sparen. $SEITEB damit der Snapshot schnell wieder aufgeloest werden kann als Puffer
if [ x$DRBD == x1 ]; then
	ssh -X -a $SEITEB "(
    if [ x$NOTMPLV == x0 ]; then
		  lvcreate -L$SIZE -n $TMPLV $TMPVG
		  mkfs.ext4 /dev/$TMPVG/$TMPLV
		  mkdir -p /mnt/tempmysqlsync
		  mount /dev/$TMPVG/$TMPLV /mnt/tempmysqlsync
    fi
		mkdir -p /mnt/tempmysqlsnap
	)"
else
  if [ x$NOTMPLV == x0 ]; then
		lvcreate -L$SIZE -n $TMPLV $TMPVG
		mkfs.ext4 /dev/$TMPVG/$TMPLV
		mkdir -p /mnt/tempmysqlsync
		mount /dev/$TMPVG/$TMPLV /mnt/tempmysqlsync
  fi
	mkdir -p /mnt/tempmysqlsnap
fi

MOUNTPOINT=$(df /etc/vservers/$MASTER/vdir/var/lib/mysql | sed '1d; s/.* //')
RELPATH=$(echo $(cd -P /etc/vservers/$MASTER/vdir/var/lib/mysql; pwd) | sed "s#^$MOUNTPOINT##")
vserver $MASTER exec bash -c "(
rm -f $REPLINFO
mknod /tmp/replicationpipe p
( echo FLUSH TABLES WITH READ LOCK\; SHOW MASTER STATUS\;
cat /tmp/replicationpipe ) | mysql --unbuffered > $REPLINFO 2>&1
)" &
# auf $SEITEA, nicht bevor die master-replication-info bekannt ist
while ! grep Binlog_Ignore_DB /etc/vservers/$MASTER/vdir$REPLINFO; do sleep 0.2; done
sync
echo sync1 done
sync
echo sync2 done
fsfreeze -f $MOUNTPOINT
echo fsfreeze done
sleep 10
if [ x$DRBD == x1 ]; then
  ssh -X -a $SEITEB lvcreate -s -L$SIZESNAP -n tempmysqlsnap /dev/$VGSEITEB/$LV
else
  lvcreate -s -L$SIZESNAP -n tempmysqlsnap /dev/$VGSEITEA/$LV
fi
echo snap done
fsfreeze -u $MOUNTPOINT
echo fsunfreeze done
vserver $MASTER exec bash -c "(echo > /tmp/replicationpipe; rm /tmp/replicationpipe)"

if [ x$DRBD == x1 ]; then
	ssh -X -a $SEITEB "(
	  mount -t $FS /dev/$VGSEITEB/tempmysqlsnap /mnt/tempmysqlsnap &&
	  if [ x$NOTMPLV == x0 ]; then
	      ( cd /mnt/tempmysqlsnap/$RELPATH/ && tar cf - . ) |
	      mbuffer -m 8G |
	      ( cd /mnt/tempmysqlsync && tar xvpf - ) &&
	      umount /mnt/tempmysqlsnap &&
	      lvremove -f /dev/$VGSEITEB/tempmysqlsnap
	    fi
	  )"
else
  mount -t $FS /dev/$VGSEITEA/tempmysqlsnap /mnt/tempmysqlsnap &&
  if [ x$NOTMPLV == x0 ]; then
	  ( cd /mnt/tempmysqlsnap/$RELPATH/ && tar cf - . ) |
	  mbuffer -m 8G |
	  ( cd /mnt/tempmysqlsync && tar xvpf - ) &&
    umount /mnt/tempmysqlsnap &&
    lvremove -f /dev/$VGSEITEB/tempmysqlsnap
  fi
fi

MASTERLOGFILE=$(sed '1d; s/\t.*//' /etc/vservers/$MASTER/vdir$REPLINFO)
MASTERLOGPOS=$(sed '1d; s/^[^\t]*\t//; s/\t//g' /etc/vservers/$MASTER/vdir$REPLINFO)

ssh -X -a $SEITEB "(
	vserver $SLAVE exec /etc/init.d/mysql stop
	cp -p /etc/vservers/$SLAVE/vdir/var/lib/mysql/master.info /etc/vservers/$SLAVE/vdir/root/
	rm -rf /etc/vservers/$SLAVE/vdir/var/lib/mysql/*
)"
if [ x$NOTMPLV == x0 ]; then
	ssh -X -a $SEITEB "( ( cd /mnt/tempmysqlsync && tar cf - . ) | mbuffer -m8G | ( cd /etc/vservers/$SLAVE/vdir/var/lib/mysql && tar xvpf - ) )"
else
  rsync -rlHpogDtvxXA --numeric-ids /mnt/tempmysqlsnap/$RELPATH/. $SEITEB:/etc/vservers/$SLAVE/vdir/var/lib/mysql/
fi
ssh -X -a $SEITEB "(
	cp -p /etc/vservers/$SLAVE/vdir/root/master.info /etc/vservers/$SLAVE/vdir/var/lib/mysql/
	vserver $SLAVE exec mysqld_safe --skip-slave-start &
	while ! echo 'SELECT NOW()' | vserver $SLAVE exec mysql; do sleep 1; done
	echo \"SHOW SLAVE STATUS; RESET SLAVE; SHOW SLAVE STATUS; CHANGE MASTER TO MASTER_LOG_FILE='$MASTERLOGFILE', MASTER_LOG_POS=$MASTERLOGPOS; SHOW SLAVE STATUS;\" | vserver $SLAVE exec mysql
	vserver $SLAVE exec /etc/init.d/mysql stop
)"
ssh -X -a $SEITEB "(vserver $SLAVE exec /etc/init.d/mysql restart)"
if [ x$DRBD == x1 ]; then
	ssh -X -a $SEITEB "(
		if [ x$NOTMPLV == x1 ]; then
		  umount /mnt/tempmysqlsnap &&
		  lvremove -f /dev/$VGSEITEB/tempmysqlsnap
		else
			umount /mnt/tempmysqlsync
			rmdir /mnt/tempmysqlsync
			lvremove -f /dev/$TMPVG/$TMPLV
		fi
		rmdir /mnt/tempmysqlsnap
	)"
else
	if [ x$NOTMPLV == x1 ]; then
		umount /mnt/tempmysqlsnap &&
		lvremove -f /dev/$VGSEITEA/tempmysqlsnap
	else
		umount /mnt/tempmysqlsync
		rmdir /mnt/tempmysqlsync
		lvremove -f /dev/$TMPVG/$TMPLV
	fi
	rmdir /mnt/tempmysqlsnap
fi
# vim: ts=2 sw=2 sts=2 sr noet
