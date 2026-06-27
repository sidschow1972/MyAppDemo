namespace MyApp.Web.Models;

public record DailyWeatherData(
    DateOnly Date,
    double MaxTemp,
    double MinTemp,
    double Precipitation
);

public record MonthlyTrend(
    string Month,
    double AvgMaxTemp,
    double AvgMinTemp,
    double TotalPrecipitation
);

public record WeatherTrendResponse(
    string Location,
    List<MonthlyTrend> Trends
);
