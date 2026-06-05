# Daycare Bulk Sender (5 Contacts)

Simple static page (HTML/CSS/JS) to send one announcement to up to 5 contacts using Evolution API.

## Files

- `index.html`
- `styles.css`
- `app.js`

## How to use

1. Open `index.html` in a browser.
2. Fill:
   - Evolution API Base URL (example: `http://localhost:8080`)
   - Instance Name
   - API Key
   - 1 to 5 phone numbers
   - Announcement message
3. Click **Validate Contacts** (uses `/chat/whatsappNumbers/:instanceName`).
4. Click **Send to Valid Contacts** (uses `/message/sendText/:instanceName` one by one).

## Notes

- Uses paced sends with random delay between min/max values.
- If validation is not run, send flow still attempts all filled contacts.
- Keep delays conservative to reduce WhatsApp risk.
