#!/bin/env python3
import subprocess
import os
import re
import datetime
import math
import sys
import urllib.request
import urllib.parse
import json

# --- Configuration ---

# Gotify Configuration
GOTIFY_URL = "https://gotify.domain.com/message"
GOTIFY_API_KEY = "UNSET" # Your Gotify application token
GOTIFY_ENABLED = True # Control Gotify notifications

# Pushover Configuration
PUSHOVER_API_URL = "https://api.pushover.net/1/messages.json"
PUSHOVER_APP_TOKEN = "UNSET" # Your Pushover application token
PUSHOVER_USER_KEY = "UNSET" # Your Pushover user/group key
PUSHOVER_ENABLED = False # Control Pushover notifications

# Monitoring Configuration
POOLS_TO_MONITOR = ["rpool"] # List of ZFS pools to monitor
RATED_TBW = 360 # Assumed SSD TBW rating in Terabytes
REPLACEMENT_YEARS_AGE_LIMIT = 5 # Default age limit for replacement suggestion
VERBOSE = False # Set to True to print status updates and raw smartctl output to console

HOSTNAME = os.uname().nodename
DATE_STR = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")

# --- Helper Functions ---

def run_command(command):
    """Runs a shell command and returns its output, ensuring /usr/sbin is in PATH."""
    try:
        # Get a copy of the current environment
        env = os.environ.copy()
        # Ensure /usr/sbin is in the PATH for the subprocess
        current_path = env.get('PATH', '')
        if '/usr/sbin' not in current_path.split(os.pathsep):
            env['PATH'] = f"/usr/sbin{os.pathsep}{current_path}"

        result = subprocess.run(command, shell=True, capture_output=True, text=True, check=False, env=env) # Pass modified env
        if result.returncode != 0:
            pass # Allow parsing logic to handle specific errors like 'pool not found'
        return result.stdout.strip(), result.stderr.strip(), result.returncode
    except Exception as e:
        print(f"Error running command '{command}': {e}", file=sys.stderr)
        return None, str(e), -1

def parse_smartctl_value(output, attribute_name):
    """
    Parses a specific SMART attribute value from smartctl output.
    Handles both SATA (-A) and NVMe (-l nvme-smart-log or -A) formats.
    """
    # Try SATA format first (value in 10th column)
    for line in output.splitlines():
        parts = line.split()
        # Check if the line looks like a SATA attribute line and matches the name
        if len(parts) >= 10 and parts[1] == attribute_name:
            return parts[9] # SATA RAW_VALUE

    # Try NVMe format (Key: Value)
    # Make the search case-insensitive and strip trailing spaces from the key
    search_key = attribute_name.strip().lower()
    for line in output.splitlines():
        if ':' in line:
            key, value = line.split(':', 1)
            key = key.strip().lower()
            if key == search_key:
                # Return the full, stripped value string for NVMe attributes
                return value.strip()
    return None

def parse_smartctl_health(output):
    """Parses the overall health status from smartctl -H output."""
    if "PASSED" in output:
        return "✅ PASSED"
    elif "FAILED" in output:
        return "❌ FAILED"
    else:
        if "SMART overall-health self-assessment test result: FAILED" in output:
             return "❌ FAILED"
        if "SMART Health Status: OK" in output: # Seen on some drives
             return "✅ PASSED"
    return "❓ Unknown"

def parse_smartctl_model(output):
    """Parses the device model from smartctl -i output."""
    for line in output.splitlines():
        if line.startswith("Device Model:") or line.startswith("Device:") : # Handle slight variations
            return line.split(":", 1)[1].strip()
    return "N/A"

def send_notification(title, message, priority_level):
    """Sends notifications via configured services using standard library."""
    pushover_priority = 0
    if priority_level <= 1: # Map low Gotify priority
        pushover_priority = -1
    elif priority_level >= 8: # Map high Gotify priority
        pushover_priority = 1

    # Send via Gotify
    if GOTIFY_ENABLED and GOTIFY_API_KEY != "UNSET" and GOTIFY_URL:
        try:
            payload = {
                "title": title,
                "message": message,
                "priority": priority_level
            }
            data = urllib.parse.urlencode(payload).encode('utf-8')
            headers = {"X-Gotify-Key": GOTIFY_API_KEY}
            req = urllib.request.Request(GOTIFY_URL, data=data, headers=headers, method='POST')
            with urllib.request.urlopen(req, timeout=10) as response:
                if response.status < 200 or response.status >= 300:
                     print(f"Gotify notification failed with status: {response.status} {response.reason}", file=sys.stderr)
        except urllib.error.URLError as e:
            print(f"Error sending Gotify notification (URLError): {e}", file=sys.stderr)
        except Exception as e:
             print(f"Error sending Gotify notification (Other): {e}", file=sys.stderr)

    # Send via Pushover
    if PUSHOVER_ENABLED and PUSHOVER_APP_TOKEN != "UNSET" and PUSHOVER_USER_KEY != "UNSET":
        try:
            payload = {
                "token": PUSHOVER_APP_TOKEN,
                "user": PUSHOVER_USER_KEY,
                "title": title,
                "message": message,
                "priority": pushover_priority,
            }
            data = urllib.parse.urlencode(payload).encode('utf-8')
            req = urllib.request.Request(PUSHOVER_API_URL, data=data, method='POST')
            with urllib.request.urlopen(req, timeout=10) as response:
                 if response.status < 200 or response.status >= 300:
                     print(f"Pushover notification failed with status: {response.status} {response.reason}", file=sys.stderr)
        except urllib.error.URLError as e:
            print(f"Error sending Pushover notification (URLError): {e}", file=sys.stderr)
        except Exception as e:
             print(f"Error sending Pushover notification (Other): {e}", file=sys.stderr)

# --- Main Logic ---

overall_health = "✅ Healthy"
overall_priority = 1
all_disks = set() # Use a set for automatic uniqueness
main_message_parts = []

if VERBOSE:
    print("--- Starting ZFS Pool Check ---")

# 1. Process each pool
for pool_name in POOLS_TO_MONITOR:
    pool_summary_lines = []
    pool_msg = ""
    current_priority = 1
    pool_usage = ""
    pool_detail = ""

    # Check ZFS pool status
    stdout, stderr, retcode = run_command(f"zpool status -x \"{pool_name}\"")

    if retcode == 0 and f"pool '{pool_name}' is healthy" in stdout:
        pool_msg = "✅ Healthy"
        current_priority = 1
    elif "no such pool" in stderr or "no such pool" in stdout:
        pool_msg = f"❌ Error: Pool '{pool_name}' not found."
        current_priority = 8
    else:
        status_line = stdout.splitlines()[0] if stdout else stderr.splitlines()[0] if stderr else "Unknown Error"
        pool_msg = f"⚠️ {status_line}"
        current_priority = 8

    # Print pool status immediately if VERBOSE
    if VERBOSE:
        print(f"Pool '{pool_name}': {pool_msg}")

    # Update overall health and priority
    if current_priority > overall_priority:
        overall_priority = current_priority
        overall_health = "⚠️ Check Details"

    pool_summary_lines.append(f"{HOSTNAME} Pool '{pool_name}': {pool_msg}")

    if "not found" not in pool_msg:
        used_out, _, _ = run_command(f"zfs get -H -o value used \"{pool_name}\"")
        avail_out, _, _ = run_command(f"zfs get -H -o value available \"{pool_name}\"")
        ratio_out, _, _ = run_command(f"zfs get -H -o value compressratio \"{pool_name}\"")
        if used_out and avail_out and ratio_out:
             pool_usage = f"📊 Usage: {used_out} used, {avail_out} free ({ratio_out} compression)"
             pool_summary_lines.append(pool_usage)

        if pool_msg != "✅ Healthy":
             stdout_detail, _, _ = run_command(f"zpool status \"{pool_name}\"")
             if stdout_detail:
                 config_section = re.search(r"config:.*?(\n\s+errors:.*)?$", stdout_detail, re.DOTALL | re.MULTILINE)
                 if config_section:
                     pool_detail = config_section.group(0).strip()
                     pool_detail = re.sub(r"\n\s+errors: No known data errors", "", pool_detail)
                     pool_summary_lines.append(f"\nPool Configuration/Status:\n{pool_detail}")

        stdout_disks, _, _ = run_command(f"zpool status \"{pool_name}\"")
        if stdout_disks:
             # Find potential disk identifiers (adjust regex as needed for different ID formats)
             # This regex looks for ata-, nvme-, or wwn- prefixed IDs, ignoring partitions
             # Make the group non-capturing (?:...) so findall returns the whole match
             found_ids = re.findall(r"\b(?:ata-|nvme-|wwn-)[^\s/]+", stdout_disks)
             # Clean up potential partition suffixes like -partX or -partX
             cleaned_ids = {re.sub(r'(-part\d+|-part\d+)$', '', id) for id in found_ids}
             all_disks.update(cleaned_ids)

    main_message_parts.append("\n".join(pool_summary_lines))

if VERBOSE:
    print("--- ZFS Pool Check Complete ---")

# 2. Send Summary Notification
full_main_message = f"\n\n---\n\n".join(main_message_parts)
if VERBOSE:
    print("Sending Summary Notification...")
send_notification(f"ZFS Status Summary - {HOSTNAME}", full_main_message, overall_priority)

if VERBOSE:
    print("--- Starting Disk SMART Check ---")
# 3. Process each unique disk
for disk_id in sorted(list(all_disks)):
    drive_message_lines = []
    disk_dev_path = f"/dev/disk/by-id/{disk_id}"

    if not os.path.exists(disk_dev_path):
        if VERBOSE: # Also print skipped disks in verbose mode
            print(f"Skipping disk ID {disk_id}: Path {disk_dev_path} not found.")
        continue

    try:
        device_path = os.path.realpath(disk_dev_path)
        disk_dev = os.path.basename(device_path)

        if not os.path.exists(f"/dev/{disk_dev}"):
             if VERBOSE:
                 print(f"Skipping disk ID {disk_id}: Resolved device /dev/{disk_dev} does not exist.")
             continue

        # Get SMART info
        # For NVMe, -A often includes the most relevant info directly
        info_out, info_err, ret_info = run_command(f"smartctl --nocheck=standby -i /dev/{disk_dev}")
        health_out, health_err, ret_health = run_command(f"smartctl --nocheck=standby -H /dev/{disk_dev}")
        attrs_out, attrs_err, ret_attrs = run_command(f"smartctl --nocheck=standby -A /dev/{disk_dev}") # Use -A for NVMe too

        # Print raw smartctl output if VERBOSE is enabled
        if VERBOSE:
            print(f"\n--- Raw SMART Data: {disk_dev} (ID: {disk_id}) ---")
            print("--- smartctl -i ---")
            print(info_out)
            if info_err: print(f"stderr: {info_err}")
            print("--- smartctl -H ---")
            print(health_out)
            if health_err: print(f"stderr: {health_err}")
            print("--- smartctl -A ---")
            print(attrs_out)
            if attrs_err: print(f"stderr: {attrs_err}")
            print("--- End Raw SMART Data ---")


        if ret_info != 0 or ret_health != 0 or ret_attrs != 0:
            print(f"Warning: Failed to get full SMART data for {disk_dev} (ID: {disk_id}). Skipping detailed report.", file=sys.stderr)
            if ret_health != 0:
                 send_notification(f"⚠️ Drive {disk_dev} SMART Error - {HOSTNAME}", f"Could not retrieve SMART health for {disk_dev} (ID: {disk_id}). Check manually.", 8)
            continue

        model = parse_smartctl_model(info_out)
        health = parse_smartctl_health(health_out)

        # Use NVMe attribute names where applicable
        temp_raw = parse_smartctl_value(attrs_out, "Temperature") # NVMe standard name
        if not temp_raw: # Fallback for SATA
             temp_raw = parse_smartctl_value(attrs_out, "Temperature_Celsius")

        hours_raw = parse_smartctl_value(attrs_out, "Power On Hours") # NVMe standard name
        if not hours_raw: # Fallback for SATA
             hours_raw = parse_smartctl_value(attrs_out, "Power_On_Hours")

        # NVMe uses "Percentage Used"
        percentage_used_raw = parse_smartctl_value(attrs_out, "Percentage Used")
        # SATA uses "Percent_Lifetime_Remain" or "Wear_Leveling_Count"
        life_remain_raw = parse_smartctl_value(attrs_out, "Percent_Lifetime_Remain")
        wear_level_raw = parse_smartctl_value(attrs_out, "Wear_Leveling_Count")

        # NVMe uses "Data Units Written"
        data_units_written_raw = parse_smartctl_value(attrs_out, "Data Units Written") # Full string like "24,550,629 [12.5 TB]"
        # SATA uses "Total_LBAs_Written"
        lba_written_raw = parse_smartctl_value(attrs_out, "Total_LBAs_Written")

        # NVMe doesn't typically report erase count this way
        erase_count_raw = parse_smartctl_value(attrs_out, "Ave_Block-Erase_Count") # Primarily SATA

        # Extract numeric part of temperature
        temp = "N/A"
        if temp_raw:
            match = re.search(r'^\s*(\d+)', temp_raw) # Find leading digits
            if match:
                temp = match.group(1)

        hours = hours_raw if hours_raw else "N/A"
        days_powered = "N/A"
        life_used_str = "N/A"

        # Calculate days powered
        try:
            if hours != "N/A":
                hours_num = int(hours.replace(',', '')) # Remove commas if present
                if hours_num >= 0:
                    days_powered = f"{hours_num / 24:.1f}"
        except ValueError:
            hours = "N/A" # Reset if not a valid number

        # Determine Life Used string (Prioritize NVMe Percentage Used)
        try:
            if percentage_used_raw is not None:
                # Value might have '%', remove it
                life_used = int(percentage_used_raw.replace('%',''))
                life_used_str = f"{life_used}% used"
            elif life_remain_raw is not None: # Fallback to SATA Percent_Lifetime_Remain
                life_remain = int(life_remain_raw)
                life_used = 100 - life_remain
                life_used_str = f"{life_used}% used"
            elif wear_level_raw is not None: # Fallback to SATA Wear_Leveling_Count
                 wear_level = int(wear_level_raw)
                 life_used_str = f"{wear_level}% used (WLC)"
        except (ValueError, TypeError):
             pass # Keep N/A if conversion fails

        erase_count_str = ""
        if erase_count_raw:
             erase_count_str = f" | 🔄 Block Erase Count: {erase_count_raw}"


        drive_message_lines.append(f"{disk_dev} ({model}): {health}")
        days_powered_str = f"({days_powered} days)" if days_powered != "N/A" else "(days N/A)"
        drive_message_lines.append(f"🌡️ {temp}°C | ⏱️ {hours}h {days_powered_str} | 🔋 {life_used_str}")

        # SSD Endurance Calculation
        tb_written = None
        gb_per_day = 0.0
        percent_tbw_used = None
        remaining_tb = None
        years_remaining = "N/A"
        days_remaining_num = None
        replace_date_str = "N/A"

        try:
            # Prioritize NVMe Data Units Written for TBW calculation
            if data_units_written_raw is not None:
                 # Extract TB value from "[12.5 TB]"
                 match = re.search(r'\[\s*([\d.]+)\s*TB\s*\]', data_units_written_raw)
                 if match:
                     tb_written = float(match.group(1))
                 else: # Fallback: try parsing the first number as Data Units (512 bytes each)
                     match_units = re.search(r'^\s*([\d,]+)', data_units_written_raw)
                     if match_units:
                         units_written = int(match_units.group(1).replace(',', ''))
                         # Assuming 512 byte units, convert to TB
                         tb_written = (units_written * 512) / (1024**4)

            # Fallback to SATA LBA Written
            elif lba_written_raw is not None:
                lba_written = int(lba_written_raw.replace(',', ''))
                # Assuming 512 byte sectors
                tb_written = (lba_written * 512) / (1024**4)

            # Proceed with calculations if we have tb_written and other necessary data
            if tb_written is not None and days_powered != "N/A" and RATED_TBW > 0:
                days_powered_num = float(days_powered)

                if days_powered_num > 0:
                    gb_per_day = (tb_written * 1024) / days_powered_num
                else:
                    gb_per_day = 0.0

                percent_tbw_used = (tb_written / RATED_TBW) * 100
                remaining_tb = RATED_TBW - tb_written

                if gb_per_day > 0.001:
                    days_remaining_num = math.floor((remaining_tb * 1024) / gb_per_day)
                    if days_remaining_num >= 0:
                        years_remaining = f"{days_remaining_num / 365:.1f}"

                        today = datetime.date.today()
                        replace_by_age_date = today + datetime.timedelta(days=REPLACEMENT_YEARS_AGE_LIMIT * 365)
                        replace_by_usage_date = today + datetime.timedelta(days=days_remaining_num)

                        if replace_by_usage_date < replace_by_age_date:
                            replace_date_str = f"{replace_by_usage_date.strftime('%Y-%m')} (TBW limited)"
                        else:
                            replace_date_str = f"{replace_by_age_date.strftime('%Y-%m')} (age limited)"
                    else:
                         replace_date_str = "Now (TBW exceeded)"
                         years_remaining = "0.0"

                elif remaining_tb >= 0:
                    replace_date_str = f"> {REPLACEMENT_YEARS_AGE_LIMIT} years (low usage)"
                    today = datetime.date.today()
                    replace_by_age_date = today + datetime.timedelta(days=REPLACEMENT_YEARS_AGE_LIMIT * 365)
                    replace_date_str = f"{replace_by_age_date.strftime('%Y-%m')} (age limited)"

                drive_message_lines.append(f"💾 {tb_written:.1f} TB written | 📊 {gb_per_day:.1f} GB/day write rate{erase_count_str}")
                drive_message_lines.append(f"📝 {percent_tbw_used:.1f}% of rated TBW ({RATED_TBW}TB) used")
                days_remaining_str = str(days_remaining_num) if days_remaining_num is not None else "N/A"
                drive_message_lines.append(f"⏳ Est. remaining life: {years_remaining} years ({days_remaining_str} days)")
                drive_message_lines.append(f"🗓️ Consider replacement by: {replace_date_str}")

            else:
                 # Non-SSD or missing data for calculation
                 drive_message_lines.append("⚠️ Endurance stats N/A (SSD data missing or invalid)")

        except (ValueError, TypeError, ZeroDivisionError, AttributeError) as calc_e: # Added AttributeError
             print(f"Warning: Calculation error for disk {disk_dev}: {calc_e}", file=sys.stderr)
             drive_message_lines.append("⚠️ Calculation error for endurance stats")


        # Print formatted drive status before sending notification if VERBOSE
        full_drive_message = "\n".join(drive_message_lines)
        if VERBOSE:
            print(f"\n--- Formatted Summary: {disk_dev} (ID: {disk_id}) ---") # Clarify this is the formatted summary
            print(full_drive_message)
            print("-----------------------------")

        # Send notification for this drive
        send_notification(f"Drive {disk_dev} - {HOSTNAME}", full_drive_message, overall_priority)

    except Exception as e:
        print(f"Error processing disk ID {disk_id}: {e}", file=sys.stderr)
        # Send a generic error notification for this disk
        send_notification(f"⚠️ Error Processing Disk {disk_id} - {HOSTNAME}", f"An unexpected error occurred while processing disk ID {disk_id}. Check logs.", 8)

if VERBOSE:
    print(f"--- Disk SMART Check Complete ---")
# Always print the final completion message
print(f"{DATE_STR} - Monitoring check complete.")