# ── Stage 1: Build ────────────────────────────────────────────────────────────
# Uses the full .NET 8 SDK image to restore, compile and publish the app.
# This image is ~750MB — we do NOT ship it to production.
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Copy project file first and restore — Docker layer caches this separately
# so a code-only change doesn't re-download all NuGet packages.
COPY MyApp.Web/MyApp.Web.csproj MyApp.Web/
RUN dotnet restore MyApp.Web/MyApp.Web.csproj

# Copy the rest of the source and publish a self-contained Release build
COPY . .
RUN dotnet publish MyApp.Web/MyApp.Web.csproj \
    --configuration Release \
    --output /app/publish \
    --no-restore

# ── Stage 2: Final runtime image ───────────────────────────────────────────────
# Uses only the ASP.NET 8 runtime (~220MB) — no SDK, smaller attack surface,
# faster pull times in the cluster.
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app
COPY --from=build /app/publish .

# ASP.NET Core 8 listens on port 8080 by default when running in a container.
# ASPNETCORE_URLS overrides the default localhost:5000 binding so Kubernetes
# can route traffic to the pod on port 8080.
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080

ENTRYPOINT ["dotnet", "MyApp.Web.dll"]
