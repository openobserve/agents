# Agents

Scripts that configure and install the Open Observe agent on various platforms.

The Linux and Windows scripts work on plain hosts and auto-detect AWS EC2, GCP Compute
Engine and Azure VMs, adding cloud resource attributes. On EC2, `host.name` is set from
the instance `Name` tag when the instance has an IAM role with `ec2:DescribeTags` and
can reach the EC2 API; otherwise `host.name` is the OS hostname.

## Linux

### Install

```bash
wget https://raw.githubusercontent.com/openobserve/agents/main/linux/install.sh && chmod +x install.sh && sudo ./install.sh {URL} {authorization_token}
```

e.g.

```bash
wget https://raw.githubusercontent.com/openobserve/agents/main/linux/install.sh && chmod +x install.sh && sudo ./install.sh https://api.openobserve.com/api/your_org/ cm9vdEBleGFtcGxlLmNvbTpDb21wbGV4cGFzcyMxMjM=
```

### Uninstall

```bash
wget https://raw.githubusercontent.com/openobserve/agents/main/linux/uninstall.sh && chmod +x uninstall.sh && sudo ./uninstall.sh
```

## Mac OS X

Collects host metrics, log files from the standard macOS locations, and the macOS
unified log. See [mac/README.md](mac/README.md) for details and tuning.

### Install

macOS does not ship `wget`, so these use `curl`.

```bash
curl -O https://raw.githubusercontent.com/openobserve/agents/main/mac/install.sh && chmod +x install.sh && sudo ./install.sh {URL} {authorization_token}
```

e.g.

```bash
curl -O https://raw.githubusercontent.com/openobserve/agents/main/mac/install.sh && chmod +x install.sh && sudo ./install.sh https://api.openobserve.com/api/your_org/ cm9vdEBleGFtcGxlLmNvbTpDb21wbGV4cGFzcyMxMjM=
```

### Uninstall

```bash
curl -O https://raw.githubusercontent.com/openobserve/agents/main/mac/uninstall.sh && chmod +x uninstall.sh && sudo ./uninstall.sh
```

## Windows

### Install

Requires Windows 10 1803+ or Windows Server 2019+ (for the built-in `tar`). From powershell terminal:

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/openobserve/agents/main/windows/install.ps1 -OutFile install.ps1 ; .\install.ps1 -URL <URL> -AUTH_KEY <Authorization_Key>
```

e.g.

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/openobserve/agents/main/windows/install.ps1 -OutFile install.ps1 ; .\install.ps1 -URL http://localhost:5080/api/default -AUTH_KEY cm9vdEBowWjJSanhscWtSbVB5S0VE
```

The script installs and starts the `otel-collector` Windows service.

![Windows logs](screenshots/windows_logs.png)

### Uninstall

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/openobserve/agents/main/windows/uninstall.ps1 -OutFile uninstall.ps1 ; .\uninstall.ps1
```

