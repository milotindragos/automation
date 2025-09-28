#!/bin/bash
set -euo pipefail
# [0] preflight-check-dependencies: Curl is only dependency by design
# Check for required tools only once
if ! command -v curl &>/dev/null; then
    echo "<error> 'curl' is required but not found." >&2
    exit 1
fi

# [1] helper-functions:

# [1.1] help-function:  
help() {
    cat <<EOF
name: gh_download_asset
details: Download assets/releases from GitHub
author: Dragos Milotin
usage: $0 [options] <github_url>
options: |
  -h, --help         Show this help message and exit
notes: |
  Run without arguments to enter interactive mode.
EOF
}


# [1.2] extract_repo_info: Helper function: Extract user and repo from a github.com URL
extract_repo_info() {
    local url="$1"
    local path
    
    # 1. Clean up URL (https?://, www.)
    # 2. Match and remove either 'github.com/' OR 'raw.githubusercontent.com/'
    path=$(echo "$url" | sed -E 's|^https?://||; s|^www\.||' | \
        sed -E 's|^raw\.githubusercontent\.com/||; s|^github\.com/||; s|/+$||')
    
    # Check if the path starts with two path segments followed by EITHER a slash 
    # and more text OR the end of the string ($)
    if [[ "$path" =~ ^([^/]+)/([^/]+)($|/) ]]; then
        # NOTE: We use BASH_REMATCH to set the *global* variables $USER and $REPO
        # for use in the pre_flight_check function.
        USER="${BASH_REMATCH[1]}"
        REPO="${BASH_REMATCH[2]}"
        return 0
    else
        echo "<error> Could not extract user/repo from URL: $url" >&2
        return 1
    fi
}

# [1.3] gh_download_asset: Helper function: Handles file/asset download
gh_download_asset() {
    local url="$1"
    local auth_header=""
    local filename=""
    local api_url=""
    local response=""
    local status
    local assets=""
    local gh_tag=""
    local count
    local choice
    local selected=""

    if [ -n "${GITHUB_TOKEN:-}" ]; then
        auth_header="Authorization: token ${GITHUB_TOKEN}"
    fi

    if ! [[ "$url" =~ ^https://(raw\.githubusercontent\.com|github\.com)/ ]]; then
        echo "<error> Only GitHub URLs are allowed." >&2
        return 8
    fi

    if [[ "$url" =~ raw.githubusercontent.com ]]; then
        filename=$(basename "$url" | cut -d '?' -f 1)
        echo "<info> Downloading raw file: $url as $filename"
        curl -fsSL -H "$auth_header" \
             -H "Accept: application/vnd.github.v3.raw" \
             -o "$filename" "$url"
    elif [[ "$url" =~ github.com/.*/.*/releases/download ]]; then
        echo "<info> Downloading release asset: $url"
        curl -fsSLO -H "$auth_header" "$url"
        filename=$(basename "$url" | cut -d '?' -f 1)
    elif extract_repo_info "$url"; then
        api_url="https://api.github.com/repos/$USER/$REPO/releases/latest"
        echo "<info> Fetching latest release for $USER/$REPO ..."
        response=$(curl -s -H "$auth_header" "$api_url")
        status=$?
        if [ "$status" -ne 0 ]; then
            echo "<error> Error fetching API ($api_url). Curl failed." >&2
            return 1
        fi
        if echo "$response" | grep -q '"message":'; then
            if echo "$response" | grep -q "Not Found"; then
                 echo "<error> Repo not found or no access (API message: Not Found)." >&2
            else
                 echo "<error> Authentication or API error. Check token scope/permissions." >&2
            fi
            return 2
        fi
        assets=$(echo "$response" | grep "browser_download_url" | cut -d '"' -f 4)
        gh_tag=$(echo "$response" | grep '"tag_name"' | cut -d '"' -f 4)
        count=$(echo "$assets" | grep -c '^')
        if [ "$count" -eq 0 ]; then
            echo "<error> No release assets found for tag: ${gh_tag:-N/A}" >&2
            return 3
        elif [ "$count" -eq 1 ]; then
            selected="$assets"
            echo "<info> Detected release tag: $gh_tag"
            echo "<info> Downloading single release asset: $selected"
            curl -fsSLO -H "$auth_header" "$selected"
            filename=$(basename "$selected" | cut -d '?' -f 1)
        else
            echo "<choice> Multiple assets found (tag: $gh_tag):"
            echo "$assets" | nl -w2 -s". "
            read -r -p "<prompt> Select asset number (1-$count) to download: " choice
            if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
                echo "<error> Invalid choice." >&2
                return 4
            fi
            selected=$(echo "$assets" | sed -n "${choice}p")
            if [ -n "$selected" ]; then
                echo "<info> Downloading: $selected"
                curl -fsSLO -H "$auth_header" "$selected"
                filename=$(basename "$selected" | cut -d '?' -f 1)
            else
                echo "<error> Failed to select asset." >&2
                return 5
            fi
        fi
    else
        if ! curl -s --head https://github.com/ >/dev/null; then
            echo "<error> Cannot reach GitHub. Check internet or proxy settings." >&2
            exit 1
        fi
        echo "<error> Unsupported URL format or malformed repo URL." >&2
        return 6
    fi

    local curl_status=$?
    if [ "$curl_status" -eq 0 ]; then
        if [ -n "$filename" ]; then
            echo "<success> Successfully downloaded $filename"
        else
            echo "<success> Successfully completed download. Check your current directory for the new file."
        fi
    else
        echo "<error> Download failed with curl status $curl_status." >&2
        return 7
    fi
}

# [1.4] 
pre_flight_check() {
    # 1. Use local variables for function arguments and internal state
    local github_token="$1"
    local repo_url="$2"
    local api_check # Declared here to ensure scope
    local status    # Declared here to ensure scope

    # 2. Check if token is available AND if repo info extraction is successful (returns 0)
    if [ -n "${github_token}" ] && extract_repo_info "$repo_url"; then
        
        # 3. $USER and $REPO must be global or set by the previous function call
        api_check="https://api.github.com/repos/$USER/$REPO"
        
        echo "<info> Checking token access for $USER/$REPO..."
        
        # 4. Use the local token variable for the header
        status=$(curl -s -o /dev/null -w "%{http_code}" \
                      -H "Authorization: token $github_token" \
                      "$api_check")
                      
        case $status in
            200) 
                echo "<success> Repo accessible (HTTP 200) ✅"
                return 0 # Success
                ;;
            404) 
                echo "<error> Repo not found or no access (HTTP 404) ⚠️" >&2
                return 1 # Failure
                ;;
            401|403) 
                echo "<error> Authentication failed (HTTP $status) ❌" >&2
                return 1 # Failure
                ;;
            *) 
                echo "<error> Unexpected status $status (URL: $api_check) 🛑" >&2
                return 1 # Failure
                ;;
        esac
    fi
    
    # 5. If no token was provided but it wasn't strictly required (e.g., public repo check), 
    # the function exits here. Assuming a token is needed for a pre-flight check to pass:
    if [ -z "${github_token}" ]; then
        echo "<info> GITHUB_TOKEN not provided. Skipping API access check."
        return 0 # Or 'return 1' if token is mandatory for the entire script to run
    fi

    # Fall-through if extract_repo_info failed (but a token was present)
    return 1
}

# [2] main-logic: Main execution logic

# [2.1] flags: Add support for flags --help
if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    help
    exit 0
fi

# [2.2] repo-url: Ask user for input
# read -r VAR < /dev/tty forces read to pull input from the terminal, not from the piped script stream.
echo "<prompt> Enter GitHub file/repo URL:"
read -r REPO_URL < /dev/tty
echo

# [2.3] working-with-secrets: SECURITY ZONE START
# read -r VAR < /dev/tty forces read to pull input from the terminal, not from the piped script stream.
echo -n "<prompt> Enter GitHub Token (or press Enter to skip, '-q' to quit): "
read -r -s GITHUB_TOKEN < /dev/tty
echo

if [ "$GITHUB_TOKEN" == "-q" ]; then
    echo "<info> Quitting as requested."
    exit 0
fi

# [2.3.2] pre-flight-check: only for repo URLs where extraction is possible
pre_flight_check "$GITHUB_TOKEN" "$REPO_URL"

# [2.3.3] main_execution: Download the file
gh_download_asset "$REPO_URL"

# [2.3.4] security_cleanup: Clear secrets immediately
unset GITHUB_TOKEN
# SECURITY ZONE END

# [3] end: Print done of successfully executed script
echo "<success> Done"
