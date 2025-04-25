# Proxmox Zpool Monitoring

A Python script for monitoring ZFS zpools and disk health on a Proxmox (or other Linux) server.

## Table of Contents

- [Proxmox Zpool Monitoring](#proxmox-zpool-monitoring)
  - [Table of Contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Features](#features)
  - [Dependencies](#dependencies)
  - [Installation](#installation)
  - [Usage](#usage)
  - [Configuration](#configuration)
  - [Contributing](#contributing)
  - [License](#license)

## Introduction

This script is designed to help you monitor the health and status of ZFS zpools and the underlying physical disks on your server. It provides detailed information and sends alerts via Gotify and/or Pushover, helping you ensure that your storage system is running smoothly. It uses standard Python libraries and requires external commands like `zpool` and `smartctl`.

## Features

- Monitors ZFS pool status (configurable list).
- Checks individual disk SMART health status using `smartctl`.
- Gathers SMART attributes like temperature, power-on hours, and lifetime remaining/used for both SATA and NVMe drives.
- Calculates estimated SSD endurance (TBW) usage and remaining life (based on a configurable `RATED_TBW`).
- Sends notifications via Gotify and/or Pushover using standard Python libraries.
- Notification priority adjusts based on pool health.
- Verbose mode for detailed console output.

## Dependencies

The script requires the following:

- **Python 3:** The script is written in Python 3. Standard libraries like `subprocess`, `os`, `re`, `datetime`, `math`, `sys`, `urllib`, and `json` are used. No external Python packages are required.
- **`zfsutils-linux`:** Provides the `zpool` and `zfs` commands used to query pool status and properties.
- **`smartmontools`:** Provides the `smartctl` command used to query disk health and SMART attributes.

## Installation

1. Clone the repository:

    ```sh
    git clone https://github.com/overcuriousity/proxmox-zpool-monitoring.git
    cd proxmox-zpool-monitoring
    ```

2. Install the required command-line dependencies (example for Debian/Ubuntu):

    ```sh
    sudo apt-get update
    sudo apt-get install -y zfsutils-linux smartmontools python3
    ```

3. Make the Python script executable:

    ```sh
    chmod +x monitor.py
    ```

    *(Optional: You can move `monitor.py` to a location in your PATH, like `/usr/local/bin/`, if desired)*

## Usage

1. **Configure the script:** Edit `monitor.py` to set your notification service API keys/tokens, enable the desired services, and configure pools and TBW rating (see Configuration section below).

2. Run the monitoring script manually:

    ```sh
    sudo ./monitor.py
    ```

    *(Or `sudo python3 monitor.py` if not executable or not in PATH)*

3. To set up a cron job to run the script periodically, edit your crontab:

    ```sh
    sudo crontab -e
    ```

    Add the following line to run the script daily at 3 AM (adjust path and timing as needed):

    ```sh
    # Example: Run daily at 3 AM from the cloned directory
    0 3 * * * cd /path/to/proxmox-zpool-monitoring && sudo ./monitor.py >> /var/log/zpool-monitor.log 2>&1
    ```

    *Make sure to replace `/path/to/proxmox-zpool-monitoring` with the actual path.*

## Configuration

Configuration is done by editing the variables at the beginning of the `monitor.py` script:

```python
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
```

- Set the `_ENABLED` flag to `True` for the notification services you want to use.
- Fill in the corresponding `_URL`, `_API_KEY`, `_APP_TOKEN`, and `_USER_KEY` values.
- Adjust `RATED_TBW` if you are using SSDs with a different endurance rating.
- Modify the `POOLS_TO_MONITOR` list with the names of the ZFS pools you wish to monitor.
- Set `VERBOSE` to `True` for detailed output during script execution.

## Contributing

We welcome contributions! Please open an issue or pull request.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
