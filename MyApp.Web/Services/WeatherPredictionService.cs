using MyApp.Web.Models;

namespace MyApp.Web.Services;

public class WeatherPredictionService
{
    private readonly WeatherService _weatherService;

    public WeatherPredictionService(WeatherService weatherService)
    {
        _weatherService = weatherService;
    }

    public async Task<WeatherForecastResponse> PredictNextSixMonthsAsync()
    {
        var historical = await _weatherService.GetSixMonthTrendsAsync();
        var trends     = historical.Trends;

        // Use index as x-axis (0,1,2,...,n) and values as y-axis
        var maxTemps = trends.Select(t => t.AvgMaxTemp).ToList();
        var minTemps = trends.Select(t => t.AvgMinTemp).ToList();
        var precips  = trends.Select(t => t.TotalPrecipitation).ToList();

        var (maxSlope, maxIntercept)   = LinearRegression(maxTemps);
        var (minSlope, minIntercept)   = LinearRegression(minTemps);
        var (precSlope, precIntercept) = LinearRegression(precips);

        // Last historical month as starting point for future months
        var lastMonth = ParseMonth(trends.Last().Month);

        var predictions = new List<MonthlyPrediction>();
        for (int i = 1; i <= 6; i++)
        {
            int x = trends.Count - 1 + i;

            var predictedMax  = Math.Round(maxSlope  * x + maxIntercept,  1);
            var predictedMin  = Math.Round(minSlope  * x + minIntercept,  1);
            var predictedPrec = Math.Round(precSlope * x + precIntercept, 1);

            // Clamp precipitation to non-negative
            predictedPrec = Math.Max(0, predictedPrec);

            var month = lastMonth.AddMonths(i).ToString("MMM yyyy");

            predictions.Add(new MonthlyPrediction(
                month,
                predictedMax,
                predictedMin,
                predictedPrec,
                ConfidenceLevel(trends.Count)
            ));
        }

        var tempTrend = maxSlope > 0.1  ? "Warming"
                      : maxSlope < -0.1 ? "Cooling"
                      : "Stable";

        var precTrend = precSlope > 1   ? "Increasing rainfall"
                      : precSlope < -1  ? "Decreasing rainfall"
                      : "Stable rainfall";

        return new WeatherForecastResponse(
            historical.Location,
            historical.Trends,
            predictions,
            tempTrend,
            precTrend,
            Math.Round(maxSlope, 3),
            Math.Round(precSlope, 3)
        );
    }

    // Ordinary least squares linear regression
    // Returns (slope, intercept) for y = slope * x + intercept
    private static (double slope, double intercept) LinearRegression(List<double> values)
    {
        int n   = values.Count;
        var xs  = Enumerable.Range(0, n).Select(i => (double)i).ToList();

        double sumX  = xs.Sum();
        double sumY  = values.Sum();
        double sumXY = xs.Zip(values, (x, y) => x * y).Sum();
        double sumX2 = xs.Sum(x => x * x);

        double slope     = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);
        double intercept = (sumY - slope * sumX) / n;

        return (slope, intercept);
    }

    // Confidence is higher with more data points
    private static string ConfidenceLevel(int dataPoints) =>
        dataPoints >= 6 ? "High" : dataPoints >= 4 ? "Medium" : "Low";

    private static DateTime ParseMonth(string month) =>
        DateTime.ParseExact(month, "MMM yyyy", System.Globalization.CultureInfo.InvariantCulture);
}
