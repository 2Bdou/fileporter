# File Express 📦

A minimalist, secure, and ephemeral file transfer hub.

## Quick Start 🚀

### ⚡ One-Click Cloud Deployment (Highly Recommended)
For a premium, instant VPS or Linux workstation installation, just copy and execute this single command:
```bash
curl -sSfL https://raw.githubusercontent.com/alivedou/FileExpress/v2/fe.sh -o fe.sh && chmod +x fe.sh && ./fe.sh
```
If `curl` is not installed, try `wget`:
```bash
wget -qO fe.sh https://raw.githubusercontent.com/alivedou/FileExpress/v2/fe.sh && chmod +x fe.sh && ./fe.sh
```
This script will guide you to configure environment, manage and run the application daemon cleanly!

### 🐳 Docker / Container Platform Deployment

**VPS (via GHCR pre-built image):**

```bash
docker pull ghcr.io/alivedou/fileexpress:latest
docker run -d --name file-express --restart always \
  -p 3000:3000 \
  -e PORT=3000 \
  -v fileexpress_data:/app/local_storage \
  ghcr.io/alivedou/fileexpress:latest
```

Or use the all-in-one management script:
```bash
curl -sSfL https://raw.githubusercontent.com/alivedou/FileExpress/v2/fe.sh -o fe.sh
chmod +x fe.sh && ./fe.sh
```

**Container Platforms (Railway / DCDeploy / Render / Fly.io):**

Just connect your GitHub repository — the platform auto-detects the `Dockerfile` and injects `PORT`. Zero manual configuration needed. All other variables (storage limits, encryption key, etc.) come with safe defaults.

### 🌱 Bare-Metal Deployment for Low-Memory Machines (`fe-lite.sh`)

Running on a tiny VPS (e.g. **1 vCPU / 256MB RAM / 5GB disk**)? Docker + nginx + certbot can eat most of your memory before File Express even starts. The lite script instead runs File Express as a plain `node` process (no Docker daemon) and replaces nginx+certbot with **Caddy** (automatic HTTPS + auto-renewal, one binary). Total memory footprint: **~135MB**.

```bash
./fe-lite.sh pack                  # 1) build & package — run on any machine with Node 20+
./fe-lite.sh deploy [tar|URL]      # 2) deploy on the small machine (installs Node + Caddy + swap)
./fe-lite.sh status|logs|update|uninstall
```

**Step 1 — Package (on a machine with Node 20+, NOT on the 256MB box):**
```bash
curl -sSfL https://raw.githubusercontent.com/2Bdou/fileporter/v2/fe-lite.sh -o fe-lite.sh && chmod +x fe-lite.sh
./fe-lite.sh pack        # produces fileexpress-lite.tar.gz (~31MB)
```

**Step 2 — Deploy (on the small machine):**
```bash
# copy fe-lite.sh + fileexpress-lite.tar.gz to the small machine, then:
./fe-lite.sh deploy fileexpress-lite.tar.gz
```

The deploy command automatically:
- Creates a **512MB swap** if RAM < 512MB and no swap exists
- Installs the official **Node 22** binary to `/usr/local`
- Extracts to `/opt/fileexpress`, generates `.env` with a **random encryption key**
- Registers a **systemd** service (heap capped at 128MB via `NODE_OPTIONS` to avoid OOM)
- Installs **Caddy**, prompts for your domain → automatic HTTPS + auto-renewal
- Verifies `/api/health` and prints the access URL

> ⚠️ **Never run `npm run build` on a 256MB machine** — Vite needs 300–600MB and will OOM. Always build with `pack` on a bigger machine and deploy the tarball.

> 🔄 `update` keeps your `.env` and uploaded files intact; `uninstall` keeps the data directory too.

### 🛠️ Manual Installation from Source

**1. Install Node.js (Version 22 LTS or 24 Current Recommended)**

*Option A: Via NVM (Recommended)*
```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc # or restart your terminal
nvm install 22
nvm use 22
```

*Option B: Direct Installation (Ubuntu/Debian)*
```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
```

**2. Clone Repository**  
```bash
git clone https://github.com/alivedou/FileExpress.git
cd FileExpress
```

**3. Install Dependencies & Build**  
```bash
npm install
npm run build
```

**4. Run Application & Configuration**  
Make the script executable and run the interactive CLI menu:
```bash
chmod +x fe.sh
./fe.sh
```

> **Configuration (`FE` Menu / `.env` file):**
> File Express can be customized through the CLI menu or directly by editing the `.env` file. Important variables include:
> - `PORT`: Custom port for the server (default `3000`).
> - `MAX_STORAGE_HOURS`: The maximum allowed duration for private files (default `24` hours). Change this value to allow longer ephemeral storage.
> - `MAX_DOWNLOADS`: The maximum allowed extraction count for private files (default `100` times).
> - `MAX_TOTAL_STORAGE_MB`: Overall max disk usage to prevent system overload.

**5. Uninstall Application**  
To permanently remove the application, all stored files, and its background processes, use the built-in self-destruct option:
```bash
./fe.sh
# Select option: 6. 高级选项 (Advanced Options)
# Select option: 2. 完全干净卸载整个应用 (Clean Uninstall)
# Type CONFIRM
```
*Alternatively, you can manually stop the process and delete the directory if needed.*

**6. Deployment Guide**  
You can easily deploy File Express in various robust environments:

- **Local & WSL**: Works perfectly out of the box using `./fe.sh`. You can also enter the Advanced Options to install a global `fe` alias, allowing you to evoke the panel from anywhere securely.
- **VPS Server (Public Node)**: Ideal for a 24/7 public file hub. Utilize the "Background Running" option (Option 4) in the `FE` menu to smoothly daemonize the service on your cloud instance.
- **Cloudflare Tunnel (Zero Trust)**: Highly recommended for exposing the service without opening firewall ports. Simply install `cloudflared` on your WSL or VPS and tunnel the local `http://localhost:<PORT>` securely to your custom domain.

## Security & Protection 🛡️

### Rate Limiting

| Mechanism | Detail |
|-----------|--------|
| IP-based throttle | Max **20 uploads/IP/hour** across all 3 upload routes (`public`, `private`, `batch`) |
| Map memory guard | **10,000 entry cap** + 5-min stale cleanup + 24h full reset |
| Download dedup | **2s window** per IP per file to prevent mobile pre-fetch miscount |

### Storage Safeguards

| Mechanism | Detail |
|-----------|--------|
| Disk fuse | Rejects upload with **503** when partition usage exceeds **80%** |
| Quota enforcement | Auto-purges expired files when total exceeds **90%** of `MAX_TOTAL_STORAGE_MB` |
| File size bounds | Single file ≤10MB, ZIP ≤50MB (configurable via `.env`) |
| TTL cache | Disk check & storage stats cached for **30s** to prevent repetitive I/O |

### Data Security

| Mechanism | Detail |
|-----------|--------|
| AES-256-GCM | Private files encrypted at rest, decrypted on extraction |
| Burn-after-read | Files physically destroyed when download cap or expiry is reached |
| XSS protection | React auto-escapes all user input |
| Command injection | Zero `eval`/`exec`/shell paths for user-supplied content |

### Input Validation

| Mechanism | Detail |
|-----------|--------|
| Public mode | `.txt` only, enforced server-side + frontend `accept` attribute |
| Private mode | Extension whitelist: images, docs, archives |

## FAQ / Troubleshooting

**Q: Styles are missing or WebSocket errors in production?**  
A: This usually happens if the application is running in "Development Mode" on a public server. 
1. Run `npm run build` to generate the production bundle.
2. Run the application using `./fe.sh` or ensure `NODE_ENV=production` is set.
3. If styles still fail, the `base: './'` relative path (configured in V2.5.0) will handle sub-directory or proxy-path issues.

**Q: Google Fonts resetting connection?**  
A: In regions like Mainland China, Google service access is blocked. File Express V2.5.0 uses the `fonts.loli.net` mirror by default to ensure stability.
