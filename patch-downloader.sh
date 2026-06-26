#! /bin/bash

#
# Patch Downloader
#

# Iterate over a list of patches in PatchList.csv and download from Oracle support, if they don't already exist locally

# Date       Author                Reason
# ~~~~       ~~~~~~                ~~~~~~
# 25/06/2026 James Gordon          Fix patchURLArray no longer working
#                                  Add debug option and debug output
#                                  Tidy patch URL logic
#                                  Tidy colouring and text of messages
# 03/10/2025 James Gordon          Add --no-check-certificate to wget to ignore certificate issues with MOS
# 19/01/2023 James Gordon          Fix em_catalog failing download and exit return codes variable errors
# 26/08/2021 James Gordon          Check for unzip or die
#                                  Ignore blank lines in CSV file
# 22/01/2021 James Gordon          Check for xmllint or die
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
      echo -e "\n${RED}Error: Unable to create patch folder $1.${RESET}\n"
      return 1
    }
  }
  return 0
}

function checkFileExists {
  # Check that a file exists
  # Return: 0 if file exists, otherwise 1
  [ -r $1 ] || {
    echo -e "${RED}Failed.\n\nError: Configuration file $1 not found.${RESET}\n"
    return 1
  }
  return 0
}

function createOutputFolder {
  # Check and create output base folder, if it doesn't exist
  # Return: 0 if exists or created successfully, otherwise 1
  [ -f $outputFolderBase ] && {
    echo -e "${RED}Failed.\n\nError: Output folder is a file.${RESET}\n"
    return 1
  }

  [ -d $outputFolderBase ] || {
    mkdir -p $outputFolderBase 2> /dev/null || {
      echo -e "${RED}Failed.\n\nError: Cannot create output folder.${RESET}\n"
      return 1
    }
  }
  return 0
}

function authenticateToMOS {
  # Authenticate to MOS (My Oracle Support)
  # Return: 0 if authenticated successfully, otherwise 1
  wget --no-check-certificate --quiet --secure-protocol=auto --save-cookies="$cookieFile" --keep-session-cookies --http-user=$oraEmail --ask-password --output-document=/dev/null "$urlBase/download"

  [ $? -ne 0 ] && {
    echo -e "\n${RED}Error: Authentication to Oracle support failed.${RESET}\n"
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

    wget --no-check-certificate --show-progress --quiet --load-cookies=$cookieFile "$urlWeb/Orion/Download/download_patch/p9348486_112000_Generic.zip" --output-document=$oemDir/p9348486_112000_Generic.zip
    wget --no-check-certificate --show-progress --quiet --load-cookies=$cookieFile "$urlWeb/download/em_catalog.zip" --output-document=$oemDir/em_catalog.zip

    [[ $? -eq 0 ]] && {
      echo -e "\nExtracting Patch Recommendations file from OEM catlog zip."
      unzip -qq -o -d $scriptPath $oemDir/em_catalog.zip patch_recommendations.xml && {
        mkdir -p ${patchXML%/*}
        mv $scriptPath/patch_recommendations.xml $patchXML
        chmod u+w $patchXML
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
  wget --no-check-certificate --quiet --load-cookies="$cookieFile" --output-document=$searchTmp "$urlBase/search?bug=$patchid"
  mapfile -t patchURLArray < <(xmllint -xpath "//patch/files/file/download_url/text()" $searchTmp | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g' | grep -oP '(?<=<!\[CDATA\[).*?(?=\]\]>)')

  [[ -n $debugOutput ]] && {
    echo -e "\nDebug: getPatchInformationFromSearch: patchURLArray has ${#patchURLArray[@]} elements."
    for item in "${patchURLArray[@]}"; do
      echo " Item: $item"
    done
  }


  [[ ${#patchURLArray[@]} -eq 0 ]] && {
    echo -e "\n${RED}Error: Cannot find patch information to download patch $patchid, skipping.${RESET}"
    ((missingDownloads++))
    return 1
  }

  bundleName=$(xmllint -xpath "/results/patch[1]/bug/abstract/text()" $searchTmp 2> /dev/null | cut -f3 -d"[" | cut -f1 -d "]")

  version=$(xmllint -xpath "/results/patch[1]/urm_components/urm_releases/urm_release[1]/@version" $searchTmp | cut -f2 -d"=" | cut -f2 -d '"')

  rm -f $searchTmp

  # Remove training digit if we have for example 12.2.1.4.0
  # [[ $(grep -oF . <<< $version | wc -l) -eq 4 ]] && version=${version: 0:-2}
  [[ ${version: -2:1} == "." ]] && version=${version: 0:-2}
  [[ ${version: -2} == ".0" ]] && version=${version: 0:-2}
  [[ ${version: -2} == ".0" ]] && version=${version: 0:-2}

  [[ ${#patchURLArray[@]} -eq 1 ]] && {
    patchURL=$urlWeb${patchURLArray[0]}
    return
  }

  [[ ${#patchURLArray[@]} -gt 1 ]] && {
    for i in "${!patchURLArray[@]}"; do
      [[ "${patchURLArray[$i]}" =~ "$os" ]] && {
        patchURL=$urlWeb${patchURLArray[$i]}
        return 0
      }
    done
  }

  echo -e "\n${RED}Error: Cannot find OS patch information for $patchid ($os), skipping.${RESET}"
  ((missingDownloads++))

  return 1
}

function getPatchInformation {
  # Get the patch information from recommendations XML file
  # Return: 0 if we have the information, otherwise 1

  patchURL=""

  # Get patch URL from recommendations XML file
  # Fails if the patch is not a recommended patch
  mapfile -t patchURLArray < <(xmllint -xpath "//patch[name[text()=\"$patchid\"]]/files/file/download_url/text()" $patchXML | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g' | grep -oP '(?<=<!\[CDATA\[).*?(?=\]\]>)')

  [[ -n $debugOutput ]] && {
    echo -e "\nDebug: getPatchInformation: patchURLArray has ${#patchURLArray[@]} elements."
    for item in "${patchURLArray[@]}"; do
      echo " Item: $item"
    done
  }

  # If the patch is missing, attempt to get it from a search
  [[ ${#patchURLArray[@]} -eq 0 ]] && {
    echo -e "\n${YELLOW}Patch $patchid ($description) ${os:-"Generic"} not listed in the recommendations file, using bug search.${RESET}"
    # Get all the required information from a search instead
    getPatchInformationFromSearch
    return $?
  }

  [[ ${#patchURLArray[@]} -eq 0 ]] && {
    [[ -n $debugOutput ]] && echo "Debug: getPatchInformation: Unable to get patch information, returning null.\n"
    patchURL=""
    return
  }

  bundleName=$(xmllint -xpath "//patch[name[text()=\"$patchid\"]][1]/psu_bundle/text()" $patchXML 2> /dev/null | cut -f3 -d"[" | cut -f1 -d "]")
  # If we can't find the bundleName in the patch recommendations file search the bugs file
  [[ $? -ne 0 ]] && {
    bundleName=$(grep -A1 $patchid $patchBugs  | grep abstract | tr -s ' '| sort -u | cut -f3 -d"[" | cut -f1 -d "]")
  }

  version=$(xmllint -xpath "//patch[name[text()=\"$patchid\"]][1]/urm_components/urm_releases/urm_release[1]/@version" $patchXML | cut -f2 -d"=" | cut -f2 -d '"')

  # Remove training digit if we have for example 12.2.1.4.0
  # [[ $(grep -oF . <<< $version | wc -l) -eq 4 ]] && version=${version: 0:-2}
  [[ ${version: -2:1} == "." ]] && version=${version: 0:-2}
  [[ ${version: -2} == ".0" ]] && version=${version: 0:-2}
  [[ ${version: -2} == ".0" ]] && version=${version: 0:-2}

  [[ ${#patchURLArray[@]} -eq 1 ]] && {
    patchURL=$urlWeb${patchURLArray[0]}
    return
  }

  [[ ${#patchURLArray[@]} -gt 1 ]] && {
    for i in "${!patchURLArray[@]}"; do
      [[ "${patchURLArray[$i]}" =~ "$os" ]] && {
        patchURL=$urlWeb${patchURLArray[$i]}
        return 0
      }
    done
  }

  echo -e "\n${RED}Error: Cannot find OS patch information for $patchid, skipping.${RESET}"
  ((missingDownloads++))

  return 1
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
E_SOFTWARE_MISSING=7     # Missing software, xmllint or unzip

# Colours
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
UUNDERLINE="\e[4m"
BOLD="\033[1m"
RESET="\e[0m"

xml_days_old=30 # Number of days before forcing download of patch_recommendations.xml

echo -e "\n${scriptName%.*} - Oracle Patch Downloader\n"

command -v xmllint > /dev/null 2>&1 || {
echo "Requires xmlling to be installed (install libxml2-utils), exiting."
  exit $E_SOFTWARE_MISSING
}

command -v unzip > /dev/null 2>&1 || {
echo "Requires unzip to be installed (install unzip), exiting."
  exit $E_SOFTWARE_MISSING
}

echo -n "Checking for configuration file..."

checkFileExists $configFile || exit $E_FILE_NOT_EXISTS

echo -ne "${GREEN}success.${RESET}\nChecking for patch list..."

checkFileExists $patchList || exit $E_FILE_NOT_EXISTS

echo -e "${GREEN}success.${RESET}"

# Read variables from configurarion file
outputFolderBase=$(grep ^outputFolderBase $configFile | cut -f2 -d"=")
oraEmail=$(grep ^oraEmail $configFile | cut -f2 -d"=")
debugOutput=$(grep ^debugOutput $configFile | cut -f2 -d"=")

[[ -z $outputFolderBase ]] && {
  echo -e "\n${RED}Error: outputFolderBase variable not defined in ${scriptName%.*}.cfg, exiting.${RESET}\n"
  exit $E_VARIABLE_NOT_DEFINED
}

echo -ne "Checking output folder..."

createOutputFolder $outputFolderBase || exit 3

echo -e "${GREEN}success.${RESET}\n"

[[ -n $debugOutput ]] && echo -e "${GREEN}Debug output enabled.${RESET}\n"

# Prompt for email address to login to support if not defailed in the configuration file
[ -z $oraEmail ] && read -p "Enter Oracle Support email address: " oraEmail || echo -e "Email address read from configuration file."

# Login to Oracle Support

echo -e "\nAuthenticating to Oracle Support as $oraEmail...\n"

authenticateToMOS || exit $E_MOS_AUTH_FAILED

echo -e "\nAuthenticated to Oracle support."

# Download OEM catalog files and extract patch recomendations XML file, if older than xml_days_old days
downloadCatalog || exit $?

# Read the file, extracting each line to process

echo -e "\nProcessing patch list file."
[[ $(grep -c "^\s*$" $patchList) -gt 0 ]] && sed -i '/^[[:space:]]*$/d' $patchList

while IFS=, read -r patchid cpu description folder_prefix os
do
  [[ "$patchid" =~ ^#.*$ ]] && continue

  ((totalDownloads++))

  # Strip newline from last field (folder_prefix or os)
  folder_prefix=${folder_prefix%$'\r'}
  os=${os%$'\r'}

  [[ -n $debugOutput ]] && {
    echo -e "\nDebug: Patch Information.

  Patch ID     : $patchid
  CPU          : $cpu
  Description  : $description
  Folder Prefix: $folder_prefix
  OS           : $os"
  }

  getPatchInformation || continue

  [[ -z $patchURL ]] && {
    echo -e " - ${RED}unable to get information of patch, ignoring.${RESET}"
    ((failedDownloads++))
  }

  patchFile=$( cut -f1 -d"?" <<< ${patchURL##*/})
  patchFolder=$outputFolderBase/${folder_prefix}_${version}
  patchFolder=${patchFolder// /_}

  [[ -n $cpu ]] && patchFolder=${patchFolder}.${cpu}

  createFolder $patchFolder

  echo -ne "\nPatch $patchFile - ${bundleName:-"Missing Description"}"

  if [[ ! -f $patchFolder/$patchFile ]]; then
    echo -e " - ${GREEN}Downloading${RESET}"
    wget --no-check-certificate --no-clobber --show-progress --quiet --load-cookies="$cookieFile" --output-document=$patchFolder/$patchFile "$patchURL"
    if [[ $? -eq 0 && $(stat --format=%s $patchFolder/$patchFile) -gt 0 ]]
    then
      ((successDownloads++))
    else
      echo -e "\n${RED}Download failed, removing patch file.${RESET}"
      rm -f $patchFolder/$patchFile
      ((failedDownloads++))
    fi
  else
    echo -e " - ${YELLOW}Patch already exists, skipping.${RESET}"
    ((skippedDownloads++))
  fi

done < $patchList

echo -e "\nDownloads: $totalDownloads, successful: ${GREEN}$successDownloads${RESET}, failed: ${RED}$failedDownloads${RESET}, skipped: ${YELLOW}$skippedDownloads${RESET}, missing: ${RED}$missingDownloads${RESET}.\nDownloads complete and stored in $outputFolderBase.\n"
