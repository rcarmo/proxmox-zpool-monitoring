#!/bin/bash
GOTIFY_URL="https://gotify.domain.com/message"
API_KEY="UNSET"
HOSTNAME=$(hostname)
DATE=$(date "+%Y-%m-%d %H:%M")

# Check ZFS pool status
POOL_STATUS=$(zpool status -x)
if [[ "$POOL_STATUS" == *"healthy"* ]]; then
  POOL_MSG="✅ Healthy"
  PRIORITY=1
else
  POOL_MSG="⚠️ $POOL_STATUS"
  PRIORITY=8
fi

# Get space usage
SPACE_USED=$(zfs get -H -o value used rpool)
SPACE_AVAIL=$(zfs get -H -o value available rpool)
COMPRESS_RATIO=$(zfs get -H -o value compressratio rpool)

# Build main ZFS message (simplified)
MAIN_MESSAGE="$HOSTNAME ZFS Status: $POOL_MSG
📊 Usage: $SPACE_USED used, $SPACE_AVAIL free ($COMPRESS_RATIO compression)"

# Add warning details only if there's an issue
if [[ "$POOL_MSG" != "✅ Healthy" ]]; then
  POOL_DETAIL=$(zpool status rpool | grep -A10 "config:" | grep -v "errors:")
  MAIN_MESSAGE="$MAIN_MESSAGE

Pool Configuration:
$POOL_DETAIL"
fi

# Send the main ZFS status message
curl -X POST "$GOTIFY_URL?token=$API_KEY" \
  -F "title=ZFS Status - $HOSTNAME" \
  -F "message=$MAIN_MESSAGE" \
  -F "priority=$PRIORITY"

sleep 1

# Get all disks in the pool
DISKS=$(zpool status rpool | grep -E 'ata-[^ ]+' | awk '{print $1}' | sed 's/-part[0-9]*$//' | sort | uniq)

# Process each disk
for DISK in $DISKS; do
  DISK_DEV=$(ls -l /dev/disk/by-id/$DISK 2>/dev/null | awk '{print $NF}' | sed 's/.*\///')
  
  if [[ -b "/dev/$DISK_DEV" ]]; then
    # Get essential SMART info only
    MODEL=$(smartctl -i /dev/$DISK_DEV | grep "Device Model" | awk -F': ' '{print $2}')
    HEALTH=$(smartctl -H /dev/$DISK_DEV | grep -q "PASSED" && echo "✅ PASSED" || echo "❌ FAILED")
    TEMP=$(smartctl -A /dev/$DISK_DEV | grep "Temperature_Celsius" | awk '{print $10}')
    HOURS=$(smartctl -A /dev/$DISK_DEV | grep "Power_On_Hours" | awk '{print $10}')
    
    # Calculate days of operation
    DAYS_POWERED=$(echo "scale=1; $HOURS/24" | bc)
    
    # For Crucial MX500 SSDs, use Percent_Lifetime_Used instead of Remain
    LIFE_REMAIN=$(smartctl -A /dev/$DISK_DEV | grep "Percent_Lifetime_Remain" | awk '{print $10}')
    LIFE_USED=$(( 100 - $LIFE_REMAIN ))
    
    # Get erase count
    ERASE_COUNT=$(smartctl -A /dev/$DISK_DEV | grep "Ave_Block-Erase_Count" | awk '{print $10}')
    
    # Get Total Data Written for SSDs and calculate drive endurance stats
    if [[ -n "$(smartctl -A /dev/$DISK_DEV | grep "Total_LBAs_Written")" ]]; then
      LBA_WRITTEN=$(smartctl -A /dev/$DISK_DEV | grep "Total_LBAs_Written" | awk '{print $10}')
      TB_WRITTEN=$(echo "scale=1; $LBA_WRITTEN * 512 / 1024 / 1024 / 1024 / 1024" | bc)
      
      # Calculate write rate in GB per day
      GB_PER_DAY=$(echo "scale=1; $TB_WRITTEN * 1024 / $DAYS_POWERED" | bc)
      
      # For MX500 drives, estimated endurance is 360TB
      RATED_TBW=360
      PERCENT_TBW_USED=$(echo "scale=1; $TB_WRITTEN * 100 / $RATED_TBW" | bc)
      
      # Calculate estimated days remaining based on current write rate
      # and remaining TBW endurance
      REMAINING_TB=$(echo "scale=1; $RATED_TBW - $TB_WRITTEN" | bc)
      DAYS_REMAINING=$(echo "scale=0; $REMAINING_TB * 1024 / $GB_PER_DAY" | bc)
      YEARS_REMAINING=$(echo "scale=1; $DAYS_REMAINING / 365" | bc)

      # For replacement planning, assume 5 years typical lifespan if not limited by TBW
      REPLACE_BY_DATE=$(date -d "+${YEARS_REMAINING} years" "+%Y-%m")
      REPLACE_BY_USAGE=$(date -d "+${DAYS_REMAINING} days" "+%Y-%m")
      
      # Choose earlier date for replacement recommendation
      if [[ $(date -d "$REPLACE_BY_USAGE" +%s) -lt $(date -d "$REPLACE_BY_DATE" +%s) ]]; then
        REPLACE_DATE="$REPLACE_BY_USAGE (TBW limited)"
      else
        REPLACE_DATE="$REPLACE_BY_DATE (age limited)"
      fi
      
      # Format the detailed message
      DRIVE_MESSAGE="$DISK_DEV ($MODEL): $HEALTH
🌡️ $TEMP°C | ⏱️ ${HOURS}h (${DAYS_POWERED} days) | 🔋 ${LIFE_USED}% used
💾 $TB_WRITTEN TB written | 📊 ${GB_PER_DAY} GB/day write rate
🔄 Block Erase Count: $ERASE_COUNT | 📝 ${PERCENT_TBW_USED}% of rated TBW used
⏳ Est. remaining life: ${YEARS_REMAINING} years (${DAYS_REMAINING} days)
🗓️ Consider replacement by: $REPLACE_DATE"
    else
      # For non-SSD drives
      DRIVE_MESSAGE="$DISK_DEV ($MODEL): $HEALTH
🌡️ $TEMP°C | ⏱️ ${HOURS}h (${DAYS_POWERED} days) | 🔋 ${LIFE_USED}% used
⚠️ Unable to calculate endurance stats (non-SSD or data unavailable)"
    fi

    # Send each drive as a separate message
    curl -X POST "$GOTIFY_URL?token=$API_KEY" \
      -F "title=Drive $DISK_DEV - $HOSTNAME" \
      -F "message=$DRIVE_MESSAGE" \
      -F "priority=$PRIORITY"
      
    sleep 1
  fi
done
