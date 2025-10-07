#! /bin/bash

#
# Extract Java
#

# Extract Java .tar.gz and .zip files from te downloads folder

# Date       Author                Reason
# ~~~~       ~~~~~~                ~~~~~~
# 07/10/2025 James Gordon          Initial versionsion

scriptPath=${0%/*}
scriptName=${0##*/}
configFile=$scriptPath/patch-downloader.cfg
outputFolderBase=$(grep ^outputFolderBase $configFile | cut -f2 -d"=")
IFS=$'\n'

for i in $(grep Java patch-downloader.csv); do
	str=${i%%[[:cntrl:]]} # Strip control characters
	patchnumber=$(echo $str | cut -f1 -d",")
	version=$(echo $(echo $str | cut -f3 -d",") | cut -f5 -d" ")
	[[ "$version" =~ ^1.8 ]] && version=${version%.*}_${version##*.}
	[[ "$version" =~ ^21 ]] && version=21
	folder=$(echo $str | cut -f4 -d",")
	os=$(echo $str | cut -f5 -d",")

    outVersion=${version%_*}
    outVersion=${version%.0*}
    [[ "$os" =~ "MSWIN" ]] && outVersion+=_win

    outFolder=$outputFolderBase/../Java/jdk_${outVersion}
	zipFile=$outputFolderBase/${folder}_$version/p${patchnumber}_*_${os}.zip

    mkdir -p $outFolder

	[[ "$os" =~ "Linux" ]] && {
	  unzip $zipFile *.tar.gz -d $outFolder
    }
    [[ "$os" =~ "MSWIN" ]] && {
	  unzip $zipFile *.zip -d $outFolder
    }
done

