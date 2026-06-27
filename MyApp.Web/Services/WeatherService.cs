using System.Text.Json;
using System.Text.Json.Serialization;
using MyApp.Web.Models;

namespace MyApp.Web.Services;

public class WeatherService
{
    private readonly HttpClient _httpClient;

    private const double Latitude  = 40.7128;
    private const double Longitude = -74.0060;
    private const string Location  = "New York";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower
    };

    public WeatherService(HttpClient httpClient)
    {
        _httpClient = httpClient;
    }

    public async Task<WeatherTrendResponse> GetSixMonthTrendsAsync()
    {
        // Open-Meteo archive has a ~5 day delay so we end 7 days ago to be safe
        var endDate   = DateOnly.FromDateTime(DateTime.UtcNow.AddDays(-7));
        var startDate = endDate.AddMonths(-6);

        var url = "https://archive-api.open-meteo.com/v1/archive" +
                  $"?latitude={Latitude}&longitude={Longitude}" +
                  $"&start_date={startDate:yyyy-MM-dd}&end_date={endDate:yyyy-MM-dd}" +
                  "&daily=temperature_2m_max,temperature_2m_min,precipitation_sum" +
                  "&timezone=America%2FNew_York";

        var json     = await _httpClient.GetStringAsync(url);
        var response = JsonSerializer.Deserialize<OpenMeteoResponse>(json, JsonOptions)!;

        var daily = response.Daily.Time
            .Select((date, i) => new DailyWeatherData(
                DateOnly.Parse(date),
                response.Daily.Temperature2mMax[i] ?? 0,
                response.Daily.Temperature2mMin[i] ?? 0,
                response.Daily.PrecipitationSum[i] ?? 0
            ))
            .ToList();

        var trends = daily
            .GroupBy(d => new { d.Date.Year, d.Date.Month })
            .OrderBy(g => g.Key.Year).ThenBy(g => g.Key.Month)
            .Select(g => new MonthlyTrend(
                new DateTime(g.Key.Year, g.Key.Month, 1).ToString("MMM yyyy"),
                Math.Round(g.Average(d => d.MaxTemp), 1),
                Math.Round(g.Average(d => d.MinTemp), 1),
                Math.Round(g.Sum(d => d.Precipitation), 1)
            ))
            .ToList();

        return new WeatherTrendResponse(Location, trends);
    }
}

// Open-Meteo API response shape
public class OpenMeteoResponse
{
    public OpenMeteoDailyData Daily { get; set; } = new();
}

public class OpenMeteoDailyData
{
    public List<string>  Time               { get; set; } = [];
    public List<double?> Temperature2mMax   { get; set; } = [];
    public List<double?> Temperature2mMin   { get; set; } = [];
    public List<double?> PrecipitationSum   { get; set; } = [];
}
