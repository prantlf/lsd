# List Duplicates

Lists duplicate files in the specified directory. Duplicates are detected only by comparing their size - the same size means duplicated files.

## Synopsis

```
❯ lsd ../rollup-plugin-serve/test/fixtures
demo.abc  9
demo.fgh  9

❯ LOG_LEVEL=debug zig-out/bin/lsd ../rollup-plugin-serve/test/fixtures
info(lsd): Listing directory: "../rollup-plugin-serve/test/fixtures".
debug(lsd): Found file: "demo.abc"
debug(lsd):  with size: 9
debug(lsd): Found file: "demo.json"
debug(lsd):  with size: 18
debug(lsd): Found file: "demo.fgh"
debug(lsd):  with size: 9
info(lsd): Found 3 files.
demo.abc                                                        	9
demo.fgh                                                        	9
info(lsd): Found 2 duplicate files.
```

## Contributing

In lieu of a formal styleguide, take care to maintain the existing coding style.  Add unit tests for any new or changed functionality. Lint and test your code using Grunt.

## License

Copyright (c) 2026 Ferdinand Prantl

Licensed under the MIT license.
