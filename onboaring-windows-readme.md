## Windows onboarding (admin rights unnecessary)

This repo includes a PowerShell onboarding script that sets up the tools needed
for working with `.docx` snippet mirrors **without requiring admin privileges**.

The script will:

- Install **Node.js** (ZIP/portable build) into a user-local folder
- Install **Pandoc** (ZIP build) into a user-local folder
- Add both to the **user PATH**
- Run the snippet mirror generator as a quick verification

### Prerequisites

- Windows 10 or later
- PowerShell (the built-in one is fine)
- An internet connection (to download Node + Pandoc ZIPs)

### Running the onboarding script

From the repository root:

```bash
powershell.exe -ExecutionPolicy Bypass -File scripts/onboarding-windows.ps1
```
