Compile both Swift hook binaries with optimization enabled.

Run these commands sequentially:
```bash
cd hooks && swiftc -O -framework AppKit -o claude-approve claude-approve.swift
cd hooks && swiftc -O -framework AppKit -o claude-stop claude-stop.swift
```

After compilation, verify both binaries were produced and report their sizes.
