// portal-web — greenfield Blazor WebAssembly SPA entry point. The WebAssemblyHostBuilder (NOT
// WebApplication/Host.CreateApplicationBuilder) is the tell: this runs in the browser as a WASM
// bundle, so the scanner must resolve runtime: browser / generatorSupported: false / inScope:
// false and /otel-instrument must refuse it — a server SDK bootstrap cannot run in a bundle.
using Microsoft.AspNetCore.Components.WebAssembly.Hosting;

var builder = WebAssemblyHostBuilder.CreateDefault(args);
builder.RootComponents.Add<App>("#app");
await builder.Build().RunAsync();
