# 🚀 Project Orion

> Enterprise Hybrid Identity & Access Management Home Lab

![Status](https://img.shields.io/badge/Status-In%20Progress-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-5391FE)
![Active Directory](https://img.shields.io/badge/Active%20Directory-Windows%20Server%202025-0078D4)

---

# Overview

Project Orion is an enterprise-style Identity and Access Management (IAM) home lab designed to simulate how organizations manage identities throughout the employee lifecycle.

This project demonstrates Active Directory administration, Role-Based Access Control (RBAC), PowerShell automation, identity governance, and hybrid identity concepts using a realistic enterprise environment.

The goal is to build a portfolio that reflects real-world IAM engineering practices rather than isolated tutorials.

---

# Lab Environment

| Component | Technology |
|---|---|
| Hypervisor | Oracle VirtualBox |
| Server | Windows Server 2025 |
| Directory Services | Active Directory Domain Services |
| DNS | Windows DNS |
| Automation | PowerShell |
| Version Control | Git & GitHub |
| Future Integration | Microsoft Entra ID |

---

# Current Progress

- ✅ Windows Server 2025 deployed
- ✅ Active Directory Domain Services installed
- ✅ Domain controller promoted
- ✅ Enterprise OU structure created
- ✅ Department security groups created
- ✅ Sample users created
- ✅ CSV-driven user provisioning
- ✅ Automated RBAC and access assignment
- ✅ Automated employee offboarding
- ✅ Automated employee transfer workflow
- 🚧 Joiner-Mover-Leaver lifecycle automation
- ⏳ Hybrid Microsoft Entra ID

---

# Repository Structure

```text
Project-Orion
│
├── data
├── diagrams
├── docs
├── logs
├── powershell
├── screenshots
└── README.md
```

---

# 🌑 Automated Employee Offboarding

Project Orion includes a PowerShell-driven leaver workflow that securely removes access when an employee leaves Northstar Aerospace Systems.

The workflow:

- Locates employees by `SamAccountName`
- Blocks built-in and privileged administrator accounts
- Supports safe validation with `-WhatIf`
- Disables the Active Directory account
- Removes all non-default security-group memberships
- Preserves the required `Domain Users` membership
- Records the termination date and reason
- Moves the account into the `Disabled Accounts` OU
- Logs completed actions for review

## Validation Evidence

### Safe Preview

![Offboarding WhatIf preview](screenshots/20-offboarding-whatif-preview.png)

*PowerShell `-WhatIf` preview of account disablement, access removal, description updates, and OU relocation.*

### Successful Execution

![Successful offboarding](screenshots/21-offboarding-completed.png)

*Successful automated offboarding of a non-privileged lab account.*

### Post-Offboarding Verification

![Post-offboarding verification](screenshots/22-offboarding-verification.png)

*Validation confirming the account is disabled, documented, relocated, and retains only its default domain membership.*

---

# 🛰️ Automated Employee Transfers

Project Orion includes a PowerShell-driven Mover workflow for securely transferring employees between departments.

The workflow:

- Locates employees by `SamAccountName`
- Blocks disabled and privileged accounts
- Validates the destination OU and security group
- Supports safe testing with `-WhatIf`
- Removes the previous department group
- Adds the destination department group
- Updates the employee's department and title
- Moves the account into the destination OU
- Preserves approved baseline access for review
- Logs completed transfer actions

## Transfer Validation Evidence

### Pre-Transfer Account State

![Pre-transfer account state](screenshots/23-mover-pre-transfer-account.png)

*Validation of the employee's original Engineering department, title, and OU placement.*

### Safe Transfer Preview

![Mover WhatIf preview](screenshots/24-mover-whatif-preview.png)

*PowerShell `-WhatIf` preview of department-group replacement, attribute updates, and OU relocation.*

### Successful Transfer

![Successful employee transfer](screenshots/25-mover-transfer-completed.png)

*Successful execution of the Engineering-to-Finance employee transfer.*

### Post-Transfer Verification

![Post-transfer verification](screenshots/26-mover-transfer-verification.png)

*Validation confirming the Finance department, updated title, correct OU placement, new department group, and preserved baseline access.*

---

# Project Roadmap

## Phase 1 — Identity Foundation

- [x] Install Windows Server
- [x] Deploy Active Directory
- [x] Create enterprise OU structure
- [x] Implement department security groups

## Phase 2 — Automated Provisioning

- [x] Automate user provisioning
- [x] Import employee data from CSV
- [x] Automate department and access-group membership

## Phase 3 — Identity Lifecycle

- [ ] Joiner process
- [x] Mover process
- [x] Leaver process

## Phase 4 — Governance and Hybrid Identity

- [ ] Active Directory auditing
- [ ] Identity governance reports
- [ ] Microsoft Entra ID integration

---

# Skills Demonstrated

- Active Directory administration
- Identity and Access Management
- Role-Based Access Control design
- PowerShell automation
- Joiner-Mover-Leaver lifecycle management
- Windows Server administration
- DNS administration
- Git and GitHub documentation

---

## Author

Built by Devian Eddins as part of an Identity & Access Management portfolio.
