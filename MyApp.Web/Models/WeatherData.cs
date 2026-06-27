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

public record MonthlyPrediction(
    string Month,
    double PredictedMaxTemp,
    double PredictedMinTemp,
    double PredictedPrecipitation,
    string Confidence
);

public record WeatherForecastResponse(
    string Location,
    List<MonthlyTrend> Historical,
    List<MonthlyPrediction> Predictions,
    string TemperatureTrend,
    string PrecipitationTrend,
    double TemperatureSlope,
    double PrecipitationSlope
);
