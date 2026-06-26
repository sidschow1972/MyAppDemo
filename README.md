# MyApp.Web — App Service deployment reference project

This is a minimal, working version of everything discussed in TCS interview prep:
a .NET 8 web app, the Terraform that provisions its App Service target (with a
staging slot), and the Azure DevOps pipeline that deploys to staging and swaps
into production.

## How to open in Visual Studio

1. Unzip this folder.
2. Double-click `MyApp.Web.sln` — Visual Studio opens the solution.
3. Press F5 (or Ctrl+F5) to run locally. It launches to `/health`, which
   returns a JSON status — that's the same endpoint the pipeline's smoke test
   hits against the staging slot before swap.
4. `appsettings.json` has empty `KeyVaultUri` and `ApplicationInsights` values
   on purpose — those get populated by the real values once deployed (set as
   App Service application settings, sourced from the Terraform outputs), not
   committed to source control.

## What's in here and how it maps to what we covered

| File | Purpose |
|---|---|
| `MyApp.Web/Program.cs` | The app itself — wires up Key Vault config via managed identity, App Insights, and exposes `/health` for the smoke test |
| `MyApp.Web/MyApp.Web.csproj` | Project file, .NET 8, references for Key Vault + App Insights |
| `infra/main.tf` | Resource Group, App Service Plan (Premium, for slots), the App Service, the staging slot, Key Vault, App Insights |
| `infra/providers.tf` | Terraform/provider version pinning |
| `azure-pipelines.yml` | Build → deploy to staging → smoke test → swap to production |

## Running the Terraform (when you're ready to actually deploy)

```bash
cd infra
terraform init
terraform plan
terraform apply
```

This provisions everything *except* the app code itself — that's the
pipeline's job. Infrastructure and code deployment are deliberately separate
concerns here, same as in a real migration.

## The sequence, end to end

1. `terraform apply` — stands up the Plan, App Service, staging slot, Key Vault, App Insights
2. Push code to `main` — pipeline builds and deploys to the **staging** slot only
3. Pipeline runs a smoke test against the staging URL
4. If it passes, pipeline swaps staging into production — this is the cutover
5. If something's wrong post-swap, the same swap action run in reverse is the rollback

## Note on GitHub Actions

If you're deploying from GitHub instead of Azure DevOps, the commented-out
block at the bottom of `infra/main.tf` sets up an OIDC federated identity —
uncomment it, fill in your org/repo, and swap `azure-pipelines.yml` for an
equivalent `.github/workflows/deploy.yml` using `azure/webapps-deploy@v3` and
`az webapp deployment slot swap` for the swap step (covered earlier in this
conversation).
