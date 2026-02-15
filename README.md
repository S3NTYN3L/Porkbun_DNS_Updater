# Porkbun DNS Updater
A robust, "strict-mode" Bash utility to synchronize your dynamic public IP (IPv4/IPv6) with Porkbun DNS records.\
Designed for 100% reliability in headless environments like cron or systemd.


- #### :sparkles: Key Features
  - Dual-Stack Ready: Automatically detects and updates both A (IPv4) and AAAA (IPv6) records.
  - Strict Mode Security: Built with `errexit`, `nounset`, and `pipefail` for maximum script stability.
  - Dependency Aware: Verifies the presence of required external utilities to prevent silent failures in minimal or containerized environments.
  - Fail-Safe Logic: Enforces Porkbun’s minimum 600s TTL and applies adjustable API pacing to reduce the risk of rate-limiting.
  - Ambiguity Protection: Safely aborts updates when multiple matching DNS records are detected to prevent unintended data corruption.
  - Atomic Logging: Reverse-ordered, formatted logs with old → new transition tracking and automatic run-based log trimming.


- #### :hammer_and_wrench: Technical Requirements
  - Bash 4.3+: required for `nameref` (`declare -n`) and `mapfile` support
  - curl: HTTPS communication for IP discovery and Porkbun API requests
  - jq: JSON payload construction and API response parsing
  - Core POSIX utilities: `mktemp`, `grep`, `sed`, `tail`, `date` (used for logging, log rotation, and runtime state management)


## :rocket: 1. Installation
  - Clone this repository:

	```bash
	git clone https://github.com/s3ntyn3l/porkbun_dns_updater
	cd porkbun_dns_updater
	chmod +x porkbun_dns_updater.sh

	```

  - Bootstrap the Configuration:
    - Run the script once to generate the `porkbun_dns_updater.env` template:

		```bash
		$ ./porkbun_dns_updater.sh
		SUCCESS: Created configuration template at:
		/home/user/porkbun_dns_updater/porkbun_dns_updater.env

		Please edit the file and rerun the script.

		```


## :gear: 2. Configuration
  - Update the file as described in: `porkbun_dns_updater.env`

	```bash
	# Porkbun DNS Updater Configuration
	# Generated: 2026-01-01 01:02:03
	# =============================================================================

	# API Credentials **REQUIRED** (https://porkbun.com/account/api)
	# -----------------------------------------------------------------------------
	# APIKEY="pk1_..."
	# SECRETAPIKEY="sk1_..."
	APIKEY=""
	SECRETAPIKEY=""
	
	# API Pacing and Log Retention
	# -----------------------------------------------------------------------------
	# API_DELAY : Seconds between API calls (default if empty: 2)
	# MAX_RUNS : Max runs to log (default if empty: 432, 3 days if 10m interval)
	API_DELAY=""
	MAX_RUNS=""

	# Records Format: "subdomain:domain:ttl:ipmode"
	# -----------------------------------------------------------------------------
	# subdomain : '@' (apex), '*' (wildcard), or name (default if empty: @)
	# domain    : base domain (example.com) **REQUIRED**
	# ttl       : time-to-live in seconds (minimum/default if empty: 600)
	# ipmode    : 'v4' (A only), 'v6' (AAAA only), (default if empty: Dual-Stack)
	RECORDS=(
	  "@:example.com::"
	# ":example.com::" also valid for apex
	  "*.example.com::v4"
	  "name:example.com:900:v6"
	)

	```


## :clock1230: 3. Automation (systemd)
  - Create the Service: `/etc/systemd/system/porkbun_dns_updater.service`

	```bash
	[Unit]
	Description=Porkbun DNS Updater Service
	After=network-online.target
	Wants=network-online.target

	[Service]
	Type=oneshot
	RemainAfterExit=no

	# Run as your admin user, not root
	User=youradminusername
	Group=youradminusergroup

	WorkingDirectory=/absolute/path/to
	ExecStart=/absolute/path/to/porkbun_dns_updater.sh
	
	ExecStartPost=/bin/true

	# Optional: Silence systemd journal logs except on error
	# View the script's logfile, porkbun_dns_updater.log, instead
	StandardOutput=null
	StandardError=inherit

	```

> [!Caution]
> Relative paths (e.g., `./script.sh`) or shell shortcuts like `~/` will cause the service to fail.\
> Systemd requires absolute paths (e.g., `/home/user/script.sh`).\
> Always provide the full path to both `ExecStart` and `WorkingDirectory`.

  - Create the Timer:
	`/etc/systemd/system/porkbun_dns_updater.timer`

	```bash
	[Unit]
	Description=Porkbun DNS Updater Timer

	[Timer]
	# Run every 10m starting 5m after the hour to avoid conflicts
	# with system services that run on the hour. (lookin' at you, Cron)
	OnCalendar=*:05/10:00

	OnBootSec=2min
	AccuracySec=5s
	Persistent=true

	[Install]
	WantedBy=timers.target

	```

  - Enable the Timer:

	```bash
	sudo systemctl daemon-reload
	sudo systemctl enable --now porkbun_dns_updater.timer

	```


#### Monitoring & Troubleshooting
  - You can monitor your automation using the following commands:

	```bash
	# Check Next Run:
	systemctl list-timers porkbun_dns_updater.timer

	# Run Manually:
	sudo systemctl start porkbun_dns_updater.service

	```


## :clipboard: Example Log Output
  - `porkbun_dns_updater.log`

	```bash
	=== Starting Porkbun DNS Update ===

	IPv4 Address: 192.0.2.2
	IPv6 Address: 2001:db8::1

	2026-01-01 12:34:56
	@.example.com
		Type   : A
		IP     : 192.0.2.1 > 192.0.2.2
		TTL    : 600
		Result : UPDATED

	2026-01-01 12:34:56
	*.example.com
		Type   : A
		IP     : 192.0.2.2
		TTL    : 600
		Result : CREATED

	2026-01-01 12:34:56
	name.example.com
		Type   : AAAA
		IP     : 2001:db8::1
		TTL    : 900
		Result : UNCHANGED

	=== Porkbun DNS Update Complete ===

	```


## :scroll: License
This project is open-source and available under the [GPL License](LICENSE.md).


## :handshake: Contributing
Found a bug or have a feature request? Please open an issue or submit a pull request!

