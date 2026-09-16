using Azure.Identity;
using Azure.Security.KeyVault.Certificates;
using JwtIssuer.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var host = new HostBuilder()
    .ConfigureFunctionsWebApplication()
    .ConfigureServices((context, services) =>
    {
        var keyVaultUri = context.Configuration["KeyVaultUri"]
            ?? throw new InvalidOperationException("KeyVaultUri app setting is required.");

        var credential = new DefaultAzureCredential();

        services.AddSingleton(credential);
        services.AddSingleton<Azure.Core.TokenCredential>(credential);
        services.AddSingleton(new CertificateClient(new Uri(keyVaultUri), credential));
        services.AddSingleton<CryptographyClientFactory>();
        services.AddSingleton<IKeyVaultCertificateService, KeyVaultCertificateService>();
        services.AddSingleton<IJwtSigningService, JwtSigningService>();
    })
    .Build();

host.Run();
