#!/usr/bin/env bash
#
# fstab-manager.sh
#
# Interactive terminal tool to add/remove externally connected drives
# to/from /etc/fstab, safely.
#
#   - Lists currently connected block devices (excludes the system disk,
#     swap, and anything already mounted at / , /boot, /boot/efi).
#   - Lets you pick a device, pick (or create) a mount point under /mnt/,
#     and appends a UUID-based fstab entry.
#   - Unmounts the drive first if it is already mounted elsewhere
#     (e.g. the desktop automounter under /media/<user>/<label>).
#   - Refuses to use a mount point that already exists and is populated;
#     an existing empty one is removed and recreated with the right owner.
#   - Hands the mounted drive over to the invoking user (not root:root).
#   - Entries always include `nofail` (+ a short device timeout, or
#     automount) so the system will boot fine even if the drive is
#     unplugged later.
#   - Lets you list/remove entries the script previously added.
#   - Backs up /etc/fstab before every change and validates the file
#     afterwards, offering an automatic rollback if validation fails.
#
# Usage:
#   sudo ./fstab-manager.sh
#
set -uo pipefail

FSTAB="/etc/fstab"
MNT_BASE="/mnt"
MARKER="# fstab-manager:"           # tag prepended to every entry we add
BACKUP_DIR="/etc/fstab-manager-backups"

# The human who ran sudo. Drives must end up owned by them, not root:root.
OWNER_UID="${SUDO_UID:-1000}"
OWNER_GID="${SUDO_GID:-1000}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This needs to modify /etc/fstab and mount things, so it must run as root."
        echo "Re-run with: sudo $0"
        exit 1
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found. Install it first (e.g. apt install util-linux)."
}

pause() {
    read -rp "Press Enter to continue..." _
}

# Numbered yes/no menu, used everywhere instead of typed y/N answers.
# Usage: ask_yes_no "Question text" [default_choice]   default_choice: 1=Yes 2=No (defaults to 2)
# Returns 0 for Yes, 1 for No.
ask_yes_no() {
    local prompt="$1"
    local default="${2:-2}"
    local choice
    echo "$prompt"
    echo "  1) Yes"
    echo "  2) No"
    read -rp "Choose [1/2, default $default]: " choice
    choice="${choice:-$default}"
    [[ "$choice" == "1" ]]
}

backup_fstab() {
    mkdir -p "$BACKUP_DIR"
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local backup="$BACKUP_DIR/fstab.bak.$ts"
    cp -a "$FSTAB" "$backup"
    echo "$backup"
}

# Validate /etc/fstab. Prefer `findmnt --verify` (modern util-linux),
# fall back to `mount -a --fake` (dry run, doesn't actually mount).
validate_fstab() {
    if command -v findmnt >/dev/null 2>&1 && findmnt --verify >/dev/null 2>&1; then
        findmnt --verify
        return $?
    elif findmnt --help 2>&1 | grep -q -- '--verify'; then
        findmnt --verify
        return $?
    else
        mount -a --fake 2>&1
        return $?
    fi
}

# Make systemd re-read /etc/fstab so it doesn't act on a stale copy.
reload_systemd() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null
    fi
    return 0
}

# Roll back to a given backup file if something goes wrong.
restore_backup() {
    local backup="$1"
    cp -a "$backup" "$FSTAB"
    reload_systemd
    echo "Restored /etc/fstab from $backup"
}

# Root device (so we never offer it as an "external drive")
root_source() {
    findmnt -n -o SOURCE / 2>/dev/null
}

# Resolve a device path to its underlying disk's kernel name (for filtering),
# e.g. /dev/sda1 -> sda
disk_of() {
    local dev="$1"
    lsblk -no PKNAME "$dev" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Mount point + mount state handling
# ---------------------------------------------------------------------------

# Non-mutating check, used while the user is choosing a folder name.
# Usage: check_mount_point <mount_point> <devpath> <uuid>
# Returns 0 if usable, 1 (with a message) if not.
check_mount_point() {
    local mp="$1" devpath="$2" uuid="$3"

    if mountpoint -q "$mp" 2>/dev/null; then
        local src mnt_uuid
        src="$(findmnt -n -o SOURCE "$mp" 2>/dev/null)"
        mnt_uuid="$(findmnt -n -o UUID "$mp" 2>/dev/null)"
        # Same drive already mounted here: fine, it gets unmounted and remounted.
        if [[ "$src" == "$devpath" || ( -n "$mnt_uuid" && "$mnt_uuid" == "$uuid" ) ]]; then
            return 0
        fi
        echo "ERROR: $mp is already a mount point of a different filesystem ($src)."
        return 1
    fi

    if [[ -e "$mp" || -L "$mp" ]]; then
        if [[ ! -d "$mp" || -L "$mp" ]]; then
            echo "ERROR: $mp exists but is not a plain directory."
            return 1
        fi
        if [[ -n "$(ls -A "$mp" 2>/dev/null)" ]]; then
            echo "ERROR: $mp already exists and is NOT empty. Contents (first 10):"
            ls -A "$mp" | head -n 10 | sed 's/^/    /'
            return 1
        fi
    fi
    return 0
}

# Unmount the device from every place it is currently mounted, including
# the desktop automounter's /media/<user>/<label> or /run/media/... location.
# Returns 1 if it could not be fully unmounted.
unmount_device_everywhere() {
    local devpath="$1" uuid="$2"
    local -a targets=()
    local t

    # Deepest paths first (reverse sort), duplicates removed.
    mapfile -t targets < <(
        {
            findmnt -ln -o TARGET -S "$devpath" 2>/dev/null
            findmnt -ln -o TARGET -S "UUID=$uuid" 2>/dev/null
        } | sort -ur
    )

    for t in "${targets[@]}"; do
        [[ -n "$t" ]] || continue
        echo "Drive is currently mounted at $t, unmounting..."
        if ! umount "$t"; then
            echo "Could not unmount $t (busy?)."
            if command -v fuser >/dev/null 2>&1; then
                echo "Processes using it:"
                fuser -vm "$t" 2>&1 | head -n 10
            fi
            if ask_yes_no "Try a lazy unmount (detaches now, finishes when no longer busy)?" 2; then
                umount -l "$t" || return 1
            else
                return 1
            fi
        fi
        # The desktop automounter can leave an empty directory behind.
        case "$t" in
            /media/*|/run/media/*) rmdir "$t" 2>/dev/null ;;
        esac
    done
    return 0
}

# Make sure the mount point is a fresh, empty directory owned by the invoking
# user. An existing empty directory is removed and recreated.
# Assumes check_mount_point already passed and the device was unmounted.
prepare_mount_point() {
    local mp="$1"

    if mountpoint -q "$mp" 2>/dev/null; then
        echo "ERROR: $mp is still a mount point."
        return 1
    fi
    if [[ -d "$mp" && ! -L "$mp" ]]; then
        if [[ -n "$(ls -A "$mp" 2>/dev/null)" ]]; then
            echo "ERROR: $mp is not empty, refusing to touch it."
            return 1
        fi
        rmdir "$mp" || { echo "ERROR: could not remove $mp"; return 1; }
    elif [[ -e "$mp" || -L "$mp" ]]; then
        echo "ERROR: $mp exists but is not a plain directory."
        return 1
    fi

    mkdir -p "$mp" || { echo "ERROR: could not create $mp"; return 1; }
    chown "$OWNER_UID:$OWNER_GID" "$mp"
    chmod 755 "$mp"
    return 0
}

# Once mounted, ext4/xfs/btrfs expose the filesystem's own root directory,
# which is root:root by default. Hand it to the invoking user (persists on the
# drive). ntfs/vfat/exfat get their ownership from the uid=/gid= mount options.
fix_ownership() {
    local mp="$1" fstype="$2"
    case "$fstype" in
        ntfs|ntfs-3g|vfat|exfat) return 0 ;;
    esac
    if mountpoint -q "$mp" 2>/dev/null; then
        chown "$OWNER_UID:$OWNER_GID" "$mp" && chmod 755 "$mp" \
            && echo "Ownership of $mp set to uid=$OWNER_UID gid=$OWNER_GID."
    fi
}

# ---------------------------------------------------------------------------
# Device discovery
# ---------------------------------------------------------------------------

# Prints candidate partitions/devices as pipe-separated fields:
# NAME|SIZE|FSTYPE|LABEL|UUID|MOUNTPOINT
list_candidate_devices() {
    local root_src
    root_src="$(root_source)"
    local root_disk=""
    if [[ -n "$root_src" ]]; then
        root_disk="$(disk_of "$root_src")"
    fi

    # -P gives KEY="value" pairs, safe to parse; -o picks fields
    lsblk -P -o NAME,PKNAME,TYPE,FSTYPE,SIZE,LABEL,UUID,MOUNTPOINT,RM 2>/dev/null | while IFS= read -r line; do
        eval "$line" # sets NAME PKNAME TYPE FSTYPE SIZE LABEL UUID MOUNTPOINT RM

        # Only consider actual partitions or whole disks with a filesystem
        [[ "$TYPE" == "part" || "$TYPE" == "disk" ]] || continue
        [[ -n "${FSTYPE:-}" ]] || continue          # must have a filesystem
        [[ "$FSTYPE" != "swap" ]] || continue        # skip swap
        [[ -n "${UUID:-}" ]] || continue             # must have a UUID to be usable

        # Skip the disk that holds the root filesystem entirely
        if [[ -n "$root_disk" && ( "$NAME" == "$root_disk" || "$PKNAME" == "$root_disk" ) ]]; then
            continue
        fi

        # Skip anything currently mounted at critical system paths
        case "${MOUNTPOINT:-}" in
            "/"|"/boot"|"/boot/efi"|"/home"|"/var"|"/usr") continue ;;
        esac

        printf '%s|%s|%s|%s|%s|%s\n' "$NAME" "${SIZE:-?}" "${FSTYPE:-?}" "${LABEL:-}" "$UUID" "${MOUNTPOINT:-}"
    done
}

show_candidate_devices() {
    echo
    printf '%-3s %-10s %-8s %-8s %-16s %-36s %s\n' "#" "DEVICE" "SIZE" "FSTYPE" "LABEL" "UUID" "MOUNTED AT"
    printf '%s\n' "----------------------------------------------------------------------------------------------"
    local i=1
    while IFS='|' read -r name size fstype label uuid mnt; do
        [[ -z "$name" ]] && continue
        printf '%-3s %-10s %-8s %-8s %-16s %-36s %s\n' "$i" "/dev/$name" "$size" "$fstype" "${label:-<none>}" "$uuid" "${mnt:-<not mounted>}"
        i=$((i+1))
    done < <(list_candidate_devices)
    echo
}

get_candidate_by_index() {
    local idx="$1"
    list_candidate_devices | sed -n "${idx}p"
}

count_candidates() {
    list_candidate_devices | wc -l
}

# ---------------------------------------------------------------------------
# Add a drive
# ---------------------------------------------------------------------------

add_drive() {
    clear
    echo "=== Connected drives available to add ==="
    show_candidate_devices

    local total
    total="$(count_candidates)"
    if [[ "$total" -eq 0 ]]; then
        echo "No eligible external/extra drives found (system disk and mounted system paths are excluded)."
        pause
        return
    fi

    local choice
    read -rp "Pick a device number to add (or 'q' to cancel): " choice
    [[ "$choice" == "q" ]] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt "$total" ]]; then
        echo "Invalid selection."
        pause
        return
    fi

    local row name size fstype label uuid mnt
    row="$(get_candidate_by_index "$choice")"
    IFS='|' read -r name size fstype label uuid mnt <<< "$row"
    local devpath="/dev/$name"

    echo
    echo "Selected: $devpath  ($size, $fstype, label='${label:-none}', UUID=$uuid)"
    if [[ -n "$mnt" ]]; then
        echo "NOTE: Currently mounted at $mnt, it will be unmounted and remounted at the new location."
    fi

    # Check if this UUID is already in fstab
    if grep -q "UUID=$uuid" "$FSTAB" 2>/dev/null; then
        echo "NOTE: This UUID already has an entry in $FSTAB:"
        grep -n "UUID=$uuid" "$FSTAB"
        ask_yes_no "Continue and add another entry anyway?" 2 || { echo "Cancelled."; pause; return; }
    fi

    # Suggest a mount point name
    local suggested="${label:-$name}"
    suggested="$(echo "$suggested" | tr ' ' '_' | tr -cd '[:alnum:]_-')"
    [[ -z "$suggested" ]] && suggested="$name"

    # Ask for a folder name until it points at a usable location
    local mount_name mount_point
    while true; do
        read -rp "Mount point folder name under $MNT_BASE/ [default: $suggested, 'q' to cancel]: " mount_name
        [[ "$mount_name" == "q" ]] && { echo "Cancelled."; pause; return; }
        mount_name="${mount_name:-$suggested}"
        mount_name="$(echo "$mount_name" | tr ' ' '_')"
        mount_point="$MNT_BASE/$mount_name"
        check_mount_point "$mount_point" "$devpath" "$uuid" && break
        echo "Choose a different folder name."
        echo
    done

    echo
    echo "Mount point will be: $mount_point"

    # How should the boot behave if this drive is missing?
    echo
    echo "How should this drive behave if it's unplugged at boot time?"
    echo "  1) nofail + short timeout (tries for a few seconds, then boot continues)  [recommended]"
    echo "  2) automount (mounted on first access, boot never waits on it at all)"
    local boot_mode
    read -rp "Choose [1/2, default 1]: " boot_mode
    boot_mode="${boot_mode:-1}"

    # Build mount options based on filesystem type
    local opts=""
    case "$fstype" in
        ntfs|ntfs-3g)
            opts="uid=$OWNER_UID,gid=$OWNER_GID,umask=022,windows_names"
            fstype="ntfs-3g"
            ;;
        vfat|exfat)
            opts="uid=$OWNER_UID,gid=$OWNER_GID,umask=022"
            ;;
        ext2|ext3|ext4|xfs|btrfs)
            opts="defaults"
            ;;
        *)
            opts="defaults"
            ;;
    esac

    if [[ "$boot_mode" == "2" ]]; then
        opts="${opts},nofail,x-systemd.automount,x-systemd.idle-timeout=60"
    else
        opts="${opts},nofail,x-systemd.device-timeout=5"
    fi

    local passno=0   # external drives: don't fsck at boot
    local dump=0

    local fstab_line="UUID=$uuid  $mount_point  $fstype  $opts  $dump  $passno"

    echo
    echo "About to unmount the drive if mounted elsewhere, (re)create the mount point"
    echo "owned by uid=$OWNER_UID gid=$OWNER_GID, and add this line to $FSTAB:"
    echo
    echo "  $MARKER $label ($devpath)"
    echo "  $fstab_line"
    echo
    ask_yes_no "Proceed?" 1 || { echo "Cancelled."; pause; return; }

    # Free the device from any existing mount (e.g. /media/<user>/<label>)
    if ! unmount_device_everywhere "$devpath" "$uuid"; then
        echo "Could not unmount the drive. Nothing was changed."
        pause
        return
    fi

    # Fresh empty mount point with the right owner
    if ! prepare_mount_point "$mount_point"; then
        echo "Nothing was changed in $FSTAB."
        pause
        return
    fi

    local backup
    backup="$(backup_fstab)"
    {
        echo "$MARKER $label ($devpath)"
        echo "$fstab_line"
    } >> "$FSTAB"

    echo
    echo "Validating fstab..."
    if ! validate_fstab; then
        echo "Validation FAILED. Rolling back."
        restore_backup "$backup"
        pause
        return
    fi

    reload_systemd

    echo "Validation OK. Mounting now to confirm it actually works..."
    if mount "$mount_point" 2>/tmp/fstab-manager-mount-err; then
        echo "Mounted successfully at $mount_point."
        fix_ownership "$mount_point" "$fstype"
    else
        echo "Mount FAILED:"
        cat /tmp/fstab-manager-mount-err
        if ! ask_yes_no "Keep the fstab entry anyway (drive may just need reconnecting)?" 2; then
            restore_backup "$backup"
            echo "Rolled back."
        fi
    fi
    rm -f /tmp/fstab-manager-mount-err
    pause
}

# ---------------------------------------------------------------------------
# List / remove managed entries
# ---------------------------------------------------------------------------

# Prints index|comment_line_no|fstab_line_no|label|devhint|fstab_line
list_managed_entries() {
    awk -v marker="$MARKER" '
        index($0, marker) == 1 {
            c=$0; cline=NR; next
        }
        cline && NR==cline+1 {
            print (++n) "|" cline "|" NR "|" c "|" $0
            cline=0
        }
    ' "$FSTAB"
}

show_managed_entries() {
    echo
    local any=0
    while IFS='|' read -r idx cline fline comment entry; do
        [[ -z "$idx" ]] && continue
        any=1
        local mp uuid
        mp="$(echo "$entry" | awk '{print $2}')"
        uuid="$(echo "$entry" | awk '{print $1}')"
        local status="not mounted"
        mountpoint -q "$mp" 2>/dev/null && status="MOUNTED"
        local present="not present"
        [[ -n "$uuid" ]] && blkid -U "${uuid#UUID=}" >/dev/null 2>&1 && present="present"
        echo "[$idx] ${comment#"$MARKER "}"
        echo "      $entry"
        echo "      -> $status, device $present"
    done < <(list_managed_entries)

    if [[ "$any" -eq 0 ]]; then
        echo "No fstab-manager entries found in $FSTAB."
    fi
    echo
}

remove_drive() {
    clear
    echo "=== fstab-manager entries ==="
    show_managed_entries

    local count
    count="$(list_managed_entries | wc -l)"
    [[ "$count" -eq 0 ]] && { pause; return; }

    local choice
    read -rp "Pick an entry number to remove (or 'q' to cancel): " choice
    [[ "$choice" == "q" ]] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt "$count" ]]; then
        echo "Invalid selection."
        pause
        return
    fi

    local row cline fline comment entry
    row="$(list_managed_entries | awk -F'|' -v i="$choice" '$1==i')"
    IFS='|' read -r _ cline fline comment entry <<< "$row"

    local mp
    mp="$(echo "$entry" | awk '{print $2}')"

    echo
    echo "Will remove:"
    echo "  $comment"
    echo "  $entry"
    ask_yes_no "Confirm removal from $FSTAB?" 2 || { echo "Cancelled."; pause; return; }

    if mountpoint -q "$mp" 2>/dev/null; then
        if ask_yes_no "$mp is currently mounted. Unmount it now?" 1; then
            umount "$mp" || echo "WARNING: umount failed, continuing anyway."
        fi
    fi

    local backup
    backup="$(backup_fstab)"
    # Delete both the comment line and the entry line (by line number, comment first since it's earlier)
    sed -i "${fline}d;${cline}d" "$FSTAB"

    echo "Validating fstab..."
    if ! validate_fstab; then
        echo "Validation FAILED. Rolling back."
        restore_backup "$backup"
        pause
        return
    fi
    reload_systemd
    echo "Removed from $FSTAB."

    if [[ -d "$mp" ]] && [[ -z "$(ls -A "$mp" 2>/dev/null)" ]]; then
        ask_yes_no "Also remove the now-empty mount point folder $mp ?" 2 && rmdir "$mp" 2>/dev/null && echo "Removed $mp."
    fi
    pause
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------

main_menu() {
    while true; do
        clear
        echo "=================================================="
        echo " fstab-manager — manage external drives in /etc/fstab"
        echo "=================================================="
        echo "1) List connected drives (candidates to add)"
        echo "2) Add a drive to fstab"
        echo "3) Show fstab-manager entries + status"
        echo "4) Remove a drive from fstab"
        echo "5) Validate /etc/fstab now"
        echo "6) Run 'mount -a' (mount everything in fstab)"
        echo "0) Exit"
        echo
        read -rp "Choose an option: " opt
        case "$opt" in
            1) show_candidate_devices; pause ;;
            2) add_drive ;;
            3) show_managed_entries; pause ;;
            4) remove_drive ;;
            5)
                if validate_fstab; then
                    echo "fstab looks valid."
                else
                    echo "fstab has problems (see above)."
                fi
                pause
                ;;
            6)
                mount -a && echo "Done." || echo "Some mounts failed (see above)."
                pause
                ;;
            0) exit 0 ;;
            *) echo "Invalid option."; pause ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

require_root
require_cmd lsblk
require_cmd blkid
require_cmd findmnt
require_cmd mount
require_cmd awk
require_cmd sed

main_menu
