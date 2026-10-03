"""One-shot maintenance script: render a markdown file to HTML. No server, no entry point."""
import sys

import markdown

if __name__ == "__main__":
    print(markdown.markdown(open(sys.argv[1]).read()))
