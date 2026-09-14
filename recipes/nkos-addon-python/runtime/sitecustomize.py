"""Default base-runtime pip installs to persistent addon data, never OS files."""
import os
import site
import sys

if sys.prefix == sys.base_prefix and site.ENABLE_USER_SITE:
    base = os.environ.setdefault('PYTHONUSERBASE', '/data/python')
    site.USER_BASE = base
    site.USER_SITE = os.path.join(base, 'lib', 'python%d.%d' % sys.version_info[:2], 'site-packages')
    if os.path.isdir(site.USER_SITE):
        site.addsitedir(site.USER_SITE)
    os.environ.setdefault('PIP_USER', 'true')
    os.environ.setdefault('PIP_CACHE_DIR', os.path.join(base, 'cache', 'pip'))
