Python 3.14 and pip for NanoKVM OS.

python and python3 launch the same interpreter. pip and pip3 launch its pip
module. There is no Python 2 runtime. New login shells discover these commands
through the installed addon bin directory; existing shells can source /etc/profile.

Default pip installs use /data/python/lib/python3.14/site-packages, with scripts
under /data/python/bin. Add that bin directory to PATH to run installed commands.
Addon updates replace the packaged interpreter and pip, preserving /data/python.
SSL trusts the OS certificate store. Source-built native extensions require an
appropriate riscv64/musl toolchain; a wheel for another architecture is not usable.

Use a POSIX filesystem for virtual environments requiring symlinks; /data is
exFAT on the normal SD layout. No Python files are installed in /usr or /bin.
