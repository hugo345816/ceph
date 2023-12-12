#!/usr/bin/env bash
set -ex

if [ -d .git ]; then
    git submodule update --init --recursive   # 递归更新子模块
fi

: ${BUILD_DIR:=build}
: ${CEPH_GIT_DIR:=..}

if [ -e $BUILD_DIR ]; then
    # 如果构建目录已存在，则提示先删除后再重试
    echo "'$BUILD_DIR' dir already exists; either rm -rf '$BUILD_DIR' and re-run, or set BUILD_DIR env var to a different directory name"
    exit 1
fi

PYBUILD="3"     # 要求使用Python3
ARGS="-GNinja"  # CMake参数，使用Ninja技术可以减少构建过程中的IO操作，加快构建速度
if [ -r /etc/os-release ]; then
  source /etc/os-release  # 获得操作系统的详细信息
  case "$ID" in
      fedora)
          if [ "$VERSION_ID" -ge "35" ] ; then
            PYBUILD="3.10"
          elif [ "$VERSION_ID" -ge "33" ] ; then
            PYBUILD="3.9"
          elif [ "$VERSION_ID" -ge "32" ] ; then
            PYBUILD="3.8"
          else
            PYBUILD="3.7"
          fi
          ;;
      rhel|centos)
          MAJOR_VER=$(echo "$VERSION_ID" | sed -e 's/\..*$//')  # 取得主版本号
          if [ "$MAJOR_VER" -ge "9" ] ; then
              # 如果是9系列，则采用Python3.9
              PYBUILD="3.9"
          elif [ "$MAJOR_VER" -ge "8" ] ; then
              # 如果是8系列，则采用Python3.6
              PYBUILD="3.6"
          fi
          ;;
      opensuse*|suse|sles)
          PYBUILD="3"
          ARGS+=" -DWITH_RADOSGW_AMQP_ENDPOINT=OFF"
          ARGS+=" -DWITH_RADOSGW_KAFKA_ENDPOINT=OFF"
          ;;
  esac
elif [ "$(uname)" == FreeBSD ] ; then
  PYBUILD="3"
  ARGS+=" -DWITH_RADOSGW_AMQP_ENDPOINT=OFF"
  ARGS+=" -DWITH_RADOSGW_KAFKA_ENDPOINT=OFF"
else
  echo Unknown release
  exit 1
fi

ARGS+=" -DWITH_PYTHON3=${PYBUILD}"  # CMake参数，指定Python的版本号
# 检测ccache工具是否存在
if type ccache > /dev/null 2>&1 ; then
    echo "enabling ccache"
    ARGS+=" -DWITH_CCACHE=ON"       # CMake参数，启用ccache
fi

mkdir $BUILD_DIR
cd $BUILD_DIR
# 检测是否存在cmake3，如果存在则优先使用cmake3。不过，在centos环境中，cmake3其实只是cmake的一个软链接。
if type cmake3 > /dev/null 2>&1 ; then
    CMAKE=cmake3
else
    CMAKE=cmake
fi
${CMAKE} $ARGS "$@" $CEPH_GIT_DIR || exit 1   # "$@"为传递给本脚本的额外参数（如果有的话）
set +x    # 后续将输出每一条待执行的shell指令

# minimal config to find plugins
cat <<EOF > ceph.conf
[global]
plugin dir = lib
erasure code dir = lib
EOF

echo done.

if [[ ! "$ARGS $@" =~ "-DCMAKE_BUILD_TYPE" ]]; then
  # 默认构建DEBUG版本，性能会受到严重影响。如果需要性能，请添加-DCMAKE_BUILD_TYPE=RelWithDebInfo参数
  cat <<EOF

****
WARNING: do_cmake.sh now creates debug builds by default. Performance
may be severely affected. Please use -DCMAKE_BUILD_TYPE=RelWithDebInfo
if a performance sensitive build is required.
****
EOF
fi

