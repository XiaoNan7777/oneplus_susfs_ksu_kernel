#!/usr/bin/env bash
set -xve

# 获取 GitHub Actions 传入的参数
MANIFEST_FILE=$1
ENABLE_LTO=$2
ENABLE_POLLY=$3
ENABLE_O3=$4

# 根据 manifest_file 映射 CPUD
case $MANIFEST_FILE in
  "oneplus12_v"|"oneplus_13r"|"oneplus_ace3_pro"|"oneplus_ace3_pro_v"|"oneplus_ace5"|"oneplus_pad2_v")
    CPUD="pineapple"  
    ;;
  *)
    echo "Error: Unsupported manifest_file: $MANIFEST_FILE"
    exit 1
    ;;
esac

# 设置版本变量
ANDROID_VERSION="android14"
KERNEL_VERSION="6.1"
SUSFS_VERSION="1.5.5"

# 设置工作目录
OLD_DIR=$(pwd)
KERNEL_WORKSPACE="$OLD_DIR/kernel_platform"

# 检查和设置编译器环境
export CC="clang"
export CLANG_TRIPLE="aarch64-linux-gnu-"
export LDFLAGS="-fuse-ld=lld"

# 根据参数设置优化标志
BAZEL_ARGS=""

if [ "$ENABLE_O3" = "true" ]; then
  BAZEL_ARGS="$BAZEL_ARGS --copt=-O3 --copt=-Wno-error"
fi

if [ "$ENABLE_LTO" = "true" ]; then
  BAZEL_ARGS="$BAZEL_ARGS --copt=-flto=thin --linkopt=-flto=thin"
fi

if [ "$ENABLE_POLLY" = "true" ]; then
  BAZEL_ARGS="$BAZEL_ARGS --copt=-mllvm --copt=-polly"
fi

# 显示编译器版本
$CC --version

# 清理旧的保护导出文件
rm -f $KERNEL_WORKSPACE/common/android/abi_gki_protected_exports_* || echo "No protected exports!"
rm -f $KERNEL_WORKSPACE/msm-kernel/android/abi_gki_protected_exports_* || echo "No protected exports!"
sed -i 's/ -dirty//g' $KERNEL_WORKSPACE/build/kernel/kleaf/workspace_status_stamp.py

# 设置 KernelSU
cd $KERNEL_WORKSPACE
curl -LSs "https://raw.githubusercontent.com/5ec1cff/KernelSU/refs/heads/main/kernel/setup.sh" | bash -
cd KernelSU
git revert -m 1 $(git log --grep="remove devpts hook" --pretty=format:"%H") -n
KSU_VERSION=$(expr $(git rev-list --count HEAD) "+" 10200)
sed -i "s/DKSU_VERSION=16/DKSU_VERSION=${KSU_VERSION}/" kernel/Makefile

# 设置 susfs
cd "$OLD_DIR"
git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-${ANDROID_VERSION}-${KERNEL_VERSION} --depth 1
git clone https://github.com/TanakaLun/kernel_patches4mksu --depth 1
cd $KERNEL_WORKSPACE
cp ../susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./KernelSU/
cp ../kernel_patches4mksu/mksu/mksu_susfs.patch ./KernelSU/
cp ../kernel_patches4mksu/mksu/fix.patch ./KernelSU/
cp ../kernel_patches4mksu/mksu/vfs_fix.patch ./KernelSU/
cp ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch ./common/
cp ../susfs4ksu/kernel_patches/fs/* ./common/fs/
cp ../susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/

# 应用补丁
cd KernelSU
patch -p1 --forward < 10_enable_susfs_for_ksu.patch || true
patch -p1 --forward < mksu_susfs.patch || true
patch -p1 --forward < fix.patch || true
patch -p1 --forward < vfs_fix.patch || true
cd ../common
patch -p1 < 50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch || true
cp ../../kernel_patches4mksu/69_hide_stuff.patch ./
patch -p1 -F 3 < 69_hide_stuff.patch

# 构建内核
cd "$OLD_DIR"
./kernel_platform/build_with_bazel.py -t ${CPUD} gki \
  --config=stamp \
  --linkopt="-fuse-ld=lld" \
  $BAZEL_ARGS

# 获取内核版本
KERNEL_VERSION=$(cat $KERNEL_WORKSPACE/out/msm-kernel-${CPUD}-gki/dist/version.txt 2>/dev/null || echo "6.1")

# 制作 AnyKernel3
git clone https://github.com/Kernel-SU/AnyKernel3 --depth=1
rm -rf ./AnyKernel3/.git
cp $KERNEL_WORKSPACE/out/msm-kernel-${CPUD}-gki/dist/Image ./AnyKernel3/

# 输出变量到 GitHub Actions
echo "kernel_version=$KERNEL_VERSION" >> $GITHUB_OUTPUT
echo "ksu_version=$KSU_VERSION" >> $GITHUB_OUTPUT
echo "susfs_version=$SUSFS_VERSION" >> $GITHUB_OUTPUT
