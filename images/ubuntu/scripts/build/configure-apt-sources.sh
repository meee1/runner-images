#!/bin/bash -e
################################################################################
##  File:  configure-apt-sources.sh
##  Desc:  Configure apt sources with failover from Azure to Ubuntu archives.
################################################################################

source $HELPER_SCRIPTS/os.sh

touch /etc/apt/apt-mirrors.txt

printf "http://azure.archive.ubuntu.com/ubuntu/\tpriority:1\n" | tee -a /etc/apt/apt-mirrors.txt
printf "https://archive.ubuntu.com/ubuntu/\tpriority:2\n" | tee -a /etc/apt/apt-mirrors.txt
printf "https://security.ubuntu.com/ubuntu/\tpriority:3\n" | tee -a /etc/apt/apt-mirrors.txt

if ! is_ubuntu22; then
    sources_file="/etc/apt/sources.list.d/ubuntu.sources"
    cloud_template="/etc/cloud/templates/sources.list.ubuntu.deb822.tmpl"
else
    sources_file="/etc/apt/sources.list"
    cloud_template="/etc/cloud/templates/sources.list.ubuntu.tmpl"
fi

# Match whichever archive host the base image shipped with: Azure marketplace images use
# azure.archive.ubuntu.com, plain cloud images use archive.ubuntu.com or
# <cloud>.clouds.archive.ubuntu.com. security.ubuntu.com is deliberately left alone.
sed -i -E 's|https?://([a-z0-9-]+\.)*archive\.ubuntu\.com/ubuntu/?|mirror+file:/etc/apt/apt-mirrors.txt|' "$sources_file"

# A sed that matched nothing leaves apt on the original archive and only surfaces much later
# as a failing Apt test, so fail here instead.
grep -q "mirror+file:/etc/apt/apt-mirrors.txt" "$sources_file" || {
    echo "No archive.ubuntu.com URI found in $sources_file to point at the mirror list:"
    cat "$sources_file"
    exit 1
}

# Apt changes to survive Cloud Init
cp -f "$sources_file" "$cloud_template"
