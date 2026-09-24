# Local HTTPS access

`https://template-test-1.dev.platform.local/` (and prod's equivalent) work as
real, browser-trustable URLs from this Mac. Getting there needs one-time
host-level setup beyond `make bootstrap`/`terraform apply` -- this is
deliberate, not an oversight: it configures the Mac itself, not any cluster,
so it's outside what Terraform/GitOps can own (see CLAUDE.md's Architecture
Principles). `make up` runs all of it in one command; this doc explains what
that command actually does and why each piece exists, for when something
needs debugging or redoing by hand.

## The chain

```
curl https://template-test-1.dev.platform.local:<nodePort>/
  -> macOS resolver: *.platform.local -> dnsmasq (127.0.0.2:53)
  -> dnsmasq: dev.platform.local -> <dev's Kind node IP, e.g. 172.18.0.2>
  -> Mac's routing table: 172.18.0.0/16 -> docker-mac-net-connect's WireGuard tunnel
  -> Istio Gateway (NodePort Service on that node) -> HTTPRoute -> app
```

The `<nodePort>` suffix is unavoidable, not an oversight: Milestone 6
dropped MetalLB (confirmed live it was 4 pods / 8 containers with zero
`resources` set on any of them -- unbounded, this project's recurring
failure pattern) in favor of Istio's native `networking.istio.io/
service-type: NodePort` annotation on the Gateway
(`platform/gateway-api/examples/gateway.yaml`). DNS has no way to encode a
port, so both `scripts/sync-monitoring-targets.sh` and
`scripts/setup-local-dns.sh` read the live nodePort (`kubectl get svc
demo-gateway-istio -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}'`)
the same way they already read the node's container IP -- see either
script's comments for the full reasoning, including why
`Gateway.status.addresses` can't be used instead (it reports a
cluster-internal Service hostname once the generated Service isn't type
LoadBalancer, confirmed live).

Three independent things have to work for that to succeed, and each maps to
one script:

### 1. `scripts/setup-mac-networking.sh` -- Mac to Docker network routing

Docker Desktop for Mac runs containers inside a VM. By default, **the Mac's
own network stack has no route into that VM's bridge networks** (confirmed
live this session: no route in the routing table, no interface, a direct
`curl` to a live container IP just times out, even though the Mac's normal
internet access works fine in the same test). This is different from Docker
on native Linux, where the bridge lives directly on the host's network
stack -- on Mac, Docker Desktop simply doesn't expose it, by design.

Fix: [`docker-mac-net-connect`](https://github.com/chipmk/docker-mac-net-connect)
(installed via `brew install chipmk/tap/docker-mac-net-connect`), a
WireGuard-based bridge that adds real routes from the Mac into Docker's
networks. It has to run as a **root** background service, because creating
the WireGuard TUN device needs root:

```
sudo brew services start docker-mac-net-connect
```

A plain (non-sudo) `brew services start` looks like it succeeds but doesn't:
it registers as a user-level LaunchAgent instead of a root LaunchDaemon,
which then fails with `failed to create TUN device: operation not permitted`
(confirmed live via `/opt/homebrew/var/log/docker-mac-net-connect/std_error.log`).
If you've hit that, clean it up first: `brew services stop
docker-mac-net-connect`, then the sudo version.

### 2. `scripts/setup-local-dns.sh` -- resolving `*.{dev,prod}.platform.local`

`dnsmasq` (via Homebrew) resolves `dev.platform.local`/`prod.platform.local`
to each cluster's Kind node container IP, read fresh from `docker inspect`
each run (not hardcoded -- Kind assigns a new IP if a cluster is ever
recreated, same caveat as `scripts/sync-runner-creds.sh`'s container IPs).
The script also prints each cluster's current Gateway nodePort -- DNS can't
carry a port, so that part has to be appended to the URL by hand (or read
by whatever script needs it, same live `kubectl get svc` lookup).

macOS's `/etc/resolver/<domain>` mechanism is what scopes this to just
`*.platform.local` without touching the Mac's system-wide DNS. Two real
quirks here, both confirmed live rather than assumed from docs:

- **`nameserver 127.0.0.1` + a non-53 port silently doesn't work.** This is
  Homebrew's own dnsmasq install caveat, easy to miss: "On current macOS
  releases, `/etc/resolver/<domain>` resolver overrides do not work if the
  nameserver is `127.0.0.1` and dnsmasq is running on a non-53 port." dnsmasq
  itself runs fine on a custom port like 5353 -- it's specifically the
  resolver-override mechanism that ignores the port field when the address is
  the literal loopback `127.0.0.1`.
- **`127.0.0.2` isn't usable without an explicit alias**, despite
  `127.0.0.0/8` nominally being "all loopback" on BSD-derived systems like
  macOS. Verified live: `ping 127.0.0.2` is 100% packet loss until you run
  `sudo ifconfig lo0 alias 127.0.0.2 up`.

So the actual setup is: dnsmasq bound to `127.0.0.2:53` (the standard DNS
port, needing root) with an `/etc/resolver/platform.local` pointing at
`nameserver 127.0.0.2` (no port field needed, since it's the default).

The loopback alias does not survive a reboot -- if DNS stops resolving after
restarting your Mac, re-run this script (or just `sudo ifconfig lo0 alias
127.0.0.2 up` + `sudo brew services restart dnsmasq`).

### 3. `scripts/trust-local-ca.sh` -- trusting the certs

Each cluster runs its own self-signed root CA (cert-manager, Milestone 5
Phase 3 -- see `platform/cert-manager/config-{dev,prod}/root-ca.yaml`; dev
and prod never share one, same as everywhere else in this project). This
script adds both public root certs to the Mac's System keychain
(`security add-trusted-cert`), so `curl`/Safari/Chrome validate the chain
with no `-k`/insecure flag.

Needs re-running after recreating dev or prod: cert-manager generates a
**fresh** key pair every time (private keys are never persisted outside the
cluster, by design -- they never touch Git). The old trusted entry just
becomes stale, not wrong or dangerous (it's a trust decision on a public
cert, not a live credential) -- safe to leave, or remove manually:

```
sudo security delete-certificate -c local-platform-dev-root-ca /Library/Keychains/System.keychain
sudo security delete-certificate -c local-platform-prod-root-ca /Library/Keychains/System.keychain
```

## Why none of this is scriptable non-interactively

Every sudo step here needs a real, interactive password or Touch ID prompt --
this is a deliberate macOS security boundary, not a gap in these scripts.
`scripts/up.sh` runs everything it can non-interactively and only pauses for
the handful of steps that genuinely need your approval (installing/starting
a root network service, binding a port below 1024, adding a trusted root
CA) -- each one is a real privilege escalation onto your actual laptop, so
it should ask.

## Tearing down

`make down` removes both clusters but deliberately leaves the host-level
setup above in place (it's inert with no clusters running, and reusable on
the next `make up` without re-prompting for sudo every cycle).
To remove it too:

```
brew services stop dnsmasq
sudo brew services stop docker-mac-net-connect
sudo rm /etc/resolver/platform.local
sudo security delete-certificate -c local-platform-dev-root-ca /Library/Keychains/System.keychain
sudo security delete-certificate -c local-platform-prod-root-ca /Library/Keychains/System.keychain
```
