#!/bin/bash -e
################################################################################
##  File:  install.sh
##  Desc:  Helper functions for installing tools
################################################################################

download_with_retry() {
    url=$1
    download_path=$2

    if [ -z "$download_path" ]; then
        download_path="/tmp/$(basename "$url")"
    fi

    echo "Downloading package from $url to $download_path..." >&2

    interval=30
    download_start_time=$(date +%s)

    for ((retries=20; retries>0; retries--)); do
        attempt_start_time=$(date +%s)
        if http_code=$(curl -4sSLo "$download_path" "$url" -w '%{http_code}'); then
            attempt_seconds=$(($(date +%s) - attempt_start_time))
            if [ "$http_code" -eq 200 ]; then
                echo "Package downloaded in $attempt_seconds seconds" >&2
                break
            else
                echo "Received HTTP status code $http_code after $attempt_seconds seconds" >&2
            fi
        else
            attempt_seconds=$(($(date +%s) - attempt_start_time))
            echo "Package download failed in $attempt_seconds seconds" >&2
        fi

        if [ "$retries" -le 1 ]; then
            total_seconds=$(($(date +%s) - download_start_time))
            echo "Package download failed after $total_seconds seconds" >&2
            exit 1
        fi

        echo "Waiting $interval seconds before retrying (retries left: $retries)..." >&2
        sleep $interval
    done

    echo "$download_path"
}

## Use dpkg to figure out if a package has already been installed
## Example use:
## if ! IsPackageInstalled packageName; then
##     echo "packageName is not installed!"
## fi
IsPackageInstalled() {
    dpkg -S $1 &> /dev/null
}

verlte() {
    sortedVersion=$(printf "$1\n$2\n" | sort -V | head -n1)
    [  "$1" = "$sortedVersion" ]
}

get_toolset_path() {
    echo "/imagegeneration/installers/toolset.json"
}

get_toolset_value() {
    local toolset_path=$(get_toolset_path)
    local query=$1
    echo "$(jq -r "$query" $toolset_path)"
}

get_github_package_download_url() {
    local REPO_ORG=$1
    local FILTER=$2
    local VERSION=$3
    local SEARCH_IN_COUNT="100"

    json=$(curl -fsSL "https://api.github.com/repos/${REPO_ORG}/releases?per_page=${SEARCH_IN_COUNT}")

    if [ -n "$VERSION" ]; then
        tagName=$(echo $json | jq -r '.[] | select(.prerelease==false).tag_name' | sort --unique --version-sort | egrep -v ".*-[a-z]|beta" | egrep "\w*${VERSION}" | tail -1)
    else
        tagName=$(echo $json | jq -r '.[] | select((.prerelease==false) and (.assets | length > 0)).tag_name' | sort --unique --version-sort | egrep -v ".*-[a-z]|beta" | tail -1)
    fi

    downloadUrl=$(echo $json | jq -r ".[] | select(.tag_name==\"${tagName}\").assets[].browser_download_url | select(${FILTER})" | head -n 1)
    if [ -z "$downloadUrl" ]; then
        echo "Failed to parse a download url for the '${tagName}' tag using '${FILTER}' filter"
        exit 1
    fi
    echo $downloadUrl
}

get_github_package_hash() {
    local repo_owner=$1
    local repo_name=$2
    local file_name=$3
    local url=$4
    local version=${5:-"latest"}
    local prerelease=${6:-false}
    local delimiter=${7:-'|'}
    local word_number=${8:-2}

    if [[ -z "$file_name" ]]; then
        echo "File name is not specified."
        exit 1
    fi

    if [[ -n "$url" ]]; then
        release_url="$url"
    else
        if [ "$version" == "latest" ]; then
            release_url="https://api.github.com/repos/${repo_owner}/${repo_name}/releases/latest"
        else
            json=$(curl -fsSL "https://api.github.com/repos/${repo_owner}/${repo_name}/releases?per_page=100")
            tags=$(echo "$json" | jq -r --arg prerelease "$prerelease" '.[] | select(.prerelease == ($prerelease | test("true"; "i"))) | .tag_name')
            tag=$(echo "$tags" | grep -o "$version")
            if [[ "$(echo "$tag" | wc -l)" -gt 1 ]]; then
                echo "Multiple tags found matching the version $version. Please specify a more specific version."
                exit 1
            fi
            if [[ -z "$tag" ]]; then
                echo "Failed to get a tag name for version $version."
                exit 1
            fi
            release_url="https://api.github.com/repos/${repo_owner}/${repo_name}/releases/tags/$tag"
        fi
    fi

    body=$(curl -fsSL "$release_url" | jq -r '.body' | tr -d '`')
    matching_line=$(echo "$body" | grep "$file_name")
    if [[ "$(echo "$matching_line" | wc -l)" -gt 1 ]]; then
        echo "Multiple lines found included the file $file_name. Please specify a more specific file name."
        exit 1
    fi
    if [[ -z "$matching_line" ]]; then
        echo "File name '$file_name' not found in release body."
        exit 1
    fi

    result=$(echo "$matching_line" | cut -d "$delimiter" -f "$word_number" | tr -d -c '[:alnum:]')
    if [[ -z "$result" ]]; then
        echo "Empty result. Check parameters delimiter and/or word_number for the matching line."
        exit 1
    fi

    echo "$result"
}

get_hash_from_remote_file() {
    local url=$1
    local keywords=("$2" "$3")
    local delimiter=${4:-' '}
    local word_number=${5:-1}

    if [[ -z "${keywords[0]}" || -z "$url" ]]; then
        echo "File name and/or URL is not specified."
        exit 1
    fi

    matching_line=$(curl -fsSL "$url" | sed 's/  */ /g' | tr -d '`')
    for keyword in "${keywords[@]}"; do
        matching_line=$(echo "$matching_line" | grep "$keyword")
    done

    if [[ "$(echo "$matching_line" | wc -l)" -gt 1 ]]; then
        echo "Multiple lines found including the words: ${keywords[*]}. Please use a more specific filter."
        exit 1
    fi

    if [[ -z "$matching_line" ]]; then
        echo "Keywords (${keywords[*]}) not found in the file with hashes."
        exit 1
    fi

    result=$(echo "$matching_line" | cut -d "$delimiter" -f "$word_number" | tr -d -c '[:alnum:]')
    if [[ ${#result} -ne 64 && ${#result} -ne 128 ]]; then
        echo "Invalid result length. Expected 64 or 128 characters. Please check delimiter and/or word_number parameters."
        echo "Result: $result"
        exit 1
    fi

    echo "$result"
}

use_checksum_comparison() {
    local file_path=$1
    local checksum=$2
    local sha_type=${3:-"256"}

    echo "Performing checksum verification"

    if [[ ! -f "$file_path" ]]; then
        echo "File not found: $file_path"
        exit 1
    fi

    local_file_hash=$(shasum --algorithm "$sha_type" "$file_path" | awk '{print $1}')

    if [[ "$local_file_hash" != "$checksum" ]]; then
        echo "Checksum verification failed. Expected hash: $checksum; Actual hash: $local_file_hash."
        exit 1
    else
        echo "Checksum verification passed"
    fi
}
