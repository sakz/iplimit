# IPLimit

IPLimit is a Debian 12 traffic-shaping tool for proxy servers and other services
where clients connect directly to the VPS. It gives every detected client IP an
independent upload and download ceiling without using packet-drop rate limiting.

- TCP and UDP, IPv4 and IPv6
- Automatic client discovery through conntrack
- Independent HTB class per client IP
- Upload shaping through selective per-client IFB redirects; download shaping on the public interface
- Interactive menu and command-line operation
- Safe cleanup of IPLimit-owned rules
- Unmatched traffic uses a high-rate default class instead of being blocked

## Install

Run on Debian 12 as root:

```bash
curl -fsSL https://raw.githubusercontent.com/sakz/iplimit/main/install.sh | sudo bash
```

The installer installs `bash`, `iproute2`, `conntrack`, `kmod`, and `systemd`,
then places the command at `/usr/local/bin/iplimit`.

You can also install from a clone:

```bash
git clone https://github.com/sakz/iplimit.git
cd iplimit
sudo ./install.sh
```

Installation does not change live traffic control. Start it explicitly after
choosing the rate.

## Use

Open the menu:

```bash
sudo iplimit
```

Or use CLI commands:

```bash
sudo iplimit start 20          # 20 Mbps per client, auto-detect interface
sudo iplimit start 12.5 eth0   # choose a decimal rate and interface
sudo iplimit set 50            # update the rate and restart shaping
sudo iplimit status
sudo iplimit clients
sudo iplimit stop
```

`start` enables the systemd service at boot. `stop` disables it and removes the
root HTB qdisc, IPLimit's ingress redirect, its IFB device, and runtime state.
It does not flush iptables/nftables or delete unrelated filters.

Configuration is stored in `/etc/iplimit.conf`:

```bash
RATE_MBIT="20"
INTERFACE="auto"
IFB_NAME="ifb-iplimit"
POLL_INTERVAL="2"
CLIENT_TTL="300"
UNSHAPED_RATE_MBIT="100000"
EXCLUDE_IPS=""
```

Space-separated addresses in `EXCLUDE_IPS` bypass per-client shaping. After
editing the file, apply it with `sudo iplimit start`.

## How it works

For downloads, packets leave the VPS with the client as the destination, so
IPLimit classifies WAN egress by destination IP. For uploads, it installs a
source-IP ingress filter after discovering a client and redirects only that
client's packets to IFB. Website responses and other unrelated ingress traffic
bypass IFB. Each address gets separate HTB classes in both directions;
`fq_codel` manages the queue inside each class.

IPv4 clients share one exact-match flower priority and IPv6 clients share a
second priority. Each client retains its own filter handle and HTB class. This
avoids a priority chain that grows linearly with the number of clients.

## CPU usage and upgrading from 1.0.0

Version 1.0.0 redirected every ingress packet to IFB, including website
responses received by the proxy. On high-throughput or high-PPS servers that
could produce heavy `ksoftirqd` CPU usage. Version 1.1.0 redirects only upload
packets from discovered client IPs.

Upgrade and restart the active service with the same one-command installer:

```bash
curl -fsSL https://raw.githubusercontent.com/sakz/iplimit/main/install.sh | sudo bash
```

Compare CPU and traffic-control counters before and after upgrading:

```bash
mpstat -P ALL 1
sudo tc -s filter show dev eth0 ingress
sudo tc -s class show dev ifb-iplimit
sudo journalctl -u iplimit.service -n 100 --no-pager
```

Replace `eth0` with the interface shown by `sudo iplimit status`.

The daemon reads the original direction of conntrack entries whose destination
is a global address on the selected interface. That distinguishes inbound
clients from the proxy's separate outbound connections to websites. TCP and UDP
are both discovered; shaping itself is IP-based, so both protocols share that
client's configured ceiling.

## Important limitations

- The VPS must see the real client source IP. If a CDN, load balancer, or another
  proxy connects to this VPS, the kernel only sees that intermediary IP and
  cannot recover an HTTP `X-Forwarded-For` address for `tc`.
- The current release targets Debian 12 with systemd and a Linux kernel that
  provides HTB, `flower`, IFB, and conntrack.
- IPLimit refuses to replace a custom root qdisc such as CAKE, TBF, or an
  existing HTB tree it does not own. Merge configurations manually rather than
  silently overwriting them.
- Applying or removing a root qdisc changes queueing on the interface. Existing
  connections are not deliberately dropped, but always keep a second console
  available when changing remote networking.
- Per-IP classes are created after the daemon observes a conntrack entry. The
  first few packets before the next poll are unshaped; unrelated ingress traffic
  never enters IFB.

## Troubleshooting

```bash
sudo iplimit status
sudo journalctl -u iplimit.service -n 100 --no-pager
sudo tc -s class show dev eth0
sudo conntrack -L -f ipv4 -o extended
```

If the service cannot start, it cleans up the state it created. `sudo iplimit
stop` is idempotent and can also remove stale IPLimit state after a crash.

## Uninstall

```bash
sudo iplimit stop
sudo rm -f /usr/local/bin/iplimit
sudo rm -f /etc/systemd/system/iplimit.service
sudo rm -f /etc/iplimit.conf
sudo systemctl daemon-reload
```

Dependencies are intentionally left installed because other networking tools
may use them.

## License

MIT
