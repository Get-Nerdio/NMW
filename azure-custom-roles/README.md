# NME Azure Custom Role - Least-Privilege Permissions

This folder contains the Azure custom role definition for **Nerdio Manager for Enterprise (NME)**.

By default, NME requires Contributor and User Access Administrator on the resource group it manages. For organizations with strict security postures, this custom role provides a least-privilege alternative - scoped to the Azure actions NME performs.

## Files

| File | Description |
|------|-------------|
| `nme-custom-role.json` | Azure custom role definition (JSON) |

## Quick Start

1. Optional: update `AssignableScopes` in `nme-custom-role.json` with your subscription or management group IDs (you must keep at least one scope to create the role).
2. Create the role in your Azure tenant:

```bash
az role definition create --role-definition @nme-custom-role.json
```

3. Assign the role to the NME service principal at each resource group NME manages.
4. Add the app setting `ExtendedConfiguration:RolesExcludedFromAssignmentCheck` = `*` to the NME Web App and restart.

> **Note:** The NME service principal still requires **Reader** at the subscription level regardless of this role.

## Full Documentation

For complete setup instructions, permissions reference, and marketplace installer steps, see the NME Knowledge Base:

**Configure a Least-Privilege Azure Custom Role for NME (link TBD)**
