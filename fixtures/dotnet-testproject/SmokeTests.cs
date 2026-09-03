// Fillr.WebTests — a plain xUnit test class. Note what is ABSENT: no top-level statements, no
// entry point, no generic-host or web-host builder, no DI container. There is nothing for the
// .NET instrumentation generator to extend, which is exactly why the scanner marks this
// generatorSupported: false (see #94) rather than discovering it only when instrumentation-gen
// refuses at generation time.
using Xunit;

public class SmokeTests
{
    [Fact]
    public void ItAdds() => Assert.Equal(4, 2 + 2);
}
