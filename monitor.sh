#!/bin/bash
# Gotify Configuration
GOTIFY_URL="https://gotify.domain.com/message"
GOTIFY_API_KEY="UNSET" # Renamed from API_KEY for clarity
GOTIFY_ENABLED=true # Control Gotify notifications

# Pushover Configuration
PUSHOVER_API_URL="https://api.pushover.net/1/messages.json"
PUSHOVER_APP_TOKEN="UNSET" # Your Pushover application token
PUSHOVER_USER_KEY="UNSET" # Your Pushover user/group key
PUSHOVER_ENABLED=false # Control Pushover notifications

# Monitoring Configuration
POOLS_TO_MONITOR="rpool" # Space-separated list of ZFS pools to monitor
RATED_TBW=360 # Assumed SSD TBW rating in Terabytes (e.g., for Crucial MX500)

HOSTNAME=$(hostname)
DATE=$(date "+%Y-%m-%d %H:%M")

# --- Notification Function ---
# Sends notification via configured services
# Arguments:
#   $1: Title
#   $2: Message
#   $3: Priority (Gotify: 1-10, Pushover: -2 to 2)
send_notification() {
  local title="$1"
  local message="$2"
  local gotify_priority="$3"
  local pushover_priority

  # Map Gotify priority to Pushover priority
  # Gotify 1 (low) -> Pushover -1 (low)
  # Gotify 8 (high) -> Pushover 1 (high)
  # Default Gotify -> Pushover 0 (normal)
  case $gotify_priority in
    1) pushover_priority=-1 ;;
    8) pushover_priority=1 ;;
    *) pushover_priority=0 ;;
  esac

  # Send via Gotify if enabled and configured
  if [[ "$GOTIFY_ENABLED" == true && "$GOTIFY_API_KEY" != "UNSET" && "$GOTIFY_URL" != "" ]]; then
    curl -s -X POST "$GOTIFY_URL?token=$GOTIFY_API_KEY" \
      -F "title=$title" \
      -F "message=$message" \
      -F "priority=$gotify_priority"
    sleep 1 # Keep the delay after a potential send
  fi

  # Send via Pushover if enabled and configured
  if [[ "$PUSHOVER_ENABLED" == true && "$PUSHOVER_APP_TOKEN" != "UNSET" && "$PUSHOVER_USER_KEY" != "UNSET" ]]; then
    # Use -F for each field, letting curl handle encoding
    curl -s -X POST "$PUSHOVER_API_URL" \
      -F "token=$PUSHOVER_APP_TOKEN" \
      -F "user=$PUSHOVER_USER_KEY" \
      -F "title=$title" \
      -F "message=$message" \
      -F "priority=$pushover_priority"
    sleep 1 # Keep the delay after a potential send
  fi
}
# --- End Notification Function ---

# Initialize overall status and disk list
OVERALL_HEALTH="✅ Healthy"
OVERALL_PRIORITY=1
ALL_DISKS=""
MAIN_MESSAGE=""

# Process each pool
for POOL_NAME in $POOLS_TO_MONITOR; do
  # Check ZFS pool status
  POOL_STATUS=$(zpool status -x "$POOL_NAME" 2>&1) # Capture stderr too
  if [[ "$POOL_STATUS" == *"pool '$POOL_NAME' is healthy"* ]]; then
    POOL_MSG="✅ Healthy"
    CURRENT_PRIORITY=1
  elif [[ "$POOL_STATUS" == *"no such pool"* ]]; then
    POOL_MSG="❌ Error: Pool '$POOL_NAME' not found."
    CURRENT_PRIORITY=8
  else
    # Extract relevant part of the status if not healthy
    POOL_MSG="⚠️ $(echo "$POOL_STATUS" | head -n 1)" # Use first line for summary
    CURRENT_PRIORITY=8
  fi

  # Update overall health and priority if any pool is unhealthy
  if [[ "$CURRENT_PRIORITY" -gt "$OVERALL_PRIORITY" ]]; then
    OVERALL_PRIORITY=$CURRENT_PRIORITY
    OVERALL_HEALTH="⚠️ Check Details" # General warning if any pool has issues
  fi

  # Get space usage if pool exists
  if [[ "$POOL_MSG" != *"not found"* ]]; then
    SPACE_USED=$(zfs get -H -o value used "$POOL_NAME")
    SPACE_AVAIL=$(zfs get -H -o value available "$POOL_NAME")
    COMPRESS_RATIO=$(zfs get -H -o value compressratio "$POOL_NAME")
    POOL_USAGE="📊 Usage: $SPACE_USED used, $SPACE_AVAIL free ($COMPRESS_RATIO compression)"
  else
    POOL_USAGE=""
  fi

  # Build message for this pool using printf for better newline handling
  printf -v POOL_SUMMARY "%s Pool '%s': %s" "$HOSTNAME" "$POOL_NAME" "$POOL_MSG"
  if [[ -n "$POOL_USAGE" ]]; then
    # Append usage info with a newline
    printf -v POOL_SUMMARY "%s\\n%s" "$POOL_SUMMARY" "$POOL_USAGE"
  fi

  # Add warning details only if there's an issue and pool exists
  if [[ "$POOL_MSG" != "✅ Healthy" && "$POOL_MSG" != *"not found"* ]]; then
    POOL_DETAIL=$(zpool status "$POOL_NAME" | grep -A10 "config:" | grep -v "errors:")
    # Append details with newlines
    printf -v POOL_SUMMARY "%s\\n\\nPool Configuration:\\n%s" "$POOL_SUMMARY" "$POOL_DETAIL"
  fi

  # Append this pool's summary to the main message
  if [[ -z "$MAIN_MESSAGE" ]]; then
    MAIN_MESSAGE="$POOL_SUMMARY" # First pool
  else
    # Append subsequent pools with separator using printf
    printf -v MAIN_MESSAGE "%s\\n---\\n%s" "$MAIN_MESSAGE" "$POOL_SUMMARY"
  fi

  # Get disks for this pool if it exists and add unique ones to ALL_DISKS
  if [[ "$POOL_MSG" != *"not found"* ]]; then
      # Process each disk identifier found in the current pool
      zpool status "$POOL_NAME" | grep -E 'ata-[^ ]+|nvme-[^ ]+' | awk '{print $1}' | sed 's/-part[0-9]*$//' | sort | uniq | while read -r disk_id; do
          # Check if the disk_id is already in ALL_DISKS (using spaces for word boundaries)
          if [[ ! " $ALL_DISKS " =~ " $disk_id " ]]; then
              ALL_DISKS+="$disk_id " # Append the unique disk_id with a space
          fi
      done
  fi
done

# Send the combined ZFS status message for all pools
send_notification "ZFS Status Summary - $HOSTNAME" "$MAIN_MESSAGE" "$OVERALL_PRIORITY"

# Process each unique disk found across all monitored pools
# The ALL_DISKS variable now contains space-separated unique disk IDs
for DISK in $ALL_DISKS; do # Iterate directly over the space-separated list
  DISK_DEV_LINK_INFO=$(ls -l /dev/disk/by-id/"$DISK" 2>&1)
  if [[ $? -ne 0 || -z "$DISK_DEV_LINK_INFO" ]]; then
      continue # Skip this disk if link not found or ls failed
  fi

  # Extract the device name (e.g., sda)
  DISK_DEV=$(echo "$DISK_DEV_LINK_INFO" | awk '{print $NF}' | sed 's/.*\///')
  
  if [[ -z "$DISK_DEV" ]]; then
      continue # Skip if device name extraction failed
  fi

  # Check if it's a valid block device
  if [[ -b "/dev/$DISK_DEV" ]]; then
    # Get essential SMART info only
    MODEL=$(smartctl -i /dev/"$DISK_DEV" | grep "Device Model" | awk -F': ' '{print $2}')
    HEALTH_OUTPUT=$(smartctl -H /dev/"$DISK_DEV")
    if echo "$HEALTH_OUTPUT" | grep -q "PASSED"; then
        HEALTH="✅ PASSED"
    elif echo "$HEALTH_OUTPUT" | grep -q "FAILED"; then
        HEALTH="❌ FAILED"
    else
        HEALTH="❓ Unknown" # Handle cases where PASSED/FAILED isn't found
    fi
    TEMP=$(smartctl -A /dev/"$DISK_DEV" | grep "Temperature_Celsius" | awk '{print $10}')
    HOURS=$(smartctl -A /dev/"$DISK_DEV" | grep "Power_On_Hours" | awk '{print $10}')

    # Calculate days of operation, handle non-numeric HOURS
    DAYS_POWERED="N/A"
    if [[ "$HOURS" =~ ^[0-9]+$ && "$HOURS" -ge 0 ]]; then # Allow 0 hours
        DAYS_POWERED=$(echo "scale=1; $HOURS/24" | bc)
    fi

    # Determine Life Used string, handle missing attributes
    LIFE_USED_STR="N/A"
    LIFE_REMAIN_RAW=$(smartctl -A /dev/"$DISK_DEV" | grep "Percent_Lifetime_Remain" | awk '{print $10}')
    if [[ "$LIFE_REMAIN_RAW" =~ ^[0-9]+$ ]]; then
        LIFE_USED=$(( 100 - LIFE_REMAIN_RAW ))
        LIFE_USED_STR="${LIFE_USED}% used"
    else
        WEAR_LEVEL_RAW=$(smartctl -A /dev/"$DISK_DEV" | grep -E '^(173| *173) Wear_Leveling_Count' | awk '{print $10}')
         if [[ "$WEAR_LEVEL_RAW" =~ ^[0-9]+$ ]]; then
             LIFE_USED_STR="${WEAR_LEVEL_RAW}% used (WLC)"
         fi
    fi

    # Get erase count if available
    ERASE_COUNT_RAW=$(smartctl -A /dev/"$DISK_DEV" | grep "Ave_Block-Erase_Count" | awk '{print $10}')
    ERASE_COUNT_STR=""
    if [[ "$ERASE_COUNT_RAW" =~ ^[0-9]+$ ]]; then
        ERASE_COUNT_STR="| 🔄 Block Erase Count: $ERASE_COUNT_RAW"
    fi

    # Get Total Data Written for SSDs and calculate drive endurance stats
    LBA_WRITTEN_RAW=$(smartctl -A /dev/"$DISK_DEV" | grep "Total_LBAs_Written" | awk '{print $10}')
    
    # Check if necessary values are numeric and positive before calculating endurance
    if [[ "$LBA_WRITTEN_RAW" =~ ^[0-9]+$ && "$DAYS_POWERED" != "N/A" && $(echo "$DAYS_POWERED >= 0" | bc -l) -eq 1 && "$RATED_TBW" =~ ^[0-9]+(\.[0-9]+)?$ && $(echo "$RATED_TBW > 0" | bc -l) -eq 1 ]]; then
      LBA_WRITTEN=$LBA_WRITTEN_RAW
      TB_WRITTEN=$(echo "scale=1; $LBA_WRITTEN * 512 / 1024 / 1024 / 1024 / 1024" | bc)
      GB_PER_DAY="0.0" # Default
      # Avoid division by zero if DAYS_POWERED is 0
      if (( $(echo "$DAYS_POWERED > 0" | bc -l) )); then
          GB_PER_DAY=$(echo "scale=1; $TB_WRITTEN * 1024 / $DAYS_POWERED" | bc)
      fi
      PERCENT_TBW_USED=$(echo "scale=1; $TB_WRITTEN * 100 / $RATED_TBW" | bc)
      REMAINING_TB=$(echo "scale=1; $RATED_TBW - $TB_WRITTEN" | bc)
      DAYS_REMAINING="N/A"
      YEARS_REMAINING="N/A"
      REPLACE_DATE="N/A"
      
      if (( $(echo "$GB_PER_DAY > 0.0" | bc -l) )); then
          DAYS_REMAINING=$(echo "scale=0; $REMAINING_TB * 1024 / $GB_PER_DAY" | bc)
          if [[ "$DAYS_REMAINING" =~ ^[0-9]+$ ]]; then
              YEARS_REMAINING=$(echo "scale=1; $DAYS_REMAINING / 365" | bc)
              REPLACE_BY_AGE_DATE=$(date -d "+5 years" "+%Y-%m")
              REPLACE_BY_USAGE_DATE=$(date -d "+${DAYS_REMAINING} days" "+%Y-%m")
              if [[ $(date -d "$REPLACE_BY_USAGE_DATE" +%s) -lt $(date -d "$REPLACE_BY_AGE_DATE" +%s) ]]; then
                REPLACE_DATE="$REPLACE_BY_USAGE_DATE (TBW limited)"
              else
                REPLACE_DATE="$REPLACE_BY_AGE_DATE (age limited)"
              fi
          fi
      elif (( $(echo "$REMAINING_TB >= 0" | bc -l) )); then # If write rate is 0, but TBW not exceeded
          REPLACE_DATE=">5 years (low usage)" # Indicate long life based on low usage
      fi

      # Format the detailed message for SSDs using printf
      printf -v DRIVE_MESSAGE "%s (%s): %s\\n🌡️ %s°C | ⏱️ %sh (%s days) | 🔋 %s\\n💾 %s TB written | 📊 %s GB/day write rate %s\\n📝 %s%% of rated TBW used\\n⏳ Est. remaining life: %s years (%s days)\\n🗓️ Consider replacement by: %s" \
          "$DISK_DEV" "$MODEL" "$HEALTH" \
          "$TEMP" "$HOURS" "$DAYS_POWERED" "$LIFE_USED_STR" \
          "$TB_WRITTEN" "$GB_PER_DAY" "$ERASE_COUNT_STR" \
          "$PERCENT_TBW_USED" \
          "$YEARS_REMAINING" "$DAYS_REMAINING" \
          "$REPLACE_DATE"
    else
      # For non-SSD drives or drives missing data for calculation
      DAYS_POWERED_STR="(${DAYS_POWERED} days)"
      if [[ "$DAYS_POWERED" == "N/A" ]]; then
          DAYS_POWERED_STR="(days N/A)"
      fi
      # Format message for non-SSDs using printf
      printf -v DRIVE_MESSAGE "%s (%s): %s\\n🌡️ %s°C | ⏱️ %sh %s | 🔋 %s\\n⚠️ Endurance stats N/A (non-SSD or data missing)" \
          "$DISK_DEV" "$MODEL" "$HEALTH" \
          "$TEMP" "$HOURS" "$DAYS_POWERED_STR" "$LIFE_USED_STR"
    fi

    # Send each drive as a separate message using the new function
    # Use the OVERALL_PRIORITY determined by the worst pool status
    send_notification "Drive $DISK_DEV - $HOSTNAME" "$DRIVE_MESSAGE" "$OVERALL_PRIORITY"
  fi
done
