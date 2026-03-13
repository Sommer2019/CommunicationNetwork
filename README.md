# CommunicationNetwork – Minecraft High Availability (HA) Setup

A complete, production-ready High Availability configuration for a Minecraft network running on **two physically separate Linux dedicated servers** (Node A and Node B).

**Goal:** If Node A (hardware or software) fails completely, players are automatically reconnected to Node B within **≤ 5 seconds** – at the same position, with the same inventory, without manual reconnection.

---

## Architecture Overview

```
Players
  │  (connect to Floating-IP 203.0.113.10:25565)
  ▼
┌─────────────────────────────────────────────────────────┐
│  Keepalived (VRRP) – Floating-IP / VIP                  │
│  Node A (192.168.1.101) ←→ Node B (192.168.1.102)       │
└──────────────────────┬──────────────────────────────────┘
                       │
           ┌───────────▼───────────┐
           │  Velocity Proxy       │  ← always running on the active node
           │  (port 25565)         │    fallback: sends players to lobby
           └───────────┬───────────┘    instead of disconnecting them
                       │
          ┌────────────┴────────────┐
          ▼                         ▼
  ┌──────────────┐         ┌──────────────┐
  │  Survival    │         │  Lobby       │   Paper/Purpur backends
  │  (port 25570)│         │  (port 25571)│   (same ports on both nodes)
  └──────────────┘         └──────────────┘
          │                         │
          └────────────┬────────────┘
                       ▼
           ┌───────────────────────┐
           │  GlusterFS Volume     │   Replicated world files (region data)
           │  /mnt/minecraft/worlds│   MASTER: read-write, BACKUP: read-only
           └───────────────────────┘

           ┌───────────────────────┐
           │  Redis Master→Replica │   Player inventory, position, session
           │  + Redis Sentinel     │   Real-time async replication
           └───────────────────────┘
```

---

## Repository Structure

```
.
├── keepalived/
│   ├── keepalived-node-a.conf   # Keepalived config for Node A (MASTER)
│   ├── keepalived-node-b.conf   # Keepalived config for Node B (BACKUP)
│   ├── check_minecraft.sh       # Health-check: TCP test against Velocity
│   ├── on_master.sh             # Called when a node acquires the VIP
│   ├── on_backup.sh             # Called when a node loses the VIP
│   └── on_fault.sh              # Called when health-check enters FAULT
├── velocity/
│   ├── velocity.toml            # Velocity proxy configuration
│   ├── forwarding.secret        # Shared secret for Paper-native forwarding
│   └── paper-global-snippet.yml # Backend server config snippet
├── redis/
│   ├── redis-master.conf        # Redis master config (Node A)
│   ├── redis-replica.conf       # Redis replica config (Node B)
│   ├── sentinel.conf            # Redis Sentinel (deploy on both nodes)
│   └── husksync-config.yml      # HuskSync plugin config (inventory sync)
├── glusterfs/
│   ├── setup-volume.sh          # One-time GlusterFS volume creation
│   ├── fstab-entries.txt        # /etc/fstab entries for both nodes
│   └── session-lock-guard.sh    # Prevents duplicate session.lock writes
└── scripts/
    ├── failover-watchdog.sh     # Continuous health-check daemon (Node B)
    ├── minecraft-failover.service  # systemd unit for the watchdog
    ├── redis-promote.sh         # Promotes Redis replica to master
    └── failback.sh              # Failback procedure when Node A returns
```

---

## Component 1 – Network Layer: Keepalived / Floating-IP

### What it does
Keepalived runs VRRP between Node A and Node B. One node holds the **Virtual IP (VIP)** `203.0.113.10`; players always connect to this address. When Node A goes down (or its health-check fails), keepalived elects Node B as the new MASTER in ~2 seconds and moves the VIP to Node B's NIC.

### Installation

```bash
# On both nodes
apt install keepalived
```

### Configuration

| File | Deploy to |
|------|-----------|
| `keepalived/keepalived-node-a.conf` | `/etc/keepalived/keepalived.conf` on Node A |
| `keepalived/keepalived-node-b.conf` | `/etc/keepalived/keepalived.conf` on Node B |
| `keepalived/check_minecraft.sh` | `/etc/keepalived/check_minecraft.sh` on both nodes |
| `keepalived/on_master.sh` | `/etc/keepalived/on_master.sh` on both nodes |
| `keepalived/on_backup.sh` | `/etc/keepalived/on_backup.sh` on both nodes |
| `keepalived/on_fault.sh` | `/etc/keepalived/on_fault.sh` on both nodes |

```bash
# Make scripts executable on both nodes
chmod +x /etc/keepalived/*.sh
systemctl enable --now keepalived
```

### Key parameters to change

| Parameter | Location | Description |
|-----------|----------|-------------|
| `auth_pass MinecraftHA2024` | both keepalived configs | Change to a strong shared secret |
| `203.0.113.10` | both configs + scripts | Your actual Floating-IP |
| `192.168.1.101/102` | both configs | Your actual Node IPs |
| `eth0` | both configs | Your actual public NIC name (`ip a`) |

### ⚠️ Race Condition Warning
If both nodes believe they are MASTER simultaneously ("split-brain"), both will run Minecraft pointing at the same world files. The `on_master.sh` / `on_backup.sh` / session.lock guard scripts prevent this, but **ensure the VRRP `auth_pass` is identical on both nodes** – an authentication mismatch is the #1 cause of split-brain.

---

## Component 2 – Proxy Layer: Velocity

### What it does
Velocity acts as the single entry-point proxy. Its **fallback server list** (`try = ["lobby", "survival"]`) means that if a backend crashes, the player is silently moved to the lobby server instead of seeing a disconnect screen. When the VIP moves to Node B, Node B's own Velocity proxy (and backends) are already configured identically and ready to accept players.

### Installation

Download Velocity from [papermc.io/downloads/velocity](https://papermc.io/downloads/velocity) and place in `/opt/velocity/`.

```bash
mkdir -p /opt/velocity
cd /opt/velocity
wget https://api.papermc.io/v2/projects/velocity/versions/latest/builds/latest/downloads/velocity-latest.jar -O velocity.jar
```

### Configuration

Copy `velocity/velocity.toml` to `/opt/velocity/velocity.toml` and adjust:

- `bind` – listening address/port
- `[servers]` – backend server IPs and ports
- `try` – fallback order

Generate a forwarding secret and place it in `velocity/forwarding.secret` (and on each backend in `plugins/HuskSync/config.yml`):

```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```

On every Paper backend, copy `velocity/paper-global-snippet.yml` values into `config/paper-global.yml` and set `online-mode=false` in `server.properties`.

---

## Component 3 – Data Synchronisation: Redis + HuskSync

### What it does
- **Redis master** on Node A stores player data (inventory, position, XP, effects) in memory with AOF persistence.
- **Redis replica** on Node B receives all writes asynchronously in real-time (<1 ms lag on LAN).
- **Redis Sentinel** (one instance per node) monitors the master and promotes the replica automatically during failover.
- **HuskSync** plugin (installed on every Paper backend) uses Redis as a pub/sub channel and MySQL for long-term storage. It applies a per-player mutex to prevent duplicate-write races.

### Installation

```bash
# On both nodes
apt install redis-server
```

### Configuration

| File | Deploy to |
|------|-----------|
| `redis/redis-master.conf` | `/etc/redis/redis.conf` on Node A |
| `redis/redis-replica.conf` | `/etc/redis/redis.conf` on Node B |
| `redis/sentinel.conf` | `/etc/redis/sentinel.conf` on **both** nodes |

```bash
# Node A
systemctl restart redis-server
redis-cli PING   # should return PONG

# Node B
systemctl restart redis-server
redis-cli INFO replication   # should show role:slave, master_link_status:up
```

### Key parameters to change

| Parameter | Files | Description |
|-----------|-------|-------------|
| `CHANGE_ME_STRONG_REDIS_PASSWORD` | all redis configs | Set a strong password (same on both nodes) |
| `192.168.1.101` | replica + sentinel configs | Node A's real IP |
| `192.168.1.102` | redis-master.conf | Node B's real IP |

### HuskSync plugin

Download from [william278.net/project/husksync](https://william278.net/project/husksync) and place in each backend's `plugins/` folder. Copy values from `redis/husksync-config.yml` into `plugins/HuskSync/config.yml`.

### ⚠️ Race Condition Warning
HuskSync uses a Redis-based **data lock** (`lock_duration: 3` seconds in the config). When a player switches servers, their data is locked for 3 seconds to prevent a second server from reading stale data. Ensure `lock_duration` is **less than** your keepalived failover window.

---

## Component 4 – World Synchronisation: GlusterFS

### What it does
GlusterFS creates a **replicated volume** (`replica 2`) that keeps an identical copy of all world files on both nodes simultaneously. Writes go to both bricks synchronously, so there is zero data loss when Node A fails.

The active (MASTER) node mounts the volume **read-write**. The standby (BACKUP) node mounts it **read-only**. The keepalived `on_master.sh` / `on_backup.sh` scripts handle remounting automatically.

### Installation

```bash
# On both nodes
apt install glusterfs-server
systemctl enable --now glusterd
```

### Setup (run once on Node A)

```bash
chmod +x glusterfs/setup-volume.sh
./glusterfs/setup-volume.sh
```

Add `/etc/fstab` entries from `glusterfs/fstab-entries.txt` to both nodes.

### ⚠️ Race Condition Warning – The Most Critical Issue
**If both nodes write to the same world directory simultaneously, the world will be corrupted within minutes.**

Safeguards in this setup:
1. **GlusterFS read-only mount** on the BACKUP node – Minecraft cannot open the world even if it starts accidentally.
2. **session.lock guard** (`glusterfs/session-lock-guard.sh`) – refuses to start Minecraft unless this node holds the VIP.
3. **on_master.sh** removes stale `session.lock` files before starting Minecraft.
4. **on_backup.sh** stops Minecraft *before* remounting read-only.

The order of operations during failover is:
1. Node A goes down (Minecraft stops, GlusterFS brick goes offline)
2. Keepalived detects failure (~2 s) and moves VIP to Node B
3. Node B's `on_master.sh` fires: remounts GlusterFS read-write → removes stale locks → starts Minecraft

---

## Component 5 – Failover Logic

### Automated failover (keepalived + watchdog)

The primary failover mechanism is **keepalived** (VIP moves within ~2 s). The `scripts/failover-watchdog.sh` daemon on Node B provides a secondary layer that activates the Minecraft stack as soon as keepalived has moved the VIP.

```bash
# Deploy on Node B
cp scripts/failover-watchdog.sh /opt/minecraft/scripts/
cp scripts/minecraft-failover.service /etc/systemd/system/
chmod +x /opt/minecraft/scripts/failover-watchdog.sh
systemctl enable --now minecraft-failover
```

### Manual Redis promotion (if Sentinel fails)

```bash
# On Node B, if Redis Sentinel did not auto-promote:
chmod +x scripts/redis-promote.sh
./scripts/redis-promote.sh
```

### Failback (Node A returning to service)

After Node A has been repaired:

```bash
# On Node A
chmod +x scripts/failback.sh
./scripts/failback.sh
# Then monitor keepalived:
journalctl -u keepalived -f
```

---

## End-to-End Failover Timeline

| Time | Event |
|------|-------|
| T+0 s | Node A hardware/OS failure |
| T+0–2 s | Keepalived detects loss of VRRP advertisements from Node A |
| T+2 s | Node B wins VRRP election, VIP moves to Node B's NIC |
| T+2 s | `on_master.sh` fires on Node B: remounts GlusterFS RW, removes session.lock |
| T+3 s | Minecraft backends start on Node B (systemd) |
| T+3 s | Velocity on Node B starts accepting connections |
| T+4 s | Redis Sentinel promotes Node B's replica to master |
| T+4–5 s | Players' TCP connections time out, Velocity's fallback reconnects them to Node B |
| T+5 s | Players are in-game on Node B with correct inventory and position |

---

## Quick-Start Checklist

- [ ] Set unique strong values for `auth_pass` (keepalived), `requirepass` (Redis), and the Velocity forwarding secret
- [ ] Replace all placeholder IPs (`192.168.1.101`, `192.168.1.102`, `203.0.113.10`) with your real addresses
- [ ] Replace `eth0` with your actual NIC name (`ip a`)
- [ ] Install keepalived, Redis, GlusterFS on both nodes
- [ ] Run `glusterfs/setup-volume.sh` on Node A once
- [ ] Deploy Velocity + Paper backends on both nodes identically
- [ ] Install HuskSync on all backends and point it at the local Redis + MySQL
- [ ] Enable and test keepalived: `systemctl enable --now keepalived`
- [ ] Enable the failover watchdog on Node B: `systemctl enable --now minecraft-failover`
- [ ] Test failover: `systemctl stop keepalived` on Node A and verify VIP moves to Node B

---

## License

MIT – see [LICENSE](LICENSE) for details.