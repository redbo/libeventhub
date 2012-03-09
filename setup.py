from setuptools import setup
from setuptools.extension import Extension
try:
    from Cython.Distutils import build_ext
    source = ['libeventhub.pyx']
    cmdclass = {'build_ext': build_ext}
except ImportError:
    source = ['libeventhub.c']
    cmdclass = {}

hub_module = Extension('libeventhub', source, libraries=['event'])

setup(name='libeventhub',
      version='0.1',
      description='Libevent-based hub for eventlet',
      author='Michael Barton',
      author_email='mike@weirdlooking.com',
      url='https://github.com/redbo/libeventhub/',
      license='BSD',
      platforms = ["any"],
      long_description = __doc__,
      cmdclass=cmdclass,
      ext_modules=[hub_module],
      install_requires=['eventlet']
     )
