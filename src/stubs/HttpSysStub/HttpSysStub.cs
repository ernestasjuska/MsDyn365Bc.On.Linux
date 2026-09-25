// Stub for Microsoft.AspNetCore.Server.HttpSys — redirects to Kestrel on Linux.
// BC calls: builder.UseHttpSys(configure) then builder.UseUrls("http://+:7048/BC/api")
// We redirect to Kestrel and use an IStartupFilter to strip URL paths at app startup.
using System;
using System.Linq;
using System.Security.Claims;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Extensions.DependencyInjection;

namespace Microsoft.AspNetCore.Server.HttpSys
{
    public class HttpSysOptions
    {
        public bool AllowSynchronousIO { get; set; }
        public long? MaxConnections { get; set; }
        public int MaxAccepts { get; set; }
        public long? MaxRequestBodySize { get; set; }
        public AuthenticationManager Authentication { get; } = new AuthenticationManager();
        public TimeoutManager Timeouts { get; } = new TimeoutManager();
        public bool ThrowWriteExceptions { get; set; }
        public int RequestQueueLimit { get; set; }
        public string? RequestQueueName { get; set; }
        public bool UnsafePreferInlineScheduling { get; set; }
    }

    public class AuthenticationManager
    {
        public bool AllowAnonymous { get; set; } = true;
        public AuthenticationSchemes Schemes { get; set; } = AuthenticationSchemes.None;
        public bool AutomaticAuthentication { get; set; }
    }

    public class TimeoutManager
    {
        public TimeSpan IdleConnection { get; set; }
        public TimeSpan EntityBody { get; set; }
        public TimeSpan DrainEntityBody { get; set; }
        public TimeSpan RequestQueue { get; set; }
        public TimeSpan HeaderWait { get; set; }
        public long MinSendBytesPerSecond { get; set; }
    }

    [Flags]
    public enum AuthenticationSchemes
    {
        None = 0, Basic = 1, Anonymous = 2, NTLM = 4, Negotiate = 8, Kerberos = 16,
    }
}

namespace Microsoft.AspNetCore.Hosting
{
    public static class WebHostBuilderHttpSysExtensions
    {
        private static readonly System.Collections.Generic.HashSet<int> _boundPorts = new();

        public static IWebHostBuilder UseHttpSys(this IWebHostBuilder builder,
            Action<Microsoft.AspNetCore.Server.HttpSys.HttpSysOptions> configure)
        {
            var opts = new Microsoft.AspNetCore.Server.HttpSys.HttpSysOptions();
            configure?.Invoke(opts);

            builder.UseKestrel(k =>
            {
                k.AllowSynchronousIO = opts.AllowSynchronousIO;
                if (opts.MaxRequestBodySize.HasValue)
                    k.Limits.MaxRequestBodySize = opts.MaxRequestBodySize;

                // Serve TLS directly when a certificate is supplied, so an https://
                // binding in hosting.json works. Kestrel would otherwise reach for the
                // dotnet developer certificate and abort with "Unable to configure HTTPS
                // endpoint". The ASPNETCORE_Kestrel__Certificates__* configuration path
                // is not an option here: BC builds its host without binding that section.
                //
                // This is what lets a proxy re-terminate TLS at the container instead of
                // forwarding plain HTTP, which in turn means the app sees the real scheme
                // natively rather than inferring it from X-Forwarded-Proto.
                var pfx = Environment.GetEnvironmentVariable("HTTPSYS_STUB_HTTPS_PFX");
                if (!string.IsNullOrEmpty(pfx) && System.IO.File.Exists(pfx))
                {
                    var pwd = Environment.GetEnvironmentVariable("HTTPSYS_STUB_HTTPS_PFX_PASSWORD") ?? string.Empty;
#if NET9_0_OR_GREATER
                    var cert = X509CertificateLoader.LoadPkcs12FromFile(pfx, pwd);
#else
                    var cert = new X509Certificate2(pfx, pwd);
#endif
                    k.ConfigureHttpsDefaults(h => h.ServerCertificate = cert);
                    Console.WriteLine($"[HttpSysStub] HTTPS certificate loaded from {pfx} (subject {cert.Subject})");
                }
            });

            builder.ConfigureServices(services =>
            {
                services.AddSingleton<IStartupFilter>(new UrlStrippingStartupFilter(_boundPorts));
            });

            return builder;
        }

        public static IWebHostBuilder UseHttpSys(this IWebHostBuilder builder)
        {
            return builder.UseKestrel();
        }
    }

    /// <summary>
    /// Startup filter that:
    /// 1. Strips URL paths from server addresses (Kestrel can't handle path-based URLs)
    /// 2. Adds UsePathBase() so BC's middleware routes correctly
    /// 3. Sets admin identity on every request (bypasses auth for all endpoints)
    /// </summary>
    internal class UrlStrippingStartupFilter : IStartupFilter
    {
        private readonly System.Collections.Generic.HashSet<int> _boundPorts;

        public UrlStrippingStartupFilter(System.Collections.Generic.HashSet<int> boundPorts)
        {
            _boundPorts = boundPorts;
        }

        private static string First(string headerValue)
        {
            if (string.IsNullOrEmpty(headerValue)) return string.Empty;
            var comma = headerValue.IndexOf(',');
            return (comma >= 0 ? headerValue.Substring(0, comma) : headerValue).Trim();
        }

        public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next)
        {
            return app =>
            {
                // Strip paths from server addresses before the server starts
                var addressFeature = app.ServerFeatures.Get<IServerAddressesFeature>();
                string? pathBase = null;
                if (addressFeature != null && addressFeature.Addresses.Count > 0)
                {
                    var original = addressFeature.Addresses.ToList();
                    addressFeature.Addresses.Clear();
                    foreach (var addr in original)
                    {
                        var (stripped, path) = StripPath(addr);
                        if (stripped != null)
                        {
                            addressFeature.Addresses.Add(stripped);
                            if (!string.IsNullOrEmpty(path))
                                pathBase = path;
                            Console.WriteLine($"[HttpSysStub] {addr} → {stripped}");
                        }
                    }
                }

                // Rebuild the request's origin from the forwarded headers a
                // TLS-terminating proxy sets, so absolute URLs the app generates
                // (the OIDC redirect_uri above all) name the public address
                // rather than the one Kestrel is bound to. The devtunnel relay
                // rewrites Host to "localhost:<port>" whatever its --host-header
                // setting says, so X-Forwarded-Host is the only place the
                // external hostname survives the hop. Opt-in: the NST has no
                // proxy in front of it and must keep trusting its own address.
                if (Environment.GetEnvironmentVariable("HTTPSYS_STUB_FORWARDED_HEADERS") == "1")
                {
                    app.Use(async (context, nextMiddleware) =>
                    {
                        var headers = context.Request.Headers;
                        var proto = First(headers["X-Forwarded-Proto"].ToString());
                        if (!string.IsNullOrEmpty(proto))
                            context.Request.Scheme = proto;

                        var host = First(headers["X-Forwarded-Host"].ToString());
                        if (!string.IsNullOrEmpty(host))
                        {
                            // X-Forwarded-Port carries the public port. Append it
                            // only when it is not the default for the scheme and
                            // the host does not already spell it out, or the
                            // redirect_uri stops matching the registered one.
                            var port = First(headers["X-Forwarded-Port"].ToString());
                            if (!host.Contains(':') && !string.IsNullOrEmpty(port) &&
                                !(proto == "https" && port == "443") &&
                                !(proto == "http" && port == "80"))
                            {
                                host = host + ":" + port;
                            }
                            context.Request.Host = new HostString(host);
                        }

                        await nextMiddleware();
                    });
                }

                if (!string.IsNullOrEmpty(pathBase))
                    app.UsePathBase(pathBase);

                // Set authenticated admin identity on every request.
                // HTTPSYS_STUB_INJECT_IDENTITY=0 disables this for processes that
                // run their own authentication (e.g. the self-hosted web client,
                // whose forms sign-in must not see a pre-authenticated principal).
                if (Environment.GetEnvironmentVariable("HTTPSYS_STUB_INJECT_IDENTITY") != "0")
                {
                    app.Use(async (context, nextMiddleware) =>
                    {
                        var identity = new ClaimsIdentity(new[] {
                            new Claim(ClaimTypes.Name, "admin"),
                            new Claim(ClaimTypes.Role, "SUPER"),
                            new Claim(ClaimTypes.Role, "AdminService"),
                            new Claim(ClaimTypes.NameIdentifier, "00000000-0000-0000-0000-000000000001"),
                        }, "Passthrough");
                        context.User = new ClaimsPrincipal(identity);
                        await nextMiddleware();
                    });
                }

                next(app);
            };
        }

        private (string? address, string? pathBase) StripPath(string url)
        {
            try
            {
                var parsed = url.Replace("://+:", "://localhost:").Replace("://*:", "://localhost:");
                var uri = new Uri(parsed);
                var scheme = url.Substring(0, url.IndexOf("://"));
                var host = url.Contains("://+:") ? "+" : url.Contains("://*:") ? "*" : uri.Host;
                var port = uri.Port;
                var path = uri.AbsolutePath.TrimEnd('/');

                lock (_boundPorts)
                {
                    if (!_boundPorts.Add(port))
                        while (!_boundPorts.Add(++port)) { }
                }
                return ($"{scheme}://{host}:{port}", string.IsNullOrEmpty(path) || path == "/" ? null : path);
            }
            catch
            {
                return (url, null);
            }
        }
    }
}
