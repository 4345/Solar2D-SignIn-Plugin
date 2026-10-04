#!/bin/bash -e

# Сборка plugin.signin для iOS: BuiltPlugin/iphone (arm64) и BuiltPlugin/iphone-sim (arm64 + x86_64).
# Запускать как ./build.sh: при «bash build.sh» не действует -e из первой строки,
# и ошибка не остановит сборку.

path=$(cd "$(dirname "$0")"; pwd)

TARGET_NAME=plugin_signin
OUTPUT_SUFFIX=a
CONFIG=Release

# Каталог build, пришедший копированием (с Windows, из архива), теряет метку Xcode
# com.apple.xcode.CreatedByBuildSystem, и clean отказывается его удалять
rm -rf "$path/BuiltPlugin" "$path/build"
xcodebuild -project "$path/Plugin.xcodeproj" -configuration $CONFIG clean

# Если у плагина есть нативное ядро (Rust, C), его собирают здесь под aarch64-apple-ios,
# aarch64-apple-ios-sim и x86_64-apple-ios с IPHONEOS_DEPLOYMENT_TARGET и сливают с
# библиотекой плагина через libtool — см. навык, references/yadro_rust.md

xcodebuild -project "$path/Plugin.xcodeproj" -configuration $CONFIG -sdk iphoneos
xcodebuild -project "$path/Plugin.xcodeproj" -configuration $CONFIG -sdk iphonesimulator

# Раскладка плагина Solar2D: библиотека и metadata.lua (staticLibs = имя библиотеки без lib)
build_plugin_structure() {

	PLUGIN_DEST=$1
	mkdir -p "$PLUGIN_DEST"
	PLATFORM=$2
	ARCH=$3

	cp "$path/build/$CONFIG-$PLATFORM/lib$TARGET_NAME.$OUTPUT_SUFFIX" "$PLUGIN_DEST/"
	cp "$path"/metadata.lua "$PLUGIN_DEST/"

	for f in "$path"/EmbeddedFrameworks/*.framework  "$path/build/$CONFIG-$PLATFORM/"*.framework
	do
		if [ ! -d "$f" ]
		then
			continue
		fi
		FRAMEWORK_NAME=$(basename "$f")
		BIN_NAME=${FRAMEWORK_NAME%.framework}
		SRC_BIN="$f"/$BIN_NAME

		if [[ $(file "$SRC_BIN" | grep -c "ar archive") -ne 0 ]]; then
			echo " - $FRAMEWORK_NAME: is a static Framework, extracting."
			DEST_DIR="$PLUGIN_DEST"
		else
			echo " + $FRAMEWORK_NAME: embedding"
			DEST_DIR="$PLUGIN_DEST"/resources/Frameworks
		fi

		DEST_BIN="$DEST_DIR/$FRAMEWORK_NAME/$BIN_NAME"
		mkdir -p "$DEST_DIR"
		"$(xcrun -f rsync)" --links --exclude '*.xcconfig' --exclude _CodeSignature --exclude .DS_Store --exclude CVS --exclude .svn --exclude .git --exclude .hg --exclude Headers --exclude PrivateHeaders --exclude Modules -resolve-src-symlinks "$f"  "$DEST_DIR"

		rm "$DEST_BIN"
		lipo "$SRC_BIN" $ARCH -o "$DEST_BIN.tmp"
		$(xcrun -f bitcode_strip) "$DEST_BIN.tmp" -r -o "$DEST_BIN"
		rm "$DEST_BIN.tmp"
		rm -rf "$PLUGIN_DEST/$FRAMEWORK_NAME/Versions"
	done
}

build_plugin_structure "$path/BuiltPlugin/iphone" iphoneos  " -extract armv7 -extract  arm64 "

build_plugin_structure "$path/BuiltPlugin/iphone-sim" iphonesimulator  " -extract i386  -extract  x86_64 "

# Проверка срезов, а не заголовка: lipo покажет обе архитектуры и тогда, когда в одном
# срезе нет кода плагина
for arch in arm64 x86_64; do
	if ! nm -arch $arch -gU "$path/BuiltPlugin/iphone-sim/lib$TARGET_NAME.a" 2>/dev/null | grep -q " _luaopen_$TARGET_NAME\$"; then
		echo "ОШИБКА: в срезе $arch библиотеки iphone-sim нет _luaopen_$TARGET_NAME"
		exit 1
	fi
done
if ! nm -gU "$path/BuiltPlugin/iphone/lib$TARGET_NAME.a" | grep -q " _luaopen_$TARGET_NAME\$"; then
	echo "ОШИБКА: в библиотеке iphone нет _luaopen_$TARGET_NAME"
	exit 1
fi
echo "Готово: $path/BuiltPlugin/{iphone,iphone-sim}"
