#!/bin/bash

ROOT_DIR=`pwd`

export BUILD_DATE=`date +"%Y%m%d"`

export ARCH=arm64
export CROSS_COMPILE=${ROOT_DIR}/toolchain/gcc-linaro-7.3.1-2018.05-x86_64_aarch64-linux-gnu/bin/aarch64-linux-gnu-

# source dirs
export atf=${ROOT_DIR}/atf-marvell
export uboot=${ROOT_DIR}/u-boot-marvell
export mvddr=${ROOT_DIR}/mv-ddr-marvell
export kernel=${ROOT_DIR}/linux
export firmware=${ROOT_DIR}/binaries-marvell

# for atf
export BL33=${uboot}/u-boot.bin
export CROSS_CM3=/usr/bin/arm-linux-gnueabi-
export WTP=${a3700_utils}
export MV_DDR_PATH=${mvddr}

# for 7k/8k
export SCP_BL2=${firmware}/mrvl_scp_bl2.img

export PRJNAME=mochabin
export BUILDTYPE=debug

if [ "${BUILDTYPE}" == "release" ]; then
    DATESTR="${BUILD_DATE}-rel"
else
    DATESTR="${BUILD_DATE}-dbg"
fi
export BUILDOUT=${ROOT_DIR}/out/build-${DATESTR}

function query_commitid {
    local path=$1

    # query latest commit
    if [ -d "$path/.git" ]; then
        commitid=`git -C $path log --no-merges --pretty=format:"%h%n" -1`
    else
        commitid="0000000"
    fi

    echo $commitid
}

function updateConfig {
    local conf=$1
    local key=$2
    local data=$3

    if [ -z "$conf" ] || [ -z "$key" ]; then
        return 1
    fi

    num=`awk -F"=" '!/^($|[[:space:]]*#)/ && /^(\s*)'${key}[^A-Za-z0-9_]'/ {print NR}' ${conf}`
    if [ -z "${num}" ]; then
        if [ ! -z "${data}" ]; then
            # not found, add new key pair to conf
            echo "${key}=${data}" >> ${conf}
        fi
    else
        if [ -z "${data}" ]; then
            # del the key
            sed -i "${num}d" ${conf}
        else
            # update the data
            sed -i "${num}c ${key}=${data}" ${conf}
        fi
    fi
    return 0
}

function create_dir {
    local dir=$1

    if [ -z "$dir" ]; then
        return
    fi

    if [ ! -d "$dir" ]; then
        mkdir -p $dir
    fi
}

# build_uboot $defconfig $device-tree-file
function build_uboot {
    local defconfig=${1}
    local dts=${2}

    if [ -f $uboot/u-boot.bin ]; then
        # remove old u-boot.bin
        rm $uboot/u-boot.bin
    fi

    # update u-boot commit id
    UBOOTGITID=$(query_commitid $uboot)

    if [ "${BUILDTYPE}" == "release" ]; then
        make -C $uboot distclean
        if [ -d "$uboot/.git" ]; then
            git -C $uboot clean -f
        fi
    fi

    make -C $uboot $defconfig

    if [ -z "${dts}" ]; then
        make -C $uboot
    else
        make -C $uboot DEVICE_TREE=${dts}
    fi

    return 0
}

# build $platform $ddr_topology
function build_atf {
    local platform=$1
    local topology=$2
    local ecc=${3:-0}
    local blout=$BUILDOUT

    if [ "${BUILDTYPE}" == "release" ]; then
        blout=$BUILDOUT/boot/bootloader
    fi

    # clean mv_ddr library to prevent using old ddr library
    make -C $mvddr clean

    # query latest commit
    DDRGITID=$(query_commitid $mvddr)
    ATFGITID=$(query_commitid $atf)

    # build image
    make -C $atf clean
    make -C $atf distclean

    case $topology in
    0)
      ddr="ddr4-4g"
      ;;
    1)
      ddr="ddr4-8g"
      ;;
    2)
      ddr="ddr4-2g"
      ;;
    *)
      echo "error: unknown ddr topology"
      return 1
    esac

    if [ $ecc -gt 0 ]; then
        ddr="${ddr}-ecc"
    fi

    make -C $atf DEBUG=0 USE_COHERENT_MEM=0 LOG_LEVEL=10 SECURE=0 PLAT=${platform} DDR_TOPOLOGY=${topology} ECC_ENABLED=${ecc} all fip
    FLASHOUT=${blout}/${platform}-bootloader-$ddr-mvddr-${DDRGITID}-atf-${ATFGITID}-uboot-${UBOOTGITID}-${DATESTR}.bin

    OUTPUTMSG="${OUTPUTMSG}`basename ${FLASHOUT}`\n"
    # copy image to output folder
    cp $atf/build/${platform}/release/flash-image.bin ${FLASHOUT}
    sync

    return 0
}

function build_bootloader {
    OUTPUTMSG=""

    if [ "${BUILDTYPE}" == "release" ]; then
        create_dir $BUILDOUT/boot/bootloader
    fi
    # build for a7040_mochabin
    build_uboot gti_mochabin-88f7040_defconfig armada-7040-mochabin

    if [ ! -f ${BL33} ]; then
        echo "Failed to build u-boot!"
        return 1
    fi

    # ddr-topology: 0: 1cs-4g, 1: 2cs-8g, 2: 1cs-2g
    for topology in 0 1 2
    do
        # without ecc
        build_atf a70x0_mochabin $topology 0

        # with ecc
        build_atf a70x0_mochabin $topology 1
    done

    printf "\nOutput:\n${OUTPUTMSG}\n"
}

function build_kernel {

    if [ "${BUILDTYPE}" == "release" ]; then
        if [ -f $kernel/.scmversion ]; then
            rm $kernel/.scmversion
            make -C $kernel clean
        fi
    else
        if [ ! -f $kernel/.scmversion ]; then
            touch $kernel/.scmversion
        fi
    fi

    #make -C $kernel gti_mochabin-88f7040_defconfig
    make -C $kernel gti_generic_mvebu_defconfig
    make -C $kernel -j4
    make -C $kernel modules_install INSTALL_MOD_PATH=${BUILDOUT}

    if [ -f "$kernel/arch/arm64/boot/Image" ]; then
        create_dir ${BUILDOUT}/boot

        cp $kernel/arch/arm64/boot/Image ${BUILDOUT}/boot/
        cp $kernel/arch/arm64/boot/dts/marvell/armada-7040-mochabin*.dtb ${BUILDOUT}/boot/
    fi
}

# gtibuild $build-prj $build-type $version
function gtibuild {
    local build_prj=$1
    local build_type=$2
    local build_ver=$3

    if [ -z "$build_type" ]; then
        export BUILDTYPE=debug
    fi
    export BUILDTYPE=$build_type

    if [ "${BUILDTYPE}" == "release" ]; then
        DATESTR="${BUILD_DATE}-rel"
    else
        DATESTR="${BUILD_DATE}-dbg"
    fi

    export BUILDOUT=${ROOT_DIR}/out/build-${DATESTR}

    create_dir ${BUILDOUT}

    case $build_prj in
      "bootloader")
        build_bootloader
      ;;
      "kernel")
        build_kernel
      ;;
      "all")
        build_bootloader
        build_kernel
      ;;
      *)
        echo "Unknown project"
      ;;
    esac
}

# create output directory
create_dir ${BUILDOUT}
