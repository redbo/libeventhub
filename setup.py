from distutils.core import setup
from distutils.extension import Extension
try:
    from Cython.Distutils import build_ext
    source = ['libeventhub.pyx']
    cmdclass = {'build_ext': build_ext}
except ImportError:
    source = ['libeventhub.c']
    cmdclass = {}

hub_module = Extension('libeventhub', source, libraries=['event'])

setup(name='libeventhub', cmdclass=cmdclass, ext_modules=[hub_module])

