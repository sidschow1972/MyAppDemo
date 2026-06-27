using Azure.Identity;
using MyApp.Web.Services;
using MyApp.Web.Models;

var builder = WebApplication.CreateBuilder(args);

// Pull config from Key Vault using the App Service's managed identity.
var keyVaultUri = builder.Configuration["KeyVaultUri"];
if (!string.IsNullOrEmpty(keyVaultUri))
{
    builder.Configuration.AddAzureKeyVault(
        new Uri(keyVaultUri),
        new DefaultAzureCredential());
}

builder.Services.AddApplicationInsightsTelemetry();

// Register WeatherService with an HttpClient
builder.Services.AddHttpClient<WeatherService>();
builder.Services.AddScoped<WeatherPredictionService>();

var app = builder.Build();

app.UseDefaultFiles();
app.UseStaticFiles();

app.MapGet("/health", () => Results.Ok(new { status = "Healthy", timestamp = DateTime.UtcNow }));

app.MapGet("/api/weather/forecast", async (WeatherPredictionService predictor, ILogger<Program> logger) =>
{
    try
    {
        var forecast = await predictor.PredictNextSixMonthsAsync();
        return Results.Ok(forecast);
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Failed to generate weather forecast");
        return Results.Problem(ex.Message);
    }
});

app.MapGet("/api/weather/trends", async (WeatherService weather, ILogger<Program> logger) =>
{
    try
    {
        var trends = await weather.GetSixMonthTrendsAsync();
        return Results.Ok(trends);
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Failed to fetch weather trends");
        return Results.Problem(ex.Message);
    }
});

app.Run();
