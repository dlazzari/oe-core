#
# Creates a root filesystem out of IPKs
#
# This rootfs can be mounted via root-nfs or it can be put into an cramfs/jffs etc.
# See image.bbclass for a usage of this.
#

EXTRAOPKGCONFIG ?= ""
ROOTFS_PKGMANAGE = "opkg opkg-collateral ${EXTRAOPKGCONFIG}"
ROOTFS_PKGMANAGE_BOOTSTRAP  = "run-postinsts"

do_rootfs[depends] += "opkg-native:do_populate_sysroot opkg-utils-native:do_populate_sysroot"
do_rootfs[recrdeptask] += "do_package_write_ipk"
rootfs_ipk_do_rootfs[vardepsexclude] += "BUILDNAME"

do_rootfs[lockfiles] += "${WORKDIR}/ipk.lock"

OPKG_PREPROCESS_COMMANDS = "package_update_index_ipk; package_generate_ipkg_conf"

OPKG_POSTPROCESS_COMMANDS = "ipk_insert_feed_uris; "

OPKGLIBDIR = "${localstatedir}/lib"

MULTILIBRE_ALLOW_REP = "${OPKGLIBDIR}/opkg"

fakeroot rootfs_ipk_do_rootfs () {
	#set -x

	rm -f ${IPKGCONF_TARGET}
	touch ${IPKGCONF_TARGET}

	${OPKG_PREPROCESS_COMMANDS}

	mkdir -p ${T}/
 
	export INSTALL_CONF_IPK="${IPKGCONF_TARGET}"
	export INSTALL_ROOTFS_IPK="${IMAGE_ROOTFS}"
	STATUS=${IMAGE_ROOTFS}${OPKGLIBDIR}/opkg/status
	mkdir -p ${IMAGE_ROOTFS}${OPKGLIBDIR}/opkg

	opkg-cl ${OPKG_ARGS} update

	# prime the status file with bits that we don't want
	for i in ${BAD_RECOMMENDATIONS}; do
		pkginfo="`opkg-cl ${OPKG_ARGS} info $i`"
		if [ ! -z "$pkginfo" ]; then
			echo "$pkginfo" | awk "/^Status:/ { print \"Status: deinstall hold not-installed\n\" }" - >> $STATUS
		else
			echo "Requested ignored recommendation $i is not a package"
		fi
	done

	#install
	export INSTALL_PACKAGES_ATTEMPTONLY_IPK="${PACKAGE_INSTALL_ATTEMPTONLY}"
	export INSTALL_PACKAGES_LINGUAS_IPK="${LINGUAS_INSTALL}"
	export INSTALL_TASK_IPK="rootfs"

	
	export INSTALL_PACKAGES_IPK="${PACKAGE_INSTALL}"

	#post install
	export D=${IMAGE_ROOTFS}
	export OFFLINE_ROOT=${IMAGE_ROOTFS}
	export IPKG_OFFLINE_ROOT=${IMAGE_ROOTFS}
	export OPKG_OFFLINE_ROOT=${IPKG_OFFLINE_ROOT}
	export INTERCEPT_DIR=${WORKDIR}/intercept_scripts
	export NATIVE_ROOT=${STAGING_DIR_NATIVE}

	package_install_internal_ipk

	# Distro specific packages should create this
	#mkdir -p ${IMAGE_ROOTFS}/etc/opkg/
	#grep "^arch" ${IPKGCONF_TARGET} >${IMAGE_ROOTFS}/etc/opkg/arch.conf

	rootfs_install_complementary

	${OPKG_POSTPROCESS_COMMANDS}
	${ROOTFS_POSTINSTALL_COMMAND}

	install -d ${IMAGE_ROOTFS}/${sysconfdir}
	echo ${BUILDNAME} > ${IMAGE_ROOTFS}/${sysconfdir}/version

	${ROOTFS_POSTPROCESS_COMMAND}

	if ${@base_contains("IMAGE_FEATURES", "read-only-rootfs", "true", "false" ,d)}; then
	        delayed_postinsts="$(delayed_postinsts)"
		if [ -n "$delayed_postinsts" ]; then
			bberror "The following packages could not be configured offline and rootfs is read-only: $delayed_postinsts"
			exit 1
		fi
	fi

	rm -f ${IMAGE_ROOTFS}${OPKGLIBDIR}/opkg/lists/*
	log_check rootfs
}

rootfs_ipk_do_rootfs[vardeps] += "delayed_postinsts"

delayed_postinsts () {
	cat ${STATUS}|grep -e "^Package:" -e "^Status:"|sed -ne 'N;s/Package: \(.*\)\nStatus:.*unpacked/\1/p'
}

save_postinsts () {
	# Scripts need to be ordered when executed, this ensures numeric order
	# If we ever run into needing more the 899 scripts, we'll have to
	# change num to start with 1000.
	num=100
	for p in $(delayed_postinsts); do
		install -d ${IMAGE_ROOTFS}${sysconfdir}/ipk-postinsts
		cp ${IMAGE_ROOTFS}${OPKGLIBDIR}/opkg/info/$p.postinst ${IMAGE_ROOTFS}${sysconfdir}/ipk-postinsts/$num-$p
		num=`echo \$((num+1))`
	done
}

remove_packaging_data_files() {
	rm -rf ${IMAGE_ROOTFS}${OPKGLIBDIR}/opkg
	# We need the directory for the package manager lock
	mkdir ${IMAGE_ROOTFS}${OPKGLIBDIR}/opkg
}

rootfs_install_packages() {
	opkg-cl ${OPKG_ARGS} install `cat $1`
}

rootfs_uninstall_packages() {
	opkg-cl ${OPKG_ARGS} --force-depends remove $@
}

ipk_insert_feed_uris () {

	echo "Building from feeds activated!"

	for line in ${IPK_FEED_URIS}
	do
		# strip leading and trailing spaces/tabs, then split into name and uri
		line_clean="`echo "$line"|sed 's/^[ \t]*//;s/[ \t]*$//'`"
		feed_name="`echo "$line_clean" | sed -n 's/\(.*\)##\(.*\)/\1/p'`"
		feed_uri="`echo "$line_clean" | sed -n 's/\(.*\)##\(.*\)/\2/p'`"

		echo "Added $feed_name feed with URL $feed_uri"

		# insert new feed-sources
		echo "src/gz $feed_name $feed_uri" >> ${IPKGCONF_TARGET}
	done

	# Allow to use package deploy directory contents as quick devel-testing
	# feed. This creates individual feed configs for each arch subdir of those
	# specified as compatible for the current machine.
	# NOTE: Development-helper feature, NOT a full-fledged feed.
	if [ -n "${FEED_DEPLOYDIR_BASE_URI}" ]; then
		for arch in ${PACKAGE_ARCHS}
		do
			echo "src/gz local-$arch ${FEED_DEPLOYDIR_BASE_URI}/$arch" >> ${IMAGE_ROOTFS}/etc/opkg/local-$arch-feed.conf
	    done
	fi
}

python () {

    if d.getVar('BUILD_IMAGES_FROM_FEEDS', True):
        flags = d.getVarFlag('do_rootfs', 'recrdeptask')
        flags = flags.replace("do_package_write_ipk", "")
        flags = flags.replace("do_deploy", "")
        flags = flags.replace("do_populate_sysroot", "")
        d.setVarFlag('do_rootfs', 'recrdeptask', flags)
        d.setVar('OPKG_PREPROCESS_COMMANDS', "package_generate_archlist\nipk_insert_feed_uris")
        d.setVar('OPKG_POSTPROCESS_COMMANDS', '')
}

