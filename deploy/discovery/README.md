# Local server discovery

The iOS wizard offers **Find nearby servers** using Bonjour/DNS-SD over mDNS.
Discovery is optional and user-initiated; manual URLs remain available. Selecting
a result performs HTTPS and OIDC preflight, then asks for explicit server trust.
DNS-SD is not an authentication mechanism and never provisions an account or CA.

## Announce from the gateway host

Run on the actual LAN host, not inside the normal Docker bridge network:

```sh
python3 scripts/advertise-server.py --name Nephos \
  --url https://photos.example.net
```

The script uses macOS's built-in `dns-sd`, or Linux's `avahi-publish-service`
(`avahi-daemon` and `avahi-utils` must be installed and running). The process
stays in the foreground; stopping it withdraws the record. A deployment can
supervise this command with launchd/systemd. It does not modify global DNS,
open ports, trust certificates or install an automatic startup job.

For persistent Linux advertising, edit the port and URL in `nephos.service`,
then install it in `/etc/avahi/services/nephos.service` on the gateway host.
Avahi loads service files automatically. Do not run both publishers for the
same instance. Removing the service file withdraws the persistent announcement.

Use the canonical **API base URL**, with a hostname covered by its certificate,
not the identity-only URL, a container name, localhost, or `0.0.0.0`. Discovery
does not fix hostname resolution: that hostname must resolve on the phone.
The announced port must be reachable and match the HTTPS URL. Self-signed/local
CAs still require explicit OS trust; public certificates avoid that setup step.

## Announcement contract

- Service: `_nephos._tcp.local.`; DNS-SD supplies the instance name and port.
- TXT `v=1`: version of this announcement format, independent of HTTP API/model versions.
- TXT `url=https://hostname[:port][/base-path]`: complete canonical API base URL.
  Maximum 251 UTF-8 bytes, leaving room for `url=` in a 255-byte TXT entry.
- Never advertise credentials, invitation links, tokens, user lists or media.

iOS reads the canonical hostname from TXT rather than turning an SRV result into
an IP-based HTTPS URL. Invalid/unsupported records are omitted with a notice.
Results are deduplicated by URL, capped at 32, updated when services disappear,
and cleared when browsing stops. Queued callbacks cannot repopulate a stopped
search. Selection never sends credentials to an unapproved discovered server.

Multicast normally stays on one LAN. Guest Wi-Fi isolation, VLAN boundaries,
firewalls and most VPNs can block it. Allow mDNS UDP 5353 on the intended LAN
only; do not expose it to the internet. No multicast entitlement is needed for
the system Bonjour browsing API; both iOS configurations declare the service
type and explain Local Network access. Discovery stops when the wizard leaves
the server step, disappears, or goes to the background.
