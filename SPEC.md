# Specification for monitor.py

## 1. Overview

`monitor.py` is a Python 3 script designed to run on a Proxmox host (or any Linux system with ZFS and smartmontools). Its primary purpose is to monitor the health and status of one or more ZFS pools (configurable via `POOLS_TO_MONITOR`) and the individual physical disks comprising those pools. It gathers key metrics and sends summary and detailed notifications via Gotify and/or Pushover.

## 2. Dependencies

The script relies on the following:

* **Python 3:** The script interpreter.
* **Python Standard Libraries:** `subprocess`, `os`, `re`, `datetime`, `math`, `sys`, `urllib.request`, `urllib.parse`, `json`. No external Python packages are required.
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
  * `VERBOSE`: Set to `True` to print status updates and raw `smartctl` output to the console during execution. Default is `False`.

## 4. Execution Flow

1. **Initialization:**
    * Imports necessary Python modules.
    * Defines configuration variables (Gotify, Pushover, Monitoring).
    * Retrieves the system `HOSTNAME` using `os.uname().nodename`.
    * Gets the current timestamp using `datetime.datetime.now()`.
    * Defines helper functions:
        * `run_command(command)`: Executes a shell command using `subprocess.run` and returns stdout, stderr, and return code.
        * `parse_smartctl_value(output, attribute_name)`: Parses specific SMART attributes from `smartctl -A` output, handling both SATA (column-based) and NVMe (key: value) formats. Returns the full value string for NVMe.
        * `parse_smartctl_health(output)`: Parses overall health ("PASSED", "FAILED", "Unknown") from `smartctl -H` output.
        * `parse_smartctl_model(output)`: Parses the device model from `smartctl -i` output.
        * `send_notification(title, message, priority_level)`: Sends notifications using `urllib.request` to Gotify and/or Pushover based on enabled status and configuration.
    * Initializes overall health status variables (`overall_health`, `overall_priority`) and containers for disk IDs (`all_disks`) and messages (`main_message_parts`).
    * Optionally prints start message if `VERBOSE` is `True`.

2. **ZFS Pool Status Check (Loop):**
    * Iterates through each `pool_name` in the `POOLS_TO_MONITOR` list.
    * For each pool:
        * Runs `zpool status -x {pool_name}` using `run_command`.
        * Determines pool health (`✅ Healthy`, `❌ Error: Pool not found.`, `⚠️ [Status Line]`) based on return code and output.
        * Sets `current_priority` (1 for healthy, 8 for error/unhealthy).
        * Updates `overall_priority` and `overall_health` if the current pool's status is worse.
        * Constructs pool summary lines, including hostname and status.
        * If the pool exists and is found:
            * Retrieves `used`, `available`, and `compressratio` using `zfs get` via `run_command`. Appends usage info to summary.
            * If the pool is *not* healthy, retrieves full `zpool status {pool_name}` output and appends the relevant `config:` section to the summary.
            * Runs `zpool status {pool_name}` again to find associated disk identifiers (`ata-`, `nvme-`, `wwn-` prefixes) using `re.findall`. Cleans partition suffixes (e.g., `-part1`) and adds unique IDs to the `all_disks` set.
        * Appends the collected summary lines for the pool to `main_message_parts`.
    * Optionally prints completion message if `VERBOSE` is `True`.

3. **Send Summary Notification:**
    * Joins the `main_message_parts` into a single message string.
    * Calls `send_notification` with the title "ZFS Status Summary - [Hostname]", the combined message, and the determined `overall_priority`.
    * Optionally prints status if `VERBOSE` is `True`.

4. **Individual Disk SMART Check (Loop):**
    * Optionally prints start message if `VERBOSE` is `True`.
    * Sorts the unique disk IDs collected in `all_disks`.
    * Iterates through each unique `disk_id`:
        * Constructs the path `/dev/disk/by-id/{disk_id}`.
        * Checks if the path exists. If not, skips (prints message if `VERBOSE`).
        * Resolves the symbolic link to the actual device path (e.g., `/dev/nvme0n1`) using `os.path.realpath`.
        * Gets the base device name (e.g., `nvme0n1`) using `os.path.basename`.
        * Checks if the resolved device path `/dev/{disk_dev}` exists. If not, skips (prints message if `VERBOSE`).
        * Runs `smartctl -i`, `smartctl -H`, and `smartctl -A` for the device using `run_command`.
        * Optionally prints raw `smartctl` output if `VERBOSE` is `True`.
        * Checks return codes. If any `smartctl` command failed, prints a warning, sends a notification if health check failed, and skips detailed reporting for this disk.
        * Parses `model` using `parse_smartctl_model`.
        * Parses `health` using `parse_smartctl_health`.
        * Parses various SMART attributes using `parse_smartctl_value`, prioritizing NVMe standard names ("Temperature", "Power On Hours", "Percentage Used", "Data Units Written") and falling back to common SATA names ("Temperature_Celsius", "Power_On_Hours", "Percent_Lifetime_Remain", "Wear_Leveling_Count", "Total_LBAs_Written").
        * Extracts the numeric temperature value from the parsed string (e.g., "50" from "50 Celsius").
        * Calculates `days_powered` from `hours` (handling potential commas).
        * Determines `life_used_str` based on available attributes (NVMe `Percentage Used` > SATA `Percent_Lifetime_Remain` > SATA `Wear_Leveling_Count`).
        * Constructs the initial drive message lines (Model, Health, Temp, Power On, Life Used).
        * **SSD Endurance Calculation (Conditional):**
            * Attempts to determine `tb_written`:
                * Prioritizes NVMe `Data Units Written`: Extracts TB value from brackets (e.g., `[12.5 TB]`) using regex. Falls back to parsing the leading number as 512-byte units if brackets aren't present.
                * If NVMe data unavailable, falls back to SATA `Total_LBAs_Written` (assuming 512-byte sectors).
            * If `tb_written`, `days_powered`, and `RATED_TBW` are valid:
                * Calculates `gb_per_day` write rate.
                * Calculates `percent_tbw_used`.
                * Calculates `remaining_tb`.
                * If `gb_per_day` is significant, calculates estimated `days_remaining_num` based on TBW.
                * Calculates `years_remaining`.
                * Determines the `replace_date_str` based on the *earlier* of the date calculated from `days_remaining_num` and the date calculated from `REPLACEMENT_YEARS_AGE_LIMIT`. Adds "(TBW limited)" or "(age limited)" indication. Handles cases where TBW is already exceeded or usage is very low.
                * Appends detailed endurance lines (TB Written, GB/day, % TBW Used, Est. Life, Replace By) to the drive message.
            * If calculation is not possible (non-SSD, missing data), appends a "Endurance stats N/A" message.
            * Handles potential calculation errors (`ValueError`, `TypeError`, `ZeroDivisionError`, `AttributeError`) gracefully.
        * Joins all drive message lines into `full_drive_message`.
        * Optionally prints the formatted summary if `VERBOSE` is `True`.
        * Calls `send_notification` with the title "Drive [Device Name] - [Hostname]", the `full_drive_message`, and the `overall_priority` (determined earlier by the worst pool status).
        * Handles any unexpected errors during disk processing, prints an error, and sends a generic error notification for that disk.
    * Optionally prints completion message if `VERBOSE` is `True`.

5. **Completion:**
    * Prints a final "Monitoring check complete" message with the timestamp.

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
  * Pushover priority is mapped from Gotify priority: `<= 1` -> `-1` (low), `>= 8` -> `1` (high), others -> `0` (normal).
* One summary notification is sent for all monitored pools.
* Separate notifications are sent for each unique physical disk found.
* The priority of *all* notifications is determined by the *worst* health status found among the monitored ZFS pools.
* Network requests have a timeout of 10 seconds. Errors during notification sending are printed to stderr but do not stop the script.

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
