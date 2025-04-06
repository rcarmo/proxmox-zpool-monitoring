Certainly! Here's a suggested README.md for the `proxmox-zpool-monitoring` repository:

```markdown
# Proxmox Zpool Monitoring

A tool for monitoring ZFS zpools on a Proxmox server.

## Table of Contents

- [Introduction](#introduction)
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [Configuration](#configuration)
- [Contributing](#contributing)
- [License](#license)

## Introduction

Proxmox Zpool Monitoring is designed to help you monitor the health and status of ZFS zpools on your Proxmox server. This tool provides detailed information and alerts about your zpools, helping you ensure that your storage system is running smoothly.

## Features

- Real-time monitoring of ZFS zpools
- Email notifications for zpool status changes
- Detailed logging of zpool events
- Easy-to-use configuration options

## Installation

1. Clone the repository:

    ```sh
    git clone https://github.com/overcuriousity/proxmox-zpool-monitoring.git
    cd proxmox-zpool-monitoring
    ```

2. Install the required dependencies:

    ```sh
    sudo apt-get update
    sudo apt-get install -y zfsutils-linux
    ```

3. Set up the monitoring script:

    ```sh
    sudo cp zpool_monitor.sh /usr/local/bin/zpool_monitor.sh
    sudo chmod +x /usr/local/bin/zpool_monitor.sh
    ```

## Usage

Run the monitoring script manually:

```sh
sudo /usr/local/bin/zpool_monitor.sh
```

To set up a cron job to run the script periodically, edit your crontab:

```sh
sudo crontab -e
```

Add the following line to run the script every hour:

```sh
0 * * * * /usr/local/bin/zpool_monitor.sh
```

## Configuration

Edit the configuration file `config.yml` to customize the monitoring settings. Here is an example configuration:

```yaml
email:
  enabled: true
  smtp_server: smtp.example.com
  smtp_port: 587
  username: your-email@example.com
  password: your-email-password
  to: recipient@example.com
  from: your-email@example.com

zpool:
  pools:
    - rpool
    - tank
```

## Contributing

We welcome contributions! Please read our [contributing guidelines](CONTRIBUTING.md) to learn how you can help.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
```
