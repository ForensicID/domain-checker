#!/bin/bash

LOG_FILE="/home/example/domain_check.log"
DOMAIN_FILE="/home/example/domains.txt"
TOKEN="YOUR_BOT_TOKEN"
CHAT_ID="YOUR_CHAT_ID"
TELEGRAM_API="https://api.telegram.org/bot$TOKEN/sendMessage"

if ! command -v whois &>/dev/null; then
    printf "Error: Perintah 'whois' tidak ditemukan. Harap instal terlebih dahulu.\n" >&2
    exit 1
fi

if [[ ! -f "$DOMAIN_FILE" ]]; then
    printf "Error: File %s tidak ditemukan.\n" "$DOMAIN_FILE" >&2
    exit 1
fi

send_telegram_message() {
    local message="$1"
    curl -s -X POST "$TELEGRAM_API" -d chat_id="$CHAT_ID" -d text="$message" >/dev/null
}

sanitize_text() {
    local text="$1"
    printf "%s" "$text" | sed 's|https\?://[a-zA-Z0-9./?=_-]*||g' | sed 's|#.*||' | xargs
}

check_domain() {
    local domain="$1"
    local whois_output; whois_output=$(whois "$domain" 2>/dev/null)

    if [[ -z "$whois_output" ]]; then
        printf "Warning: Tidak dapat mengambil data WHOIS untuk domain %s\n" "$domain" >&2
        return
    fi

    # Read old values from log
    local old_entry; old_entry=$(grep -A 5 "^Domain: $domain$" "$LOG_FILE" | sed '/^$/d')
    local old_status; old_status=$(echo "$old_entry" | grep "Status:" | awk -F': ' '{print $2}' | xargs)
    local old_expiry; old_expiry=$(echo "$old_entry" | grep "Tanggal Expired:" | awk -F': ' '{print $2}' | xargs)
    local old_days_left; old_days_left=$(echo "$old_entry" | grep "Sisa Hari:" | awk -F': ' '{print $2}' | xargs)

    # Parse new WHOIS output
    local status; status=$(echo "$whois_output" | grep -i -E 'Domain Status|Status' | head -n 1 | awk -F': ' '{print $2}' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    local registrar; registrar=$(echo "$whois_output" | awk -F': ' '/Registrar:|Registrar Organization:/ {print $2; exit}' | xargs)
    local registrar_url; registrar_url=$(echo "$whois_output" | awk -F': ' '/Registrar URL:/ {print $2; exit}' | xargs)
    local expiry_date; expiry_date=$(echo "$whois_output" | grep -i -E "Registry Expiry Date:|Expiration Date:" | awk -F': ' '{print $2}' | xargs | awk '{print $1}' | cut -d'T' -f1)

    # Calculate days left
    local days_left
    if [[ -n "$expiry_date" ]]; then
        local expiry_epoch; expiry_epoch=$(date -d "$expiry_date" +%s)
        local current_epoch; current_epoch=$(date +%s)
        days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
    else
        days_left="N/A"
    fi

    # Normalize status
    local status_label
    case "$status" in
        *active*|*clientDeleteProhibited*|*clientTransferProhibited*|*clientUpdateProhibited*|*clientRenewProhibited*|*ok*)
            status_label="Active"
            ;;
        *redemption*|*pendingDelete*|*inactive*|*expired*|*serverHold*|*clientHold*)
            status_label="Dead"
            ;;
        *)
            status_label="Unknown"
            ;;
    esac

    # Compare with old status and send notifications if needed
    if [[ "$old_status" != "$status_label" ]]; then
        send_telegram_message "📝Breaking News📝%0ADomain: $domain%0AStatus: $status_label%0ARegistrar: $registrar%0ARegistrar URL: $registrar_url%0AExpired Date: $expiry_date"
    fi

    if [[ "$days_left" =~ ^[0-9]+$ ]]; then
        if [[ "$days_left" -eq 30 ]]; then
            send_telegram_message "🔔Attention🔔%0ADomain $domain%0ARegistrar: $registrar%0ARegistrar URL: $registrar_url%0AWill be expired in $days_left days"
        elif [[ "$days_left" -eq 7 ]]; then
            send_telegram_message "⚠️Warning⚠️%0ADomain $domain%0ARegistrar: $registrar%0ARegistrar URL: $registrar_url%0AWill be expired in $days_left days"
        elif [[ "$days_left" -le 3 && "$days_left" -ge 1 ]]; then
            send_telegram_message "🔥Danger🔥%0ADomain $domain%0ARegistrar: $registrar%0ARegistrar URL: $registrar_url%0AWill be expired in $days_left days"
        elif [[ "$days_left" -eq 0 ]]; then
            send_telegram_message "🗿Tewas%0ADomain $domain expired%0ARegistrar: $registrar%0ARegistrar URL: $registrar_url%0A"
        fi
    fi

    # Save updated values to log
    local new_log_entry; new_log_entry=$(printf "Domain: %s\nStatus: %s\nRegistrar: %s\nRegistrar URL: %s\nTanggal Expired: %s\nSisa Hari: %s\n" \
        "$domain" "$status_label" "$registrar" "$registrar_url" "$expiry_date" "$days_left")

    sed -i "/^Domain: $domain$/,+5 d" "$LOG_FILE"
    printf "%s\n" "$new_log_entry" >> "$LOG_FILE"
}

while IFS= read -r domain; do
    if [[ -n "$domain" ]]; then
        check_domain "$domain"
    fi
done < "$DOMAIN_FILE"