## Windows onboarding (admin rights unnecessary)

This repo includes a PowerShell onboarding script that sets up the tools needed
for working with `.docx` files **without requiring admin privileges**.

The script will:

- Install **Node.js** (ZIP/portable build) into a user-local folder (if not already installed)
  - Setup NPM to access the Nexus package repository
- Install **Pandoc** (ZIP build) into a user-local folder (if not already installed)
- Add both **Node.js** and **Pandoc**to the **user PATH**

### Prerequisites

- `Git for Windows` installed
- Git clone of this repo in Windows
- PowerShell (the built-in one is fine)
- A VPN/internet connection (to download Node + Pandoc ZIPs)

### Running the onboarding script

Open a Windows cmd.exe shell and from the repository root run:

```
scripts\onboarding-windows
```

### Run NPM Install

The onboarding script should have configured everything such that you can now simply run:

```
npm i
```

However, in case manual troubleshooting becomes necessary after running the script, here are the manual steps to consider:

- Make sure that proxy environment variables are set in Windows (HTTP_PROXY and HTTPS_PROXY)
  - In Windows, CTRL+ESC and enter "edit environment variables for your account"
  - If necessary, add the proxy env vars (see the Linux setup for these if you need an example)
  - Alternatively, you can run `setx <ENV_VAR> <VAL>` from the command shell
- Check your current NPM Registry setting:
  - `npm config get registry`
- Configure Nexus (if necessary):
  - `npm config set registry http://your-nexus-url/repository/npm-group/`
- Download the Nexus Cert file to your `C:\Users\<PIN>` folder from:
  - `https://example.com/path/to/your/file.zip"`
- Configure the certificate
  - `npm config set cafile "C:\Users\<PIN>\certificate.pem"`
