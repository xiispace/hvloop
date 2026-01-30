# Tech Stack Upgrade Implementation Plan

> **For Claude:** This plan has been completed. See summary below.

**Goal:** Upgrade hvloop to Python 3.10+, Cython 3.1, scikit-build-core 0.10, and CMake 3.25

**Architecture:** Update build configuration files, classifiers, and documentation to reflect new minimum versions

**Tech Stack:** Python 3.10+, Cython 3.1, scikit-build-core 0.10, CMake 3.25

---

## Summary of Changes

### Completed Changes

#### 1. pyproject.toml Updates
- **scikit-build-core**: `>=0.5.0` → `>=0.10.0`
- **cython**: `>=3.0.0` → `>=3.1.0`
- **requires-python**: `>=3.8` → `>=3.10`
- **version**: `0.1.0` → `0.2.0`
- **pytest**: `>=7.0` → `>=8.0`
- **pytest-asyncio**: added `>=0.23` version constraint
- **classifiers**: Removed 3.8, 3.9; Added 3.10, 3.11, 3.12, 3.13
- **black.target-version**: `['py38']` → `['py310', 'py311', 'py312', 'py313']`
- **ruff.target-version**: `"py38"` → `"py310"`
- **mypy.python_version**: `"3.8"` → `"3.10"`
- **pytest.minversion**: `"7.0"` → `"8.0"`

#### 2. CMakeLists.txt Updates
- **cmake_minimum_required**: `VERSION 3.21` → `VERSION 3.25`

#### 3. README.md Updates
- **python requirement**: `python3.6 or greater` → `Python 3.10 or greater`

#### 4. Cython Compatibility Fixes (prerequisite for upgrade)
The following files were modified to fix Cython 3.x compatibility:

- **src/hvloop/handle.pxd**: Added imports for `htimer_t` and `Loop`
- **src/hvloop/handle.pyx**: Removed nested `cdef:` block in `with gil`
- **src/hvloop/loop.pxd**: Added `_wakeup` declaration; fixed imports
- **src/hvloop/loop.pyx**: Removed `hv.` prefixes from types (using direct imports)
- **src/hvloop/server.pxd**: Added imports for `hio_t` and `Loop`
- **src/hvloop/transport.pxd**: Added imports for `hio_t`, `Loop`, and `Server`

### Verification

Build completed successfully with all updated dependencies:
- scikit-build-core 0.11.6
- Cython 3.x
- CMake 4.1.3
- Python 3.10+ compatibility

---

## Remaining Work (Optional)

### CI/CD Updates
- Update `.github/workflows/` to test on Python 3.10, 3.11, 3.12, 3.13
- Remove Python 3.8, 3.9 from test matrix

### Release Notes
Consider adding a changelog entry noting:
- Breaking change: Python 3.10+ now required
- Upgrade to Cython 3.1 and scikit-build-core 0.10
- Various compatibility improvements
