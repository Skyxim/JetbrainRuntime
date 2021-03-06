#!/bin/bash -x

# The following parameters must be specified:
#   JBSDK_VERSION    - specifies major version of OpenJDK e.g. 11_0_6 (instead of dots '.' underbars "_" are used)
#   JDK_BUILD_NUMBER - specifies update release of OpenJDK build or the value of --with-version-build argument to configure
#   build_number     - specifies the number of JetBrainsRuntime build
#   bundle_type      - specifies bundle to be built; possible values:
#                        <empty> or nomod - the release bundles without any additional modules (jcef)
#                        jcef - the release bundles with jcef
#                        fd - the fastdebug bundles which also include the jcef module
#
# jbrsdk-${JBSDK_VERSION}-osx-x64-b${build_number}.tar.gz
# jbr-${JBSDK_VERSION}-osx-x64-b${build_number}.tar.gz
#
# $ ./java --version
# openjdk 11.0.6 2020-01-14
# OpenJDK Runtime Environment (build 11.0.6+${JDK_BUILD_NUMBER}-b${build_number})
# OpenJDK 64-Bit Server VM (build 11.0.6+${JDK_BUILD_NUMBER}-b${build_number}, mixed mode)
#
# Environment variables:
#   JCEF_PATH - specifies the path to the directory with JCEF binaries.
#               By default JCEF binaries should be located in ./jcef_mac

JBSDK_VERSION=$1
JDK_BUILD_NUMBER=$2
build_number=$3
bundle_type=$4
architecture=$5 # aarch64 or x64
enable_aot=$6 # temporary param for building test jre with aot under aarch64
JBSDK_VERSION_WITH_DOTS=$(echo $JBSDK_VERSION | sed 's/_/\./g')
WITH_IMPORT_MODULES="--with-import-modules=${MODULAR_SDK_PATH:=./modular-sdk}"
JCEF_PATH=${JCEF_PATH:=./jcef_mac}
architecture=${architecture:=x64}
MAJOR_JBSDK_VERSION=$(echo "$JBSDK_VERSION_WITH_DOTS" | awk -F "." '{print $1}')
BOOT_JDK=${BOOT_JDK:=$(/usr/libexec/java_home -v 16)}

source jb/project/tools/common/scripts/common.sh

function copyJNF {
  __contents_dir=$1
    mkdir -p ${__contents_dir}/Frameworks
    cp -Rp Frameworks/JavaNativeFoundation.framework ${__contents_dir}/Frameworks
}

function create_image_bundle {
  __bundle_name=$1
  __arch_name=$2
  __modules_path=$3
  __modules=$4

  tmp=.bundle.$$.tmp
  mkdir "$tmp" || do_exit $?

  [ "$bundle_type" == "fd" ] && [ "$__arch_name" == "$JBRSDK_BUNDLE" ] && __bundle_name=$__arch_name && fastdebug_infix="fastdebug-"
  JBR=${__bundle_name}-${JBSDK_VERSION}-osx-${architecture}-${fastdebug_infix}b${build_number}

  JRE_CONTENTS=$tmp/$__arch_name/Contents
  mkdir -p "$JRE_CONTENTS" || do_exit $?

  echo Running jlink...
  "$JSDK"/bin/jlink \
    --module-path "$__modules_path" --no-man-pages --compress=2 \
    --add-modules "$__modules" --output "$JRE_CONTENTS/Home" || do_exit $?

  grep -v "^JAVA_VERSION" "$JSDK"/release | grep -v "^MODULES" >> "$JRE_CONTENTS/Home/release"
  if [ "$__arch_name" == "$JBRSDK_BUNDLE" ]; then
    sed 's/JBR/JBRSDK/g' $JRE_CONTENTS/Home/release > release
    mv release $JRE_CONTENTS/Home/release
    copy_jmods "$__modules" "$__modules_path" "$JRE_CONTENTS"/Home/jmods
  fi

  cp -R "$JSDK"/../MacOS "$JRE_CONTENTS"
  cp "$JSDK"/../Info.plist "$JRE_CONTENTS"

  if [[ "${architecture}" == *aarch64* ]]; then
    # we can't notarize this library as usual framework (with headers and tbd-file)
    # but single library notarizes correctly
    copyJNF $JRE_CONTENTS
  fi

  [ -n "$bundle_type" ] && (cp -a $JCEF_PATH/Frameworks "$JRE_CONTENTS" || do_exit $?)

  echo Creating "$JBR".tar.gz ...
  COPYFILE_DISABLE=1 tar -pczf "$JBR".tar.gz --exclude='*.dSYM' --exclude='man' -C "$tmp" "$__arch_name" || do_exit $?
  rm -rf "$tmp"
}

WITH_DEBUG_LEVEL="--with-debug-level=release"
CONF_ARCHITECTURE=x86_64
if [[ "${architecture}" == *aarch64* ]]; then
  CONF_ARCHITECTURE=aarch64
fi
RELEASE_NAME=macosx-${CONF_ARCHITECTURE}-server-release

case "$bundle_type" in
  "jcef")
    do_reset_changes=1
    ;;
  "dcevm")
    HEAD_REVISION=$(git rev-parse HEAD)
    git am jb/project/tools/patches/dcevm/*.patch || do_exit $?
    do_reset_dcevm=1
    do_reset_changes=1
    ;;
  "nomod" | "")
    bundle_type=""
    ;;
  "fd")
    do_reset_changes=1
    WITH_DEBUG_LEVEL="--with-debug-level=fastdebug"
    RELEASE_NAME=macosx-${CONF_ARCHITECTURE}-server-fastdebug
    JBSDK=macosx-${architecture}-server-release
    ;;
esac

if [[ "${architecture}" == *aarch64* ]]; then
  sh configure \
    $WITH_DEBUG_LEVEL \
    --with-vendor-name="${VENDOR_NAME}" \
    --with-vendor-version-string="${VENDOR_VERSION_STRING}" \
    --with-jvm-features=shenandoahgc \
    --with-version-pre= \
    --with-version-build="${JDK_BUILD_NUMBER}" \
    --with-version-opt=b"${build_number}" \
    --with-boot-jdk="$BOOT_JDK" \
    --disable-hotspot-gtest --disable-javac-server --disable-full-docs --disable-manpages \
    --enable-cds=no \
    --with-extra-cflags="-F$(pwd)/Frameworks" \
    --with-extra-cxxflags="-F$(pwd)/Frameworks" \
    --with-extra-ldflags="-F$(pwd)/Frameworks" || do_exit $?
else
  sh configure \
    $WITH_DEBUG_LEVEL \
    --with-vendor-name="$VENDOR_NAME" \
    --with-vendor-version-string="$VENDOR_VERSION_STRING" \
    --with-jvm-features=shenandoahgc \
    --with-version-pre= \
    --with-version-build="$JDK_BUILD_NUMBER" \
    --with-version-opt=b"$build_number" \
    --with-boot-jdk="$BOOT_JDK" \
    --enable-cds=yes || do_exit $?
fi
make clean CONF=$RELEASE_NAME || do_exit $?
make images CONF=$RELEASE_NAME || do_exit $?

IMAGES_DIR=build/$RELEASE_NAME/images
JSDK=$IMAGES_DIR/jdk-bundle/jdk-$MAJOR_JBSDK_VERSION.jdk/Contents/Home
JSDK_MODS_DIR=$IMAGES_DIR/jmods
JBRSDK_BUNDLE=jbrsdk

if [ "$bundle_type" == "jcef" ] || [ "$bundle_type" == "dcevm" ] || [ "$bundle_type" == "fd" ]; then
  git apply -p0 < jb/project/tools/patches/add_jcef_module.patch || do_exit $?
  update_jsdk_mods "$JSDK" "$JCEF_PATH"/jmods "$JSDK"/jmods "$JSDK_MODS_DIR" || do_exit $?
  cp $JCEF_PATH/jmods/* $JSDK_MODS_DIR # $JSDK/jmods is not changed

  jbr_name_postfix="_${bundle_type}"
fi

# create runtime image bundle
modules=$(xargs < modules.list | sed s/" "//g) || do_exit $?
create_image_bundle "jbr${jbr_name_postfix}" "jbr" $JSDK_MODS_DIR "$modules" || do_exit $?

# create sdk image bundle
modules=$(cat "$JSDK"/release | grep MODULES | sed s/MODULES=//g | sed s/' '/','/g | sed s/\"//g | sed s/\\n//g) || do_exit $?
if [ "$bundle_type" == "jcef" ] || [ "$bundle_type" == "dcevm" ] || [ "$bundle_type" == "fd" ] || [ "$bundle_type" == "$JBRSDK_BUNDLE" ]; then
  modules=${modules},$(get_mods_list "$JCEF_PATH"/jmods)
fi
create_image_bundle "$JBRSDK_BUNDLE${jbr_name_postfix}" "$JBRSDK_BUNDLE" "$JSDK_MODS_DIR" "$modules" || do_exit $?

if [ -z "$bundle_type" ]; then
    JBRSDK_TEST=${JBRSDK_BUNDLE}-${JBSDK_VERSION}-osx-test-${architecture}-b${build_number}
    echo Creating "$JBRSDK_TEST" ...
    make test-image CONF=$RELEASE_NAME || do_exit $?
    [ -f "$JBRSDK_TEST.tar.gz" ] && rm "$JBRSDK_TEST.tar.gz"
    COPYFILE_DISABLE=1 tar -pczf "$JBRSDK_TEST".tar.gz -C $IMAGES_DIR --exclude='test/jdk/demos' test || do_exit $?
fi

do_exit 0