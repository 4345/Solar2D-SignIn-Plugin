#!/bin/bash -e


PLUGIN="plugin.signin"
PUBLISHER="ovh.azi"

path=$(cd "$(dirname "$0")"; pwd)

(
	set -e
	cd "$path"

	./build.sh
	cd BuiltPlugin

	for platform in *
	do
	    if [ "$platform" != "universal" ] && [ -d "$platform" ]
	    then
	    (
	        cd "$platform"
	        tarPath="$HOME/Solar2DPlugins/$PUBLISHER/$PLUGIN/$platform"
	        rm -rf "$tarPath"
	        mkdir -p "$tarPath"
	        # Журнал tar не нужен: переменная REV в скрипте не задана, и он ложился файлом «.txt» рядом с архивом
        COPYFILE_DISABLE=1 tar -czf "$tarPath/data.tgz" -- * || { echo "Errored on $PUBLISHER/$PLUGIN/$platform"; exit 1; }
	    )
		fi
	done
)

echo
echo '== !!! IMPORTANT !!! =='
echo "Make sure to delete plugin when done: ~/Solar2DPlugins/$PUBLISHER/$PLUGIN"
echo "This plugin will override any Solar2Directory plugin, or plugin from any other source"
echo
