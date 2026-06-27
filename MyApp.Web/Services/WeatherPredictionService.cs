using MyApp.Web.Models;
using System.Globalization;

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
        var historical = await _weatherService.GetHistoricalTrendsAsync();
        var trends     = historical.Trends;

        // Build a calendar-month baseline (seasonal profile) from all historical data.
        // For each calendar month (Jan=1 .. Dec=12) average every occurrence across years.
        var byCalendarMonth = trends
            .GroupBy(t => ParseMonth(t.Month).Month)
            .ToDictionary(
                g => g.Key,
                g => new
                {
                    AvgMax  = g.Average(t => t.AvgMaxTemp),
                    AvgMin  = g.Average(t => t.AvgMinTemp),
                    AvgPrec = g.Average(t => t.TotalPrecipitation)
                }
            );

        // Compute the year-over-year trend by running OLS on the de-seasonalised residuals.
        // Residual = actual value – seasonal baseline for that calendar month.
        var deseasonMax  = trends.Select(t => t.AvgMaxTemp  - byCalendarMonth[ParseMonth(t.Month).Month].AvgMax).ToList();
        var deseasonMin  = trends.Select(t => t.AvgMinTemp  - byCalendarMonth[ParseMonth(t.Month).Month].AvgMin).ToList();
        var deseasonPrec = trends.Select(t => t.TotalPrecipitation - byCalendarMonth[ParseMonth(t.Month).Month].AvgPrec).ToList();

        var (maxSlope,  maxIntercept)  = LinearRegression(deseasonMax);
        var (minSlope,  minIntercept)  = LinearRegression(deseasonMin);
        var (precSlope, precIntercept) = LinearRegression(deseasonPrec);

        var lastMonth = ParseMonth(trends.Last().Month);
        int n         = trends.Count;

        var predictions = new List<MonthlyPrediction>();
        for (int i = 1; i <= 6; i++)
        {
            int futureIndex    = n - 1 + i;
            var futureMonth    = lastMonth.AddMonths(i);
            int calMonth       = futureMonth.Month;

            // Prediction = seasonal baseline + extrapolated de-seasonalised trend
            var seasonal = byCalendarMonth.TryGetValue(calMonth, out var s)
                ? s
                : byCalendarMonth.Values.First();

            var predictedMax  = Math.Round(seasonal.AvgMax  + maxSlope  * futureIndex + maxIntercept,  1);
            var predictedMin  = Math.Round(seasonal.AvgMin  + minSlope  * futureIndex + minIntercept,  1);
            var predictedPrec = Math.Max(0, Math.Round(seasonal.AvgPrec + precSlope * futureIndex + precIntercept, 1));

            predictions.Add(new MonthlyPrediction(
                futureMonth.ToString("MMM yyyy"),
                predictedMax,
                predictedMin,
                predictedPrec,
                ConfidenceLevel(n)
            ));
        }

        // Annualised trend: multiply monthly slope by 12 so it's °C/year
        double annualTempSlope = Math.Round(maxSlope * 12, 3);
        double annualPrecSlope = Math.Round(precSlope * 12, 3);

        var tempTrend = annualTempSlope > 0.3  ? "Warming"
                      : annualTempSlope < -0.3 ? "Cooling"
                      : "Stable";

        var precTrend = annualPrecSlope > 5   ? "Increasing rainfall"
                      : annualPrecSlope < -5  ? "Decreasing rainfall"
                      : "Stable rainfall";

        return new WeatherForecastResponse(
            historical.Location,
            historical.Trends,
            predictions,
            tempTrend,
            precTrend,
            annualTempSlope,
            annualPrecSlope
        );
    }

    // Ordinary least squares: y = slope * x + intercept
    private static (double slope, double intercept) LinearRegression(List<double> values)
    {
        int n    = values.Count;
        double sumX  = n * (n - 1) / 2.0;
        double sumY  = values.Sum();
        double sumXY = values.Select((y, i) => i * y).Sum();
        double sumX2 = Enumerable.Range(0, n).Sum(i => (double)i * i);

        double slope     = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);
        double intercept = (sumY - slope * sumX) / n;

        return (slope, intercept);
    }

    private static string ConfidenceLevel(int dataPoints) =>
        dataPoints >= 18 ? "High" : dataPoints >= 12 ? "Medium" : "Low";

    private static DateTime ParseMonth(string month) =>
        DateTime.ParseExact(month, "MMM yyyy", CultureInfo.InvariantCulture);
}
