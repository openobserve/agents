Note: Not ready for production use yet.

# Agents

Scripts that configure and install the Open Observe agent on various platforms.

## Linux

### install

```bash
wget https://raw.githubusercontent.com/openobserve/agents/main/linux/install.sh && chmod +x install.sh && sudo ./install.sh {URL} {authorization_token}
```

e.g. 

```bash
wget https://raw.githubusercontent.com/openobserve/agents/main/linux/install.sh && chmod +x install.sh && sudo ./install.sh https://api.openobserve.com/api/your_org/ cm9vdEBleGFtcGxlLmNvbTpDb21wbGV4cGFzcyMxMjM=
``` 

### uninstall

```bash
wget https://raw.githubusercontent.com/openobserve/agents/main/linux/uninstall.sh && chmod +x uninstall.sh && sudo ./uninstall.sh
```

## Windows

### install

```powershell
powershell -Command "Invoke-WebRequest -Uri https://raw.githubusercontent.com/openobserve/agents/main/windows/install.ps1 -OutFile install.ps1" ; install - powershell -ExecutionPolicy Bypass -File .\install.ps1 -URL <URL> -AUTH_KEY <Authorization_Key>
```

### uninstall
```powershell
powershell -Command "Invoke-WebRequest -Uri https://raw.githubusercontent.com/openobserve/agents/main/windows/uninstall.ps1 -OutFile uninstall.ps1" ; powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

