#!/usr/bin/env bash
# -*- mode:sh; tab-width:8; indent-tabs-mode:t -*-
#
# Ceph distributed storage system
#
# Copyright (C) 2014, 2015 Red Hat <contact@redhat.com>
#
# Author: Loic Dachary <loic@dachary.org>
#
#  This library is free software; you can redistribute it and/or
#  modify it under the terms of the GNU Lesser General Public
#  License as published by the Free Software Foundation; either
#  version 2.1 of the License, or (at your option) any later version.
#
set -e
DIR=/tmp/install-deps.$$    # "$$" 的意思是当前shell的PID，也就是脚本运行的当前进程号。
trap "rm -fr $DIR" EXIT     # trap 是Shell内建命令，用于指定在接收到信号后将要采取的动作。常见的用途是在脚本程序被中断时完成清理工作。
mkdir -p $DIR               # 创建临时目录
if test $(id -u) != 0 ; then    # 测试一下当前账号是否root账号。
    SUDO=sudo               # 如果不是的话，则后续部分指令需要采用sudo方式执行
fi
export LC_ALL=C # the following is vulnerable to i18n. 去除所有本地化的设置，让命令能正确执行。

ARCH=$(uname -m)    # 获得当前架构，如："x86_64"
# 生成`ceph.spec`文件
function munge_ceph_spec_in {
    local with_seastar=$1
    shift
    local with_zbd=$1
    shift
    local for_make_check=$1
    shift
    local with_jaeger=$1
    shift
    local OUTFILE=$1
    sed -e 's/@//g' < ceph.spec.in > $OUTFILE
    # http://rpm.org/user_doc/conditional_builds.html
    if $with_seastar; then
        sed -i -e 's/%bcond_with seastar/%bcond_without seastar/g' $OUTFILE
    fi
    if $with_jaeger; then
        sed -i -e 's/%bcond_with jaeger/%bcond_without jaeger/g' $OUTFILE
    fi
    if $with_zbd; then
        sed -i -e 's/%bcond_with zbd/%bcond_without zbd/g' $OUTFILE
    fi
    if $for_make_check; then
        sed -i -e 's/%bcond_with make_check/%bcond_without make_check/g' $OUTFILE
    fi
}

function munge_debian_control {
    local version=$1
    shift
    local control=$1
    case "$version" in
        *squeeze*|*wheezy*)
	    control="/tmp/control.$$"
	    grep -v babeltrace debian/control > $control
	    ;;
    esac
    if $with_jaeger; then
	sed -i -e 's/^# Jaeger[[:space:]]//g' $control
	sed -i -e 's/^# Crimson      libyaml-cpp-dev,/d' $control
    fi
    echo $control
}

function ensure_decent_gcc_on_ubuntu {
    # point gcc to the one offered by g++-7 if the used one is not
    # new enough
    local old=$(gcc -dumpfullversion -dumpversion)
    local new=$1
    local codename=$2
    if dpkg --compare-versions $old ge ${new}.0; then
	return
    fi

    if [ ! -f /usr/bin/g++-${new} ]; then
	$SUDO tee /etc/apt/sources.list.d/ubuntu-toolchain-r.list <<EOF
deb [lang=none] http://ppa.launchpad.net/ubuntu-toolchain-r/test/ubuntu $codename main
deb [arch=amd64 lang=none] http://mirror.nullivex.com/ppa/ubuntu-toolchain-r-test $codename main
EOF
	# import PPA's signing key into APT's keyring
	cat << ENDOFKEY | $SUDO apt-key add -
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: SKS 1.1.6
Comment: Hostname: keyserver.ubuntu.com

mI0ESuBvRwEEAMi4cDba7xlKaaoXjO1n1HX8RKrkW+HEIl79nSOSJyvzysajs7zUow/OzCQp
9NswqrDmNuH1+lPTTRNAGtK8r2ouq2rnXT1mTl23dpgHZ9spseR73s4ZBGw/ag4bpU5dNUSt
vfmHhIjVCuiSpNn7cyy1JSSvSs3N2mxteKjXLBf7ABEBAAG0GkxhdW5jaHBhZCBUb29sY2hh
aW4gYnVpbGRziLYEEwECACAFAkrgb0cCGwMGCwkIBwMCBBUCCAMEFgIDAQIeAQIXgAAKCRAe
k3eiup7yfzGKA/4xzUqNACSlB+k+DxFFHqkwKa/ziFiAlkLQyyhm+iqz80htRZr7Ls/ZRYZl
0aSU56/hLe0V+TviJ1s8qdN2lamkKdXIAFfavA04nOnTzyIBJ82EAUT3Nh45skMxo4z4iZMN
msyaQpNl/m/lNtOLhR64v5ZybofB2EWkMxUzX8D/FQ==
=LcUQ
-----END PGP PUBLIC KEY BLOCK-----
ENDOFKEY
	$SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -y || true
	$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y g++-${new}
    fi

    case "$codename" in
        trusty)
            old=4.8;;
        xenial)
            old=5;;
        bionic)
            old=7;;
    esac
    $SUDO update-alternatives --remove-all gcc || true
    $SUDO update-alternatives \
	 --install /usr/bin/gcc gcc /usr/bin/gcc-${new} 20 \
	 --slave   /usr/bin/g++ g++ /usr/bin/g++-${new}

    if [ -f /usr/bin/g++-${old} ]; then
      $SUDO update-alternatives \
  	 --install /usr/bin/gcc gcc /usr/bin/gcc-${old} 10 \
  	 --slave   /usr/bin/g++ g++ /usr/bin/g++-${old}
    fi

    $SUDO update-alternatives --auto gcc

    # cmake uses the latter by default
    $SUDO ln -nsf /usr/bin/gcc /usr/bin/${ARCH}-linux-gnu-gcc
    $SUDO ln -nsf /usr/bin/g++ /usr/bin/${ARCH}-linux-gnu-g++
}

function ensure_python3_sphinx_on_ubuntu {
    local sphinx_command=/usr/bin/sphinx-build
    # python-sphinx points $sphinx_command to
    # ../share/sphinx/scripts/python2/sphinx-build when it's installed
    # let's "correct" this
    if test -e $sphinx_command  && head -n1 $sphinx_command | grep -q python$; then
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -y remove python-sphinx
    fi
}

function install_pkg_on_ubuntu {
    local project=$1
    shift
    local sha1=$1
    shift
    local codename=$1
    shift
    local force=$1
    shift
    local pkgs=$@
    local missing_pkgs
    if [ $force = "force" ]; then
	missing_pkgs="$@"
    else
	for pkg in $pkgs; do
	    if ! apt -qq list $pkg 2>/dev/null | grep -q installed; then
		missing_pkgs+=" $pkg"
	    fi
	done
    fi
    if test -n "$missing_pkgs"; then
	local shaman_url="https://shaman.ceph.com/api/repos/${project}/master/${sha1}/ubuntu/${codename}/repo"
	$SUDO curl --silent --location $shaman_url --output /etc/apt/sources.list.d/$project.list
	$SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -y -o Acquire::Languages=none -o Acquire::Translation=none || true
	$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install --allow-unauthenticated -y $missing_pkgs
    fi
}

function install_boost_on_ubuntu {
    local ver=1.75
    local installed_ver=$(apt -qq list --installed ceph-libboost*-dev 2>/dev/null |
                              grep -e 'libboost[0-9].[0-9]\+-dev' |
                              cut -d' ' -f2 |
                              cut -d'.' -f1,2)
    if test -n "$installed_ver"; then
        if echo "$installed_ver" | grep -q "^$ver"; then
            return
        else
            $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -y remove "ceph-libboost.*${installed_ver}.*"
            $SUDO rm -f /etc/apt/sources.list.d/ceph-libboost${installed_ver}.list
        fi
    fi
    local codename=$1
    local project=libboost
    local sha1=7aba8a1882670522ee1d1ee1bba0ea170b292dec
    install_pkg_on_ubuntu \
	$project \
	$sha1 \
	$codename \
	check \
	ceph-libboost-atomic$ver-dev \
	ceph-libboost-chrono$ver-dev \
	ceph-libboost-container$ver-dev \
	ceph-libboost-context$ver-dev \
	ceph-libboost-coroutine$ver-dev \
	ceph-libboost-date-time$ver-dev \
	ceph-libboost-filesystem$ver-dev \
	ceph-libboost-iostreams$ver-dev \
	ceph-libboost-program-options$ver-dev \
	ceph-libboost-python$ver-dev \
	ceph-libboost-random$ver-dev \
	ceph-libboost-regex$ver-dev \
	ceph-libboost-system$ver-dev \
	ceph-libboost-test$ver-dev \
	ceph-libboost-thread$ver-dev \
	ceph-libboost-timer$ver-dev
}

function install_libzbd_on_ubuntu {
    local codename=$1
    local project=libzbd
    local sha1=1fadde94b08fab574b17637c2bebd2b1e7f9127b
    install_pkg_on_ubuntu \
        $project \
        $sha1 \
        $codename \
        check \
        libzbd-dev
}
# 版本号比较
function version_lt {
    test $1 != $(echo -e "$1\n$2" | sort -rV | head -n 1)
}

for_make_check=false
if tty -s; then     #  tty 命令用于显示终端机连接标准输入设备的文件名称。-s 参数表示不显示任何信息，只回传状态代码。
    # interactive   #  当前处于交互模式
    for_make_check=true
elif [ $FOR_MAKE_CHECK ]; then
    for_make_check=true
else
    for_make_check=false
fi

# 配置PIP仓库本地源
$SUDO tee /etc/pip.conf <<-EOF
[global]
trusted-host=mirrors.aliyun.com
index-url=http://mirrors.aliyun.com/pypi/simple/
EOF

if [ x$(uname)x = xFreeBSDx ]; then     # 如果当前系统是FreeBSD
    $SUDO pkg install -yq \
        devel/babeltrace \
        devel/binutils \
        devel/git \
        devel/gperf \
        devel/gmake \
        devel/cmake \
        devel/nasm \
        devel/boost-all \
        devel/boost-python-libs \
        devel/valgrind \
        devel/pkgconf \
        devel/libedit \
        devel/libtool \
        devel/google-perftools \
        lang/cython \
        databases/leveldb \
        net/openldap24-client \
        archivers/snappy \
        archivers/liblz4 \
        ftp/curl \
        misc/e2fsprogs-libuuid \
        misc/getopt \
        net/socat \
        textproc/expat2 \
        textproc/gsed \
        lang/gawk \
        textproc/libxml2 \
        textproc/xmlstarlet \
        textproc/jq \
        textproc/py-sphinx \
        emulators/fuse \
        java/junit \
        lang/python36 \
        devel/py-pip \
        devel/py-flake8 \
        devel/py-tox \
        devel/py-argparse \
        devel/py-nose \
        devel/py-prettytable \
        devel/py-yaml \
        www/py-routes \
        www/py-flask \
        www/node \
        www/npm \
        www/fcgi \
        security/nss \
        security/krb5 \
        security/oath-toolkit \
        sysutils/flock \
        sysutils/fusefs-libs \

	# Now use pip to install some extra python modules
	pip install pecan

    exit
else
    [ $WITH_SEASTAR ] && with_seastar=true || with_seastar=false
    [ $WITH_JAEGER ] && with_jaeger=true || with_jaeger=false
    [ $WITH_ZBD ] && with_zbd=true || with_zbd=false
    source /etc/os-release  # 获得当前操作系统的相关信息。
    case "$ID" in
    debian|ubuntu|devuan|elementary|softiron)   # debian家族
        echo "Using apt-get to install dependencies"
        $SUDO apt-get install -y devscripts equivs
        $SUDO apt-get install -y dpkg-dev
        ensure_python3_sphinx_on_ubuntu
        case "$VERSION" in
            *Bionic*)
                ensure_decent_gcc_on_ubuntu 9 bionic
                [ ! $NO_BOOST_PKGS ] && install_boost_on_ubuntu bionic
                $with_zbd && install_libzbd_on_ubuntu bionic
                ;;
            *Focal*)
                [ ! $NO_BOOST_PKGS ] && install_boost_on_ubuntu focal
                $with_zbd && install_libzbd_on_ubuntu focal
                ;;
            *)
                $SUDO apt-get install -y gcc
                ;;
        esac
        if ! test -r debian/control ; then
            echo debian/control is not a readable file
            exit 1
        fi
        touch $DIR/status

        backports=""
        control=$(munge_debian_control "$VERSION" "debian/control")
            case "$VERSION" in
                *squeeze*|*wheezy*)
                    backports="-t $codename-backports"
                    ;;
            esac

        # make a metapackage that expresses the build dependencies,
        # install it, rm the .deb; then uninstall the package as its
        # work is done
        build_profiles=""
        if $for_make_check; then
            build_profiles+=",pkg.ceph.check"
        fi
        if $with_seastar; then
            build_profiles+=",pkg.ceph.crimson"
        fi
        if $with_jaeger; then
            build_profiles+=",pkg.ceph.jaeger"
        fi

        $SUDO env DEBIAN_FRONTEND=noninteractive mk-build-deps \
            --build-profiles "${build_profiles#,}" \
            --install --remove \
            --tool="apt-get -y --no-install-recommends $backports" $control || exit 1
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -y remove ceph-build-deps
        if [ "$control" != "debian/control" ] ; then rm $control; fi
        ;;
    centos|fedora|rhel|ol|virtuozzo)            # redhat家族
        builddepcmd="dnf -y builddep --allowerasing"
        echo "Using dnf to install dependencies"
        $SUDO dnf install -y curl
        case "$ID" in
            fedora)
                $SUDO dnf install -y dnf-utils
                ;;
            centos|rhel|ol|virtuozzo)
                MAJOR_VERSION="$(echo $VERSION_ID | cut -d. -f1)"   # 获得主要版本号
                $SUDO dnf install -y dnf-utils selinux-policy-targeted  # 安装两个组件，其中：
                                                                        # dnf-utils: 在CentOS下名为yum-utils，是为了兼容传统的yum命令而做的适配层。
                                                                        # selinux-policy-targeted: SELinux参考策略目标基本模块。
                # 安装epel仓库
                rpm --quiet --query epel-release || \
                $SUDO dnf install -y epel-release   # CentOS自带，所以改为dnf安装即可
		        # $SUDO dnf -y install --nogpgcheck https://dl.fedoraproject.org/pub/epel/epel-release-latest-$MAJOR_VERSION.noarch.rpm
                # 修改EPEL仓库地址到本地镜像站
                $SUDO sed -e 's|^#baseurl=|baseurl=|g' -e 's|^metalink=|#metalink|g' \
                    -e 's|https://download.example/pub/|https://mirrors.aliyun.com/|g' \
                    /etc/yum.repos.d/epel.repo /etc/yum.repos.d/epel-modular.repo  -i.bak
                $SUDO rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-$MAJOR_VERSION
                # 移除fedora相关的仓库（？可能是会有干扰？）
                $SUDO rm -f /etc/yum.repos.d/dl.fedoraproject.org*
		        if test $ID = centos -a $MAJOR_VERSION = 8 ; then
                    # Enable 'powertools' or 'PowerTools' repo
                    # 需要启用 'powertools' 仓库
                    $SUDO dnf config-manager --set-enabled $(dnf repolist --all 2>/dev/null|gawk 'tolower($0) ~ /^powertools\s/{print $1}')
		            # before EPEL8 and PowerTools provide all dependencies, we use sepia for the dependencies
                    # 在EPEL8及PowerTools提供所有依赖之前，我们先使用sepia作为依赖项
                    $SUDO dnf config-manager --add-repo http://apt-mirror.front.sepia.ceph.com/lab-extras/8/
                    # 禁用sepia仓库的gpg检查
                    $SUDO dnf config-manager --setopt=apt-mirror.front.sepia.ceph.com_lab-extras_8_.gpgcheck=0 --save
                elif test $ID = rhel -a $MAJOR_VERSION = 8 ; then   # 如果是 RHEL 8
                    # 需要启用 'codeready-builder' 仓库
                    $SUDO dnf config-manager --set-enabled "codeready-builder-for-rhel-8-${ARCH}-rpms"
                    # 在EPEL8及PowerTools提供所有依赖之前，我们先使用sepia作为依赖项
                    $SUDO dnf config-manager --add-repo http://apt-mirror.front.sepia.ceph.com/lab-extras/8/
                    # 禁用sepia仓库的gpg检查
                    $SUDO dnf config-manager --setopt=apt-mirror.front.sepia.ceph.com_lab-extras_8_.gpgcheck=0 --save
                fi
                ;;
        esac
        # 生成规格文件
        munge_ceph_spec_in $with_seastar $with_zbd $for_make_check $with_jaeger $DIR/ceph.spec
        # for python3_pkgversion macro defined by python-srpm-macros, which is required by python3-devel
        $SUDO dnf install -y python3-devel
        # 按照指定的规格文件安装编译所需的依赖包
        $SUDO $builddepcmd $DIR/ceph.spec 2>&1 | tee $DIR/yum-builddep.out
        [ ${PIPESTATUS[0]} -ne 0 ] && exit 1
        $SUDO dnf install -y gcc-c++ ccache rpm-build rpmdevtools ant doxygen   # 好象漏了这个没有安排？？
        # 忽略SELinux相关的错误
        IGNORE_YUM_BUILDEP_ERRORS="ValueError: SELinux policy is not managed or store cannot be accessed."
        sed "/$IGNORE_YUM_BUILDEP_ERRORS/d" $DIR/yum-builddep.out | grep -i "error:" && exit 1
        ;;
    opensuse*|suse|sles)
        echo "Using zypper to install dependencies"
        zypp_install="zypper --gpg-auto-import-keys --non-interactive install --no-recommends"
        $SUDO $zypp_install systemd-rpm-macros rpm-build || exit 1
        munge_ceph_spec_in $with_seastar false $for_make_check $with_jaeger $DIR/ceph.spec
        $SUDO $zypp_install $(rpmspec -q --buildrequires $DIR/ceph.spec) || exit 1
        ;;
    *)
        echo "$ID is unknown, dependencies will have to be installed manually."
	    exit 1
        ;;
    esac
fi

# 填充驾驶室。其实就是执行 pip 指令。
# 比如用 pip 安装一些软件包。
function populate_wheelhouse() {
    local install=$1
    shift

    # although pip comes with virtualenv, having a recent version
    # of pip matters when it comes to using wheel packages
    PIP_OPTS="--timeout 300 --exists-action i"
    pip $PIP_OPTS $install \
      'setuptools >= 0.8' 'pip >= 21.0' 'wheel >= 0.24' 'tox >= 2.9.1' || return 1
    if test $# != 0 ; then  # 如果还有更多参数
        # '--use-feature=fast-deps --use-deprecated=legacy-resolver' added per
        # https://github.com/pypa/pip/issues/9818 These should be able to be
        # removed at some point in the future.
        pip --use-feature=fast-deps --use-deprecated=legacy-resolver $PIP_OPTS $install $@ || return 1
    fi
}

function activate_virtualenv() {
    local top_srcdir=$1
    local env_dir=$top_srcdir/install-deps-python3

    if ! test -d $env_dir ; then
        python3 -m venv ${env_dir}  # 创建Python虚拟环境
        . $env_dir/bin/activate     # 激活Python虚拟环境
        if ! populate_wheelhouse install ; then # 安装构建wheel的依赖包，包括setuptools、pip、wheel、tox四个依赖包
            # 如果失败，则删除虚拟环境并返回
            rm -rf $env_dir
            return 1
        fi
    fi
    . $env_dir/bin/activate
}
# 预加载python模块，使tox可以在没有网络访问的情况下运行
function preload_wheels_for_tox() {
    local ini=$1
    shift
    pushd . > /dev/null     # 保存当前目录。对应“函数”尾部的 popd 操作
    cd $(dirname $ini)      # 进入tox.ini所在的子目录
    local require_files=$(ls *requirements*.txt 2>/dev/null) || true    # 查找当前目录下的pip包【依赖】定义文件。依赖的包都会被安装。
    local constraint_files=$(ls *constraints*.txt 2>/dev/null) || true  # 查找当前目录下的pip包【约束】定义文件。
                                                                        # 备注：
                                                                        # “依赖”声明需要什么包，依赖的包都会被安装。而“约束”只控制“依赖包”的版本要求，
                                                                        # 而不管它是否被安装。当然也可以在“依赖”中直接声明需要什么版本的包。
    local require=$(echo -n "$require_files" | sed -e 's/^/-r /')
    local constraint=$(echo -n "$constraint_files" | sed -e 's/^/-c /')
    local md5=wheelhouse/md5    # "wheelhouse"子目录下有个md5文件存放着部分文件的md5 hash值
    if test "$require"; then
        if ! test -f $md5 || ! md5sum -c $md5 > /dev/null; then
            # 如果不存在md5文件或md5校验不通过，则删除"wheelhouse"子目录
            rm -rf wheelhouse
        fi
    fi
    if test "$require" && ! test -d wheelhouse ; then   # 如果子目录wheelhouse不存在，则重新构建
        type python3 > /dev/null 2>&1 || continue       # 测试python3命令是否有效，否则退出循环。（？continue可以不在循环语句中执行？）
        activate_virtualenv $top_srcdir || exit 1       # 激活Python虚拟环境，如果失败则退出
        populate_wheelhouse "wheel -w $wip_wheelhouse" $require $constraint || exit 1   # 根据需求和依赖关系构建Wheel档案。如果失败则退出。
        mv $wip_wheelhouse wheelhouse                   # 将目录从wheelhouse-wip重命名为wheelhouse
        md5sum $require_files $constraint_files > $md5  # 重新生成md5校验码
    fi
    popd > /dev/null    # 重回之前保存的目录。对应之前的 pushd 操作
}

# use pip cache if possible but do not store it outside of the source
# tree
# see https://pip.pypa.io/en/stable/reference/pip_install.html#caching
if $for_make_check; then
    mkdir -p install-deps-cache
    top_srcdir=$(pwd)
    export XDG_CACHE_HOME=$top_srcdir/install-deps-cache
    wip_wheelhouse=wheelhouse-wip
    #
    # preload python modules so that tox can run without network access
    #
    find . -name tox.ini | while read ini ; do
        # 预加载python模块，使tox可以在没有网络访问的情况下运行
        preload_wheels_for_tox $ini
    done
    rm -rf $top_srcdir/install-deps-python3
    rm -rf $XDG_CACHE_HOME
    type git > /dev/null || (echo "Dashboard uses git to pull dependencies." ; false)
fi
