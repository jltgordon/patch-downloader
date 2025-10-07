#
# Patch Downloader - Batch Oracle support patch downloader
#

This script uses patch-downloader.csv to download from a list of patches specified.

It doesn't re-download patch files, if the already exist, so you will need to remove a file to force the script to download it again.

It requires xmllint to be installed, install from libxml2-utils.

# patch-downloader.cfg

There are two variables set in this configuration file, one optional.

- outputFolderBase - Base folder to check and download files
- oraEmail         - Oracle support website username, optional, will prompt if missing

# patch-downloader.csv

This file contains the list of patches to download and contains the following columns:

- PatchID     - The patch number
- CPU         - CPU e.g. 200717 or the old style 20, leave blank to stop adding to folder name
- Description - Patch description, makes patches easy to find when updating csv
- Group       - Used to group seperate patches together, e.g. Portal or WLS
- OS          - Operating system Linux-x86-64 or MSWIN-x86-64, for Generic leave blank

The following values are combined to make the output folder in $outoutFolderBase, if CPU is blank only $group is used:

$group_$version.$cpu

e.g. ~/OraMedia/Patches/Portal_12.2.1.4.0.200717

This script uses the patch_recommendations.xml from the OEM catalog zip, renaming it to patch-downloader.xml.

It downloads the catalog zip and p9348486_112000_Generic.zip automatically, useful for loading into OEM, if patch-downloader.xml is missing or more than 30 days old.

# extract-java.sh

This helper script extracts the Linux .tar.gz and Windows .zip friles from downloads into Java/jdk_$version[_win] folder.
