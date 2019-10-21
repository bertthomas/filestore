#!/bin/sh -x
exec 2>/home/scripts/boot1.log 2>&1

SDDEVICE="/dev/mmcblk0"				# SD card device
SDP1="${SDDEVICE}p1"				# SD card partition 1 device
SDP2="${SDDEVICE}p2"				# SD card partition 2 device
SDP1MP=/tmp/mnt/mmcblk0p1/			# mountpoint for SD card partition 1
SDP2MP=/tmp/mnt/mmcblk0p2/			# mountpoint for SD card partition 2
SDSWAP="${SDDEVICE}p3"				# SD card partition 3 device
USBMP=/tmp/mnt/sda1				# USB stick mountpoint
USBDEV=/dev/sda1				# USB stick device partition 1
P2IMAGEFILENAME=E2_20190827.img			# Filename of image to get from internet
FRAMEBUFFERDEV=/dev/fb0				# Framebuffer device

msg()
{
	/bin/text2fb 0 220 0 65535 "$*           "
	echo "$@"
}

create_partitions() {

	# delete all partitions

	PARTITIONS=$(fdisk ${SDDEVICE} -l |grep "^${SDDEVICE}" |sed 's/ .*$//') 2>/dev/null
	for p in ${PARTITIONS}
	do
	        umount -f "${p}" 2>/dev/null || /bin/true
	done

	PARTITIONS=`fdisk ${SDDEVICE} -l |grep "^${SDDEVICE}" |wc -l`
	echo "Found ${PARTITIONS} to delete"

	FD=''
	NEWLINE=$'\n'
	for i in `seq 1 ${PARTITIONS}`
	do
		FD="${FD}d$NEWLINE$NEWLINE"
	done
	FD="${FD}d${NEWLINE}w$NEWLINE"
	# modified to preserve fdisk output in /tmp/rb.stat
	echo "$FD" |fdisk ${SDDEVICE} 2>&1 >/tmp/rb.stat 2>&1
	if grep -q "next reboot" /tmp/rb.stat ; then
	 	printf "\n${GREEN}partition deleted: reboot ...${NC}"
	 	msg "Reboot 1"
                sync
		reboot
		exit 1
	fi
	echo "Delete done"
	fdisk /dev/mmcblk0 -l

	SECTORS=$(fdisk ${SDDEVICE} -l |head -n 1 |awk '{print $7}')

	# Now create the new partitions
	#2048 sectors reserved
	#1.5GB for partition 2 = 3145728 sectors
	#0.5GB for partition 3 = 1048576 sectors

	P1END=$(expr $SECTORS - 4196353)

	FD=$(cat <<-END
n
p
1

+$P1END
n
p
2

+1.5G
n
p
3


p
w
END
)
	echo "$FD " |fdisk ${SDDEVICE}

	mkfs.ext4 -F ${SDP1} >/dev/null
	mkfs.ext4 -F ${SDP2} >/dev/null
        init_swap
	init_p2
}

init_p2() {
	printf "\n${GREEN}Mounting the SD card...${NC}"
	msg "Preparing SD card (1)"
	mkdir -p ${SDP2MP}
	mount ${SDP2} ${SDP2MP} >/dev/null 2>&1

	printf "\nTest if USB device is mounted"
	msg "Preparing SD card (2)"
	if ! [ -s ${USBMP} ] ; then
    	    msg "Preparing SD card (3)"
	    printf "\nNot mounted, try to mount"
	    mkdir -p ${USBMP}

            mount ${USBDEV} ${USBMP}
            RESULT=$?
	    if [ "${RESULT}" -ne 0 ]; then
     	        msg "No USB stick inserted"
	        printf "\nFailed to mount USB dev rc=${RESULT}"
	    fi
	else
  	    msg "USB stick mounted"
	    printf "\nUSB mounted"
	fi

	printf "\n${GREEN}Get SD card image${NC}\n"
	rm -rf ${SDP2MP}/p2.tgz
        ARCH=$(ls -t ${USBMP}/E2_*img | head -1)
        if [ -s "${ARCH}" ] && [ "${ARCH}" ] ; then
            printf "\nCopy from USB\n"
	    msg "Copy from USB"
            (cd /tmp || exit ; tar xzf "${ARCH}" p2.bin ; mv /tmp/p2.bin ${SDP2MP}/p2.tgz )
        else
	    msg "Get image from network"
            printf "\nTry to get image from internet\n"
	    if wget -P ${SDP2MP} https://github.com/bertthomas/filestore/raw/master/${P2IMAGEFILENAME} >/dev/null 2>&1 ; then
	        printf "\nDownload succesful\n"
   	        msg "Download succesful"
	    else
	        printf "\nDownload unsuccesful\n"
   	        msg "Download unsuccesful"
	    fi
            ls ${SDP2MP} -la
            cd /tmp
            tar xzf ${SDP2MP}${P2IMAGEFILENAME}
            mv /tmp/p2.bin ${SDP2MP}/p2.tgz

	    ls -la ${SDP2MP}

        fi
	printf "\n${GREEN}Populate SD card P2${NC}"
	msg "Preparing SD card (4)"
	mkdir -p ${SDP2MP}/home
	tar xzf ${SDP2MP}/p2.tgz -C ${SDP2MP}/home >/dev/null 2>&1
}

init_swap() {
	test -b ${SDSWAP} && swapon -s | grep mmc || mkswap ${SDSWAP} && swapon ${SDSWAP} >/dev/null 2>&1
}

recover_fstab() {
	msg "Config SD"
	printf "\n${GREEN}Setup fstab...${NC}"

        # remove old uuid (needed as otherwise in some cases after upgrade the overlay won't work anymore)
        # one of the next lines will fail, but hopefully the other will be succesful
        rm ${SDP1MP}/etc/.extroot-uuid
        rm /mnt/mmcblk0p1/etc/.extroot-uuid

        block detect > /etc/config/fstab
        uci set fstab.@mount[0].enabled='1'
        uci set fstab.@mount[0].target='/overlay'
        uci set fstab.@mount[1].enabled='0'
        uci set fstab.@mount[1].options='remount,ro,noauto'
	# add automount USB
        uci add fstab mount
        uci set fstab.@mount[2].enabled='1'
        uci set fstab.@mount[2].target='/tmp/mnt/sda1'
        uci set fstab.@mount[2].device='/dev/sda1'
        uci set fstab.@mount[2].options='ro,sync'
        uci set fstab.@swap[0].enabled='1'
        uci commit fstab
        /etc/init.d/fstab enable
}

create_overlay() {
	if [ ! -d /overlay ] ; then
	        msg "Init overlay(1)"
		printf "\n${RED}No /overlay, create and mount it from mtdblock6...${NC}"
		mkdir /overlay
		mount -t jffs2 /dev/mtdblock6 /overlay >/dev/null 2>&1
		if [ ! $? ] ; then
		        msg "Init overlay(1)"
			printf "\n${RED}No /overlay, can not initialize partition 1...${NC}"
			rm -f /etc/config/fstab
			FD=$(cat <<-END
d
1
w

END
)
			echo "$FD " |fdisk ${SDDEVICE} >/dev/null 2>&1
			umount /overlay
		        rmdir /overlay
			return 1
		fi
	fi
	msg "Init overlay(2)"
	printf "\n${GREEN}Mounting the SD card...${NC}"
	mkdir -p ${SDP1MP}
	mount ${SDP1} ${SDP1MP} >/dev/null 2>&1

	msg "Init overlay(3)"
	printf "\n${GREEN}Duplicating the overlay directory...${NC}"
	cd /
	tar -C /overlay -cf - . | tar -C ${SDP1MP} -xf -
	mkdir -p ${SDP2MP}
	mount ${SDP2} ${SDP2MP} >/dev/null 2>&1
	if [ -d ${SDP2MP}/home ] ; then
		if [ -d ${SDP1MP}/upper ] ; then
	                printf "\n${GREEN}Install usercode...${NC}"
			msg "Init overlay(3)"
			mkdir -p ${SDP1MP}/upper/home
			tar -C ${SDP2MP}/home -cf - . | tar -C ${SDP1MP}/upper/home -xf -
			#BT added:
			cp ${SDP2MP}/home/scripts/etc_rc.local ${SDP1MP}/upper/etc/rc.local
		else
			msg "Init overlay(4)"
			printf "\n${RED}${SDP1MP}/upper destination is missing...${NC}"
		fi
	else
		msg "Init overlay(5)"
		printf "\n${RED}${SDP2MP}/home source is missing...${NC}"
		init_p2
	fi
	umount ${SDP1}
	return 0
}

copy_recovery_to_workpartition() {
	# mountpoints

	msg "Copy recovery to work (1)"
	printf "\n${GREEN}Recover ${SDP1}...${NC}"

	printf "\n${GREEN}Formatting SD card partition 1...${NC}"
	umount ${SDP1} 2>/dev/null || /bin/true
	mkfs.ext4 -F ${SDP1} >/dev/null 2>&1

	printf "\n${GREEN}Setup swap...${NC}"
	msg "Copy recovery to work (2)"
        init_swap
}

init_partitioned() {
	printf "\n${GREEN}Finishing up...${NC}"
        zcat </home/scripts/umlogoS2.raw > ${FRAMEBUFFERDEV}
	recover_fstab
        zcat </home/scripts/umlogoS3.raw > ${FRAMEBUFFERDEV}
	create_overlay
        zcat </home/scripts/umlogoS5.raw > ${FRAMEBUFFERDEV}

	# why is this needed?
	# sleep 5

 	printf "\n${GREEN}New SD card initialized. Reboot now...${NC}"

        # BT create_overlay unmounts, so following will never work
        #if [ -s /home/scripts/etc_rc.local ] ; then
        #    if ! diff /home/scripts/etc_rc.local /etc/rc.local > /dev/null; then
        #        echo "init rc.local script 2"
        #        # changed from / to SD1MP as in this stage we are most likely running
        #        # on either mtdblock6 or tmpfs
        #        cp /home/scripts/etc_rc.local ${SDP1MP}/etc/rc.local
        #    fi
        #fi
	echo "reboot $1"
        sync
	reboot
	exit 2
}

full_init() {
	zcat </home/scripts/umlogoS1.raw > ${FRAMEBUFFERDEV}
	create_partitions
	init_partitioned $1
}

set -x
echo "Start script (1) $0"
msg "Start recovery"
date

if [ ! -b $SDDEVICE ]; then
	echo "No SD card found, fatal!"
	msg "No SD card found"
	sleep 5
	exit 9
else
	PARTITIONS=$(fdisk ${SDDEVICE} -l |grep "^${SDDEVICE}" |wc -l) >/dev/null
	NR_PART=$(ls ${SDDEVICE}p* 2>/dev/null |wc -l)
	echo "partitions: ${PARTITIONS} ${NR_PART}"

	if [[ ${PARTITIONS} -ne 3 || ${NR_PART} -ne 3 ]] ; then
		full_init 1
	else
	 	printf "\n3 partitions on SD card, check for valid filesystems"
		OVERLAY_ERR=0

		if ! grep "overlay" /etc/config/fstab >/dev/null; then
			echo "SD should have been mounted as overlay, but isn't"
			msg "SD mount problem 1"
			OVERLAY_ERR=1
		else
			echo "check for matching uuid"
			UUID=$(block detect | grep uuid | head -1 | cut -f4) >/dev/null
			if [ "${UUID}" == "" ] ;then
				UUID="None"
			fi

			if ! grep ${UUID} /etc/config/fstab >/dev/null; then
				echo "fstab does not match SD UUID, create new fstab"
				msg "SD mount problem 2"
				OVERLAY_ERR=2
			else
				# check id /overlay is mounted on proper FS
				echo "check for proper /overlay"
				df -h

				if df | grep overlay | grep mtdblock6 >/dev/null; then
					OVERLAY_ERR=3

					#don't do this twice!
	                                zcat </home/scripts/umlogoS1.raw >/dev/fb0
					create_partitions
                		fi
                	fi
                fi
		if [ ${OVERLAY_ERR} -ne 0 ] ; then
			init_partitioned 2	# won't return
		fi

		echo "check for filesystem on ${SDP2}"

		FS_ERR=0

		if e2fsck -nf ${SDP2} >/dev/null 2>&1 ; then
	                zcat </home/scripts/umlogoS1.raw >/dev/fb0
			FS_ERR=2
		else
			echo "check for filesystem on ${SDP1}"

			if e2fsck -nf ${SDP1} >/dev/null 2>&1; then
	                        zcat </home/scripts/umlogoS2.raw >/dev/fb0
				copy_recovery_to_workpartition
			        FS_ERR=1
			fi
		fi
		if [ ${FS_ERR} -ne 0 ]; then
			echo "filesystem ${FS_ERR} check failed, re-init SD"
			init_partitioned 9
		else
                        NEW_RC=0
                        if [ -s /home/scripts/etc_rc.local ] ; then
                           if diff /home/scripts/etc_rc.local /etc/rc.local; then
                               echo "init rc.local script 0"
                               cp /home/scripts/etc_rc.local /etc/rc.local
                               NEW_RC=1
                           fi
                        fi
	                zcat </home/scripts/umlogo.raw >/dev/fb0
                        if [ ${NEW_RC} -ne 0 ] ; then
                            msg "Reboot"
                            sync
                            reboot
                            exit 7
                        fi
		fi
                echo "done"
		exit 0
        fi
fi
