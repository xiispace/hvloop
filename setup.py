# coding:utf-8
import os
import platform
import shutil
import sys
import subprocess

from setuptools import find_packages
from setuptools.command.build_ext import build_ext
from distutils.core import setup, Extension
from distutils import log as logger
from Cython.Build import cythonize

is_x64 = platform.architecture()[0] == '64bit'
is_win = sys.platform.startswith('win')
is_mac = sys.platform.startswith('darwin')
use_openssl = not (is_win or is_mac)

LIBHV_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "vendor", "libhv"))


class hvloop_build_ext(build_ext):

    def build_libhv(self):
        # cmake configure
        cmake_args = [
            LIBHV_DIR,
        ]
        if is_x64:
            cmake_args.append("-DCMAKE_GENERATOR_PLATFORM=x64")

        print(cmake_args)

        subprocess.check_call(["cmake"] + cmake_args, cwd=self.build_temp)

        # cmake build
        subprocess.check_call([
            "cmake", "--build", ".", "--config", "Release", "--target", "libhv_static"],
            cwd=self.build_temp)

    def build_extension(self, *args, **kwargs):
        if not os.path.exists(self.build_temp):
            os.makedirs(self.build_temp)

        build_dir = os.path.abspath(self.build_temp)

        self.build_libhv()

        libhv_lib = os.path.join(build_dir, "lib", "Release", "hv_static.lib")
        if not os.path.exists(libhv_lib):
            raise RuntimeError("failed to build libhv")
        self.extensions[-1].extra_objects.extend([libhv_lib])
        self.compiler.add_include_dir(os.path.join(build_dir, "include", "hv"))

        super().build_extension(*args, **kwargs)


ext_type = Extension(
    "hvloop.loop",
    sources=["hvloop/loop.pyx"],
    language="c",
    define_macros=[('HV_STATICLIB', '1'), ],
)

with open("README.md", "r", encoding="utf-8") as f:
    LONG_DESCRIPTION = f.read()

setup(
    name="hvloop",
    version="0.0.2",
    packages=['hvloop'],
    license="MIT License",
    author="xiispace",
    author_email="xiispace@163.com",
    description="asyncio event loop base on libhv",
    long_description=LONG_DESCRIPTION,
    long_description_content_type="text/markdown",
    url="https://github.com/xiispace/hvloop",
    classifiers=[
        'Development Status :: 1 - Planning',
        'Framework :: AsyncIO',
        'Programming Language :: Python :: 3 :: Only',
        'Programming Language :: Python :: 3.6',
        'Programming Language :: Python :: 3.7',
        'Programming Language :: Python :: 3.8',
        'License :: OSI Approved :: Apache Software License',
        'License :: OSI Approved :: MIT License',
        'Intended Audience :: Developers',
    ],
    cmdclass={
        "build_ext": hvloop_build_ext
    },
    python_requires=">=3.6",
    include_package_data=True,
    ext_modules=cythonize([ext_type], compiler_directives={'language_level': "3"})
)
