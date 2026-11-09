function platform_build_bootimg(){
	# DRAFT parameters: base 0x80000000, kernel at +0x8000, 2048 byte pages (the usual MSM8953 LK layout, not verified)
	python3 "${ROOTDIR}/tools/mkbootimg.py" \
		--kernel "${WORKSPACE}/uefi-${DEVICE}-kernel" \
		--ramdisk ramdisk \
		--base 0x80000000 \
		--pagesize 2048 \
		--kernel_offset 0x00008000 \
		--ramdisk_offset 0x01000000 \
		--tags_offset 0x00000100 \
		--header_version "${BOOTIMG_HEADER_VERSION}" \
		-o "${OUTDIR}/boot-${DEVICE}${EXT}.img" \
		||return "$?"
}
