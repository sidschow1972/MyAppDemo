using Azure.Identity;

var builder = WebApplication.CreateBuilder(args);

// Pull config from Key Vault using the App Service's managed identity.
// "KeyVaultUri" matches the app_settings value set in the Terraform azurerm_linux_web_app resource.
var keyVaultUri = builder.Configuration["KeyVaultUri"];
if (!string.IsNullOrEmpty(keyVaultUri))
{
    builder.Configuration.AddAzureKeyVault(
        new Uri(keyVaultUri),
        new DefaultAzureCredential());
}

// Application Insights — connection string comes from app_settings,
// matches azurerm_application_insights in Terraform.
builder.Services.AddApplicationInsightsTelemetry();

var app = builder.Build();

// Health check endpoint — this is what the pipeline's smoke test step
// (curl .../health) hits after deploying to the staging slot, before swap.
app.MapGet("/health", () => Results.Ok(new { status = "Healthy", timestamp = DateTime.UtcNow }));

app.MapGet("/", () => "MyApp is running.");

app.Run();
