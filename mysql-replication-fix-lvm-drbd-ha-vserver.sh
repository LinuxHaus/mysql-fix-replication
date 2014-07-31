MySQL Replikation wieder aufsetzen mit VServer/DRBD/LVM.
Plan: MySQL-VServer MASTER laeuft auf SEITEA, MySQL-VServer SLAVE laeuft auf SEITEB.
/var/lib/mysql ist $SIZE gross. Volumegroups heissen $VGSEITEA und $VGSEITEB.
DRBDIPA und DRBDIPA sind die IPs der Direktverbindung zwischen $SEITEA und $SEITEB.
Der Snapshot ist SIZESNAP gross.

Versuch mit Parametrisierung, nicht als Skript geeignet.
SEITEA=m01host01a
SEITEB=m01host01b
TMPLV=tempmysqlsync
TMPVG=vg_m01host01b
VGSEITEA=vg_m01host01a_sas
VGSEITEB=vg_m01host01b_sas
LV=vs_m01mysql03_var_lib_mysql
DRBDIPA=10.1.2.11
DRBDIPB=10.1.2.12
SIZE=490G
SIZESNAP=50G
MASTER=m01mysql03
SLAVE=m01mysql04
REPLINFO=/root/master-replication-info

# Neuer Versuch m01mysql05->06
SEITEA=m01host01a
SEITEB=m01host01b
TMPLV=tempmysqlsync
TMPVG=vg_m01host01b
VGSEITEA=vg_m01host01a
VGSEITEB=vg_m01host01b
LV=vs_m01mysql05
DRBDIPA=10.1.2.11
DRBDIPB=10.1.2.12
SIZE=490G
SIZESNAP=50G
MASTER=m01mysql05
SLAVE=m01mysql06
REPLINFO=/root/master-replication-info

SEITEA=m01host01b
SEITEB=m01host01a
TMPLV=tempmysqlsync
TMPVG=vg_m01host01a
VGSEITEA=vg_m01host01b_ssd
VGSEITEB=vg_m01host01a_ssd
LV=m01mysql01_v_lib_mysql
DRBDIPA=10.1.2.12
DRBDIPB=10.1.2.11
SIZE=490G
SIZESNAP=4G
MASTER=m01mysql01
SLAVE=m01mysql02
REPLINFO=/root/master-replication-info
# auf $SEITEA, 1 shell sparen. $SEITEB damit der Snapshot schnell wieder aufgeloest werden kann als Puffer
(cd /etc/vservers/$MASTER/vdir/var/lib/mysql && tar cf - . | nc -l -p 5679 ) &
ssh $SEITEB "(
lvcreate -L$SIZE -n tempmysqlsync $TMPVG
mkfs.ext4 /dev/$TMPVG/$TMPLV
mkdir -p /mnt/tempmysqlsync
mkdir -p /mnt/tempmysqlsnap
mount /dev/$TMPVG/$TMPLV /mnt/tempmysqlsync
(cd /mnt/tempmysqlsync && nc $DRBDIPA 5679 | mbuffer -m 8G | tar xvpf - )
)"

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
ssh $SEITEB lvcreate -s -L$SIZESNAP -n tempmysqlsnap /dev/$VGSEITEB/$LV
echo snap done
fsfreeze -u $MOUNTPOINT
echo fsunfreeze done
vserver $MASTER exec bash -c "(echo > /tmp/replicationpipe; rm /tmp/replicationpipe)"

ssh $SEITEB "(
mount /dev/$VGSEITEB/tempmysqlsnap /mnt/tempmysqlsnap &&
rsync -rlHpogDtSvx -c --stats --progress --numeric-ids --delete /mnt/tempmysqlsnap/$RELPATH/. /mnt/tempmysqlsync/ &&
umount /mnt/tempmysqlsnap &&
lvremove -f /dev/$VGSEITEB/tempmysqlsnap
)"

MASTERLOGFILE=$(sed '1d; s/\t.*//' /etc/vservers/$MASTER/vdir$REPLINFO)
MASTERLOGPOS=$(sed '1d; s/^[^\t]*\t//; s/\t//g' /etc/vservers/$MASTER/vdir$REPLINFO)

ssh $SEITEB "(
vserver $SLAVE exec /etc/init.d/mysql stop
cp -p /etc/vservers/$SLAVE/vdir/var/lib/mysql/master.info /etc/vservers/$SLAVE/vdir/root/
rm -rf /etc/vservers/$SLAVE/vdir/var/lib/mysql/*
( cd /mnt/tempmysqlsync && tar cf - . ) | mbuffer -m8G | ( cd /etc/vservers/$SLAVE/vdir/var/lib/mysql && tar xvpf - )
cp -p /etc/vservers/$SLAVE/vdir/root/master.info /etc/vservers/$SLAVE/vdir/var/lib/mysql/
vserver $SLAVE exec mysqld_safe --skip-slave-start &
while ! echo 'SELECT NOW()' | vserver $SLAVE exec mysql; do sleep 1; done
echo \"SHOW SLAVE STATUS; RESET SLAVE; SHOW SLAVE STATUS; CHANGE MASTER TO MASTER_LOG_FILE='$MASTERLOGFILE', MASTER_LOG_POS=$MASTERLOGPOS; SHOW SLAVE STATUS;\" | vserver $SLAVE exec mysql
vserver $SLAVE exec /etc/init.d/mysql stop
)"
ssh $SEITEB "(vserver $SLAVE exec /etc/init.d/mysql restart)"
ssh $SEITEB "(
umount /mnt/tempmysqlsync
rmdir /mnt/tempmysqlsync
rmdir /mnt/tempmysqlsnap
lvremove -f /dev/$TMPVG/$TMPLV
)"

