#!/usr/bin/env bash

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
MX_FF_SRC_DIR="${SCRIPT_DIR}/src"
BUILD_ROOT="${MX_FF_SRC_DIR}/jni"
SRC_FILENAME="ffmpeg-src.tar.gz"

DEFAULT_VERSION="2.5.0"
DEFAULT_URL="https://amazon-source-code-downloads.s3.us-east-1.amazonaws.com/MXPlayer/client/mxplayer-2.5.0-ffmpeg-v4.2-src.tar.gz"

log_info() { echo -e "\033[36m[INFO] $*\033[0m"; }
log_warn() { echo -e "\033[33m[WARN] $*\033[0m" >&2; }
die() { echo -e "\033[31m[ERR] $*\033[0m" >&2; exit 1; }

log_info "Checking for the latest FFmpeg source code..."
DOWNLOAD_PAGE="https://mx.j2inter.com/download"
DETECTED_URL=$(curl -sL "$DOWNLOAD_PAGE" | grep -oE 'https://[^"]+mxplayer-[0-9.]+-ffmpeg-[^"]+-src\.tar\.gz' | head -n 1)

if [[ -n "$DETECTED_URL" ]]; then
    DETECTED_VERSION=$(echo "$DETECTED_URL" | sed -E 's/.*mxplayer-([0-9.]+)-ffmpeg.*/\1/')
    
    log_info "Latest version found: $DETECTED_VERSION"
    log_info "Source URL: $DETECTED_URL"
    
    MX_FF_SRC_URL="$DETECTED_URL"
    VERSION="${VERSION:=$DETECTED_VERSION}"
else
    log_warn "Failed to auto-detect latest version (network error or site layout change)."
    log_warn "Falling back to default hardcoded version: $DEFAULT_VERSION"
    
    MX_FF_SRC_URL="$DEFAULT_URL"
    VERSION="${VERSION:=$DEFAULT_VERSION}"
fi

BUILD_NUMBER="0"

execute() {
	log_info ":==> $*\n"
	"$@" || die "failed to execute $*"
	echo ""
}

if [[ ! -d "$NDK" ]]; then
	NDK_BUILD_PATH="$(which ndk-build)"
	if [[ -n "$NDK_BUILD_PATH" ]]; then
		export NDK=$(dirname "$NDK_BUILD_PATH")
		log_warn "NDK location auto-detected! path: $NDK"
	else
		die "Unable to detect NDK!!"
	fi
fi

build() {
	[[ -z "$1" ]] && die "invalid usage! please specify cpu arch."
	case "${1}" in
	arm64)
		ARCH_NAME="neon64"
		TARGET="${BUILD_ROOT}/libs/arm64-v8a"
		;;
	neon)
		ARCH_NAME="neon"
		TARGET="${BUILD_ROOT}/libs/armeabi-v7a/neon"
		;;
	x86)
		ARCH_NAME="x86"
		TARGET="${BUILD_ROOT}/libs/x86"
		;;
	x86_64)
		ARCH_NAME="x86_64"
		TARGET="${BUILD_ROOT}/libs/x86_64"
		;;
	*)
		die "unknown arch: $1"
		;;
	esac

	LIB_NAME="${TARGET}/libffmpeg.mx.so"
	TARGET_LIB_NAME="${LIB_NAME}.${ARCH_NAME}.${VERSION}"
	TARGET_ARCHIVE_NAME="${OUTPUT_DIR}/${ARCH_NAME}-${VERSION}-build_${BUILD_NUMBER}.zip"
	TARGET_AIO_ARCHIVE_NAME="${OUTPUT_DIR}/aio-${VERSION}-build_${BUILD_NUMBER}.zip"

	if [[ ! -d "$TARGET" ]]; then
		execute mkdir -p "$TARGET"
	else
		execute find "$TARGET" \( -iname "*.so" -or -iname "*.a" \) -not -iname "libmx*.so" -exec rm {} +
	fi

	log_info "========== building codec for $1 =========="
	execute "${PWD}/build-libmp3lame.sh" "$1"
	execute "${PWD}/build-openssl.sh" "$1"
	execute "${PWD}/build-libsmb2.sh" "$1"
	execute "${PWD}/build-libdav1d.sh" "$1"
	execute "${PWD}/build.sh" mxutil release build "$1"
	execute "${PWD}/build-ffmpeg.sh" "$1" | tee build-ffmpeg.log

	if [[ -f "$LIB_NAME" ]]; then
		execute mv "$LIB_NAME" "$TARGET_LIB_NAME"
	else
		die "unable to locate the artifact. check the build logs for more info"
	fi

	if [[ -f "$TARGET_LIB_NAME" ]]; then
		execute mkdir -p "$OUTPUT_DIR"
		execute zip -qj9 "$TARGET_ARCHIVE_NAME" "$TARGET_LIB_NAME"
		execute zip -qj9 "$TARGET_AIO_ARCHIVE_NAME" "$TARGET_LIB_NAME"
		execute rm -f "$TARGET_LIB_NAME"
	else
		die "no artifact found in the output directory. check the build logs for more info"
	fi
}

[[ -d "$MX_FF_SRC_DIR" ]] && execute rm -rfd "$MX_FF_SRC_DIR"
execute mkdir -p "$MX_FF_SRC_DIR"
execute curl -#LR -C - "$MX_FF_SRC_URL" -o "${SCRIPT_DIR}/${SRC_FILENAME}"
execute tar --strip-components=1 -C "$MX_FF_SRC_DIR" -xzf "${SCRIPT_DIR}/${SRC_FILENAME}"

cd "$BUILD_ROOT" || die "failed to switch to source directory"

log_info "update config files"
echo "$PWD"
# perl -i -pe 's/(FF_FEATURES\+=\$FF_FEATURE_(DEMUXER|DECODER|MISC))/# $1/g' config-ffmpeg.sh
perl -i -pe 's/ENABLE_ALL_DEMUXER_DECODER=false/ENABLE_ALL_DEMUXER_DECODER=true/g' config-ffmpeg.sh
perl -i -pe 's/#\!\/bin\/sh/#\!\/usr\/bin\/env bash/g' ffmpeg/configure # too many shift error may occur when the configure script is called on a posix compliant shell.

CLEAN="false"
BUILD_ALL="false"
ARCH=()

while [ "$#" -gt 0 ]; do
	case "$1" in
	--clean)
		CLEAN=true
		;;
	--arm64 | --neon | --x86_64 | --x86)
		if [[ "$BUILD_ALL" != true ]]; then
			ARCH+=("${1#--}")
		fi
		;;
	--all)
		BUILD_ALL="true"
		ARCH=("arm64" "neon" "x86_64" "x86")
		;;
	*)
		die "unknown arg: $1"
		;;
	esac
	shift 1
done

if [[ $CLEAN == "true" ]] && [[ -d "$OUTPUT_DIR" ]]; then
	execute rm -vrf "${OUTPUT_DIR}/"*
fi

if [[ -z "${ARCH[*]}" ]]; then
	log_warn "no arch specified. building all!"
	ARCH=("arm64" "neon" "x86_64" "x86")
fi

for arch in "${ARCH[@]}"; do
	build "$arch"
done
