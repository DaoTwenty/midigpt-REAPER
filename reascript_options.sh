python3 - <<'EOF'
import sysconfig, pathlib
libdir = pathlib.Path(sysconfig.get_config_var("LIBDIR"))
print(f"Python DLL path: {libdir}")
for p in libdir.glob("libpython*.dylib"):
    print(f"Python .dylib filename: {p.name}")
EOF