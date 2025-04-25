# Specification for monitor.py

## 1. Overview

`monitor.py` is a Python 3 script designed to run on a Proxmox host (or any Linux system with ZFS and smartmontools). Its primary purpose is to monitor the health and status of one or more ZFS pools (configurable via `POOLS_TO_MONITOR`) and the individual physical disks comprising those pools. It gathers key metrics, logs status information, and sends a summary notification for all pools. It also sends detailed notifications for individual disks *only if* specific issues (like SMART failures, high TBW usage, or impending replacement needs) are detected. Notifications are sent via Gotify and/or Pushover.

## 2. Dependencies

The script relies on the following:

* **Python 3:** The script interpreter.
* **Python Standard Libraries:** `subprocess`, `os`, `re`, `datetime`, `math`, `sys`, `urllib.request`, `urllib.parse`, `json`, `logging`. No external Python packages are required.
* **Command-line Utilities:**
  * `zpool`: For querying ZFS pool status and properties.
  * `smartctl`: (from `smartmontools`) For querying disk SMART health data.

## 3. Configuration

The script requires configuration primarily through variables defined at the top of the `monitor.py` file:

* **Gotify:**
  * `GOTIFY_ENABLED`: Set to `True` to enable Gotify notifications, `False` to disable.
  * `GOTIFY_URL`: The full URL of the Gotify server's message endpoint. **Must be set if Gotify is enabled.**
  * `GOTIFY_API_KEY`: A Gotify application token for authentication. **Must be set if Gotify is enabled.**
* **Pushover:**
  * `PUSHOVER_ENABLED`: Set to `True` to enable Pushover notifications, `False` to disable.
  * `PUSHOVER_API_URL`: The URL for the Pushover API (default: `https://api.pushover.net/1/messages.json`).
  * `PUSHOVER_APP_TOKEN`: Your Pushover application's API token. **Must be set if Pushover is enabled.**
  * `PUSHOVER_USER_KEY`: Your Pushover user or group key. **Must be set if Pushover is enabled.**
* **Monitoring:**
  * `POOLS_TO_MONITOR`: A Python list of strings containing the names of the ZFS pools to monitor (e.g., `["rpool", "tank"]`). Default is `["rpool"]`.
  * `RATED_TBW`: An integer representing the assumed Total Bytes Written endurance rating (in Terabytes) for SSDs. Used for life expectancy calculations. Default is `360`.
  * `REPLACEMENT_YEARS_AGE_LIMIT`: An integer representing the default age limit (in years) for suggesting drive replacement based purely on age. Default is `5`.
  * `VERBOSE`: Set to `True` to enable `DEBUG` level logging (including raw `smartctl` output and detailed drive summaries). Set to `False` for `INFO` level logging (default).

## 4. Execution Flow

1. **Initialization:**
    * Imports necessary Python modules.
    * Defines configuration variables (Gotify, Pushover, Monitoring).
    * Sets up logging using `logging.basicConfig`. Log level is `DEBUG` if `VERBOSE` is `True`, otherwise `INFO`.
    * Retrieves the system `HOSTNAME` using `os.uname().nodename`.
    * Gets the current timestamp using `datetime.datetime.now()`.
    * Defines helper functions:
        * `run_command(command)`: Executes a shell command using `subprocess.run` and returns stdout, stderr, and return code. Errors are logged.
        * `parse_smartctl_value(output, attribute_name)`: Parses specific SMART attributes from `smartctl -A` output, handling both SATA (column-based) and NVMe (key: value) formats. Returns the full value string for NVMe.
        * `parse_smartctl_health(output)`: Parses overall health ("PASSED", "FAILED", "Unknown") from `smartctl -H` output.
        * `parse_smartctl_model(output)`: Parses the device model from `smartctl -i` output.
        * `send_notification(title, message, priority_level)`: Sends notifications using `urllib.request` to Gotify and/or Pushover based on enabled status and configuration. Errors are logged.
    * Initializes overall health status variables (`overall_health`, `overall_priority`) and containers for disk IDs (`all_disks`) and messages (`main_message_parts`).
    * Logs script start message.

2. **ZFS Pool Status Check (Loop):**
    * Iterates through each `pool_name` in the `POOLS_TO_MONITOR` list.
    * For each pool:
        * Runs `zpool status -x {pool_name}` using `run_command`.
        * Determines pool health (`✅ Healthy`, `❌ Error: Pool not found.`, `⚠️ [Status Line]`) based on return code and output. Logs the status.
        * Sets `current_priority` (1 for healthy, 8 for error/unhealthy).
        * Updates `overall_priority` and `overall_health` if the current pool's status is worse.
        * Constructs pool summary lines, including hostname and status.
        * If the pool exists and is found:
            * Retrieves `used`, `available`, and `compressratio` using `zfs get` via `run_command`. Appends usage info to summary.
            * If the pool is *not* healthy, retrieves full `zpool status {pool_name}` output and appends the relevant `config:` section to the summary.
            * Runs `zpool status {pool_name}` again to find associated disk identifiers (`ata-`, `nvme-`, `wwn-` prefixes) using `re.findall`. Cleans partition suffixes (e.g., `-part1`) and adds unique IDs to the `all_disks` set.
        * Appends the collected summary lines for the pool to `main_message_parts`.
    * Logs pool check completion message.

3. **Send Summary Notification:**
    * Joins the `main_message_parts` into a single message string.
    * Logs that the summary notification is being sent.
    * Calls `send_notification` with the title "ZFS Status Summary - [Hostname]", the combined message, and the determined `overall_priority` (based on the worst pool status).

4. **Individual Disk SMART Check (Loop):**
    * Logs disk check start message.
    * Sorts the unique disk IDs collected in `all_disks`.
    * Iterates through each unique `disk_id`:
        * Initializes flags and variables for potential drive-specific notification (`send_drive_notification`, `drive_priority`, `drive_issue_reason`).
        * Constructs the path `/dev/disk/by-id/{disk_id}`.
        * Checks if the path exists. If not, logs and skips.
        * Resolves the symbolic link to the actual device path (e.g., `/dev/nvme0n1`) using `os.path.realpath`.
        * Gets the base device name (e.g., `nvme0n1`) using `os.path.basename`.
        * Checks if the resolved device path `/dev/{disk_dev}` exists. If not, logs and skips.
        * Runs `smartctl -i`, `smartctl -H`, and `smartctl -A` for the device using `run_command`.
        * Logs raw `smartctl` output if log level is `DEBUG`.
        * Checks return codes. If any `smartctl` command failed, logs a warning, sends a notification if health check (`-H`) failed (priority 8), and skips detailed reporting for this disk.
        * Parses `model` using `parse_smartctl_model`.
        * Parses `health` using `parse_smartctl_health`.
        * **Checks for notification triggers:**
            * If `health` is "FAILED", sets `send_drive_notification = True`, `drive_priority = 8`, `drive_issue_reason = "SMART Health FAILED"`.
        * Parses various SMART attributes using `parse_smartctl_value`, prioritizing NVMe standard names and falling back to common SATA names.
        * Extracts the numeric temperature value.
        * Calculates `days_powered` from `hours`.
        * Determines `life_used_str` based on available attributes.
        * Constructs the initial drive message lines (Model, Health, Temp, Power On, Life Used).
        * **SSD Endurance Calculation (Conditional):**
            * Attempts to determine `tb_written` from NVMe or SATA attributes.
            * If `tb_written`, `days_powered`, and `RATED_TBW` are valid:
                * Calculates `gb_per_day`, `percent_tbw_used`, `remaining_tb`, `days_remaining_num`, `years_remaining`.
                * Determines the `replace_date_str` based on the *earlier* of the TBW-based and age-based limits.
                * **Checks for notification triggers:**
                    * If `replace_date_str` indicates "Now (TBW exceeded)", sets `send_drive_notification = True`, updates `drive_priority` (max 8), sets `drive_issue_reason` (if not already set).
                    * If `replace_date_str` indicates replacement is due within one year (parses date), sets `send_drive_notification = True`, updates `drive_priority` (max 5), sets `drive_issue_reason` (if not already set).
                * Appends detailed endurance lines to the drive message.
            * If calculation is not possible, appends a "Endurance stats N/A" message.
            * Handles potential calculation errors (`ValueError`, etc.), logs a warning, appends an error message, sets `send_drive_notification = True`, updates `drive_priority` (max 5), and sets `drive_issue_reason`.
        * Joins all drive message lines into `full_drive_message`.
        * Logs the formatted summary if log level is `DEBUG`.
        * **Send Drive-Specific Notification (Conditional):**
            * If `send_drive_notification` is `True`:
                * Determines an appropriate `notification_title` based on the issue (e.g., "❌ Drive ... FAILED", "⚠️ Drive ... Issue").
                * Logs the reason for sending the notification.
                * Calls `send_notification` with the specific `notification_title`, `full_drive_message`, and the determined `drive_priority`.
            * Else (no issue detected):
                * Logs that the drive status is OK and no notification is sent.
        * Handles any unexpected errors during disk processing, logs the error, and sends a generic error notification (priority 8) for that disk.
    * Logs disk check completion message.

5. **Completion:**
    * Logs a final "Monitoring check complete" message with the timestamp.

## 5. Calculations (Python Implementation)

* **Days Powered On:** `float(hours_num) / 24` (Python float division)
* **Life Used %:** Derived from NVMe `Percentage Used` or calculated as `100 - life_remain` from SATA `Percent_Lifetime_Remain`, or taken from SATA `Wear_Leveling_Count`.
* **TB Written:**
  * From NVMe `Data Units Written`: Regex extraction `r'\[\s*([\d.]+)\s*TB\s*\]'` or `(units * 512) / (1024**4)`.
  * From SATA `Total_LBAs_Written`: `(lba_written * 512) / (1024**4)`.
* **GB/Day Write Rate:** `(tb_written * 1024) / days_powered_num`.
* **% TBW Used:** `(tb_written / RATED_TBW) * 100`.
* **Remaining TB:** `RATED_TBW - tb_written`.
* **Days Remaining (TBW):** `math.floor((remaining_tb * 1024) / gb_per_day)`.
* **Years Remaining (TBW):** `days_remaining_num / 365`.
* **Replacement Date (Age):** `datetime.date.today() + datetime.timedelta(days=REPLACEMENT_YEARS_AGE_LIMIT * 365)`.
* **Replacement Date (TBW):** `datetime.date.today() + datetime.timedelta(days=days_remaining_num)`.
* **Final Replacement Date:** The earlier date between the Age-based and TBW-based calculations, formatted as `YYYY-MM`.

## 6. Notifications

* Uses the `send_notification` function.
* Uses Python's `urllib.request` module to send HTTP POST requests.
* Data is URL-encoded using `urllib.parse.urlencode`.
* **Gotify (if enabled):**
  * Sends POST to `GOTIFY_URL`.
  * Authentication via `X-Gotify-Key` header using `GOTIFY_API_KEY`.
  * Payload includes `title`, `message`, `priority`.
* **Pushover (if enabled):**
  * Sends POST to `PUSHOVER_API_URL`.
  * Authentication via `token` (`PUSHOVER_APP_TOKEN`) and `user` (`PUSHOVER_USER_KEY`) fields in the payload.
  * Payload includes `token`, `user`, `title`, `message`, `priority`.
  * Pushover priority is mapped from the script's priority level: `<= 1` -> `-1` (low), `>= 8` -> `1` (high), others -> `0` (normal).
* **Summary Notification:**
  * One summary notification is always sent for all monitored pools.
  * The priority of the summary notification (`overall_priority`) is determined by the *worst* health status found among the monitored ZFS pools (1 for all healthy, 8 if any pool has issues or errors).
* **Drive-Specific Notifications:**
  * Separate notifications are sent for individual physical disks *only if* an issue is detected during the SMART check (e.g., SMART health "FAILED", TBW exceeded, replacement suggested within a year, calculation error, SMART data retrieval error).
  * The title and priority (`drive_priority`) of these notifications depend on the specific issue detected (e.g., priority 8 for FAILED/TBW exceeded, priority 5 for replacement suggested soon or calculation errors).
* Network requests have a timeout of 10 seconds. Errors during notification sending are logged as warnings/errors but do not stop the script.

## 7. Assumptions and Limitations

* Requires Python 3, `zpool`, and `smartctl` to be installed and in the system PATH.
* Assumes `smartctl` and `zpool` output formats remain reasonably consistent for parsing.
* Relies on `/dev/disk/by-id/` links being present and correctly pointing to storage devices used by ZFS.
* SSD endurance calculations depend on:
  * The `RATED_TBW` variable being set appropriately for the drives in use.
  * `smartctl` providing readable `Data Units Written` (NVMe) or `Total_LBAs_Written` (SATA) attributes.
  * `smartctl` providing readable `Power On Hours`.
* Replacement date estimation uses a simple linear extrapolation based on average daily writes and a fixed age limit.
* Requires user configuration of API keys/tokens and enabling desired notification services within the script.
* Error handling for external commands (`zpool`, `smartctl`) relies on checking return codes and parsing stderr, but might not cover all edge cases.
