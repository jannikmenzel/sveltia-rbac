#!/bin/bash
#
# GitLab Pre-Receive Hook - Role-Based Editing Permissions
#
# Checked on every push:
#   - Who is pushing? What role does the user have?
#   - Default-deny: ONLY files matching one of the configured content
#     collections (see CONTENT_COLLECTIONS below) get a role-based check.
#     Everything else in the repo (config JSON, components, scripts,
#     package.json, ...) can only be created, changed, or deleted by admin -
#     except media in public/uploads/ (see below).
#   - For changed/deleted content files: was the user ALREADY authorized
#     beforehand? (edit_roles from the OLD file; also applies to deletion)
#   - Was edit_roles changed? -> Admin only
#   - Config changes (src/config/roles/*.json) -> Admin only
#   - New content files: check edit_roles from the new file. If edit_roles
#     is NOT set, any role may create the file, and the creator's role is
#     tracked server-side as its owner (same mechanism as media, see below) -
#     that role plus admin may then edit/delete it, instead of it being
#     admin-only. As soon as edit_roles is set explicitly in the frontmatter,
#     it takes precedence over the tracked owner role.
#   - Media (public/uploads/**): any role may upload new files. Changing or
#     deleting an existing file is restricted to admin or the role that
#     uploaded it.
#   - The file->role mapping (media AND ownerless content files) is
#     maintained server-side next to the hook (owners.tsv, not part of the
#     Git repo).

set -o pipefail

GITLAB_URL="https://gitlab.example.com"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
ROLES_DIR="src/config/roles"
MEDIA_DIR="public/uploads"
BRANCH="main"
CONTENT_COLLECTIONS=(
    "src/content/pages/*.md"
)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
OWNERS_FILE="$(dirname "$SCRIPT_DIR")/owners.tsv"
ZERO_COMMIT="0000000000000000000000000000000000000000"

# Collects owner changes (media + ownerless content files) during the run;
# applied only at the end in apply_owner_changes().
OWNER_NEW_PATHS=()
OWNER_NEW_ROLES=()
OWNER_REMOVED_PATHS=()

# User identification - determines the GitLab username of the pusher.
# Prefers GL_USERNAME (set by GitLab), falls back to an API call via GL_ID.
get_pusher_username() {
    local gl_id="${GL_ID}"
    local gl_username="${GL_USERNAME}"

    if [[ -n "$gl_username" ]]; then
        echo "$gl_username"
        return 0
    fi

    if [[ "$gl_id" =~ ^user-([0-9]+)$ ]]; then
        local user_id="${BASH_REMATCH[1]}"
        if [[ -n "$GITLAB_TOKEN" ]]; then
            curl -sf "${GITLAB_URL}/api/v4/users/${user_id}" \
                -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])" 2>/dev/null
        fi
    fi
}

# Frontmatter parser - extracts edit_roles from a Markdown file's YAML frontmatter.
# Supports inline syntax (edit_roles: [user, admin]) and block-list syntax.
get_edit_roles_md() {
    local content="$1"
    echo "$content" | python3 -c "
import sys, re
content = sys.stdin.read()
fm_match = re.match(r'^---\s*\n(.*?)\n---\s*\n', content, re.DOTALL)
frontmatter = fm_match.group(1) if fm_match else content

roles = []
# Inline style: edit_roles: [user, admin]
match = re.search(r'edit_roles\s*:\s*\[(.*?)\]', frontmatter, re.DOTALL)
if match:
    roles = [r.strip().strip('\"').strip(\"'\") for r in match.group(1).split(',')]
else:
    # YAML block-list style:
    # edit_roles:
    #   - user
    #   - admin
    match = re.search(r'edit_roles\s*:\s*\n((?:[ \t]*-[ \t]*.+\n?)+)', frontmatter)
    if match:
        for line in match.group(1).splitlines():
            item = line.strip()
            if item.startswith('-'):
                item = item[1:].strip().strip('\"').strip(\"'\")
                if item:
                    roles.append(item)

roles = [r for r in roles if r]
if roles:
    print(','.join(roles))
" 2>/dev/null
}

get_edit_roles() {
    local file="$1"
    local ref="$2"
    local content
    content=$(git show "${ref}:${file}" 2>/dev/null) || return 0
    get_edit_roles_md "$content"
}

# Role lookup - scans all JSON files in src/config/roles/ and finds every
# role the user is a member of (a user can belong to multiple roles).
# Filename (without .json) = role name. Result as CSV.
get_user_roles() {
    local ref="$1"
    local username="$2"
    local roles=()
    while read -r mode type sha name; do
        [[ -z "$name" ]] && continue
        if git show "${sha}" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for entry in data:
        if entry.get('username') == '${username}':
            print('found')
            break
except: pass
" 2>/dev/null | grep -q found; then
            roles+=("$(basename "$name" .json)")
        fi
    done < <(git ls-tree -r "${ref}" "${ROLES_DIR}" 2>/dev/null)
    local IFS=','
    echo "${roles[*]}"
}

# Checks whether a single role is contained in a comma-separated role list.
role_in_list() {
    local role="$1"
    local list_csv="$2"
    local r
    IFS=',' read -ra list <<< "$list_csv"
    for r in "${list[@]}"; do
        r="${r// }"
        [[ "$r" == "$role" ]] && return 0
    done
    return 1
}

# Checks whether two comma-separated role lists share at least one role.
roles_overlap() {
    local csv1="$1"
    local csv2="$2"
    local r
    IFS=',' read -ra list1 <<< "$csv1"
    for r in "${list1[@]}"; do
        r="${r// }"
        [[ -n "$r" ]] && role_in_list "$r" "$csv2" && return 0
    done
    return 1
}

# Permission check - checks whether at least one of the user's roles is in
# the allowed edit_roles list. Admin always has access (self-lockout
# protection), regardless of what other roles the user has.
has_permission() {
    local user_roles_csv="$1"
    local edit_roles_csv="$2"

    role_in_list "admin" "$user_roles_csv" && return 0

    # No edit_roles set -> admin-only, not open to everyone.
    [[ -z "$edit_roles_csv" ]] && return 1

    roles_overlap "$user_roles_csv" "$edit_roles_csv"
}

# Owner management - reads/writes the file -> role mapping from the
# server-side TSV file (owners.tsv, not part of the Git repo).
# Used for media (public/uploads/**) AND for content files that were created
# without edit_roles in the frontmatter.
get_owner() {
    local path="$1"
    [[ -f "$OWNERS_FILE" ]] || return 0
    awk -F'\t' -v p="$path" '$1==p { print $2; exit }' "$OWNERS_FILE"
}

set_owner() {
    local path="$1"
    local role="$2"
    touch "$OWNERS_FILE"
    awk -F'\t' -v p="$path" '$1!=p' "$OWNERS_FILE" > "${OWNERS_FILE}.tmp"
    printf '%s\t%s\n' "$path" "$role" >> "${OWNERS_FILE}.tmp"
    mv "${OWNERS_FILE}.tmp" "$OWNERS_FILE"
}

remove_owner() {
    local path="$1"
    [[ -f "$OWNERS_FILE" ]] || return 0
    awk -F'\t' -v p="$path" '$1!=p' "$OWNERS_FILE" > "${OWNERS_FILE}.tmp"
    mv "${OWNERS_FILE}.tmp" "$OWNERS_FILE"
}

is_content_collection() {
    local file="$1"
    local pattern
    for pattern in "${CONTENT_COLLECTIONS[@]}"; do
        case "$file" in $pattern) return 0;; esac
    done
    return 1
}

# Applies all collected ownership changes atomically.
# Uses flock for exclusive access so concurrent pushes don't collide.
apply_owner_changes() {
    [[ ${#OWNER_NEW_PATHS[@]} -eq 0 && ${#OWNER_REMOVED_PATHS[@]} -eq 0 ]] && return 0

    exec 200>"${OWNERS_FILE}.lock"
    command -v flock >/dev/null 2>&1 && flock -x 200

    local i
    for ((i = 0; i < ${#OWNER_NEW_PATHS[@]}; i++)); do
        set_owner "${OWNER_NEW_PATHS[$i]}" "${OWNER_NEW_ROLES[$i]}"
    done
    for path in "${OWNER_REMOVED_PATHS[@]}"; do
        remove_owner "$path"
    done

    exec 200>&-
}

# Main logic - reads each pushed ref and checks permissions per changed file.
main() {
    while read -r oldrev newrev refname; do
        [[ "$refname" != "refs/heads/${BRANCH}" ]] && continue

        local pusher
        pusher=$(get_pusher_username)

        if [[ -z "$pusher" ]]; then
            echo "Error: could not determine GitLab username"
            exit 1
        fi

        local ref_for_role="$oldrev"
        [[ "$oldrev" == "$ZERO_COMMIT" ]] && ref_for_role="$newrev"

        local user_roles
        user_roles=$(get_user_roles "$ref_for_role" "$pusher")

        if [[ -z "$user_roles" ]]; then
            echo "User '$pusher' has no role in ${ROLES_DIR}"
            exit 1
        fi

        # Branch deletion: only admin may delete the main branch itself.
        if [[ "$newrev" == "$ZERO_COMMIT" ]]; then
            if ! role_in_list "admin" "$user_roles"; then
                echo "Only admins may delete the ${BRANCH} branch"
                exit 1
            fi
            continue
        fi

        local changes
        # --no-renames: prevents renamed files from showing up as merely "new".
        # Without this flag, an admin-only protection could be bypassed by
        # renaming + setting edit_roles in the new file.
        changes=$(git diff --no-renames --name-only "${oldrev}" "${newrev}" 2>/dev/null)

        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            file="${file//$'\t'/ }"
            file="${file## }"
            file="${file%% }"
            [[ -z "$file" ]] && continue

            # Role config: only admin may change it.
            if [[ "$file" == "$ROLES_DIR"/* ]]; then
                if ! role_in_list "admin" "$user_roles"; then
                    echo "Only admins may change role files"
                    exit 1
                fi
                continue
            fi

            # Media: new uploads allowed for everyone, changing/deleting only for owner or admin.
            if [[ "$file" == "$MEDIA_DIR"/* ]]; then
                local media_new_exists=true
                git show "${newrev}:${file}" &>/dev/null || media_new_exists=false
                local media_old_exists=true
                git show "${oldrev}:${file}" &>/dev/null || media_old_exists=false

                if [[ "$media_old_exists" == "false" ]]; then
                    OWNER_NEW_PATHS+=("$file")
                    OWNER_NEW_ROLES+=("$user_roles")
                    continue
                fi

                local owner_roles
                owner_roles=$(get_owner "$file")
                if ! role_in_list "admin" "$user_roles" && ! roles_overlap "$user_roles" "$owner_roles"; then
                    echo "Only admin or the uploading role may change/delete '$file'"
                    echo "Uploaded by role(s): ${owner_roles:-unknown (not tracked, admin only)}"
                    exit 1
                fi

                if [[ "$media_new_exists" == "false" ]]; then
                    OWNER_REMOVED_PATHS+=("$file")
                fi
                continue
            fi

            # Default-deny: everything outside the configured content collections is admin-only.
            if ! is_content_collection "$file"; then
                if ! role_in_list "admin" "$user_roles"; then
                    echo "Only admins may change files outside the configured content collections"
                    echo "File: $file"
                    exit 1
                fi
                continue
            fi

            local new_exists=true
            git show "${newrev}:${file}" &>/dev/null || new_exists=false
            local old_exists=true
            git show "${oldrev}:${file}" &>/dev/null || old_exists=false

            # New file: check edit_roles from the new file.
            if [[ "$oldrev" == "$ZERO_COMMIT" || "$old_exists" == "false" ]]; then
                local new_roles
                new_roles=$(get_edit_roles "$file" "$newrev")
                if [[ -n "$new_roles" ]]; then
                    if ! has_permission "$user_roles" "$new_roles"; then
                        echo "User '$pusher' (roles: $user_roles) may not create new file '$file'"
                        echo "Required role(s): $new_roles"
                        exit 1
                    fi
                else
                    # No edit_roles -> any role may create it. The creator's
                    # role is tracked as owner so that role (+ admin) may
                    # edit/delete the file later.
                    OWNER_NEW_PATHS+=("$file")
                    OWNER_NEW_ROLES+=("$user_roles")
                fi
                continue
            fi

            # Existing file: check permission based on the OLD edit_roles.
            # If edit_roles is missing from the frontmatter, fall back to the
            # tracked owner role (from creation without edit_roles) instead of
            # admin-only.
            local old_roles
            old_roles=$(get_edit_roles "$file" "$oldrev")

            local effective_old_roles="$old_roles"
            if [[ -z "$old_roles" ]]; then
                local tracked_owner
                tracked_owner=$(get_owner "$file")
                [[ -n "$tracked_owner" ]] && effective_old_roles="$tracked_owner"
            fi

            if ! has_permission "$user_roles" "$effective_old_roles"; then
                echo "User '$pusher' (roles: $user_roles) was not authorized for '$file'"
                echo "Required role(s): ${effective_old_roles:-admin}"
                exit 1
            fi

            # Deleted file: permission was already checked above, clean up the
            # tracked owner (if any); no further checks needed.
            if [[ "$new_exists" == "false" ]]; then
                OWNER_REMOVED_PATHS+=("$file")
                continue
            fi

            # edit_roles changed: only admin may adjust permissions.
            local new_roles
            new_roles=$(get_edit_roles "$file" "$newrev")
            if [[ "$old_roles" != "$new_roles" ]]; then
                if ! role_in_list "admin" "$user_roles"; then
                    echo "Only admins may change a file's permissions"
                    echo "File: $file"
                    exit 1
                fi
            fi
        done <<< "$changes"
    done

    apply_owner_changes
}

main "$@"
