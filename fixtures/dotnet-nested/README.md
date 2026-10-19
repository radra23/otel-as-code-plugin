# dotnet-nested

The layout most real .NET repos use (#182): the solution file at the root, the project below it.

```
svc.sln                 <- the scanner's rootDir is this folder
src/Svc/Svc.csproj
src/Svc/Program.cs      <- runnableEntry
```

An SDK-style project compiles only the `*.cs` files under its own directory. A generated
`OpenTelemetry.cs` written to the root is in no project, so the pasted
`AddOtelObservability` line fails to build; it has to go in `src/Svc/`. The existing
`dotnet-greenfield` fixture is flat (csproj at the root), so it cannot catch this.
`tests/e2e/dotnet-placement.sh` builds this fixture both ways.
