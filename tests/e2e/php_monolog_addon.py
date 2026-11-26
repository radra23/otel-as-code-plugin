#!/usr/bin/env python3
"""The golden telemetry.php with the generator's Monolog logs add-on, for tests/e2e/log-trace-ids.sh.

usage: php_monolog_addon.py <instrumentation-gen.md> <golden telemetry.php> <out>

The add-on is the php block under "### Logs (Monolog bridge", read out of the generator and put
where it says: after the metrics block, before the providers are registered. Nothing in it is
adjusted, so a block that does not compile or run as written fails the e2e.
"""
import sys

gen, gold, out = sys.argv[1:4]
text = open(gen, encoding="utf-8").read()
section = text[text.index("### Logs (Monolog bridge"):]
block = section[section.index("```php\n") + len("```php\n"):]
block = block[:block.index("```")]
bootstrap = open(gold, encoding="utf-8").read()
anchor = "\\OpenTelemetry\\API\\Globals::registerInitializer(function ($configurator)"
if bootstrap.count(anchor) != 1:
    sys.exit(f"the golden has no single provider registration to put the add-on before: {anchor}")
open(out, "w", encoding="utf-8").write(bootstrap.replace(anchor, block + "\n" + anchor))
