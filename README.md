# wireguard-vps

One readable script that turns a fresh **Ubuntu or Debian VPS** into your own **WireGuard VPN server**, with
ready-to-import client configs (and QR codes for the phone app). Add or remove clients later with one command.

```bash
curl -fsSLO https://raw.githubusercontent.com/phantomvps/wireguard-vps/main/wireguard-vps.sh
less wireguard-vps.sh              # read it first: it is short
sudo bash wireguard-vps.sh --clients 3 --qr
```

Then import `/etc/wireguard/clients/client1.conf` into the WireGuard app (desktop), or scan the QR code (phone).

## What it does

| Step | Details |
|---|---|
| Install | `wireguard-tools` and `iptables` from your distribution (`qrencode` with `--qr`) |
| Server keys | created **once** in `/etc/wireguard/server.key`; an existing key is never overwritten |
| Server config | `/etc/wireguard/wg0.conf`, address `10.8.0.1/24`, UDP port `51820` |
| Clients | `client1` ... `clientN` in `/etc/wireguard/clients/`, each with its own key and pre-shared key |
| Forwarding + NAT | `net.ipv4.ip_forward=1` (persistent in `/etc/sysctl.d/`), MASQUERADE via the detected default interface |
| Firewall | if `ufw` is active, opens the UDP port; forwarding rules are added in front of ufw's, so routing works |
| Service | `wg-quick@wg0` is enabled at boot and started |

Running the script again is safe: keys, clients and `wg0.conf` are kept. Adding or removing a client is applied
to the running interface with `wg syncconf`, so other clients stay connected.

## Options

| Option | Default | Meaning |
|---|---|---|
| `--clients N` | `3` | clients to create on the first run (0-250) |
| `--port N` | `51820` | UDP port |
| `--endpoint HOST` | detected IP | public IP or hostname clients connect to; **set it if the server is behind NAT** (the script warns when the detected IP is private) |
| `--subnet A.B.C.0/24` | `10.8.0.0/24` | VPN subnet (a /24) |
| `--dns IP,IP` | `1.1.1.1,9.9.9.9` | DNS servers written into client configs |
| `--wan-if NAME` | detected | network interface used for NAT |
| `--qr` | off | also print each client config as a QR code |
| `--no-start` | off | write everything but do not bring `wg0` up (see below) |
| `--yes` | off | do not ask for confirmation |
| `--add-client NAME` | | add a client (letters, digits, `-`, `_`) and print its config |
| `--remove-client NAME` | | remove a client; its key stops working at once |
| `--show-client NAME` | | print a client config again (with `--qr` as a QR code) |
| `--list-clients` | | list client names |

Port, subnet, endpoint, DNS and interface are saved in `/etc/wireguard/wireguard-vps.env` on the first run; later
runs reuse them (the script warns if you pass different values).

## Safety notes

- Client config files contain **private keys**. They are stored with mode `600` in `/etc/wireguard/clients/`.
  Copy them to your devices over SSH (`scp`) or use the QR code; do not paste them into chats.
- The tunnel carries IPv4. Client configs route `0.0.0.0/0, ::/0` into the tunnel, so IPv6 traffic does not bypass
  the VPN (it is dropped instead; apps fall back to IPv4).
- WireGuard needs kernel support. Most KVM VPS and dedicated servers have it (Linux 5.6+). Some container-based
  VPS (OpenVZ / LXC) do not: there the script stops with a clear message, and `--no-start` lets you create the
  configs anyway.
- It does not touch SSH or enable ufw for you. For a basic firewall, see
  [vps-first-steps](https://github.com/phantomvps/vps-first-steps) (`--allow 51820/udp`).

## Tested on

Every push runs on GitHub Actions on **Ubuntu 22.04 and 24.04**: bad input is refused, full setup with ufw active,
key/config/forwarding/NAT checks, a second run that must not change keys, and adding/removing clients (a freed
address is reused). When the runner kernel loads the `wireguard` module, CI also brings `wg0` up and connects a
test client from a network namespace: it pings the server through the tunnel and reaches the internet through NAT.
If the module cannot be loaded on a runner, CI falls back to `--no-start` and tests config generation only; the
log of each run shows which path ran. Debian 12 / 13 are supported by the script but not tested in CI.

## Need a server?

Maintained by the team behind [PhantomVPS](https://phantomvps.com?ref=github): VPS and dedicated servers with root access,
no ID documents, paid with Monero, Bitcoin, Litecoin, USDT, USDC, SOL or TRX.
See [VPS for your own VPN](https://phantomvps.com/vpn-vps?ref=github).

## License

MIT
