#! /bin/bash

#
# Patch Downloader
#

# Iterate over a list of patches in PatchList.csv and download from Oracle support, if they don't already exist locally

# Date       Author                Reason
# ~~~~       ~~~~~~                ~~~~~~
# 23/07/2020 James Gordon          Allow no CPU in CSV and not alter folder name
# 22/07/2020 James Gordon          Get recommendations file from OEM catalog zip
# 17/07/2020 James Gordon          Get ARU etc. from patch_recommendations.xml
# 15/07/2020 James Gordon          Initial version

trap 'rm -f $cookieFile; exit 1' 1 2 3 6

# Sets $? of the last program to exit non-zero in a pipe or zero if all exited successfully
set -o pipefail

function createFolder {
  # Create the patch folder
  # Return: 0 if exists or created successfully, otherwise 1
  [ -d $1 ] || {
    mkdir -p $1 || {
      echo -e "\n\e[31mError: Unable to create patch folder $1.\e[0m\n"
      return 1
    }
  }
  return 0
}

function checkFileExists {
  # Check that a file exists
  # Return: 0 if file exists, otherwise 1
  [ -r $1 ] || {
    echo -e "\e[31mFailed.\n\nError: Configuration file $1 not found.\e[0m\n"
    return 1
  }
  return 0
}

function createOutputFolder {
  # Check and create output base folder, if it doesn't exist
  # Return: 0 if exists or created successfully, otherwise 1
  [ -f $outputFolderBase ] && {
    echo -e "\e[31mFailed.\n\nError: Output folder is a file.\e[0m\n"
    return 1
  }

  [ -d $outputFolderBase ] || {
    mkdir -p $outputFolderBase 2> /dev/null || {
      echo -e "\e[31mFailed.\n\nError: Cannot create output folder.\e[0m\n"
      return 1
    }
  }
  return 0
}

function authenticateToMOS {
  # Authenticate to MOS (My Oracle Support)
  # Return: 0 if authenticated successfully, otherwise 1
  wget --quiet --secure-protocol=auto --save-cookies="$cookieFile" --keep-session-cookies --http-user=$oraEmail --ask-password --output-document=/dev/null "$urlBase/download"

  [ $? -ne 0 ] && {
    echo -e "\n\e[31mError: Authentication to Oracle support failed.\e[0m\n"
    return 1
  }
  return 0
}

function downloadCatalog {
  # Download OEM catlog files
  # Extract patch_recommendations.xml from OEM catalog zip
  # Extract bug data from XML file into separate file and remove as it's too large for xmllint
  # Return: 0 if all goes to plan, otherwise E_PATCH_DIR_FAILED or E_EXTRACT_FAILED
  [[ ! -f $patchXML ||  $(find -wholename $patchXML -mtime +$xml_days_old) ]] && {
    echo -e "\nFile ${patchXML##*/} is missing or downloaded more than $xml_days_old days ago, downloading a new copy.\n"

    oemDir=$outputFolderBase/OEM/Catalog
    createFolder $oemDir || return $E_PATCH_DIR_FAILED

    echo -e "Downloading OEM catalog files to $oemDir.\n"

    wget  --show-progress --quiet --user-agent="Mozilla/5.0"  --load-cookies=$cookieFile --save-cookies=$cookieFile --keep-session-cookies "$urlWeb/Orion/Download/download_patch/p9348486_112000_Generic.zip" --output-document=$oemDir/p9348486_112000_Generic.zip
    wget  --show-progress --quiet --user-agent="Mozilla/5.0"  --load-cookies=$cookieFile --save-cookies=$cookieFile --keep-session-cookies "$urlWeb/download/em_catalog.zip" --output-document=$oemDir/em_catalog.zip

    [[ $? -eq 0 ]] && {
      echo -e "\nExtracting Patch Recommendations file from OEM catlog zip."
      unzip -qq -o -d $scriptPath $oemDir/em_catalog.zip patch_recommendations.xml && {
        mkdir -p ${patchXML%/*}
        mv $scriptPath/patch_recommendations.xml $patchXML
      } || {
        echo -e "\nError: Extracting recommendations file failed, exiting.\n"
        return $E_EXTRACT_FAILED
      }
    }

    # Strip bug information as the file is too large for xmllint
    [ $? -eq 0 ] && {
      grep -A3 "<bug>" $patchXML > $patchBugs
      sed -i '/<bug>/,+3d' $patchXML
    }
  }
  return 0
}

function getPatchInformationFromSearch {
  # Get the patch information XML from MOS
  # Return: 0 if we can get all the data, otherwise 1
  local searchTmp=$(mktemp --tmpdir mos_search.XXXXXX)
  wget --quiet --load-cookies="$cookieFile" --output-document=$searchTmp "$urlBase/search?bug=$patchid"
  local patchURLArray=($(xmllint -xpath "//patch/files/file/download_url/text()" $searchTmp 2> /dev/null | cut -f3 -d"[" | cut -f1 -d "]"))

  [[ ${#patchURLArray[@]} -eq 0 ]] && {
    echo -e "\n\e[31mError: Cannot find patch information to download patch $patchid, skipping.\e[0m"
    ((missingDownloads++))
    return 1
  }

  [[ ${#patchURLArray[@]} -gt 1 ]] && {
    for i in "${!patchURLArray[@]}"; do
      [[ "${patchURLArray[$i]}" =~ "$os" ]] && {
        patchURL=$urlWeb${patchURLArray[$i]}
        break
      }
    done
  } || {
    patchURL=$urlWeb${patchURLArray[0]}
  }

  bundleName=$(xmllint -xpath "/results/patch[1]/bug/abstract/text()" $searchTmp 2> /dev/null | cut -f3 -d"[" | cut -f1 -d "]")

  version=$(xmllint -xpath "/results/patch[1]/urm_components/urm_releases/urm_release[1]/@version" $searchTmp | cut -f2 -d"=" | cut -f2 -d '"')

  rm -f $searchTmp
  return 0
}

function getPatchInformation {
  # Get the patch information from recommendations XML file
  # Return: 0 if we have the information, otherwise 1

  # Get patch URL from recommendations XML file
  # Fails if the patch is not a recommended patch
  local patchURLArray=($(xmllint -xpath "//patch[name[text()=\"$patchid\"]]/files/file/download_url/text()" $patchXML 2> /dev/null | cut -f3 -d"[" | cut -f1 -d "]"))

  # If the patch is missing, attempt to get it from a search
  [[ ${#patchURLArray[@]} -eq 0 ]] && {
    echo -e "\n\e[33mPatch $patchid ($description) ${os:-"Generic"} not listed in the recommendations file, using bug search.\e[0m"
    # Get all the required information from a search instead
    getPatchInformationFromSearch
    return $?
  }

  [[ ${#patchURLArray[@]} -gt 1 ]] && {
    for i in "${!patchURLArray[@]}"; do
      [[ "${patchURLArray[$i]}" =~ "$os" ]] && {
        patchURL=$urlWeb${patchURLArray[$i]}
        break
      }
    done
  } || {
    patchURL=$urlWeb${patchURLArray[0]}
  }

  bundleName=$(xmllint -xpath "//patch[name[text()=\"$patchid\"]][1]/psu_bundle/text()" $patchXML 2> /dev/null | cut -f3 -d"[" | cut -f1 -d "]")
  # If we can't find the bundleName in the patch recommendations file search the bugs file
  [[ $? -ne 0 ]] && {
    bundleName=$(grep -A1 $patchid $patchBugs  | grep abstract | tr -s ' '| sort -u | cut -f3 -d"[" | cut -f1 -d "]")
  }

  version=$(xmllint -xpath "//patch[name[text()=\"$patchid\"]][1]/urm_components/urm_releases/urm_release[1]/@version" $patchXML | cut -f2 -d"=" | cut -f2 -d '"')

  return 0
}

#
# Initial setup and checks
#

scriptPath=${0%/*}
scriptName=${0##*/}

# File names
patchList=$scriptPath/${scriptName%.*}.csv
patchXML=$scriptPath/data/${scriptName%.*}.xml
patchBugs=$scriptPath/data/${scriptName%.*}.bugs
configFile=$scriptPath/${scriptName%.*}.cfg
cookieFile=$(mktemp --tmpdir wget_cookie.XXXXXX)

# Base URLs
urlWeb="https://updates.oracle.com"
urlBase="$urlWeb/Orion/Services"

# Download totals
totalDownloads=0
successDownloads=0
failedDownloads=0
skippedDownloads=0
missingDownloads=0

# Error Codes
E_PATCH_DIR_FAILED=1     # Unable to create individual patch folder
E_FILE_NOT_EXISTS=2      # File don't exist
E_OUTPUT_DIR_FAILED=3    # Base output folder creation failed
E_VARIABLE_NOT_DEFINED=4 # Expected variable not defined
E_MOS_AUTH_FAILED=5      # Authentication to Oracle MOS failed
E_EXTRACT_FAILED=6       # File extraction failed

xml_days_old=30 # Number of days before forcing download of patch_recommendations.xml

echo -e "\n${scriptName%.*} - Oracle Patch Downloader\n"

echo -n "Checking for configuration file..."

checkFileExists $configFile || exit $E_FILE_NOT_EXISTS

echo -ne "Success.\nChecking for patch list..."

checkFileExists $patchList || exit $E_FILE_NOT_EXISTS

echo -e "Success."

# Read variables from configurarion file
outputFolderBase=$(grep ^outputFolderBase $configFile | cut -f2 -d"=")
oraEmail=$(grep ^oraEmail $configFile | cut -f2 -d"=")

[[ -z $outputFolderBase ]] && {
  echo -e "\n\e[31mError: outputFolderBase variable not defined in ${scriptName%.*}.cfg, exiting.\e[0m\n"
  exit $E_VARIABLE_NOT_DEFINED
}

echo -ne "Checking output folder..."

createOutputFolder $outputFolderBase || exit 3

echo -e "Success.\n"

# Prompt for email address to login to support if not defailed in the configuration file
[ -z $oraEmail ] && read -p "Enter Oracle Support email address: " oraEmail || echo -e "Email address read from configuration file."

# Login to Oracle Support

echo -e "\nAuthenticating to Oracle Support as $oraEmail...\n"

authenticateToMOS || exit $E_MOS_AUTH_FAILED

echo -e "\nAuthenticated to Oracle support."

# Download OEM catalog files and extract patch recomendations XML file, if older than xml_days_old days
downloadCatalog || exit $?

# Set the variables before first use to define as global
#patchURL= # The URL to download the patch

# Read the file, extracting each line to process

echo -e "\nProcessing patch list file."

while IFS=, read -r patchid cpu description group os
do
  [[ "$patchid" =~ ^#.*$ ]] && continue

  ((totalDownloads++))

  # Strip newline from last field (group or os)
  group=${group%$'\r'}
  os=${os%$'\r'}

  getPatchInformation || continue

  patchFile=$( cut -f1 -d"?" <<< ${patchURL##*/})
  patchFolder=$outputFolderBase/${group}

  [[ -n $cpu ]] && patchFolder=${patchFolder}_${version}.${cpu}

  createFolder $patchFolder

  echo -ne "\nPatch $patchFile - ${bundleName:-"Missing Description"}"

  if [[ ! -f $patchFolder/$patchFile ]]; then
    echo -e " - \e[32mDownloading\e[0m"
    wget --no-clobber --show-progress --quiet --load-cookies="$cookieFile" --output-document=$patchFolder/$patchFile "$patchURL"
    if [[ $? -eq 0 ]]; then ((successDownloads++)); else ((failedDownloads++)); fi
  else
    echo -e " - \e[1;33mPatch file already exists, skipping download.\e[0m"
    ((skippedDownloads++))
  fi

done < $patchList

echo -e "\nDownloads: $totalDownloads, successful: \e[32m$successDownloads\e[0m, failed: \e[31m$failedDownloads\e[0m, skipped: \e[1;33m$skippedDownloads\e[0m, missing: \e[31m$missingDownloads\e[0m.\nDownloads complete and stored in $outputFolderBase.\n"
